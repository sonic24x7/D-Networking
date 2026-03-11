#!/usr/bin/env bash
# =============================================================================
# cleanup-networking.sh
# RMBC NUC225 — Remove all previous engineer networking config
#
# Run this BEFORE configure-networking.sh on any unit that has had a previous
# version of the networking script applied, to ensure a clean slate.
#
# Usage:
#   sudo bash cleanup-networking.sh          # interactive
#   echo "YES" | sudo bash cleanup-networking.sh  # non-interactive
#   sudo bash cleanup-networking.sh --yes    # non-interactive (flag)
#
# What this removes:
#   - RMBC Netplan files for engineer LAN and WiFi interfaces
#   - RMBC dnsmasq config files
#   - hostapd config and DAEMON_CONF entry
#   - wifi-ap-ip.service systemd unit
#   - dnsmasq systemd drop-in
#   - UFW rules added by previous RMBC networking scripts
#   - Stale 10.50.x.x IP addresses on non-production interfaces
#
# What this NEVER touches:
#   - Production Netplan config (H685 router interface)
#   - UFW default policies or non-RMBC rules
#   - Tailscale config
#   - Nx Witness config
#   - Storage / fstab config
# =============================================================================
set -Eeuo pipefail

ASSUME_YES=0
for arg in "$@"; do
  [[ "$arg" == "--yes" || "$arg" == "-y" ]] && ASSUME_YES=1
done

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
error(){ echo "[ERROR] $*" >&2; }
die()  { error "$*"; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run with sudo or as root."
}

confirm() {
  echo
  echo "═══════════════════════════════════════════════"
  echo " RMBC NUC225 — cleanup-networking.sh"
  echo "═══════════════════════════════════════════════"
  echo " Removes all previous RMBC engineer networking"
  echo " config from this unit."
  echo
  echo " Production LAN (H685 router) will NOT"
  echo " be touched. SSH will remain active."
  echo "═══════════════════════════════════════════════"
  echo

  [[ "$ASSUME_YES" -eq 1 ]] && { log "Assumption YES flag set — continuing."; return 0; }

  read -r -p "Type YES to continue: " reply
  [[ "$reply" == "YES" ]] || { warn "Aborted."; exit 1; }
}

stop_services() {
  log "Stopping engineer networking services..."
  for svc in hostapd dnsmasq wifi-ap-ip; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
      systemctl stop    "${svc}.service" 2>/dev/null || true
      systemctl disable "${svc}.service" 2>/dev/null || true
      log "  Stopped and disabled: ${svc}.service"
    fi
  done
}

unmask_services() {
  log "Unmasking services (clean state for re-install)..."
  systemctl unmask hostapd 2>/dev/null || true
  systemctl unmask dnsmasq 2>/dev/null || true
}

remove_netplan_files() {
  log "Removing RMBC Netplan config files..."
  local files=(
    /etc/netplan/60-rmbc-engineer.yaml
    /etc/netplan/61-rmbc-wifi.yaml
    /etc/netplan/60-rmbc-local-access.yaml
    /etc/netplan/99-rmbc-engineer.yaml
    /etc/netplan/rmbc-engineer.yaml
    /etc/netplan/rmbc-local-access.yaml
  )
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then rm -f "$f"; log "  Removed: $f"; fi
  done
}

remove_dnsmasq_config() {
  log "Removing RMBC dnsmasq config files..."
  local files=(
    /etc/dnsmasq.d/rmbc-networking.conf
    /etc/dnsmasq.d/rmbc-local-access.conf
    /etc/dnsmasq.d/rmbc-engineer.conf
  )
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then rm -f "$f"; log "  Removed: $f"; fi
  done
}

remove_hostapd_config() {
  log "Removing hostapd config..."
  if [[ -f /etc/hostapd/hostapd.conf ]]; then
    rm -f /etc/hostapd/hostapd.conf
    log "  Removed: /etc/hostapd/hostapd.conf"
  fi
  if [[ -f /etc/default/hostapd ]]; then
    sed -i 's|^DAEMON_CONF=.*|#DAEMON_CONF=""|' /etc/default/hostapd
    log "  Reset: /etc/default/hostapd"
  fi
}

remove_systemd_units() {
  log "Removing RMBC systemd units and drop-ins..."

  local unit="/etc/systemd/system/wifi-ap-ip.service"
  if [[ -f "$unit" ]]; then rm -f "$unit"; log "  Removed: $unit"; fi

  local dropin="/etc/systemd/system/dnsmasq.service.d/rmbc-wait-interfaces.conf"
  if [[ -f "$dropin" ]]; then rm -f "$dropin"; log "  Removed: $dropin"; fi

  local dropin_dir="/etc/systemd/system/dnsmasq.service.d"
  if [[ -d "$dropin_dir" ]] && [[ -z "$(ls -A "$dropin_dir")" ]]; then
    rmdir "$dropin_dir"
    log "  Removed empty dir: $dropin_dir"
  fi

  systemctl daemon-reload
  log "  systemd daemon reloaded."
}

remove_ufw_rules() {
  log "Removing RMBC UFW rules..."

  local comments=(
    "RMBC engineer LAN port"
    "RMBC engineer WiFi AP"
    "DHCP engineer LAN"
    "DHCP engineer WiFi"
    "rmbc-engineer"
    "rmbc-local-access"
  )

  for comment in "${comments[@]}"; do
    while true; do
      local rule_num
      rule_num="$(ufw status numbered 2>/dev/null \
        | grep "$comment" \
        | awk -F'[][]' '{print $2}' \
        | head -n1 || true)"
      [[ -z "${rule_num:-}" ]] && break
      echo "y" | ufw delete "$rule_num" 2>/dev/null || true
      log "  Deleted UFW rule #${rule_num} ($comment)"
    done
  done

  for subnet in "10.50.0" "10.50.1"; do
    while true; do
      local rule_num
      rule_num="$(ufw status numbered 2>/dev/null \
        | grep "$subnet" \
        | awk -F'[][]' '{print $2}' \
        | head -n1 || true)"
      [[ -z "${rule_num:-}" ]] && break
      echo "y" | ufw delete "$rule_num" 2>/dev/null || true
      log "  Deleted UFW subnet rule #${rule_num} (${subnet}.x)"
    done
  done
}

flush_stale_ips() {
  log "Flushing stale 10.50.x.x addresses from non-production interfaces..."

  local prod
  prod="$(ip route show default | awk '/default/ {print $5}' | head -n1 || true)"

  if [[ -z "${prod:-}" ]]; then
    warn "Cannot detect production interface — skipping IP flush to be safe."
    return
  fi

  while IFS= read -r line; do
    local iface addr
    iface="$(echo "$line" | awk '{print $1}')"
    addr="$(echo "$line" | awk '{print $2}')"
    if [[ "$iface" != "$prod" ]]; then
      ip addr del "$addr" dev "$iface" 2>/dev/null || true
      log "  Flushed $addr from $iface"
    fi
  done < <(ip -o addr show | awk '$4 ~ /^10\.50\./ {print $2, $4}' || true)
}

reapply_netplan() {
  log "Re-applying Netplan (production LAN only)..."
  netplan apply 2>/dev/null || warn "netplan apply returned non-zero — check manually."
  log "  Done."
}

summary() {
  echo
  echo "═══════════════════════════════════════════════"
  echo " Cleanup complete."
  echo "═══════════════════════════════════════════════"
  echo
  echo " Current interfaces:"
  ip -br addr
  echo
  echo " Default route (production LAN):"
  ip route show default
  echo
  echo " UFW status:"
  ufw status numbered
  echo
  echo " Ready to run:"
  echo "   sudo bash configure-networking.sh --yes"
  echo "   or"
  echo "   echo \"YES\" | sudo bash configure-networking.sh"
  echo
}

main() {
  require_root
  confirm
  stop_services
  unmask_services
  remove_netplan_files
  remove_dnsmasq_config
  remove_hostapd_config
  remove_systemd_units
  remove_ufw_rules
  flush_stale_ips
  reapply_netplan
  summary
}

main "$@"
