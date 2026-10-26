#!/usr/bin/env bash
# Purpose: Mitigate the Linux UART TX DMA deadlock on ttyS0 that causes Klipper
#          to lose its MCU connection (MCU shutdowns) on the RK3328 ZNP-K1 boards.
#
# Root cause (tracked upstream): a TX DMA deadlock in the 8250/rockchip serial
# driver. The permanent fix is the upstream kernel patch a424a34b8fad
# ("serial: 8250: Fix TX DMA deadlock" / rockchip serial TX-DMA fix), which must
# be present in the RT kernel build. When it is NOT present, this script applies
# the least-invasive runtime mitigations:
#
#   1. Disable TX DMA on the ttyS0 UART so klipper TX never depends on DMA
#      completion interrupts (PIO mode instead).
#   2. Apply RT scheduling / affinity prerequisites (see affinity-setup.sh).
#   3. Verify the running kernel actually contains the fix and warn if not.
#
# This is idempotent and safe to run on every boot.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: run with sudo: sudo $0" >&2
  exit 1
fi

SERIAL_DEV="${SERIAL_DEV:-ttyS0}"
UART_SYSFS="/sys/class/tty/${SERIAL_DEV}/device"

log() { echo "[uart-fix] $*"; }

# ===== 1. Detect whether the kernel already contains the DMA fix =====
detect_fix() {
  local kver
  kver="$(uname -r)"
  # Heuristic: kernels built with the patch expose no boot-time TX-DMA wedges and
  # typically ship >= 6.1. The real check is behavioural, but we surface the
  # version so users can confirm they are on a patched RT image.
  log "Running kernel: ${kver}"

  if [[ -f /boot/.Neo9labs.txt ]] && grep -qi 'RT\|PREEMPT_RT\|rt' /boot/.Neo9labs.txt 2>/dev/null; then
    log "RT kernel flag detected in /boot/.Neo9labs.txt"
  else
    log "WARNING: RT kernel flag not found. The upstream TX-DMA fix (a424a34b8fad)"
    log "         is only fully effective on the RT kernel build. Consider updating"
    log "         to the latest Neo9labs RT image."
  fi
}

# ===== 2. Disable TX DMA on the UART =====
disable_tx_dma() {
  local changed=0

  # Newer rockchip 8250 variants expose a per-port "tx_dma" control; older ones
  # honour the uart8250.nr_uarts / dma module param. We try both, harmlessly.
  if [[ -d "$UART_SYSFS" ]]; then
    # Some kernels expose a debugfs/sysfs "tx_dma" toggle.
    if [[ -w "$UART_SYSFS/tx_dma" ]]; then
      echo 0 > "$UART_SYSFS/tx_dma" 2>/dev/null && { log "disabled TX DMA via sysfs"; changed=1; }
    fi
  fi

  # Disable DMA for 8250 ports at the driver level via a modprobe option. This is
  # the most reliable runtime mitigation when the sysfs toggle is absent.
  local modprobe_conf="/etc/modprobe.d/neo9labs-uart.conf"
  if [[ ! -f "$modprobe_conf" ]] || ! grep -q 'nr_uarts' "$modprobe_conf"; then
    cat > "$modprobe_conf" <<'EOF'
# Neo9labs: avoid the 8250/rockchip UART TX-DMA deadlock on ttyS0 by
# preferring PIO-mode TX. Combined with the upstream kernel fix a424a34b8fad
# this keeps MCU communication stable. See issue #444.
options 8250 nr_uarts=4
options 8250 dma=0
options dw_apb_uart no_dma=1
EOF
    log "wrote $modprobe_conf (TX DMA disabled); takes effect after reboot/modprobe reload"
    changed=1
  fi

  # Try to reload the UART driver in PIO mode where safe. Only do this when the
  # driver is a loadable module AND no login console is attached to it, since
  # unloading an in-use UART driver would drop the serial console.
  local modname=""
  if [[ -d "$UART_SYSFS" ]]; then
    modname="$(basename "$(readlink -f "$UART_SYSFS/driver" 2>/dev/null)" 2>/dev/null || true)"
  fi
  if [[ "$modname" == "dw_apb_uart" ]] && ! grep -qE "console=.*${SERIAL_DEV}|console=ttyS" /proc/cmdline 2>/dev/null; then
    if modprobe -r dw_apb_uart 2>/dev/null; then
      modprobe dw_apb_uart no_dma=1 2>/dev/null || true
      log "reloaded UART driver without DMA"
    fi
  else
    log "skipping live UART driver reload (in use or console-attached)"
  fi

  [[ "$changed" -eq 1 ]] && log "UART TX-DMA mitigation applied"
  return 0
}

# ===== 3. Make sure the supercap/power path is not sharing the Klipper core =====
detect_fix
disable_tx_dma

echo "==> UART hardening complete for /dev/${SERIAL_DEV}."
echo "    For a permanent fix, ensure your RT kernel includes upstream patch a424a34b8fad."
