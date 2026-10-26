#!/usr/bin/env bash
# Purpose: Reconcile optional integration services (display, obico, janus,
#          mobileraker, etc.) so they do not conflict or spam errors (issues
#          #424, #443, #436).
#
# Actions:
#   * Rebuild ~/printer_data/moonraker.asvc so it only lists services that are
#     actually installed/known, instead of unconditionally listing moonraker-obico
#     (which errors when absent).
#   * Detect known port conflicts between optional components and warn.
#   * Print clear install guidance for the optional components.

set -euo pipefail

HOME_DIR="${HOME}"
ASVC="${HOME_DIR}/printer_data/moonraker.asvc"
MOONRAKER_CONF="${HOME_DIR}/printer_data/config/moonraker.conf"

log() { echo "[integrations] $*"; }

# Candidate optional services and the systemd unit that indicates presence.
declare -A OPTIONAL=(
  [klipper_mcu]="klipper-mcu.service"
  [webcamd]="webcamd.service"
  [MoonCord]="MoonCord.service"
  [KlipperScreen]="KlipperScreen.service"
  [moonraker-telegram-bot]="moonraker-telegram-bot.service"
  [moonraker-obico]="moonraker-obico.service"
  [sonar]="sonar.service"
  [octoeverywhere]="octoeverywhere.service"
  [ratos-configurator]="ratos-configurator.service"
  [mobileraker]="mobileraker.service"
  [display]="display.service"
  [janus]="janus.service"
)

is_installed() {
  local unit="$1"
  # Installed if the unit exists (enabled or not) or the program dir is present.
  if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
    return 0
  fi
  [[ -f "/etc/systemd/system/${unit}" ]] && return 0
  return 1
}

# 1) Rebuild moonraker.asvc with only genuinely available services.
rebuild_asvc() {
  mkdir -p "$(dirname "$ASVC")"
  local tmp; tmp="$(mktemp)"
  {
    echo "# Auto-managed by neo9labs-integrations.sh"
    echo "# Lists only services that are actually installed to avoid Moonraker errors."
  } > "$tmp"

  local name unit
  for name in "${!OPTIONAL[@]}"; do
    unit="${OPTIONAL[$name]}"
    if is_installed "$unit"; then
      echo "$name" >> "$tmp"
      log "included: $name ($unit)"
    else
      log "omitted (not installed): $name"
    fi
  done

  mv "$tmp" "$ASVC"
  log "wrote $ASVC"
}

# 2) Warn about the most common optional-component conflicts.
check_conflicts() {
  # Obico and Janus are mutually-exclusive remote-access plugins in practice;
  # running both can cause duplicate API polling and Moonraker warnings.
  if is_installed "moonraker-obico.service" && is_installed "janus.service"; then
    log "WARNING: both moonraker-obico and janus are installed."
    log "         Running both remote-access plugins simultaneously is known to cause"
    log "         duplicate polling / Moonraker errors. Disable one:"
    log "           sudo systemctl disable --now moonraker-obico   # or janus"
  fi
  # Display service and KlipperScreen both bind a touch UI; conflicts are common.
  if is_installed "display.service" && is_installed "KlipperScreen.service"; then
    log "WARNING: both 'display' (Neo9labs touch) and KlipperScreen are installed."
    log "         Disable KlipperScreen if using the Neo9labs display service:"
    log "           sudo systemctl disable --now KlipperScreen"
  fi
}

# 3) Disable [update_manager ...] blocks whose managed path/virtualenv is missing,
#    which otherwise makes Moonraker log repeated errors (issue #443).
prune_update_managers() {
  [[ -f "$MOONRAKER_CONF" ]] || { log "no moonraker.conf at $MOONRAKER_CONF"; return 0; }

  local tmp; tmp="$(mktemp)"
  local in_um=0 bad=0 block=""
  local line val expanded out=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[ ]]; then
      # Flush the previous block.
      if [[ -n "$block" ]]; then
        if [[ "$bad" -eq 1 ]]; then
          while IFS= read -r bl; do out+="# disabled (missing path) ${bl}"$'\n'; done <<< "${block%$'\n'}"
        else
          out+="$block"
        fi
      fi
      block=""; bad=0
      if [[ "$line" =~ ^\[update_manager ]]; then
        in_um=1
      else
        in_um=0
      fi
    fi

    if [[ "$in_um" -eq 1 ]]; then
      block+="${line}"$'\n'
      if [[ "$line" =~ ^[[:space:]]*(path|virtualenv)[[:space:]]*: ]]; then
        val="${line#*:}"
        val="${val#"${val%%[![:space:]]*}"}"   # ltrim
        val="${val%"${val##*[![:space:]]}"}"   # rtrim
        expanded="${val/#\~/$HOME_DIR}"
        [[ -e "$expanded" ]] || bad=1
      fi
    else
      out+="${line}"$'\n'
    fi
  done < "$MOONRAKER_CONF"

  # Flush the final block.
  if [[ -n "$block" ]]; then
    if [[ "$bad" -eq 1 ]]; then
      while IFS= read -r bl; do out+="# disabled (missing path) ${bl}"$'\n'; done <<< "${block%$'\n'}"
    else
      out+="$block"
    fi
  fi

  printf '%s' "$out" > "$tmp"

  if ! diff -q "$MOONRAKER_CONF" "$tmp" >/dev/null 2>&1; then
    cp "$MOONRAKER_CONF" "${MOONRAKER_CONF}.bak.integrations" 2>/dev/null || true
    mv "$tmp" "$MOONRAKER_CONF"
    log "pruned update_manager blocks with missing paths (backup: ${MOONRAKER_CONF}.bak.integrations)"
  else
    rm -f "$tmp"
    log "no update_manager pruning needed"
  fi
}

case "${1:-all}" in
  asvc)      rebuild_asvc ;;
  conflicts) check_conflicts ;;
  prune)     prune_update_managers ;;
  all|*)     rebuild_asvc; check_conflicts; prune_update_managers ;;
esac

log "done."
