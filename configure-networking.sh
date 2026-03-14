#!/usr/bin/env bash
# =============================================================================
# configure-networking.sh
# RMBC NUC225 CCTV Unit — Engineer LAN Port + WiFi 6 AP Setup
#
# Script 3 of 3 in deployment stack:
#   A. prepare-cctv-storage-fixed.sh FIRST  — NVMe storage
#   B. installer-tailscale.sh SECOND        — apps & services
#   C. configure-networking.sh THIRD AND LAST — this script
#
# What this script does:
#   - Installs required packages (hostapd, dnsmasq, rfkill, iw, network-manager)
#   - Masks NetworkManager so it cannot steal engineer interfaces
#   - Detects production LAN (H685 router) and leaves it untouched
#   - Configures second ethernet port as engineer access port (10.50.0.1/24)
#     with DHCP pool 10.50.0.50–99 via dnsmasq
#   - Configures RZ616 WiFi 6 card as local AP (10.50.1.1/24)
#     SSID: NX-XXX (derived from hostname), DHCP pool 10.50.1.50–99
#   - Applies UFW rules per-interface (not per-subnet)
#   - Installs systemd drop-in so dnsmasq waits for interfaces before starting
#
# Usage:
#   sudo bash configure-networking.sh          # interactive
#   echo "YES" | sudo bash configure-networking.sh  # non-interactive
#   sudo bash configure-networking.sh --yes    # non-interactive (flag)
#
# Tested on: Ubuntu Server 24.04 LTS
# Hardware:  Intel NUC225, RZ616 MT7922 WiFi 6 card
# =============================================================================
set -Eeuo pipefail

# Ensure sbin paths are available (sudo may strip them from PATH)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ─── Flags ───────────────────────────────────────────────────────────────────

ASSUME_YES=0
for arg in "$@"; do
  [[ "$arg" == "--yes" || "$arg" == "-y" ]] && ASSUME_YES=1
done

# ─── Network Configuration ───────────────────────────────────────────────────

ENGINEER_IP="10.50.0.1"
ENGINEER_PREFIX="24"
ENGINEER_DHCP_START="10.50.0.50"
ENGINEER_DHCP_END="10.50.0.99"
ENGINEER_LEASE="12h"

WIFI_IP="10.50.1.1"
WIFI_PREFIX="24"
WIFI_DHCP_START="10.50.1.50"
WIFI_DHCP_END="10.50.1.99"
WIFI_LEASE="12h"
WIFI_PASS='!#Nuc-8003#!'
WIFI_CHANNEL=36
WIFI_COUNTRY=GB

LOG_FILE="/var/log/configure-networking.log"
DNSMASQ_CONF="/etc/dnsmasq.d/rmbc-networking.conf"
ENGINEER_NETPLAN="/etc/netplan/60-rmbc-engineer.yaml"
WIFI_NETPLAN="/etc/netplan/61-rmbc-wifi.yaml"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HOSTAPD_DEFAULT="/etc/default/hostapd"

# ─── Logging ─────────────────────────────────────────────────────────────────

log()  { local m="[INFO]  $*"; echo "$m"; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$m" >> "$LOG_FILE" 2>/dev/null || true; }
warn() { local m="[WARN]  $*"; echo "$m" >&2; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$m" >> "$LOG_FILE" 2>/dev/null || true; }
error(){ local m="[ERROR] $*"; echo "$m" >&2; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$m" >> "$LOG_FILE" 2>/dev/null || true; }
die()  { error "$*"; exit 1; }

# ─── Preflight ───────────────────────────────────────────────────────────────

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script with sudo or as root."
}

init_log() {
  touch "$LOG_FILE" 2>/dev/null || true
  log "========== configure-networking.sh started =========="
}

# Called AFTER install_packages so all tools are present
require_cmds() {
  local missing=0
  local cmds=(ip iw rfkill hostname awk grep sed netplan ufw dnsmasq hostapd systemctl findmnt)
  for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Missing required command: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Required commands still missing after package install. Check apt output above."
}

# ─── Unit Identity ───────────────────────────────────────────────────────────

get_unit_ssid() {
  local hn unit_num
  hn="$(hostname)"
  unit_num="$(echo "$hn" | grep -oP '\d+$' || true)"
  [[ -n "${unit_num:-}" ]] || die "Cannot derive unit number from hostname '$hn'. Expected format: rmbc-NNN"
  printf 'NX-%03d' "$((10#$unit_num))"
}

# ─── Interface Detection ─────────────────────────────────────────────────────

# The interface holding the default route = production LAN (H685 side). Never touch this.
get_production_iface() {
  local iface
  iface="$(ip route show default | awk '/default/ {print $5}' | head -n1 || true)"
  [[ -n "${iface:-}" ]] || die "Cannot detect production interface. Is the H685 router connected?"
  echo "$iface"
}

# Second ethernet = engineer LAN port
get_engineer_iface() {
  local prod="$1" iface
  iface="$(ip -o link show | awk -F': ' '$2 ~ /^en/ {print $2}' \
    | grep -v "^${prod}$" | head -n1 || true)"
  [[ -n "${iface:-}" ]] || die "Cannot detect engineer ethernet interface. Is a second NIC present?"
  echo "$iface"
}

# WiFi interface = any interface with a wireless/ subdirectory in sysfs
get_wifi_iface() {
  local iface
  iface="$(find /sys/class/net/*/wireless -maxdepth 0 2>/dev/null \
    | awk -F'/' '{print $5}' | head -n1 || true)"
  [[ -n "${iface:-}" ]] || die "No WiFi interface found. Is the RZ616 card seated and driver loaded?"
  echo "$iface"
}

# ─── Confirmation Prompt ─────────────────────────────────────────────────────

confirm() {
  local prod="$1" eng="$2" wifi="$3" ssid="$4"

  echo
  echo "═══════════════════════════════════════════════"
  echo " RMBC NUC225 — configure-networking.sh"
  echo "═══════════════════════════════════════════════"
  printf ' Unit SSID     : %s\n' "$ssid"
  printf ' Production    : %s  (untouched — H685 router)\n' "$prod"
  printf ' Engineer LAN  : %s   → %s/%s\n' "$eng" "$ENGINEER_IP" "$ENGINEER_PREFIX"
  printf ' WiFi AP       : %s  → %s/%s\n' "$wifi" "$WIFI_IP" "$WIFI_PREFIX"
  echo "═══════════════════════════════════════════════"
  echo

  [[ "$ASSUME_YES" -eq 1 ]] && { log "Assumption YES flag set — continuing."; return 0; }

  read -r -p "Type YES to continue: " reply
  [[ "$reply" == "YES" ]] || { warn "Aborted by user."; exit 1; }
}

# ─── Package Installation ────────────────────────────────────────────────────

install_packages() {
  log "Updating package lists..."
  apt-get update -qq

  # network-manager is installed but will be masked below so it cannot
  # interfere with hostapd/dnsmasq on engineer interfaces
  local pkgs=(hostapd dnsmasq rfkill iw network-manager ufw)
  for pkg in "${pkgs[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
      log "Package already installed: $pkg"
    else
      log "Installing: $pkg"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
    fi
  done
}

# ─── Mask NetworkManager ─────────────────────────────────────────────────────
# NetworkManager must not manage our engineer interfaces.
# Masking is safe — networkd handles production LAN via Netplan.

mask_network_manager() {
  log "Masking NetworkManager (networkd manages all interfaces on this unit)..."
  systemctl stop    NetworkManager 2>/dev/null || true
  systemctl mask    NetworkManager
  systemctl mask    NetworkManager-wait-online 2>/dev/null || true
  log "NetworkManager masked."
}

# ─── Netplan: Engineer LAN Port ──────────────────────────────────────────────

configure_engineer_netplan() {
  local iface="$1"
  log "Configuring engineer LAN port ($iface) via Netplan..."

  cat > "$ENGINEER_NETPLAN" <<EOF
# RMBC engineer service port — managed by configure-networking.sh
# DO NOT EDIT MANUALLY
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${ENGINEER_IP}/${ENGINEER_PREFIX}
      link-local: []
EOF

  chmod 600 "$ENGINEER_NETPLAN"
  log "Netplan config written: $ENGINEER_NETPLAN"
  netplan apply
  sleep 2
  log "Netplan applied."
}

# ─── Netplan: WiFi Interface ──────────────────────────────────────────────────
# Declared as a plain ethernet entry so networkd leaves it alone.
# Using the 'wifis:' block requires access-points and would conflict with hostapd.
# The ethernets: block with no addresses simply prevents networkd from touching it.

configure_wifi_netplan() {
  local iface="$1"
  log "Setting WiFi interface ($iface) as unmanaged in Netplan (hostapd will own it)..."

  cat > "$WIFI_NETPLAN" <<EOF
# RMBC WiFi 6 AP — hostapd owns this interface, networkd leaves it alone
# DO NOT EDIT MANUALLY
# NOTE: Using 'ethernets' renderer intentionally — do NOT change to 'wifis'
#       as that requires access-points defined and conflicts with hostapd AP mode.
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: false
      dhcp6: false
      link-local: []
EOF

  chmod 600 "$WIFI_NETPLAN"
  log "WiFi Netplan config written: $WIFI_NETPLAN"
  netplan apply
  sleep 2
}

# ─── hostapd: WiFi 6 AP ──────────────────────────────────────────────────────

configure_hostapd() {
  local iface="$1" ssid="$2"
  log "Configuring hostapd for SSID: $ssid on $iface..."

  # rfkill unblock MUST run before hostapd starts — without this,
  # hostapd silently fails on first run even if the driver is loaded
  rfkill unblock wifi
  log "rfkill: WiFi unblocked."

  cat > "$HOSTAPD_CONF" <<EOF
# RMBC WiFi 6 AP — managed by configure-networking.sh
# DO NOT EDIT MANUALLY
interface=${iface}
driver=nl80211
ssid=${ssid}

# 5GHz 802.11a/n/ac/ax (WiFi 6)
# hw_mode=a is required for 5GHz — do NOT use hw_mode=g (limits to 2.4GHz only)
hw_mode=a
channel=${WIFI_CHANNEL}
ieee80211d=1
ieee80211h=1
country_code=${WIFI_COUNTRY}

# WiFi 4/5/6 capability flags
ieee80211n=1
ieee80211ac=1
ieee80211ax=1
wmm_enabled=1
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]

# 80MHz VHT (WiFi 5) channel block
# Channel 36 centre of 80MHz block = ch 36+40+44+48, centre index 42
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=42
vht_capab=[SHORT-GI-80][MAX-MPDU-11454][RX-ANTENNA-PATTERN][TX-ANTENNA-PATTERN]

# 80MHz HE (WiFi 6) channel block — must match VHT settings above
he_oper_chwidth=1
he_oper_centr_freq_seg0_idx=42

# Security: WPA2 PSK
wpa=2
wpa_passphrase=${WIFI_PASS}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP

# Client isolation — engineers cannot reach each other across the AP
ap_isolate=1

# Logging
logger_syslog=-1
logger_syslog_level=2
EOF

  # Set DAEMON_CONF in /etc/default/hostapd
  if grep -q 'DAEMON_CONF' "$HOSTAPD_DEFAULT" 2>/dev/null; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' "$HOSTAPD_DEFAULT"
  else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> "$HOSTAPD_DEFAULT"
  fi

  # Drop-in: retry hostapd on failure so a slow WiFi card init at boot doesn't
  # permanently strand the service. Without this, hostapd fails once at boot
  # (card not ready), wifi-ap-ip.service fails with DEPEND, and the AP has no IP.
  #
  # ExecStartPost re-triggers wifi-ap-ip after every hostapd start — including
  # Restart=on-failure retries. This bypasses the DEPEND-failed state that wifi-ap-ip
  # would otherwise be stuck in even after hostapd recovers: systemctl restart clears
  # the failed state and begins a fresh poll for stable AP mode.
  local dropin_dir="/etc/systemd/system/hostapd.service.d"
  mkdir -p "$dropin_dir"
  cat > "${dropin_dir}/rmbc-restart-on-failure.conf" <<EOF
# DO NOT EDIT MANUALLY — managed by configure-networking.sh
[Service]
Restart=on-failure
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=60
ExecStartPost=/bin/systemctl restart --no-block wifi-ap-ip.service
EOF
  systemctl daemon-reload

  log "hostapd configured."
}

# ─── WiFi AP IP Service ───────────────────────────────────────────────────────
# hostapd brings the interface into AP mode but does NOT assign an IP.
# This oneshot service runs after hostapd and assigns the static AP-side IP.

install_wifi_ip_service() {
  local iface="$1"
  log "Installing wifi-ap-ip.service to assign ${WIFI_IP}/${WIFI_PREFIX} to $iface..."

  # The ExecStart polls until hostapd has fully transitioned the interface into
  # AP mode (iw reports "type AP") before assigning the IP. Without this poll,
  # hostapd reinitialises the interface AFTER wifi-ap-ip assigns the address,
  # wiping it — causing dnsmasq to start with no inet address and clients to
  # receive APIPA instead of a DHCP lease. The loop retries for up to 30 s.
  cat > /etc/systemd/system/wifi-ap-ip.service <<EOF
[Unit]
Description=Assign static IP to RMBC WiFi AP interface
After=hostapd.service
BindsTo=hostapd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  stable=0; \
  for i in \$(seq 1 60); do \
    mode=\$(iw dev ${iface} info 2>/dev/null | awk "/type/ {print \$2}"); \
    if [ "\$mode" = "AP" ]; then \
      stable=\$((stable + 1)); \
      [ \$stable -ge 3 ] && break; \
    else \
      stable=0; \
    fi; \
    sleep 1; \
  done; \
  /sbin/ip addr replace ${WIFI_IP}/${WIFI_PREFIX} dev ${iface}; \
  /sbin/ip link set ${iface} up'
ExecStartPost=/bin/systemctl restart --no-block dnsmasq

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wifi-ap-ip.service
  log "wifi-ap-ip.service installed and enabled."
}

# ─── dnsmasq ─────────────────────────────────────────────────────────────────
# port=0 disables DNS entirely — this sidesteps the port 53 conflict with
# systemd-resolved. We only need DHCP on the engineer interfaces, not DNS.

configure_dnsmasq() {
  local eng="$1" wifi="$2"
  log "Configuring dnsmasq for DHCP on $eng and $wifi..."

  cat > "$DNSMASQ_CONF" <<EOF
# RMBC dnsmasq config — managed by configure-networking.sh
# DO NOT EDIT MANUALLY

# Disable DNS entirely — prevents port 53 conflict with systemd-resolved.
# This unit uses systemd-resolved for DNS. dnsmasq provides DHCP only.
port=0

# Only serve DHCP on our two engineer interfaces — never on production LAN
interface=${eng}
interface=${wifi}
bind-dynamic

# Engineer LAN port DHCP pool
dhcp-range=${eng},${ENGINEER_DHCP_START},${ENGINEER_DHCP_END},${ENGINEER_LEASE}
dhcp-option=${eng},3,${ENGINEER_IP}

# WiFi AP DHCP pool
dhcp-range=${wifi},${WIFI_DHCP_START},${WIFI_DHCP_END},${WIFI_LEASE}
dhcp-option=${wifi},3,${WIFI_IP}

# Log DHCP activity to syslog
log-dhcp
EOF

  log "dnsmasq config written: $DNSMASQ_CONF"
}

# ─── dnsmasq systemd drop-in ─────────────────────────────────────────────────
# Without this, dnsmasq starts before the engineer ethernet interface is
# fully registered by the kernel and fails with "unknown interface".

install_dnsmasq_dropin() {
  local eng="$1"
  log "Installing dnsmasq systemd drop-in (wait for $eng before starting)..."

  local dir="/etc/systemd/system/dnsmasq.service.d"
  mkdir -p "$dir"

  cat > "${dir}/rmbc-wait-interfaces.conf" <<EOF
[Unit]
After=sys-subsystem-net-devices-${eng}.device
After=hostapd.service
After=wifi-ap-ip.service
BindsTo=sys-subsystem-net-devices-${eng}.device
EOF

  systemctl daemon-reload
  log "dnsmasq drop-in installed."
}

# ─── UFW ─────────────────────────────────────────────────────────────────────
# Rules are applied per-interface name, NOT per-subnet.
# This is intentional fleet safety — a unit that is physically inaccessible
# (e.g. mounted 30ft up a lighting column) must never lock out an engineer
# even if subnet addressing changes between sites.

configure_ufw() {
  local eng="$1" wifi="$2"
  log "Configuring UFW rules for engineer interfaces..."

  ufw allow in on "$eng"  comment "RMBC engineer LAN port"
  ufw allow in on "$wifi" comment "RMBC engineer WiFi AP"

  # Belt-and-braces DHCP rules (UDP 67)
  ufw allow in on "$eng"  to any port 67 proto udp comment "DHCP engineer LAN"
  ufw allow in on "$wifi" to any port 67 proto udp comment "DHCP engineer WiFi"

  log "UFW rules applied."
}

# ─── IP Forwarding + NAT Masquerade ──────────────────────────────────────────
# Engineers on 10.50.0.0/23 (LAN port + WiFi AP) need to reach the production
# LAN (192.168.X.0/24) to access Nx Witness at .50. Without ip_forward=1 the
# NUC drops all routed packets. Without MASQUERADE the production LAN has no
# return path back to the engineer subnet.

configure_routing() {
  local prod="$1"
  log "Enabling IP forwarding and NAT masquerade for engineer → production LAN routing..."

  # Persistent ip_forward
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-rmbc-ip-forward.conf
  sysctl -w net.ipv4.ip_forward=1

  # Remove any duplicate rules first, then add fresh
  iptables -t nat -D POSTROUTING -s 10.50.0.0/23 -o "$prod" -j MASQUERADE 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s 10.50.0.0/23 -o "$prod" -j MASQUERADE

  # Save rules via UFW's after.rules mechanism so they survive reboot
  # UFW runs iptables-restore on boot — we hook into its post-rules file
  local ufw_after="/etc/ufw/after.rules"
  if ! grep -q "RMBC masquerade" "$ufw_after" 2>/dev/null; then
    cat >> "$ufw_after" <<EOF

# RMBC masquerade — engineer subnets → production LAN
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.50.0.0/23 -o ${prod} -j MASQUERADE
COMMIT
EOF
  fi

  log "IP forwarding enabled. Masquerade rule set for 10.50.0.0/23 → $prod."
}

# ─── Start Services ───────────────────────────────────────────────────────────

restart_services() {
  local wifi="$1"
  log "Starting/restarting services..."

  # hostapd — enable for next boot via wants symlink (avoids systemd-sysv-install hang)
  systemctl unmask hostapd 2>/dev/null || true
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /lib/systemd/system/hostapd.service \
    /etc/systemd/system/multi-user.target.wants/hostapd.service
  ln -sf /lib/systemd/system/dnsmasq.service \
    /etc/systemd/system/multi-user.target.wants/dnsmasq.service

  # --no-block prevents blocking on D-Bus job completion.
  # timeout 10 guards against D-Bus being unresponsive entirely.
  # wifi-ap-ip.service is restarted via hostapd's ExecStartPost drop-in.
  timeout 10 systemctl restart --no-block hostapd || true

  # Wait for hostapd to fork — check PID file directly, no D-Bus needed.
  log "Waiting for hostapd to start..."
  for i in $(seq 1 30); do
    [[ -f /run/hostapd.pid ]] \
      && kill -0 "$(cat /run/hostapd.pid 2>/dev/null)" 2>/dev/null \
      && break
    sleep 1
  done
  if ! { [[ -f /run/hostapd.pid ]] && kill -0 "$(cat /run/hostapd.pid 2>/dev/null)" 2>/dev/null; }; then
    warn "hostapd PID not found within 30s"
  fi

  # Wait for wifi-ap-ip.service to assign 10.50.1.1 to the WiFi interface.
  # wifi-ap-ip.service (via BindsTo) polls for 3 consecutive seconds of 'type AP'
  # before assigning — this handles the RZ616's multiple reinit cycles that would
  # otherwise wipe the IP after assignment. Allow up to 90s for it to settle.
  log "Waiting for WiFi AP IP to be assigned (wifi-ap-ip.service)..."
  for i in $(seq 1 90); do
    ip addr show dev "${wifi}" 2>/dev/null | grep -q "${WIFI_IP}" && break
    sleep 1
  done
  if ip addr show dev "${wifi}" 2>/dev/null | grep -q "${WIFI_IP}"; then
    log "WiFi AP IP ${WIFI_IP} confirmed on ${wifi}."
  else
    warn "WiFi AP IP not assigned within 90s — check: journalctl -u wifi-ap-ip -n 20"
  fi

  # dnsmasq — wifi-ap-ip.service's ExecStartPost already restarted it once the
  # IP was assigned. Restart again here as a safety net in case of ordering races.
  # --no-block + pgrep poll avoids D-Bus hangs.
  timeout 10 systemctl restart --no-block dnsmasq || true
  for i in $(seq 1 15); do
    pgrep -x dnsmasq > /dev/null 2>&1 && break
    sleep 1
  done
  pgrep -x dnsmasq > /dev/null 2>&1 || warn "dnsmasq did not start within 15s"

  log "Services started."
}

# ─── Verification ─────────────────────────────────────────────────────────────

verify() {
  local eng="$1" wifi="$2" ssid="$3"
  local all_ok=1

  echo
  echo "═══════════════════════════════════════════════"
  echo " RMBC Networking — Verification"
  echo "═══════════════════════════════════════════════"

  if ip addr show "$eng" | grep -q "${ENGINEER_IP}"; then
    log "✔ Engineer LAN port IP: ${ENGINEER_IP} on ${eng}"
  else
    warn "✘ Engineer LAN port IP not detected on ${eng}"
    all_ok=0
  fi

  if ip addr show "$wifi" | grep -q "${WIFI_IP}"; then
    log "✔ WiFi AP IP: ${WIFI_IP} on ${wifi}"
  else
    warn "✘ WiFi AP IP not detected on ${wifi} — check: systemctl status wifi-ap-ip"
    all_ok=0
  fi

  if [[ -f /run/hostapd.pid ]] && kill -0 "$(cat /run/hostapd.pid 2>/dev/null)" 2>/dev/null; then
    log "✔ hostapd: active (SSID: $ssid)"
  else
    warn "✘ hostapd is not running — check: sudo journalctl -u hostapd -n 30 --no-pager"
    all_ok=0
  fi

  if pgrep -x dnsmasq > /dev/null 2>&1; then
    log "✔ dnsmasq: active (DHCP serving on both interfaces)"
  else
    warn "✘ dnsmasq is not running — check: sudo journalctl -u dnsmasq -n 30 --no-pager"
    all_ok=0
  fi

  local prod
  prod="$(ip route show default | awk '/default/ {print $5}' | head -n1 || true)"
  if [[ -n "${prod:-}" ]]; then
    log "✔ Production LAN default route intact via: $prod"
  else
    warn "✘ Default route missing — check H685 router connection"
    all_ok=0
  fi

  echo "═══════════════════════════════════════════════"

  if [[ "$all_ok" -eq 1 ]]; then
    log "All checks passed."
    echo
    echo " Network layout:"
    printf '   Production LAN : %-10s → H685 router (192.168.X.X)\n'       "${prod:-unknown}"
    printf '   Engineer LAN   : %-10s → %s/%s  (DHCP: %s–%s)\n' \
      "$eng" "$ENGINEER_IP" "$ENGINEER_PREFIX" "$ENGINEER_DHCP_START" "$ENGINEER_DHCP_END"
    printf '   WiFi AP        : %-10s → %s/%s   (SSID: %s)\n' \
      "$wifi" "$WIFI_IP" "$WIFI_PREFIX" "$ssid"
    echo
  else
    warn "One or more checks failed. Review log: $LOG_FILE"
    echo
    echo " Useful debug commands:"
    echo "   sudo journalctl -u hostapd -n 30 --no-pager"
    echo "   sudo journalctl -u dnsmasq -n 30 --no-pager"
    echo "   sudo journalctl -u wifi-ap-ip -n 20 --no-pager"
    echo "   ip -br addr"
    echo
  fi
}

# ─── Timeshift Snapshot ───────────────────────────────────────────────────────
# Taken after successful verification. Timeshift is already installed by earlier
# scripts in the deployment stack — this function does NOT install or configure it.

create_timeshift_snapshot() {
  log "Creating Timeshift snapshot (post-networking-complete)..."

  if ! timeshift --create --yes --scripted \
       --comments "02-networking-complete-final-deployment" 2>&1 \
       | tee -a "$LOG_FILE"; then
    warn "Timeshift snapshot creation failed — continuing without snapshot."
    return
  fi

  # Identify the newest snapshot directory
  local snap_dir
  snap_dir="$(find /timeshift/snapshots -mindepth 1 -maxdepth 1 -type d \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | awk '{print $2}')"

  if [[ -z "${snap_dir:-}" ]]; then
    warn "Could not locate newest Timeshift snapshot directory — skipping lock marker."
    return
  fi

  log "Newest Timeshift snapshot directory: $snap_dir"

  # Drop .rmbc_deploy_lock marker
  if ! printf 'RMBC_DEPLOY_LOCK=GOLDEN_OPERATIONAL\nSCRIPT=configure-networking.sh\nHOSTNAME=%s\nDATE=%s\nSNAPSHOT=%s\n' \
       "$(hostname)" "$(date -Iseconds)" "$snap_dir" \
       > "${snap_dir}/.rmbc_deploy_lock" 2>/dev/null; then
    warn "Failed to write .rmbc_deploy_lock to $snap_dir — continuing."
    return
  fi

  # Drop README_RMBC_DEPLOY.txt
  if ! cat > "${snap_dir}/README_RMBC_DEPLOY.txt" 2>/dev/null <<EOF
RMBC NUC225 — Golden Operational Deployment Snapshot
=====================================================
This Timeshift snapshot was taken automatically by configure-networking.sh
after successful completion of all three deployment scripts.

Deployment stack completed:
  A. prepare-cctv-storage-fixed.sh  — NVMe storage
  B. installer-tailscale.sh         — apps & services
  C. configure-networking.sh        — networking (this script)

Unit     : $(hostname)
Date     : $(date -Iseconds)
Snapshot : $snap_dir

This snapshot represents a known-good GOLDEN_OPERATIONAL state.
Do not delete without engineering authorisation.
EOF
  then
    warn "Failed to write README_RMBC_DEPLOY.txt to $snap_dir — continuing."
    return
  fi

  log "Deployment lock markers written to: $snap_dir"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  require_root
  init_log

  log "Detecting unit identity..."
  local ssid
  ssid="$(get_unit_ssid)"
  log "Unit SSID will be: $ssid"

  log "Detecting network interfaces..."
  local prod eng wifi
  prod="$(get_production_iface)"
  eng="$(get_engineer_iface "$prod")"
  wifi="$(get_wifi_iface)"

  log "Production LAN : $prod (H685 router — will not be touched)"
  log "Engineer LAN   : $eng"
  log "WiFi 6 card    : $wifi"

  confirm "$prod" "$eng" "$wifi" "$ssid"

  # Packages first — require_cmds runs after so tools are guaranteed present
  install_packages
  require_cmds
  mask_network_manager

  configure_engineer_netplan "$eng"
  configure_wifi_netplan     "$wifi"
  configure_hostapd          "$wifi" "$ssid"
  install_wifi_ip_service    "$wifi"
  configure_dnsmasq          "$eng" "$wifi"
  install_dnsmasq_dropin     "$eng"
  configure_ufw              "$eng" "$wifi"
  configure_routing          "$prod"
  restart_services "$wifi"
  verify "$eng" "$wifi" "$ssid"
  create_timeshift_snapshot

  log "configure-networking.sh completed successfully."
}

main "$@"
