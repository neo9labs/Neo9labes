#!/usr/bin/env bash
# Purpose: Pin host-to-MCU critical work (Klipper, serial IRQ) to a dedicated
#          CPU core and keep best-effort work off it. Addresses MCU-communication
#          instability caused by IRQ/thread migration (missed digital-out events,
#          "timer too close", MCU shutdowns).
#
# This is intentionally idempotent and safe to run repeatedly (e.g. after every
# boot or after a USB/serial device is reopened). It installs:
#   * /etc/systemd/system/affinity.service        - applies pinning at boot
#   * /usr/local/bin/neo9labs-affinity.sh     - the actual pinning logic
#   * a udev rule to re-apply serial IRQ affinity after the MCU device is added

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: run with sudo: sudo $0" >&2
  exit 1
fi

# ===== Configuration =====
# Single-core (non-SMT) RK3328 has 4 cores: 0-3.
# Core 0: housekeeping (network, moonraker, background).
# Core 3: dedicated to Klipper + serial IRQ (highest priority work).
KLIPPER_CORE="${KLIPPER_CORE:-3}"
IRQ_CORE="${IRQ_CORE:-3}"
RESERVED_CORE_LIST="${RESERVED_CORE_LIST:-3}"
NCORES="$(nproc 2>/dev/null || echo 1)"
# Guard: if the requested core does not exist, fall back to the last core.
if [[ "$KLIPPER_CORE" -ge "$NCORES" ]]; then
  KLIPPER_CORE=$((NCORES - 1))
fi
if [[ "$IRQ_CORE" -ge "$NCORES" ]]; then
  IRQ_CORE=$((NCORES - 1))
fi
if [[ "$RESERVED_CORE_LIST" -ge "$NCORES" ]]; then
  RESERVED_CORE_LIST=$((NCORES - 1))
fi

AFFINITY_BIN="/usr/local/bin/neo9labs-affinity.sh"
AFFINITY_SERVICE="/etc/systemd/system/affinity.service"
UDEV_RULE="/etc/udev/rules.d/90-neo9labs-serial-affinity.rules"
SERIAL_DEV="${SERIAL_DEV:-ttyS0}"

echo "==> Detected ${NCORES} CPU core(s); Klipper core=${KLIPPER_CORE}, IRQ core=${IRQ_CORE}"

# ===== Install the pinning helper =====
cat > "$AFFINITY_BIN" <<'SCRIPT'
#!/usr/bin/env bash
# Applies and re-applies CPU/IRQ affinity for host-to-MCU communication.
# Idempotent; safe to run repeatedly.

set -u
KLIPPER_CORE="${KLIPPER_CORE:-3}"
IRQ_CORE="${IRQ_CORE:-3}"
RESERVED_CORE_LIST="${RESERVED_CORE_LIST:-3}"
SERIAL_DEVS=("${@:-}")
if [[ -z "${SERIAL_DEVS[0]:-}" ]]; then
  SERIAL_DEVS=(ttyS0 ttyACM0 ttyACM1 ttyUSB0 ttyUSB1)
fi

log() { echo "[affinity] $*"; }

pin_pid() {
  local pid="$1" core="$2" name="${3:-pid $1}"
  if [[ -d "/proc/$pid" ]]; then
    if taskset -pc "$core" "$pid" >/dev/null 2>&1; then
      log "pinned $name ($pid) -> core $core"
      return 0
    fi
  fi
  return 1
}

# 1) Pin the Klipper host process and all of its threads.
#    Restarting klipper re-creates the process, so this must be re-run each boot.
pin_klipper() {
  local pid
  pid="$(systemctl show -p MainPID --value klipper 2>/dev/null || true)"
  [[ -z "$pid" || "$pid" == "0" ]] && return 1
  pin_pid "$pid" "$KLIPPER_CORE" "klipper" || return 1
  # Pin every thread of klippy (TMC/serial workers, etc.)
  local tid
  for tid in /proc/"$pid"/task/*; do
    [[ -d "$tid" ]] || continue
    taskset -pc "$KLIPPER_CORE" "$(basename "$tid")" >/dev/null 2>&1 || true
  done
  return 0
}

# 2) Pin the serial (UART) IRQ handler. This is the critical one for #444/#445:
#    if the ttyS0 IRQ migrates or lands on the same core as heavy userspace work,
#    TX DMA completion can be delayed and the MCU can shut down.
pin_serial_irqs() {
  local dev irq irq_dir irqname pinned=0
  # Map serial device names to their interrupt numbers.
  for dev in "${SERIAL_DEVS[@]}"; do
    [[ -e "/dev/$dev" ]] || continue
    for irq_dir in /sys/class/tty/"$dev"/device/../irq/*; do
      [[ -d "$irq_dir" ]] || continue
      irq="$(basename "$irq_dir")"
      [[ "$irq" =~ ^[0-9]+$ ]] || continue
      irqname="$(cat "$irq_dir/actions" 2>/dev/null || echo "$dev")"
      if echo "$irq" > /proc/irq/"$irq"/smp_affinity_list 2>/dev/null; then
        log "pinned IRQ $irq ($irqname) -> core $IRQ_CORE"
        pinned=1
      fi
    done
  done

  # Fallback: find the serial driver's IRQ by name in /proc/interrupts.
  if [[ "$pinned" -eq 0 ]]; then
    local line irqn
    while read -r line; do
      case "$line" in
        *serial*|*uart*|*ttyS0*|*rk_serial*)
          irqn="$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')"
          [[ "$irqn" =~ ^[0-9]+$ ]] || continue
          if echo "$irqn" > /proc/irq/"$irqn"/smp_affinity_list 2>/dev/null; then
            log "pinned serial IRQ $irqn -> core $IRQ_CORE"
            pinned=1
          fi
          ;;
      esac
    done < /proc/interrupts
  fi

  # Keep Ethernet IRQs OFF the Klipper core so network bursts cannot preempt it.
  local eth_irq
  for eth_irq in $(grep -iE 'eth|mmc|gmac' /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' '); do
    [[ "$eth_irq" =~ ^[0-9]+$ ]] || continue
    # Pin Ethernet to core 0 (housekeeping), never the reserved core.
    if echo "0" > /proc/irq/"$eth_irq"/smp_affinity_list 2>/dev/null; then
      log "moved network IRQ $eth_irq -> core 0"
    fi
  done

  return 0
}

# 3) Ensure the reserved core is not used for generic work by keeping systemd
#    IRQ balancer away from it where possible.
pin_irqbalance() {
  if systemctl is-active --quiet irqbalance 2>/dev/null; then
    # Keep irqbalance away from the core reserved for Klipper/serial (core 3),
    # so background IRQ balancing cannot migrate the UART IRQ onto it.
    local mask
    mask="$(printf '%x' $(( 1 << RESERVED_CORE_LIST )))"
    sed -i -E "s/^#?IRQBALANCE_BANNED_CPUS=.*/IRQBALANCE_BANNED_CPUS=$mask/" \
      /etc/default/irqbalance 2>/dev/null || true
    systemctl restart irqbalance 2>/dev/null || true
  fi
}

main() {
  pin_klipper || log "klipper not running yet (will be pinned when it starts)"
  pin_serial_irqs
  pin_irqbalance
}

main "$@"
SCRIPT
chmod 0755 "$AFFINITY_BIN"

# Propagate the resolved (clamped) core numbers into the installed helper so the
# defaults match this machine even when the helper runs without env vars (via
# systemd or udev).
sed -i \
  -e "s/^KLIPPER_CORE=\"\${KLIPPER_CORE:-[0-9]*}\"/KLIPPER_CORE=\"\${KLIPPER_CORE:-${KLIPPER_CORE}}\"/" \
  -e "s/^IRQ_CORE=\"\${IRQ_CORE:-[0-9]*}\"/IRQ_CORE=\"\${IRQ_CORE:-${IRQ_CORE}}\"/" \
  -e "s/^RESERVED_CORE_LIST=\"\${RESERVED_CORE_LIST:-[0-9]*}\"/RESERVED_CORE_LIST=\"\${RESERVED_CORE_LIST:-${RESERVED_CORE_LIST}}\"/" \
  "$AFFINITY_BIN"

# ===== Install the systemd service =====
cat > "$AFFINITY_SERVICE" <<EOF
[Unit]
Description=Neo9labs CPU/IRQ affinity for host-to-MCU stability
After=klipper.service network.target
Wants=klipper.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$AFFINITY_BIN
# Re-apply periodically so a Klipper restart / device reopen cannot leave the
# serial IRQ or klippy threads unpinned (root cause tracked in #445).
ExecStartPost=/bin/sh -c 'sleep 20; $AFFINITY_BIN || true'

[Install]
WantedBy=multi-user.target
EOF

# ===== udev rule: re-apply after the MCU serial device (re)appears =====
cat > "$UDEV_RULE" <<EOF
# Re-apply Neo9labs CPU/IRQ affinity whenever the MCU serial device appears
# (e.g. after a Klipper restart or USB re-enumeration).
SUBSYSTEM=="tty", KERNEL=="$SERIAL_DEV*", ACTION=="add", RUN+="$AFFINITY_BIN $SERIAL_DEV"
SUBSYSTEM=="tty", KERNEL=="ttyACM*", ACTION=="add", RUN+="$AFFINITY_BIN %k"
SUBSYSTEM=="tty", KERNEL=="ttyUSB*", ACTION=="add", RUN+="$AFFINITY_BIN %k"
EOF

# ===== Enable/refresh =====
systemctl daemon-reload
systemctl enable affinity.service >/dev/null 2>&1 || true
systemctl restart affinity.service >/dev/null 2>&1 || true
udevadm control --reload-rules 2>/dev/null || true

# ===== Best-effort RT budget so RT klippy threads are never throttled =====
SYSCTL_DROPIN="/etc/sysctl.d/10-disable-rt-group-limit.conf"
printf 'kernel.sched_rt_runtime_us = -1\n' > "$SYSCTL_DROPIN"
sysctl --system >/dev/null 2>&1 || true

echo "==> affinity.service installed and enabled."
