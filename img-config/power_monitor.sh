#!/usr/bin/env bash
# Purpose: Robust power-loss monitor with correct v1/v2 semantics and debounce.

set -euo pipefail

# ===== Configuration =====
DEBUG="${DEBUG:-false}"
CHIP="${CHIP:-gpiochip1}"
LINE_SUPERCAP="${LINE_SUPERCAP:-21}"
LINE_PWRLOSS="${LINE_PWRLOSS:-10}"   # rising = loss
LINE_PWRGOOD="${LINE_PWRGOOD:-19}"   # falling = loss
LOG_TAG="${LOG_TAG:-power_monitor}"
VERIFY_SAMPLES="${VERIFY_SAMPLES:-5}"
VERIFY_INTERVAL_MS="${VERIFY_INTERVAL_MS:-40}"
MONITOR_START_TIMEOUT="${MONITOR_START_TIMEOUT:-5}"
# If true, refuse to run when the monitored GPIO lines are unavailable (rather
# than silently running without power-loss protection). Set to "false" only for
# boards without the supercap/power-loss circuitry.
REQUIRE_MONITOR="${REQUIRE_MONITOR:-true}"

# ===== Helpers =====
log() { echo "$1" | systemd-cat -t "$LOG_TAG" -p info 2>/dev/null || true; echo "$1"; }
die() { log "ERROR: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found"; }
ms_sleep() {
  # Pure-bash millisecond sleep with no external interpreter dependency.
  local ms="$1" sec frac
  sec=$(( ms / 1000 ))
  frac=$(( ms % 1000 ))
  [ "$sec" -gt 0 ] && sleep "$sec"
  [ "$frac" -gt 0 ] && sleep "0.$(printf '%03d' "$frac")"
  return 0
}

# ===== Pre-flight =====
need_cmd gpioget; need_cmd gpioset; need_cmd gpiomon; need_cmd systemctl
[ "$(id -u)" -eq 0 ] || die "This script must be run as root"

if command -v gpioinfo >/dev/null 2>&1; then
  log "Detected libgpiod: $(gpioinfo --version 2>&1 | head -n1 2>/dev/null || echo 'unknown')"
fi
$DEBUG && log "===== DEBUG MODE (no destructive ops) ====="

# Detect v2 tool syntax
USE_V2=false
if gpioget --help 2>&1 | grep -q '\-c, \-\-chip'; then
  USE_V2=true; log "Using libgpiod v2 tool syntax"
else
  USE_V2=false; log "Using libgpiod v1 tool syntax"
fi

# Track background processes for cleanup
MON_PIDS=()
SUPERCAP_PID=""

cleanup() {
  # Kill monitors on exit
  for p in "${MON_PIDS[@]:-}"; do 
    kill "$p" >/dev/null 2>&1 || true
  done
  # Kill supercap holder if it exists
  if [ -n "${SUPERCAP_PID}" ] && kill -0 "$SUPERCAP_PID" >/dev/null 2>&1; then
    kill "$SUPERCAP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ===== Supercap enable =====
enable_supercap() {
  if $DEBUG; then
    log "[DEBUG] gpioset ${CHIP} ${LINE_SUPERCAP}=1 (no-op)"
    return
  fi

  if $USE_V2; then
    # v2: daemonize mode keeps the line held after the parent exits.
    if gpioset -c "$CHIP" --daemonize "${LINE_SUPERCAP}=1"; then
      sleep 0.2  # give the daemon time to fork and grab the line
      SUPERCAP_PID="$(pgrep -n -x gpioset 2>/dev/null || true)"
      log "Super-capacitor charging enabled (GPIO ${LINE_SUPERCAP} HIGH) [v2 daemonized${SUPERCAP_PID:+ pid=$SUPERCAP_PID}]"
    else
      # Fall back to a background holder if daemonize is unsupported.
      gpioset -c "$CHIP" "${LINE_SUPERCAP}=1" &
      SUPERCAP_PID=$!
      log "Super-capacitor charging enabled (GPIO ${LINE_SUPERCAP} HIGH) [v2 background pid=${SUPERCAP_PID}]"
    fi
  else
    # v1: run gpioset in the background to HOLD the line high.
    gpioset "$CHIP" "${LINE_SUPERCAP}=1" &
    SUPERCAP_PID=$!
    log "Super-capacitor charging enabled (GPIO ${LINE_SUPERCAP} HIGH) [v1 pid=${SUPERCAP_PID}]"
  fi
}

# ===== Read states =====
read_states() {
  local out
  if $DEBUG; then
    if $USE_V2; then out="\"${LINE_PWRLOSS}\"=inactive \"${LINE_PWRGOOD}\"=active"
    else out="0 1"; fi
  else
    if $USE_V2; then out="$(gpioget -c "$CHIP" "$LINE_PWRLOSS" "$LINE_PWRGOOD" 2>&1)"
    else out="$(gpioget "$CHIP" "$LINE_PWRLOSS" "$LINE_PWRGOOD")"; fi
  fi

  local pl pg
  if $USE_V2; then
    # Handle both "LINE"=state and chip LINE=state formats
    if echo "$out" | grep -Eq "(\"${LINE_PWRLOSS}\"|${CHIP}[[:space:]]+${LINE_PWRLOSS})=active"; then pl=1
    elif echo "$out" | grep -Eq "(\"${LINE_PWRLOSS}\"|${CHIP}[[:space:]]+${LINE_PWRLOSS})=inactive"; then pl=0
    else 
      log "WARNING: Could not parse PWRLOSS from: $out"
      pl=2
    fi
    
    if echo "$out" | grep -Eq "(\"${LINE_PWRGOOD}\"|${CHIP}[[:space:]]+${LINE_PWRGOOD})=active"; then pg=1
    elif echo "$out" | grep -Eq "(\"${LINE_PWRGOOD}\"|${CHIP}[[:space:]]+${LINE_PWRGOOD})=inactive"; then pg=0
    else 
      log "WARNING: Could not parse PWRGOOD from: $out"
      pg=2
    fi
  else
    read -r pl pg <<<"$out"
  fi

  echo "$pl $pg"
}

# ===== Monitors (per-line, correct polarity) =====
start_monitors() {
  MON_PIDS=()
  if $DEBUG; then
    log "[DEBUG] would start: gpiomon PWRLOSS(rising), PWRGOOD(falling)"
    return 0
  fi

  local pid1 pid2 started=0 deadline

  if $USE_V2; then
    # v2: separate invocations for the two different edge directions.
    gpiomon -c "$CHIP" --edges=rising -n 1 "$LINE_PWRLOSS" & pid1=$!
    gpiomon -c "$CHIP" --edges=falling -n 1 "$LINE_PWRGOOD" & pid2=$!
  else
    # v1: classic syntax.
    gpiomon --num-events=1 --rising-edge "$CHIP" "$LINE_PWRLOSS" & pid1=$!
    gpiomon --num-events=1 --falling-edge "$CHIP" "$LINE_PWRGOOD" & pid2=$!
  fi
  MON_PIDS=("$pid1" "$pid2")

  # Wait up to MONITOR_START_TIMEOUTs for the monitors to settle (a monitor that
  # exits immediately means its line/chip is unavailable).
  deadline=$(( MONITOR_START_TIMEOUT * 10 ))
  while [ "$deadline" -gt 0 ]; do
    if kill -0 "$pid1" 2>/dev/null && kill -0 "$pid2" 2>/dev/null; then
      started=$((started + 1))
      [ "$started" -ge 3 ] && break
    else
      break
    fi
    ms_sleep 100
    deadline=$((deadline - 1))
  done

  if kill -0 "$pid1" 2>/dev/null && kill -0 "$pid2" 2>/dev/null; then
    log "Monitors started: PWRLOSS(${LINE_PWRLOSS}↑ pid=$pid1) PWRGOOD(${LINE_PWRGOOD}↓ pid=$pid2)"
    return 0
  fi

  log "ERROR: one or more gpiomon monitors exited immediately (chip/line unavailable)"
  cleanup
  return 1
}

wait_any_event() {
  if $DEBUG; then
    log "[DEBUG] simulate waiting 30s"; sleep 30; return 0
  fi

  # Wait for ANY monitor to finish (an event fired or the monitor died).
  if [ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }; then
    wait -n "${MON_PIDS[@]}"
  else
    wait
  fi
}

# ===== Verify event (simple debounce/confirm) =====
verify_loss() {
  local ok=0 cnt=0
  log "Verifying power loss condition..."
  
  while [ "$cnt" -lt "$VERIFY_SAMPLES" ]; do
    read -r pl pg < <(read_states)
    # Loss if PWRLOSS==1 or PWRGOOD==0
    if [ "$pl" = "1" ] || [ "$pg" = "0" ]; then
      ok=$((ok+1))
    fi
    cnt=$((cnt+1))
    [ "$cnt" -lt "$VERIFY_SAMPLES" ] && ms_sleep "$VERIFY_INTERVAL_MS"
  done
  
  log "Verification: ${ok}/${VERIFY_SAMPLES} samples confirmed loss"
  # Require majority true
  [ "$ok" -ge $(( (VERIFY_SAMPLES+1)/2 )) ]
}

handle_power_cut() {
  log "Power loss verified. Initiating safe shutdown..."
  if $DEBUG; then
    log "[DEBUG] Would execute: systemctl poweroff"
  else
    systemctl poweroff || true
  fi
  return 0
}

# ===== Main =====
enable_supercap

# Give the supercap a moment to stabilize
sleep 0.5

read -r pl pg < <(read_states)
log "Initial states — PowerLoss(${LINE_PWRLOSS})=${pl}, PowerGood(${LINE_PWRGOOD})=${pg}"

if [ "$pl" = "0" ] && [ "$pg" = "1" ]; then
  log "Pins in expected stable state. Starting monitors."
else
  log "WARNING: Unexpected initial state (PWRLOSS=${pl}, PWRGOOD=${pg}). Continuing anyway."
fi

# Supervision loop. We deliberately avoid `exec "$0"` so that systemd keeps
# tracking a single process (Restart=no means a lost main process would end the
# monitor permanently and silently disable power-loss protection).
while true; do
  if ! start_monitors; then
    if [ "$REQUIRE_MONITOR" = "true" ]; then
      die "Power-loss monitoring could not be started; refusing to run unprotected."
    fi
    log "Monitors unavailable; retrying in 10s."
    sleep 10
    continue
  fi

  # An event fired (or a monitor died). Verify before acting.
  wait_any_event

  if verify_loss; then
    handle_power_cut
    # In real mode poweroff is already in progress; stop the loop.
    exit 0
  else
    log "Glitch detected and ignored. Restarting monitors."
    cleanup
    sleep 0.5
  fi
done
