#!/usr/bin/env bash

# rebuild-owtest-enhanced.sh (MicroVM Edition)
# Purpose: Fully staged and validated rebuild of the owtest host VM on Proxmox,
#          followed by a clean NixOS install via nixos-anywhere, and post-boot
#          verification of the MicroVM guest.
#
# Key steps:
#  1) Destroy any existing VM on Proxmox.
#  2) Recreate the VM and boot from a NixOS installer ISO.
#  3) Wait for SSH and install NixOS using nixos-anywhere.
#  4) Reboot into the final system.
#  5) Wait for host services (overlay creation, MicroVM start, UCI deploy) to complete.
#  6) Verify the MicroVM service is running and connected to the host bridge.
#
# Safety:
#  - set -euo pipefail; every remote step logged; retries for SSH; explicit checks.

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

# ---------------------------- Utilities ----------------------------
log() { echo "=> [$(date -Is)] $*" | tee -a "${LOGFILE}"; }

require_cmds() {
  local missing=()
  for c in just ssh nc nix; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if (( ${#missing[@]} )); then log "ERROR: Missing required tools: ${missing[*]}"; exit 1; fi
}

run_on_proxmox() {
  local cmd="$*"
  log "[PROXMOX ${PMX_HOST}] $cmd"
  just ssr "${PMX_HOST} ${cmd}"
}
run_on_proxmox_quiet() {
  local cmd="$*"
  just ssr "${PMX_HOST} ${cmd}" >/dev/null 2>&1
}

vm_exists() {
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
    for i in $(seq 1 30); do
      if ! vm_exists; then log "VM ${VMID} no longer exists"; return 0; fi
      sleep 1
    done
    log "WARN: VM ${VMID} still reported existing after destroy attempts"
  else
    log "VM ${VMID} not present; nothing to destroy"
  fi
}

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
  local service_name="$1"
  log "Waiting for ${service_name} to complete on host ${HOST_IP}..."
  for i in $(seq 1 240); do
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

  log "First, build locally, save the hassle!"
  nixos-rebuild build --flake .#owtest || exit 1

  log "Step 1: Ensure previous VM is fully removed"
  force_destroy_vm

  log "Step 2: Create, configure, and attach disk for new VM"
  run_on_proxmox "qm create ${VMID} --agent 1 --boot order=ide2 --cores ${CORES} --cpu host --memory ${MEMORY_MB} --name ${VM_NAME} --net0 virtio=${NET0_MAC},bridge=${BRIDGE} --scsihw virtio-scsi-single --ide2 ${ISO_PATH},media=cdrom"
  run_on_proxmox "pvesm alloc ${DISK_STORE} ${VMID} vm-${VMID}-disk-0 ${DISK_SIZE}"
  run_on_proxmox "qm set ${VMID} --scsi0 ${DISK_STORE}:vm-${VMID}-disk-0,ssd=1,iothread=1"
  run_on_proxmox "qm set ${VMID} -usb0 mapping=wireless,usb3=yes"

  log "Step 3: Boot installer and wait for SSH (${HOST_IP})"
  run_on_proxmox "qm start ${VMID}"
  if ! wait_for_ssh "${HOST_IP}" "NixOS installer"; then
    log "ERROR: SSH did not come up at ${HOST_IP}. Ensure DHCP/reservation for MAC ${NET0_MAC} -> ${HOST_IP}."; exit 1
  fi

  log "Step 4: Install NixOS via nixos-anywhere (to root@${HOST_IP})"
  cd "${SAVED_DIR}"
  "${REPO_ROOT}/scripts/mkhost-new.sh" "${HOST_IP}" "${VM_NAME}"

  log "Step 5: Switch boot to disk and reboot into the new system"
  run_on_proxmox "qm set ${VMID} --boot order=scsi0"
  run_on_proxmox "qm stop ${VMID}"
  wait_for_shutdown "${HOST_IP}"
  run_on_proxmox "qm start ${VMID}"
  wait_for_ssh "${HOST_IP}" "Final NixOS system"

  log "Step 6: Post-boot verification"
  # Wait for the declarative service chain to complete
  wait_for_service_completion prepare-owtest-overlay.service || true
  wait_for_service_completion ow-config-deploy.service || true
  wait_for_service_completion clone-nix-config.service || true

  log "Step 7: Sanity checks on the host and MicroVM"
  run_on_host "${HOST_IP}" "hostnamectl || true" | tee -a "${LOGFILE}"
  run_on_host "${HOST_IP}" "ip -o addr show || true" | tee -a "${LOGFILE}"
  run_on_host "${HOST_IP}" "systemctl --failed || true" | tee -a "${LOGFILE}"

  # Step 7.1: Validate MicroVM service and network attachment
  log "Verifying MicroVM status..."
  run_on_host "${HOST_IP}" "systemctl status microvm@owtest-openwrt.service --no-pager -l" | tee -a "${LOGFILE}"
  if ! run_on_host_quiet "${HOST_IP}" "systemctl is-active --quiet microvm@owtest-openwrt.service"; then
    log "ERROR: microvm@owtest-openwrt.service is not active!"; exit 1;
  fi

  log "Verifying MicroVM network attachment to bridge br0..."
  if ! run_on_host_quiet "${HOST_IP}" "ip link show master br0 | grep -q 'tap-'"; then
    log "ERROR: No tap interface found attached to host bridge br0"; exit 1;
  fi
  log "MicroVM tap interface is attached to br0."

  # Step 7.2: Ping OpenWrt default VLAN (untagged) from host
  ip=10.77.0.1
  ok=false
  log "Pinging OpenWRT guest at ${ip}..."
  for i in $(seq 1 20); do
    if run_on_host_quiet "${HOST_IP}" "ping -c 1 -W 1 ${ip}"; then
      run_on_host "${HOST_IP}" "ping -c 2 -W 1 ${ip}" | tee -a "${LOGFILE}"
      ok=true; break
    fi
    sleep 2
  done
  if [ "${ok}" != true ]; then log "ERROR: Ping to ${ip} failed after retries"; exit 1; fi

  # Step 7.3: VLAN and UCI Diagnostics (via SSH into the guest)
  log "=== GUEST VLAN DIAGNOSTICS ==="
  log "VLAN Interfaces Status:"
  run_on_host "${HOST_IP}" "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.77.0.1 'ip a | grep \"br-lan\\.[0-9]\"'" | tee -a "${LOGFILE}"

  log "UCI Network Configuration:"
  run_on_host "${HOST_IP}" "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.77.0.1 'uci show network | grep -E \"(vlan|bridge)\"'" | tee -a "${LOGFILE}"

  log "VLAN Connectivity Tests from Host:"
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

  log "--- COMPLETE ---"
}

main "$@"
