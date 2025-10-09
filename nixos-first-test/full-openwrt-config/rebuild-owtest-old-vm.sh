#!/usr/bin/env bash
# rebuild-owtest-validated.sh
# Purpose: Fully staged and validated rebuild of the owtest host VM on Proxmox,
#          followed by a clean NixOS install via nixos-anywhere, and post-boot
#          verification. Does NOT execute nixos-rebuild on your workstation; it
#          calls nixos-anywhere to root@HOST_IP as required.
#
# Key steps:
#  1) Destroy any existing VM (qm stop/destroy --purge)
#  2) Recreate VM with desired CPU/MEM/NIC/DISK and attach a NixOS installer ISO
#  3) Boot VM from ISO and wait for SSH on HOST_IP (be sure DHCP or mapping exists)
#  4) nixos-anywhere --flake "${FLAKE_URI}" root@HOST_IP   <= pay attention: root@HOST_IP
#  5) Set boot to scsi0, stop, start, wait for SSH again
#  6) Wait for internal services (e.g., configure-openwrt-vm.service) and verify
#
# Safety:
#  - set -euo pipefail; every remote step logged; retries for SSH; explicit checks
#  - No side-effects on your repo; this script only orchestrates Proxmox + ssh

set -euo pipefail

# -------------------------- Configuration --------------------------
SAVED_DIR="$(pwd)"
PMX_HOST="${PMX_HOST:-spino.bruc}"           # Proxmox host to run qm/pvesm on
VMID="${VMID:-204}"
VM_NAME="${VM_NAME:-owtest}"
HOST_IP="${HOST_IP:-192.168.11.50}"          # The IP the VM will use in the installer and final system
CORES="${CORES:-6}"
MEMORY_MB="${MEMORY_MB:-8192}"
BRIDGE="${BRIDGE:-vmbr0}"
NET0_MAC="${NET0_MAC:-0E:00:00:00:FF:FF}"
DISK_STORE="${DISK_STORE:-zpool}"
DISK_SIZE="${DISK_SIZE:-32G}"
ISO_PATH="${ISO_PATH:-syn-warez:iso/nixos-minimal-25.05.20250708.88983d4-x86_64-linux.iso}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FLAKE_URI="${FLAKE_URI:-${REPO_ROOT}#owtest}"
LOGFILE="${LOGFILE:-${SCRIPT_DIR}/rebuild-owtest.log}"
: > "${LOGFILE}"
cd "${SAVED_DIR}"

# ---------- Argument processing ----------
USE_VM=false
for arg in "$@"; do
  case "$arg" in
    --usevm) USE_VM=true ;;
    --*)     log "Unknown option: $arg"; exit 1 ;;
  esac
done

# ---------------------------- Utilities ----------------------------
log() { echo "=> [$(date -Is)] $*" | tee -a "${LOGFILE}"; }

require_cmds() {
  local missing=()
  for c in just ssh nc nix; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if (( ${#missing[@]} )); then log "ERROR: Missing required tools: ${missing[*]}"; exit 1; fi
}

# Helper to safely single-quote a command for bash -c on remote side
_quote_squote() { sed "s/'/'\"'\"'/g"; }

# Execute a command on Proxmox via `just ss` using the required format:
#   just ssr "<HOST> <cmd>"
run_on_proxmox() {
  local cmd="$*"
  log "[PROXMOX ${PMX_HOST}] $cmd"
  just ssr "${PMX_HOST} ${cmd}"
}
# Quiet helper for existence/probing checks (suppresses output)
run_on_proxmox_quiet() {
  local cmd="$*"
  just ssr "${PMX_HOST} ${cmd}" >/dev/null 2>&1
}

vm_exists() {
  # qm config exits 0 when the VM exists
  if run_on_proxmox_quiet "qm config ${VMID}"; then return 0; else return 1; fi
}

force_destroy_vm() {
  log "Killing datastore VM ${VMID}-disk-0 on ${PMX_HOST}"
  run_on_proxmox "zfs destroy ${DISK_STORE}/vm-${VMID}-disk-0" || true
  if vm_exists; then
    log "Attempting forceful destroy of VM ${VMID} on ${PMX_HOST}"
    run_on_proxmox "qm unlock ${VMID} || true"
    run_on_proxmox "qm stop ${VMID} --skiplock 1 || true"
    run_on_proxmox "qm destroy ${VMID} --purge 1 || true"
    # Wait until gone
    for i in $(seq 1 30); do
      if ! vm_exists; then log "VM ${VMID} no longer exists"; return 0; fi
      sleep 1
    done
    log "WARN: VM ${VMID} still reported existing after destroy attempts"
  else
    log "VM ${VMID} not present; nothing to destroy"
  fi
}

# Execute a command on the VM host via `just ss` (HOST_IP)
run_on_host() {
  local ip="$1"; shift; local cmd="$*"
  log "[HOST ${ip}] ${cmd}"
  just ssr "${ip} ${cmd}"
}
run_on_host_quiet() {
  local ip="$1"; shift; local cmd="$*"
  just ssr "${ip} ${cmd}" >/dev/null 2>&1
}


wait_for_ssh() {
  local ip="$1"; local label="${2:-}"
  log "Waiting for SSH at ${ip} ${label:+(${label})}..."
  for i in $(seq 1 300); do
    if nc -z -w 1 "$ip" 22; then log "SSH is up at ${ip}"; sleep 3; return 0; fi
    sleep 2
  done
  log "ERROR: Timeout waiting for SSH at ${ip}"; return 1
}

wait_for_shutdown() {
  local ip="$1"
  log "Waiting for ${ip} to go down (SSH closed)..."
  for i in $(seq 1 120); do
    if ! run_on_host_quiet "${ip}" true; then log "Host ${ip} is down"; return 0; fi
    sleep 1
  done
  log "WARN: ${ip} did not go down in time; proceeding"
}

wait_for_service_completion() {
  local service_name="${1:-configure-openwrt-vm.service}"
  log "Waiting for ${service_name} to complete on host ${HOST_IP}..."
  for i in $(seq 1 240); do
    # Query both LoadState and ActiveState; if not-found, skip waiting
    local load active
    load=$(just ssr "${HOST_IP} systemctl show '${service_name}' --property=LoadState --value" 2>/dev/null || echo unknown)
    active=$(just ssr "${HOST_IP} systemctl show '${service_name}' --property=ActiveState --value" 2>/dev/null || echo unknown)
    log "${service_name}: LoadState=${load} ActiveState=${active}"
    case "$load" in
      not-found)
        log "Service ${service_name} not found on ${HOST_IP}; skipping wait"
        return 0 ;;
    esac
    case "$active" in
      inactive|failed)
        log "Service ${service_name} state: ${active}"
        run_on_host "${HOST_IP}" "journalctl -u ${service_name} --no-pager -n 200" |& tee -a "${LOGFILE}"
        return 0 ;;
      active|activating)
        : ;; # keep waiting
      *)
        : ;;
    esac
    sleep 2
  done
  log "ERROR: Timed out waiting for ${service_name}"
  run_on_host "${HOST_IP}" "systemctl status ${service_name} || true" || true
  return 0
}

# ----------------------------- Workflow ----------------------------
main() {
  require_cmds

  log "Step 1: Ensure previous VM is fully removed"
  force_destroy_vm

  log "Step 2a: Create VM shell"
  run_on_proxmox "qm create ${VMID} --agent 1 --boot order=ide2 --cores ${CORES} --cpu host --memory ${MEMORY_MB} --name ${VM_NAME} --net0 virtio=${NET0_MAC},bridge=${BRIDGE} --scsihw virtio-scsi-single --ide2 ${ISO_PATH},media=cdrom"
  log "Step 2b: Create disk"
  run_on_proxmox "pvesm alloc ${DISK_STORE} ${VMID} vm-${VMID}-disk-0 ${DISK_SIZE}"
  log "Step 2c: Attach disk"
  run_on_proxmox "qm set ${VMID} --scsi0 ${DISK_STORE}:vm-${VMID}-disk-0,ssd=1,iothread=1"

  log "Step 3: Boot installer and wait for SSH (${HOST_IP})"
  run_on_proxmox "qm start ${VMID}"
  if ! wait_for_ssh "${HOST_IP}" "NixOS installer"; then
    log "ERROR: SSH did not come up at ${HOST_IP}. Ensure DHCP/reservation for MAC ${NET0_MAC} -> ${HOST_IP}."; exit 1
  fi

  log "Step 4: Install NixOS via nixos-anywhere (to root@${HOST_IP})"
  # IMPORTANT: nixos-anywhere connects to root@HOST_IP
  # nix run github:nix-community/nixos-anywhere -- --flake "${FLAKE_URI}" "root@${HOST_IP}" |& tee -a "${LOGFILE}"
  cd "${SAVED_DIR}"
  "${REPO_ROOT}/scripts/mkhost-new.sh" "${HOST_IP}" "${VM_NAME}"

  log "Step 5: Switch boot to disk and reboot into the new system"
  run_on_proxmox "qm set ${VMID} --boot order=scsi0"
  run_on_proxmox "qm stop ${VMID}"
  wait_for_shutdown "${HOST_IP}"
  run_on_proxmox "qm start ${VMID}"
  wait_for_ssh "${HOST_IP}" "Final NixOS system"

  log "Step 6: Post-boot verification"
  # Wait for your host-internal configurator to finish (e.g., OpenWrt provisioning)
  wait_for_service_completion ow-mini-deploy.service || true
  wait_for_service_completion clone-nix-config.service || true

  log "Step 7: Sanity checks on the host"
  run_on_host "${HOST_IP}" "hostnamectl || true" | tee -a "${LOGFILE}"
  run_on_host "${HOST_IP}" "ip -o addr show || true" | tee -a "${LOGFILE}"
  run_on_host "${HOST_IP}" "systemctl --failed || true" | tee -a "${LOGFILE}"

  # Step 7.1: Validate OpenWrt NIC and basic connectivity (single-NIC trunk on br0)
  run_on_host "${HOST_IP}" "virsh domiflist owtest-openwrt || true" | tee -a "${LOGFILE}"
  if ! run_on_host_quiet "${HOST_IP}" "virsh domiflist owtest-openwrt | grep -qi '0e:00:00:00:ee:00'"; then
    log "ERROR: Missing NIC with MAC 0e:00:00:00:ee:00 on owtest-openwrt"; exit 1; fi
  if ! run_on_host_quiet "${HOST_IP}" "virsh domiflist owtest-openwrt | grep -q ' br0 '"; then
    log "ERROR: owtest-openwrt is not attached to br0"; exit 1; fi

  # Ensure vnet interface is enslaved to host bridge br0
  if ! run_on_host_quiet "${HOST_IP}" "ip -o link show master br0 | grep -q vnet"; then
    log "ERROR: No vnet enslaved to br0 on host"; exit 1; fi

  # Ping OpenWrt default VLAN (untagged) from host
  ip=10.77.0.1
  ok=false
  for i in $(seq 1 20); do
    if run_on_host_quiet "${HOST_IP}" "ping -c 1 -W 1 ${ip}"; then
      run_on_host "${HOST_IP}" "ping -c 2 -W 1 ${ip}" | tee -a "${LOGFILE}"
      ok=true; break
    fi
    sleep 2
  done
  if [ "${ok}" != true ]; then log "ERROR: Ping to ${ip} failed after retries"; exit 1; fi

  # VLAN and UCI Diagnostics
  log "=== VLAN DIAGNOSTICS ==="

  # Check VLAN interfaces are UP with correct IPs
  log "VLAN Interfaces Status:"
  run_on_host "${HOST_IP}" "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.77.0.1 'ip a | grep \"br-lan\\.[0-9]\"'" | tee -a "${LOGFILE}"

  # Show applied UCI network configuration
  log "UCI Network Configuration:"
  run_on_host "${HOST_IP}" "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.77.0.1 'uci show network | grep -E \"(vlan|bridge)\"'" | tee -a "${LOGFILE}"

  # Test connectivity to each VLAN gateway
  log "VLAN Connectivity Tests:"
  for vlan in 0 10 11 12 13 99; do
    if [ "${vlan}" = "0" ]; then
      vlan_ip="10.77.0.1"
      vlan_name="default (VLAN1)"
    else
      vlan_ip="10.77.${vlan}.1"
      vlan_name="VLAN${vlan}"
    fi
    log "Testing ${vlan_name} (${vlan_ip}):"
    if run_on_host_quiet "${HOST_IP}" "ping -c 1 -W 2 ${vlan_ip}"; then
      log "  ✓ ${vlan_name} reachable"
    else
      log "  ⚠ ${vlan_name} unreachable (expected for isolated VLANs)"
    fi
  done

  # Check ow-mini-deploy service status
  log "Service Status Check:"
  run_on_host "${HOST_IP}" "systemctl status ow-mini-deploy.service --no-pager -l" | tee -a "${LOGFILE}"

  log "--- COMPLETE ---"
}

main "$@"

