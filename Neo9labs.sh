#!/bin/bash

# Path to the script and other resources
SCRIPT="${HOME}/Neo9labs/Neo9labs.sh"
DISPLAY_SERVICE_INSTALLER="${HOME}/display_connector/display-service-installer.sh"
MCU_RPI_INSTALLER="${HOME}/Neo9labs/img-config/rpi-mcu-install.sh"
USB_STORAGE_AUTOMOUNT="${HOME}/Neo9labs/img-config/usb-storage-automount.sh"
ANDROID_RULE_INSTALLER="${HOME}/Neo9labs/img-config/adb-automount.sh"
UPDATED_DISPLAY_FIRMWARE_INSTALLER="${HOME}/display_firmware/screen-firmware.sh"
WEBCAM_SETUP_INSTALLER="${HOME}/Neo9labs/img-config/webcam-setup.sh"
BASE_IMAGE_INSTALLER="${HOME}/Neo9labs/img-config/base_image_configuration.sh"
SSH_KEY_INSTALLER="${HOME}/Neo9labs/img-config/update-ssh-keys.sh"

FLAG_FILE="/boot/.Neo9labs.txt"
MODEL_FROM_FLAG=""
KERNEL_FROM_FLAG=""
if [[ -r $FLAG_FILE ]]; then
    MODEL_FROM_FLAG=$(grep -E '^N4|^n4' "$FLAG_FILE" 2>/dev/null | head -n 1 | tr -d '\r')
    KERNEL_FROM_FLAG=$(grep 'Linux' "$FLAG_FILE" 2>/dev/null | head -n 1 | awk '{split($3,a,"-"); print a[1]}' | tr -d '\r')
fi

NEO9LABS_REPO="https://github.com/neo9labs/Neo9labes.git"
NEO9LABS_DIR="${HOME}/Neo9labs"
DISPLAY_CONNECTOR_REPO="https://github.com/neo9labs/display_connector.git"
DISPLAY_CONNECTOR_DIR="${HOME}/display_connector"
DISPLAY_FIRMWARE_REPO="https://github.com/neo9labs/display_firmware.git"
DISPLAY_FIRMWARE_DIR="${HOME}/display_firmware"

current_branch=""

# Command line arguments
model_key=""
motor_current=""
pcb_version=""
auto_yes="false"

# ASCII art for Neo9labs
NEO9LABS_ART=$(cat <<'EOF'
 _   _  _____   ___    ___   _        _     ____   ____
| \ | || ____| / _ \  / _ \ | |      / \   | __ ) / ___|
|  \| ||  _|  | | | || (_) || |     / _ \  |  _ \ \___ \
| |\  || |___ | |_| | \__, || |___ / ___ \ | |_) | ___) |
|_| \_||_____| \___/    /_/ |_____/_/   \_\|____/ |____/

EOF
)

R=$'\e[1;91m'    # Red ${R}
G=$'\e[1;92m'    # Green ${G}
Y=$'\e[1;93m'    # Yellow ${Y}
M=$'\e[1;95m'    # Magenta ${M}
C=$'\e[96m'      # Cyan ${C}
NC=$'\e[0m'      # No Color ${NC}

# ---------------------------------------------------------------------------
# Terminal UI helpers
# ---------------------------------------------------------------------------
UI_WIDTH=74
UI_USE_COLOR=0
UI_REPLY=""

ui_init() {
    local cols="${COLUMNS:-80}"

    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null || printf '%s' "$cols")
    fi
    [[ $cols =~ ^[0-9]+$ ]] || cols=80
    (( cols < 60 )) && cols=60
    (( cols > 100 )) && cols=100
    UI_WIDTH=$((cols - 4))

    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != "dumb" ]]; then
        UI_USE_COLOR=1
    else
        UI_USE_COLOR=0
        R='' G='' Y='' M='' C='' NC=''
    fi
}

clear_screen() {
    # Emit the ANSI clear sequence directly; this avoids TERM/tput failures
    # when the script is launched from a serial console or a minimal shell.
    if [[ -t 1 ]]; then
        printf '\033[H\033[2J'
    fi
}

ui_rule() {
    local char="${1:-=}" color="${2:-$C}"
    printf '%b' "$color"
    printf '%*s' "$UI_WIDTH" '' | tr ' ' "$char"
    printf '%b\n' "$NC"
}

ui_center() {
    local text="$1" color="${2:-}"
    local pad=$(( (UI_WIDTH - ${#text}) / 2 ))
    (( pad < 0 )) && pad=0
    printf '%*s%b%s%b\n' "$pad" '' "$color" "$text" "$NC"
}

ui_header() {
    local title="$1" subtitle="${2:-}"
    local branch="${current_branch:-unknown}"
    local model="${MODEL_FROM_FLAG:-not set}"
    local kernel="${KERNEL_FROM_FLAG:-unknown}"

    clear_screen
    printf '%b\n' "${C}${NEO9LABS_ART}${NC}"

    if (( ${#branch} + ${#model} + ${#kernel} + 30 > UI_WIDTH )); then
        printf '  %bBranch:%b %s   %bModel:%b %s\n' "$G" "$NC" "$branch" "$G" "$NC" "$model"
        printf '  %bKernel:%b %s\n' "$G" "$NC" "$kernel"
    else
        printf '  %bBranch:%b %s   %bModel:%b %s   %bKernel:%b %s\n' \
            "$G" "$NC" "$branch" "$G" "$NC" "$model" "$G" "$NC" "$kernel"
    fi

    ui_rule
    ui_center "$title" "$M"
    [[ -n $subtitle ]] && ui_center "$subtitle"
    ui_rule
    printf '\n'
}

ui_section() {
    local line
    line=$(printf '%*s' $((UI_WIDTH - 2)) '' | tr ' ' '-')
    printf '\n  %b%s%b\n' "$Y" "$1" "$NC"
    printf '  %b%s%b\n' "$C" "$line" "$NC"
}

ui_item() {
    local key="$1" label="$2" desc="${3:-}"
    local key_width=4 label_width=36 desc_width

    if (( ${#label} > label_width )); then
        label="${label:0:$((label_width - 3))}..."
    fi
    desc_width=$((UI_WIDTH - label_width - key_width - 6))
    (( desc_width < 8 )) && desc_width=8
    if (( ${#desc} > desc_width )); then
        desc="${desc:0:$((desc_width - 3))}..."
    fi

    printf '  %b%-*s%b %-*s' "$G" "$key_width" "$key" "$NC" "$label_width" "$label"
    [[ -n $desc ]] && printf ' %b%s%b' "$C" "$desc" "$NC"
    printf '\n'
}

ui_msg() {
    local color="$1" tag="$2" message="$3"
    printf '  %b[%-4s]%b %s\n' "$color" "$tag" "$NC" "$message"
}

ui_info() { ui_msg "$C" "INFO" "$1"; }
ui_ok()   { ui_msg "$G" "OK" "$1"; }
ui_warn() { ui_msg "$Y" "WARN" "$1"; }
ui_err()  { ui_msg "$R" "FAIL" "$1"; }

ui_confirm() {
    local prompt="$1" default="${2:-n}" hint reply

    if [[ $default == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    printf '  %b%s%b %s ' "$M" "$prompt" "$NC" "$hint"
    if ! IFS= read -r reply; then
        printf '\n'
        return 1
    fi
    reply="${reply//[[:space:]]/}"
    [[ -z $reply ]] && reply="$default"
    [[ $reply =~ ^[Yy]$ ]]
}

ui_read() {
    local prompt="$1" default="${2:-}"

    UI_REPLY=""
    if [[ -n $default ]]; then
        printf '  %b%s%b [%s]: ' "$M" "$prompt" "$NC" "$default"
    else
        printf '  %b%s%b: ' "$M" "$prompt" "$NC"
    fi

    if ! IFS= read -r UI_REPLY; then
        printf '\n'
        UI_REPLY="$default"
        return 1
    fi
    [[ -z $UI_REPLY && -n $default ]] && UI_REPLY="$default"
    return 0
}

ui_pause() {
    local message="${1:-Press Enter to continue...}"
    printf '\n  %b%s%b' "$Y" "$message" "$NC"
    read -r _ || true
}

require_cmd() {
    local cmd="$1" hint="${2:-}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        ui_err "Required command '$cmd' is not installed.${hint:+ $hint}"
        return 1
    fi
}

ui_init
trap 'printf "%b" "${NC}"' EXIT

install_webui_favicon() {
    local quiet="${1:-false}"
    local src="${HOME}/Neo9labs/img-config/webui/favicon.ico"
    local dir target installed=0

    [[ -f $src ]] || return 0

    for dir in "${HOME}/fluidd" "${HOME}/mainsail"; do
        [[ -d $dir ]] || continue

        target="$dir/favicon.ico"
        if [[ -f $target ]] && cmp -s "$src" "$target" 2>/dev/null; then
            continue
        fi

        if [[ -f $target && ! -f ${target}.neo9labs.bak ]]; then
            cp -a "$target" "${target}.neo9labs.bak" 2>/dev/null || true
        fi

        if cp -f "$src" "$target" 2>/dev/null; then
            installed=1
        else
            ui_warn "Could not install the favicon into $dir."
        fi
    done

    if (( installed )) && [[ $quiet != "true" ]]; then
        ui_ok "Web UI favicon installed for Fluidd/Mainsail."
    fi
    return 0
}

run_fixes() {
    # Get current user dynamically instead of hardcoding 'mks'
    CURRENT_USER="${USER:-$(whoami)}"
    
    # Add current user to 'gpio' and 'spiusers' groups for GPIO and SPI access
    if ! sudo usermod -aG gpio,spiusers "$CURRENT_USER" &>/dev/null; then
        printf '%s\n' "${R}Failed to add user '$CURRENT_USER' to groups 'gpio' and 'spiusers'${NC}"
    fi

    # Ensure NetworkManager override for Wi-Fi power-save exists
    NM_CONF_DIR="/etc/NetworkManager/conf.d"
    NM_PS_FILE="${NM_CONF_DIR}/zz-20-override-wifi-powersave-disable.conf"
    if [ ! -f "$NM_PS_FILE" ]; then
        if ! sudo mkdir -p "$NM_CONF_DIR"; then
            printf '%s\n' "${R}Failed to create $NM_CONF_DIR${NC}"
        elif ! sudo tee "$NM_PS_FILE" >/dev/null <<'EOF'
[connection]
wifi.powersave = 2
EOF
        then
            printf '%s\n' "${R}Failed to create $NM_PS_FILE${NC}"
        else
            sudo systemctl restart NetworkManager >/dev/null 2>&1
        fi
    fi

    # Remove obsolete GPIO script if it exists
    if [ -f "/usr/local/bin/set_gpio.sh" ]; then
        if ! sudo rm -f "/usr/local/bin/set_gpio.sh"; then
            printf '%s\n' "${R}Failed to remove /usr/local/bin/set_gpio.sh${NC}"
        fi
    fi

    # Ensure the flag file exists to mark completion of fixes
    if ! sudo touch "$FLAG_FILE"; then
        printf '%s\n' "${R}Failed to ensure flag file exists at $FLAG_FILE${NC}"
    fi

    # Append system information to the flag file if not already present
    SYSTEM_INFO=$(uname -a)
    if ! sudo grep -qF "$SYSTEM_INFO" "$FLAG_FILE" 2>/dev/null; then
        if ! echo "$SYSTEM_INFO" | sudo tee -a "$FLAG_FILE" >/dev/null; then
            printf '%s\n' "${R}Failed to append system info to $FLAG_FILE${NC}"
        fi
    fi

    # Create a symbolic link for the Neo9labs logo in Fluidd, when present.
    if [[ -d ${HOME}/fluidd ]]; then
        ln -sf "${HOME}/Neo9labs/pictures/logo_neo9labs.svg" \
            "${HOME}/fluidd/logo_neo9labs.svg" > /dev/null 2>&1 || true
    fi

    # Keep the custom browser favicon applied to Fluidd and Mainsail.
    install_webui_favicon true

    # Create a symbolic link to the main script if it doesn't exist
    SYMLINK_PATH="/usr/local/bin/neo9labs"
    if [ ! -L "$SYMLINK_PATH" ]; then
        if ! sudo ln -sf "$SCRIPT" "$SYMLINK_PATH"; then
            printf '%s\n' "${R}Failed to create symlink at $SYMLINK_PATH${NC}"
        fi
    fi

    # Add /bin/sync to crontab if not present
    if ! (crontab -l 2>/dev/null | grep -q "/bin/sync"); then
        (crontab -l 2>/dev/null | grep -v '/bin/sync'; echo "*/10 * * * * /bin/sync") | crontab -
    fi

    # Create (or repair) a power_monitor.service. If an existing unit points at a
    # stale path (e.g. hardcoded /home/mks on a different user), rewrite it.
    PM_UNIT="/etc/systemd/system/power_monitor.service"
    PM_EXPECTED="${HOME}/Neo9labs/img-config/power_monitor.sh"
    if [ ! -f "$PM_UNIT" ] || ! sudo grep -qF "ExecStart=${PM_EXPECTED}" "$PM_UNIT" 2>/dev/null; then
        sudo tee "$PM_UNIT" > /dev/null <<EOF
[Unit]
Description=Power Cut Monitor and Safe Shutdown
After=klipper.service

[Service]
Type=simple
ExecStart=${PM_EXPECTED}
User=root
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload > /dev/null 2>&1
        sudo systemctl enable power_monitor.service > /dev/null 2>&1
        sudo systemctl restart power_monitor.service > /dev/null 2>&1
    fi

    # Install/refresh the CPU & IRQ affinity service (host-to-MCU stability).
    # Re-run every boot so a Klipper restart or serial device reopen cannot
    # leave the UART IRQ / klippy threads unpinned (issues #444/#445/#420/#409).
    AFFINITY_SETUP="${HOME}/Neo9labs/img-config/affinity-setup.sh"
    if [ -f "$AFFINITY_SETUP" ]; then
        sudo bash "$AFFINITY_SETUP" >/dev/null 2>&1 || \
            printf '%s\n' "${Y}Warning: affinity setup failed.${NC}"
    fi

    # Apply UART TX-DMA mitigation for the ttyS0 MCU link (issue #444).
    UART_FIX="${HOME}/Neo9labs/img-config/uart-dma-fix.sh"
    if [ -f "$UART_FIX" ]; then
        sudo bash "$UART_FIX" >/dev/null 2>&1 || \
            printf '%s\n' "${Y}Warning: UART DMA mitigation failed.${NC}"
    fi

    # Publish the host IP for UI/display (issue #416). Ensure the include file
    # exists even if publishing fails, so Klipper's [include network.cfg] is valid.
    NET_CFG="${HOME}/printer_data/config/network.cfg"
    mkdir -p "$(dirname "$NET_CFG")"
    if [ ! -f "$NET_CFG" ]; then
        printf '# Auto-generated placeholder; see img-config/ip-publish.sh\n[gcode_macro _NET_INFO]\nvariable_ip: "unavailable"\nvariable_all_ips: "unavailable"\n\n[gcode_macro SHOW_IP]\ndescription: Print the printer IP address(es)\ngcode:\n  {action_respond_info("Printer IP: " + _NET_INFO.ip)}\n  M117 {"IP: " + _NET_INFO.ip}\n' > "$NET_CFG"
    fi
    IP_PUBLISH="${HOME}/Neo9labs/img-config/ip-publish.sh"
    if [ -f "$IP_PUBLISH" ]; then
        bash "$IP_PUBLISH" >/dev/null 2>&1 || true
    fi

    # Reconcile optional integrations (display/obico/janus/mobileraker) so they
    # stop conflicting or spamming errors (issues #424, #443, #436).
    INTEGRATIONS="${HOME}/Neo9labs/img-config/integrations.sh"
    if [ -f "$INTEGRATIONS" ]; then
        bash "$INTEGRATIONS" >/dev/null 2>&1 || \
            printf '%s\n' "${Y}Warning: integrations reconciliation failed.${NC}"
    fi

    # Make systemd-logind ignore power key / long press (silent, idempotent)
    LOGIND_CONF="/etc/systemd/logind.conf"
    if [ -f "$LOGIND_CONF" ]; then
        if ! sudo grep -q '^HandlePowerKey=ignore$' "$LOGIND_CONF" || \
           ! sudo grep -q '^HandlePowerKeyLongPress=ignore$' "$LOGIND_CONF"; then
            sudo cp "$LOGIND_CONF" "${LOGIND_CONF}.bak" 2>/dev/null || true
            sudo sed -i 's/^[#]*HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF" 2>/dev/null || true
            sudo sed -i 's/^[#]*HandlePowerKeyLongPress=.*/HandlePowerKeyLongPress=ignore/' "$LOGIND_CONF" 2>/dev/null || true
            sudo systemctl restart systemd-logind >/dev/null 2>&1 || true
        fi
    fi
}

update_repo() {
    ui_header "Repository Update" "Checking Neo9labs and companion repositories"

    if ! require_cmd git; then
        sleep 3
        return 1
    fi

    process_repo_update "$NEO9LABS_DIR" "Neo9labs"
    moonraker_update_manager "Neo9labs"

    if [ -d "${HOME}/Neo9labs/display/venv" ]; then
        ui_warn "The Touch-Screen Display Service was moved to a different directory."
        if [ "$auto_yes" = "true" ] || ui_confirm "Run the automatic migration now?" y; then
            if initialize_display_connector && eval "$DISPLAY_SERVICE_INSTALLER"; then
                rm -rf "${HOME}/Neo9labs/display"
                ui_ok "Display service migration completed."
            else
                ui_err "Display service migration failed."
            fi
        else
            ui_warn "Skipping migration. The display service will not work until it is completed."
            sleep 2
        fi
    elif [ -d "$DISPLAY_CONNECTOR_DIR" ]; then
        process_repo_update "$DISPLAY_CONNECTOR_DIR" "Display Connector"
        moonraker_update_manager "display"
    fi

    if [ -d "${HOME}/display_firmware/venv" ]; then
        process_repo_update "$DISPLAY_FIRMWARE_DIR" "Display Firmware"
        moonraker_update_manager "display_firmware"
    else
        ui_info "Display Firmware is not installed; skipping."
    fi

    ui_rule
}

process_repo_update() {
    local repo_dir="$1"
    local name="$2"
    local update_branch
    local local_rev remote_rev
    local update_output

    if [ ! -d "$repo_dir" ]; then
        ui_err "Repository directory not found: $repo_dir"
        sleep 2
        return 1
    fi

    update_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null)
    if [ -z "$update_branch" ]; then
        ui_err "Could not determine the current branch for $repo_dir."
        sleep 2
        return 1
    fi

    ui_info "Checking $name ($update_branch)..."

    if ! git -C "$repo_dir" fetch origin "$update_branch" --quiet; then
        ui_err "Failed to fetch updates for $name."
        sleep 2
        return 1
    fi

    if ! local_rev=$(git -C "$repo_dir" rev-parse '@' 2>/dev/null) ||
       ! remote_rev=$(git -C "$repo_dir" rev-parse '@{u}' 2>/dev/null); then
        ui_err "Could not resolve local/remote revisions for $name."
        sleep 2
        return 1
    fi

    if [ "$local_rev" = "$remote_rev" ]; then
        ui_ok "$name is already up-to-date."
        sleep 1
        return 0
    fi

    ui_warn "Updates are available for $name."
    if [ "$auto_yes" != "true" ] && ! ui_confirm "Install the $name update?" y; then
        ui_warn "Update skipped."
        sleep 1
        return 0
    fi

    ui_info "Updating $name..."
    if ! update_output=$(git -C "$repo_dir" pull origin "$update_branch" 2>&1); then
        if printf '%s' "$update_output" | grep -q "divergent branches"; then
            ui_warn "Divergent branches detected; resetting to origin/$update_branch."
            sleep 1
            if ! git -C "$repo_dir" reset --hard "origin/${update_branch}"; then
                ui_err "Failed to hard reset $name."
                sleep 1
                return 1
            fi
            if ! git -C "$repo_dir" clean -fd; then
                ui_err "Failed to clean $name."
                sleep 1
                return 1
            fi
        else
            ui_err "Failed to update $name."
            printf '%s\n' "$update_output"
            sleep 2
            return 1
        fi
    fi

    ui_ok "$name updated successfully."
    sleep 1

    # Warn if this update requires an eMMC/MCU re-flash rather than a normal
    # in-place update (issue #426). Repos signal this with REQUIRES_REFLASH*.
    if [ -n "$(find "$repo_dir" -maxdepth 1 -name 'REQUIRES_REFLASH*' -print -quit 2>/dev/null)" ]; then
        ui_rule "-" "$R"
        ui_warn "IMPORTANT: this update may require a device re-flash."
        printf '        A normal in-place update may not be enough for %s.\n' "$name"
        printf '        Re-flash the eMMC with the latest image.\n'
        printf '        Releases: https://github.com/neo9labs/Neo9labes/releases\n'
        ui_rule "-" "$R"
        if [ "${auto_yes:-false}" != "true" ]; then
            ui_pause "Press Enter to acknowledge..."
        fi
    fi

    return 0
}

moonraker_update_manager() {
    local update_selection="$1"
    local config_file="$HOME/printer_data/config/moonraker.conf"
    local new_lines=""

    if [[ ! -f $config_file ]]; then
        ui_warn "Moonraker config not found: $config_file"
        return 1
    fi

    if [ "$update_selection" = "Neo9labs" ]; then
        local current_neo9labs_branch
        current_neo9labs_branch=$(git -C "$NEO9LABS_DIR" symbolic-ref --short HEAD 2>/dev/null)
        [[ -n $current_neo9labs_branch ]] || current_neo9labs_branch="main"
        new_lines=$(cat <<EOF
[update_manager $update_selection]
type: git_repo
primary_branch: $current_neo9labs_branch
path: $NEO9LABS_DIR
is_system_service: False
origin: $NEO9LABS_REPO
EOF
)

    elif [ "$update_selection" = "display" ]; then
        local current_display_branch
        current_display_branch=$(git -C "$DISPLAY_CONNECTOR_DIR" symbolic-ref --short HEAD 2>/dev/null)
        [[ -n $current_display_branch ]] || current_display_branch="main"
        new_lines=$(cat <<EOF
[update_manager $update_selection]
type: git_repo
primary_branch: $current_display_branch
path: $DISPLAY_CONNECTOR_DIR
virtualenv: $DISPLAY_CONNECTOR_DIR/venv
requirements: requirements.txt
origin: $DISPLAY_CONNECTOR_REPO
managed_services: display
EOF
)

    elif [ "$update_selection" = "display_firmware" ]; then
        local current_firmware_branch
        current_firmware_branch=$(git -C "$DISPLAY_FIRMWARE_DIR" symbolic-ref --short HEAD 2>/dev/null)
        [[ -n $current_firmware_branch ]] || current_firmware_branch="main"
        new_lines=$(cat <<EOF
[update_manager $update_selection]
type: git_repo
primary_branch: $current_firmware_branch
path: $DISPLAY_FIRMWARE_DIR
is_system_service: False
virtualenv: $DISPLAY_FIRMWARE_DIR/venv
requirements: requirements.txt
origin: $DISPLAY_FIRMWARE_REPO
EOF
)

    else
        printf '%b\n' "${R}Invalid argument. Please specify either 'Neo9labs', 'display', or 'display_firmware'.${NC}"
        return 1
    fi
    
    # Update or append block
    if grep -qF "[update_manager $update_selection]" "$config_file" 2>/dev/null; then
        # Use awk for safer in-place editing
        local temp_file
        temp_file=$(mktemp)
        awk -v section="[update_manager $update_selection]" -v new_content="$new_lines" '
        BEGIN { in_section=0; printed=0 }
        $0 == section { in_section=1; print new_content; printed=1; next }
        in_section && /^\[/ { in_section=0 }
        !in_section { print }
        ' "$config_file" > "$temp_file"
        
        if [ -s "$temp_file" ]; then
            mv "$temp_file" "$config_file"
            sync
        else
            rm -f "$temp_file"
        fi
    else
        if [ -s "$config_file" ] && [ "$(tail -c1 "$config_file" 2>/dev/null)" != $'\n' ]; then
            echo >> "$config_file"
        fi
        printf "\n%s\n" "$new_lines" >> "$config_file"
    fi
}

set_current_branch() {
    current_branch=$(git -C "$NEO9LABS_DIR" symbolic-ref --short HEAD 2>/dev/null)
}

advanced_more() {
    local choice

    while true; do
        ui_header "Advanced Options" "Maintenance, recovery and experimental tools"

        ui_section "MAINTENANCE"
        ui_item "1"  "Android ADB rules"                "Fix klipperscreen apps"
        ui_item "2"  "Webcam auto-config"               "Set up mjpg-streamer"
        ui_item "3"  "Resize Armbian partition"         "For eMMC larger than 8 GB"
        ui_item "4"  "Update Neo9labs"              "Pull the latest repositories"

        ui_section "ADVANCED / RISKY"
        ui_item "5"  "Flash display firmware"           "Alpha touch-screen firmware"
        ui_item "6"  "Switch git branch"                "Toggle between main and dev"
        ui_item "7"  "Base ZNP-K1 image config"         "Not for Neo9labs"
        ui_item "8"  "Change printer hardware"          "Model, board, motor current"
        ui_item "9"  "Update SSH server keys"           "Regenerate host keys"

        ui_section "RECOVERY / DIAGNOSTICS"
        ui_item "10" "Create GitHub issue zip"          "Collect logs for support"
        ui_item "11" "Repair CPU/IRQ affinity"          "Host-to-MCU stability"
        ui_item "12" "Apply UART TX-DMA mitigation"     "ttyS0 deadlock workaround"
        ui_item "13" "Repair optional integrations"     "Display, Obico, Janus"

        ui_rule
        ui_item "b"  "Back to main menu"
        ui_rule
        printf '%b' "  ${G}Enter choice:${NC} "

        if ! read -r choice; then
            choice="b"
        fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1) android_rules ;;
            2) webcam_setup ;;
            3) armbian_resize ;;
            4) update_repo ;;
            5) display_firmware ;;
            6) toggle_branch ;;
            7) base_image_config ;;
            8) "${HOME}/Neo9labs/img-config/set-printer-model.sh"; exit 0 ;;
            9) update_ssh_keys ;;
            10) "${HOME}/Neo9labs/img-config/github-issue-debug.sh"; exit 0 ;;
            11) affinity_setup ;;
            12) uart_dma_fix ;;
            13) integrations_repair ;;
            b|B) return ;;
            *) ui_err "Invalid choice '$choice'."; sleep 1; continue ;;
        esac

        ui_pause
    done
}

install_feature() {
    local feature_name="$1"
    local action="$2"  # This can be a script path or direct commands
    local prompt_message="$3"
    local run_install=1

    ui_header "$feature_name" "Installation"

    if [[ $auto_yes != "true" ]]; then
        if ! ui_confirm "$prompt_message" y; then
            run_install=0
        fi
    fi

    if (( ! run_install )); then
        ui_warn "Installation skipped."
        sleep 1
        return 0
    fi

    printf '\n'
    ui_info "Running $feature_name installer..."

    if [[ -z $action ]]; then
        ui_err "No action is configured for $feature_name."
        sleep 2
        return 1
    fi

    if [[ -f $action ]]; then
        if bash "$action"; then
            ui_ok "$feature_name installer finished successfully."
            sleep 1
        else
            ui_err "$feature_name installer encountered an error."
            sleep 2
            return 1
        fi
    elif eval "$action"; then
        ui_ok "$feature_name installer finished successfully."
        sleep 1
    else
        ui_err "$feature_name installer encountered an error."
        sleep 2
        return 1
    fi

    return 0
}

android_rules() {
    install_feature "Android ADB Rules" "$ANDROID_RULE_INSTALLER" "Do you want to install the android ADB rules? (may fix klipperscreen issues)"
}

webcam_setup() {
    install_feature "Webcam Setup" "$WEBCAM_SETUP_INSTALLER" "Do you want to configure mjpg-streamer?"
}

base_image_config() {
    install_feature "Base Armbian Image Config" "$BASE_IMAGE_INSTALLER" "Do you want to configure a base/fresh armbian image that you compiled?"
}

update_ssh_keys() {
    install_feature "SSH Key Update" "$SSH_KEY_INSTALLER" "Do you want to update the SSH server keys?"
}

affinity_setup() {
    install_feature "CPU/IRQ Affinity Setup" "sudo bash ${HOME}/Neo9labs/img-config/affinity-setup.sh" "Re-apply CPU/IRQ affinity for MCU stability?"
}

uart_dma_fix() {
    install_feature "UART TX-DMA Fix" "sudo bash ${HOME}/Neo9labs/img-config/uart-dma-fix.sh" "Apply the ttyS0 UART TX-DMA mitigation?"
}

integrations_repair() {
    install_feature "Integrations Repair" "bash ${HOME}/Neo9labs/img-config/integrations.sh" "Repair optional integrations (display/obico/janus/mobileraker)?"
}

armbian_resize() {
    local resize_commands="sudo systemctl enable armbian-resize-filesystem && sudo reboot"
    install_feature "Armbian Resize" "$resize_commands" "Reboot then resize Armbian filesystem?"
}

toggle_branch() {
    local target_branch

    ui_header "Git Branch" "Switch between the main and dev branches"

    if ! require_cmd git; then
        sleep 3
        return 1
    fi
    if [[ ! -d $NEO9LABS_DIR ]]; then
        ui_err "$NEO9LABS_DIR does not exist or is not accessible."
        sleep 2
        return 1
    fi
    if [[ -z $current_branch ]]; then
        set_current_branch
    fi
    if [[ -z $current_branch ]]; then
        ui_err "Could not determine the current branch for $NEO9LABS_DIR."
        sleep 2
        return 1
    fi

    switch_branch() {
        local branch_name="$1"
        local repo_dir="$2"

        if [ ! -d "$repo_dir" ]; then
            return 1
        fi
        git -C "$repo_dir" reset --hard >/dev/null 2>&1
        git -C "$repo_dir" clean -fd >/dev/null 2>&1
        if git -C "$repo_dir" checkout "$branch_name" >/dev/null 2>&1; then
            ui_ok "Switched $repo_dir to $branch_name."
            return 0
        fi
        ui_err "Could not switch $repo_dir to $branch_name."
        return 1
    }

    if [[ $current_branch == "main" ]]; then
        target_branch="dev"
    else
        target_branch="main"
    fi

    ui_info "Current branch: $current_branch"
    ui_warn "Switching branches discards local changes in all managed repositories."
    if ! ui_confirm "Switch to '$target_branch'?" n; then
        ui_warn "Branch switch aborted."
        sleep 1
        return 0
    fi

    if switch_branch "$target_branch" "$NEO9LABS_DIR"; then
        moonraker_update_manager "Neo9labs"
    fi

    if [[ -d $DISPLAY_CONNECTOR_DIR ]] && switch_branch "$target_branch" "$DISPLAY_CONNECTOR_DIR"; then
        moonraker_update_manager "display"
    fi

    if [[ -d ${DISPLAY_FIRMWARE_DIR}/venv ]] && switch_branch "$target_branch" "$DISPLAY_FIRMWARE_DIR"; then
        moonraker_update_manager "display_firmware"
    fi

    ui_ok "Branch switch completed."
    sync
    sudo service moonraker restart >/dev/null 2>&1 || \
        ui_warn "Moonraker did not restart cleanly; check its service status."
    exec "$SCRIPT"
}

display_firmware() {
    ui_header "Display Firmware" "Flash or update the touch-screen firmware (Alpha)"

    if ! require_cmd git; then
        sleep 3
        return 1
    fi
    if [[ -z $current_branch ]]; then
        set_current_branch
    fi
    if [[ -z $current_branch ]]; then
        ui_err "Current git branch is not set."
        sleep 2
        return 1
    fi

    if [[ ! -d $DISPLAY_FIRMWARE_DIR ]]; then
        ui_info "Cloning Display Firmware repository..."
        if git clone -b "$current_branch" "$DISPLAY_FIRMWARE_REPO" "$DISPLAY_FIRMWARE_DIR"; then
            ui_ok "Display Firmware repository initialized."
        else
            ui_err "Failed to clone the Display Firmware repository."
            return 1
        fi
    fi

    install_feature "Display Firmware" "$UPDATED_DISPLAY_FIRMWARE_INSTALLER" \
        "Flash or update the display firmware (Alpha)?"
}

check_and_set_printer_model() {
    if [ -z "$MODEL_FROM_FLAG" ]; then
        ui_warn "Model flag is empty. Running the model setup script..."
        if [ -f "${HOME}/Neo9labs/img-config/set-printer-model.sh" ]; then
            if ! "${HOME}/Neo9labs/img-config/set-printer-model.sh"; then
                ui_err "The model setup script did not complete successfully."
                return 1
            fi
        else
            ui_err "set-printer-model.sh not found."
            return 1
        fi
        if [[ -r $FLAG_FILE ]]; then
            MODEL_FROM_FLAG=$(grep -E '^N4|^n4' "$FLAG_FILE" 2>/dev/null | head -n 1 | tr -d '\r')
        fi
        if [ -z "$MODEL_FROM_FLAG" ]; then
            ui_err "Failed to set the model flag."
            return 1
        fi
        ui_ok "Model flag set successfully."
        return 0
    fi

    ui_info "Model detected: $MODEL_FROM_FLAG"
    return 0
}

extract_model_and_motor() {
    local flag="${MODEL_FROM_FLAG//$'\r'/}"

    model_key="${flag%%-*}"
    model_key="${model_key,,}"

    # Motor current is optional and only present for n4/n4pro (e.g. "0.8A").
    if [[ $flag =~ [0-9.]+A ]]; then
        motor_current="${flag#*-}"
        motor_current="${motor_current%%A*}"
    else
        motor_current=""
    fi

    # PCB version: first "-vN.N" token. Type-C variants append "-typec" after it.
    if [[ $flag =~ -v([0-9]+\.[0-9]+) ]]; then
        pcb_version="${BASH_REMATCH[1]}"
    else
        pcb_version=""
    fi

    # Toolhead variant (e.g. typec) if present.
    if [[ ${flag,,} == *typec* ]]; then
        toolhead_variant="typec"
    else
        toolhead_variant=""
    fi
}

install_printer_cfg() {
    local diff_output spaces generated

    ui_header "Printer Configuration" "Generate and apply the latest printer.cfg"

    if ! require_cmd python3 "Install python3 and try again."; then
        sleep 3
        return 1
    fi

    if ! check_and_set_printer_model; then
        sleep 1
        return 1
    fi
    sleep 1

    extract_model_and_motor

    case "$model_key" in
        n4|n4pro|n4plus|n4max) ;;
        *)
            ui_err "Unsupported printer model '$model_key'."
            return 1
            ;;
    esac

    PRINTER_CFG_DEST="${HOME}/printer_data/config"
    DATABASE_DEST="${HOME}/printer_data/database"
    PRINTER_CFG_FILE="$PRINTER_CFG_DEST/printer.cfg"
    PRINTER_CFG_SOURCE="${HOME}/Neo9labs/printer-confs/output.cfg"
    generated="${HOME}/Neo9labs/printer-confs/generate_conf.py"

    if [[ ! -f $generated ]]; then
        ui_err "Configuration generator not found: $generated"
        return 1
    fi

    ui_info "Generating configuration for $model_key..."
    if [[ $model_key == "n4" || $model_key == "n4pro" ]]; then
        if ! python3 "$generated" "$model_key" "$motor_current" >/dev/null 2>&1; then
            ui_err "Failed to generate the printer configuration."
            return 1
        fi
    else
        if ! python3 "$generated" "$model_key" >/dev/null 2>&1; then
            ui_err "Failed to generate the printer configuration."
            return 1
        fi
    fi
    sync

    if [[ ! -f $PRINTER_CFG_SOURCE ]]; then
        ui_err "Generated configuration not found: $PRINTER_CFG_SOURCE"
        return 1
    fi
    sleep 1

    if ! mkdir -p "$PRINTER_CFG_DEST" "$DATABASE_DEST"; then
        ui_err "Could not create printer_data directories."
        return 1
    fi
    touch "${HOME}/printer_data/config/user_settings.cfg"

    if [[ $auto_yes != "true" ]] && ui_confirm "Compare your current printer.cfg with the latest?" n; then
        clear_screen
        ui_section "PRINTER.CFG DIFF"
        spaces=$(printf '%*s' 32 '')
        printf '  %bUpdated File:%b%sCurrent File:\n' "$C" "$NC" "$spaces"

        if [[ ! -f $PRINTER_CFG_FILE ]]; then
            ui_warn "No current printer.cfg found; a new file will be created."
        else
            diff_output=$(diff -y --suppress-common-lines --width=58 \
                "$PRINTER_CFG_SOURCE" "$PRINTER_CFG_FILE" 2>/dev/null || true)

            if [[ -z $diff_output ]]; then
                ui_ok "No differences; the current printer.cfg is already up-to-date."
            else
                printf '%s\n' "$diff_output"
            fi
        fi

        printf '\n'
        if ! ui_confirm "Continue with the printer.cfg update?" y; then
            ui_warn "Exiting the update process."
            sleep 1
            return 0
        fi
    else
        ui_info "Continuing with printer.cfg update..."
        sleep 1
    fi

    if ! apply_configuration; then
        ui_err "Failed to apply the printer configuration."
        return 1
    fi

    sync
    ui_info "Restarting Klipper service..."
    sleep 1
    if ! sudo service klipper restart; then
        ui_err "Klipper restart failed. Check 'sudo systemctl status klipper'."
        return 1
    fi
    ui_ok "Printer configuration applied and Klipper restarted."
}

apply_configuration() {
    local backup_count=1
    local backup_file tmp_file

    if [[ -z ${PRINTER_CFG_DEST:-} || -z ${PRINTER_CFG_FILE:-} ]]; then
        ui_err "Printer configuration paths are not initialized."
        return 1
    fi
    if [[ ! -f ${PRINTER_CFG_SOURCE:-} ]]; then
        ui_err "Invalid printer configuration source: ${PRINTER_CFG_SOURCE:-unset}"
        return 1
    fi

    if ! mkdir -p "$PRINTER_CFG_DEST"; then
        ui_err "Could not create $PRINTER_CFG_DEST."
        return 1
    fi

    backup_file="$PRINTER_CFG_DEST/backup-printer.cfg.bak$backup_count"
    while [[ -f $backup_file ]]; do
        ((backup_count++))
        backup_file="$PRINTER_CFG_DEST/backup-printer.cfg.bak$backup_count"
    done

    if [[ -f $PRINTER_CFG_FILE ]]; then
        if ! cp -a "$PRINTER_CFG_FILE" "$backup_file"; then
            ui_err "Could not back up printer.cfg; aborting to avoid data loss."
            return 1
        fi
        ui_ok "Backup created: $backup_file"
        sleep 1
    fi

    tmp_file="${PRINTER_CFG_FILE}.tmp.$$"
    if ! cp -f "$PRINTER_CFG_SOURCE" "$tmp_file"; then
        rm -f "$tmp_file"
        ui_err "Could not stage the new printer configuration."
        return 1
    fi
    if ! mv -f "$tmp_file" "$PRINTER_CFG_FILE"; then
        rm -f "$tmp_file"
        ui_err "Could not install the new printer configuration."
        return 1
    fi

    ui_ok "Printer configuration updated from $PRINTER_CFG_SOURCE."
    sleep 1
    return 0
}

install_configs() {
    # Menu label -> space-separated file list
    declare -A config_files=(
        ["Fluidd web interface Conf"]="data.mdb"
        ["Moonraker Conf"]="moonraker.conf moonraker.asvc"
        ["KAMP Conf"]="KAMP_Settings.cfg"
        ["Mainsail web interface Conf"]="mainsail.cfg"
        ["Pico USB-C ADXL Conf"]="adxl.cfg"
        ["Klipper DEBUG Addon"]="klipper_debug.cfg"
    )
    local config_order=(
        "Fluidd web interface Conf"
        "Moonraker Conf"
        "KAMP Conf"
        "Mainsail web interface Conf"
        "Pico USB-C ADXL Conf"
        "Klipper DEBUG Addon"
    )

    # ----------------- Helpers -----------------

    dest_path_for() {
        local f="$1"
        case "$f" in
            data.mdb)          printf '%s\n' "${HOME}/printer_data/database/data.mdb" ;;
            moonraker.asvc)    printf '%s\n' "${HOME}/printer_data/moonraker.asvc" ;;
            *)                 printf '%s\n' "${HOME}/printer_data/config/${f}" ;;
        esac
    }

    install_one() {
        local f="$1"
        local src="${HOME}/Neo9labs/img-config/printer-data/${f}"
        local dst dstdir tmp

        dst="$(dest_path_for "$f")"
        if [[ ! -f $src ]]; then
            ui_err "Source missing: $src"
            return 1
        fi

        dstdir="$(dirname "$dst")"
        if ! mkdir -p "$dstdir"; then
            ui_err "Could not create directory: $dstdir"
            return 1
        fi

        if [[ $f == "data.mdb" ]]; then
            mkdir -p "${HOME}/printer_data/config" "${HOME}/printer_data/database"
            tmp="${HOME}/printer_data/config/data.mdb"
            if ! cp -f "$src" "$tmp" || ! mv -f "$tmp" "$dst"; then
                ui_err "Failed to install $f."
                return 1
            fi
        elif ! cp -f "$src" "$dst"; then
            ui_err "Failed to install $f to $dst."
            return 1
        fi

        ui_ok "$f installed to $dst."
    }

    maybe_diff() {
        local f="$1"
        local src cur out

        if [[ $f == "data.mdb" ]]; then
            ui_info "Skipping diff for binary file: $f"
            return 2
        fi

        src="${HOME}/Neo9labs/img-config/printer-data/${f}"
        cur="$(dest_path_for "$f")"

        if [[ ! -f $src ]]; then
            ui_err "Source missing for diff: $src"
            return 1
        fi
        if [[ ! -f $cur ]]; then
            ui_warn "No current file found for $f; nothing to diff."
            return 3
        fi

        out="$(diff -y --suppress-common-lines --width=90 "$src" "$cur" 2>/dev/null || true)"
        if [[ -z $out ]]; then
            ui_ok "No differences for $f; up-to-date."
            return 4
        fi

        ui_info "Differences for $f:"
        printf '%s\n' "$out"
        return 0
    }

    # ----------------- Prompt / flow -----------------

    local install_configs_var="false"
    ui_header "Configuration Files" "KAMP, Moonraker, Fluidd, Mainsail and add-ons"

    if [[ $auto_yes == "true" ]]; then
        install_configs_var="true"
    else
        printf '  The latest configurations include updated settings and features.\n'
        printf '  %bRecommended on fresh installs or when resetting to defaults.%b\n\n' "$Y" "$NC"
        if ui_confirm "Install the latest configurations?" n; then
            install_configs_var="true"
        fi
    fi

    if [[ $install_configs_var != "true" ]]; then
        ui_warn "Installation of latest configurations skipped."
        sleep 1
        return 0
    fi

    install_webui_favicon

    local opt opt_name files file key failed i

    if [[ $auto_yes == "true" ]]; then
        ui_info "Installing all configurations (non-interactive mode)..."
        failed=0
        for key in "${config_order[@]}"; do
            files="${config_files[$key]}"
            for file in $files; do
                install_one "$file" || failed=1
            done
        done
        if (( failed )); then
            ui_warn "Some configurations failed to install."
        else
            ui_ok "All configurations installed."
        fi
        sleep 1
        return "$failed"
    fi

    while true; do
        ui_header "Install Configurations" "Choose a configuration set to install"

        ui_item "1" "All configurations"       "Install every file below"
        ui_item "2" "Fluidd web interface"     "Database (data.mdb)"
        ui_item "3" "Moonraker"                "moonraker.conf + services"
        ui_item "4" "KAMP"                     "KAMP_Settings.cfg"
        ui_item "5" "Mainsail web interface"   "mainsail.cfg"
        ui_item "6" "Pico USB-C ADXL"          "adxl.cfg"
        ui_item "7" "Klipper DEBUG addon"      "klipper_debug.cfg"
        ui_rule
        ui_item "8" "Exit"                     "Return to the main menu"
        ui_rule

        ui_read "Select an option (1-8)" ""

        opt="${UI_REPLY//[[:space:]]/}"
        case "$opt" in
            1)
                ui_info "Installing all configurations..."
                failed=0
                for key in "${config_order[@]}"; do
                    files="${config_files[$key]}"
                    for file in $files; do
                        install_one "$file" || failed=1
                    done
                done
                if (( failed )); then
                    ui_warn "All configurations finished with one or more errors."
                else
                    ui_ok "All configurations installed."
                fi
                sleep 2
                return "$failed"
                ;;
            2|3|4|5|6|7)
                opt_name=""
                case "$opt" in
                    2) opt_name="Fluidd web interface Conf" ;;
                    3) opt_name="Moonraker Conf" ;;
                    4) opt_name="KAMP Conf" ;;
                    5) opt_name="Mainsail web interface Conf" ;;
                    6) opt_name="Pico USB-C ADXL Conf" ;;
                    7) opt_name="Klipper DEBUG Addon" ;;
                esac
                files="${config_files[$opt_name]}"

                ui_info "Selected: $opt_name"
                if ui_confirm "Compare the current $opt_name files with the latest?" n; then
                    clear_screen
                    ui_section "DIFF: $opt_name"
                    for file in $files; do
                        local diff_rc=0
                        maybe_diff "$file" || diff_rc=$?
                        if [[ $diff_rc -eq 0 || $diff_rc -eq 2 || $diff_rc -eq 3 ]]; then
                            if ui_confirm "Continue with update for $file?" y; then
                                install_one "$file" || true
                            else
                                ui_warn "Skipping $file."
                            fi
                        fi
                    done

                    if ! ui_confirm "Install another configuration?" y; then
                        ui_warn "Exiting the update process."
                        sleep 1
                        break
                    fi
                else
                    ui_info "Continuing with $opt_name update..."
                    sleep 1
                    for file in $files; do
                        install_one "$file" || ui_warn "Failed: $file"
                    done
                fi

                ui_ok "$opt_name installed successfully."
                sleep 1
                ;;
            8)
                ui_warn "Exiting the update process."
                break
                ;;
            *)
                ui_err "Invalid selection '$opt'. Enter 1-8."
                sleep 1
                ;;
        esac
    done

    ui_ok "Selected configurations installed successfully."
    sleep 1
}

wifi_config() {
    ui_header "WiFi Configuration" "NetworkManager text interface"

    if ! require_cmd nmtui "Install NetworkManager to configure WiFi."; then
        sleep 3
        return 1
    fi

    sudo nmtui
}

usb_auto_mount() {
    install_feature "USB Auto Mount" "$USB_STORAGE_AUTOMOUNT" \
        "Automatically mount USB drives?"
}

update_mcu_rpi_fw() {
    install_feature "MCU Updater" "$MCU_RPI_INSTALLER" \
        "Update the mainboard and virtual MCU firmware?"
}

install_screen_service() {
    install_feature "Touch-Screen Display Service" run_install_screen_service_with_setup \
        "Install or update the touch-screen display service?"
}

run_install_screen_service_with_setup() {
    if [[ -d ${HOME}/display_connector ]]; then
        rm -rf "${HOME}/display_connector" || {
            ui_err "Could not remove the old display_connector checkout."
            return 1
        }
    fi

    if ! initialize_display_connector; then
        ui_err "Failed to initialize display_connector."
        return 1
    fi
    if [[ ! -f $DISPLAY_SERVICE_INSTALLER ]]; then
        ui_err "Display service installer not found: $DISPLAY_SERVICE_INSTALLER"
        return 1
    fi

    bash "$DISPLAY_SERVICE_INSTALLER"
}

initialize_display_connector() {
    if ! require_cmd git; then
        return 1
    fi
    if [[ -z $current_branch ]]; then
        set_current_branch
    fi
    if [[ -z $current_branch ]]; then
        ui_err "Current git branch is not set."
        return 1
    fi

    if [ ! -d "$DISPLAY_CONNECTOR_DIR" ]; then
        if git clone -b "$current_branch" "$DISPLAY_CONNECTOR_REPO" "$DISPLAY_CONNECTOR_DIR"; then
            ui_ok "Display Connector repository initialized."
        else
            ui_err "Failed to clone the Display Connector repository."
            return 1
        fi
    fi

    if ! moonraker_update_manager "display"; then
        ui_warn "Display repository is ready, but the Moonraker update block was not written."
    fi
    return 0
}

reboot_system() {
    ui_header "Reboot Required" "A reboot is needed to apply the changes"

    sync
    if [ "$auto_yes" != "true" ] && ! ui_confirm "Reboot the printer now?" y; then
        ui_warn "Reboot canceled."
        sleep 1
        return 0
    fi

    ui_info "System will reboot now..."
    sleep 1
    sudo reboot
}

print_help() {
    cat << EOF
Usage: $0 [OPTIONS] COMMAND
Neo9labs configuration script.

Options:
  -y, --yes                  Automatically confirm all prompts (non-interactive mode).
  --printer_model=MODEL      Specify the printer model (e.g., n4, n4pro, n4plus / n4max).
  --motor_current=VALUE      Specify the stepper motor current (e.g., 0.8, 1.2).
  --pcb_version=VERSION      Specify the mainboard PCB version (e.g., 2.3).
  -h, --help                 Display this help message and exit.

Commands:
  install_printer_cfg        Install or update the Neo9labs printer.cfg.
  install_configs            Install or update KAMP/Moonraker/Fluidd/Mainsail configs.
  wifi_config                Launch NetworkManager's text UI (nmtui).
  update_mcu_rpi_fw          Update MCU and virtual MCU firmware.
  install_screen_service     Install or update the touch-screen service (BETA).
  usb_auto_mount             Enable USB storage auto-mount.
  update_repo                Update the Neo9labs repositories.
  android_rules              Install Android ADB rules (klipperscreen).
  webcam_setup               Configure mjpg-streamer.
  base_image_config          Apply base config to a freshly built Armbian image.
  armbian_resize             Resize the active Armbian partition (eMMC > 8GB).
  affinity_setup             Re-apply CPU/IRQ affinity for host-to-MCU stability.
  uart_dma_fix               Apply the ttyS0 UART TX-DMA deadlock mitigation.
  integrations_repair        Reconcile optional integrations (display/obico/janus).

Exit status:
  0  Success
  1  Invalid option, unknown command, or a requested action failed.

EOF
}

print_menu() {
    ui_header "Neo9labs Control Center" "De-Elegoo-izing the Neo9labs series"

    ui_section "PRINTER"
    ui_item "1" "Install / update printer.cfg" "Apply the generated model cfg"
    ui_item "2" "Install / update web configs" "KAMP, Moonraker, Fluidd, UI"
    ui_item "3" "Configure WiFi"                 "NetworkManager text UI"
    ui_item "4" "Update MCU firmware"            "Mainboard and virtual MCU"
    ui_item "5" "Touch-screen service"           "Install or update (BETA)"
    ui_item "6" "USB storage auto-mount"         "Auto-mount USB drives"

    ui_section "SYSTEM"
    ui_item "7" "Advanced options"               "Maintenance and recovery"

    ui_rule
    ui_item "q" "Quit"
    ui_rule
    printf '%b' "  ${G}Enter choice:${NC} "
}

# Parse Command-Line Arguments
if ! TEMP=$(getopt -o yh --long yes,help,printer_model:,motor_current:,pcb_version: -n 'Neo9labs.sh' -- "$@"); then
    printf '%b\n' "${R}Failed to parse options.${NC}" >&2
    exit 1
fi

eval set -- "$TEMP"

while true; do
    case "$1" in
        --printer_model) model_key="$2"; shift 2 ;;
        --motor_current) motor_current="$2"; shift 2 ;;
        --pcb_version) pcb_version="$2"; shift 2 ;;
        -y|--yes) auto_yes="true"; shift ;;
        -h|--help) print_help; exit 0 ;;
        --) shift; break ;;
        *) printf '%b\n' "${R}Invalid option: $1 ${NC}"; exit 1 ;;
    esac
done

# Main Script Logic
if [ -z "$1" ]; then
    run_fixes
    set_current_branch
    update_repo

    while true; do
        print_menu

        if ! read -r choice; then
            printf '\n'
            clear_screen
            ui_ok "Goodbye."
            exit 0
        fi
        choice="${choice//[[:space:]]/}"

        case "$choice" in
            1) install_printer_cfg ;;
            2) install_configs ;;
            3) wifi_config ;;
            4) update_mcu_rpi_fw ;;
            5) install_screen_service ;;
            6) usb_auto_mount ;;
            7) advanced_more; continue ;;
            q|Q)
                clear_screen
                ui_ok "Goodbye."
                exit 0
                ;;
            *)
                ui_err "Invalid choice '$choice'. Enter 1-7 or q."
                sleep 1
                continue
                ;;
        esac

        ui_pause "Press Enter to return to the main menu..."
    done
else
    run_fixes
    COMMAND="$1"
    case "$COMMAND" in
        install_printer_cfg) install_printer_cfg ;;
        install_configs) install_configs ;;
        wifi_config) wifi_config ;;
        update_mcu_rpi_fw) update_mcu_rpi_fw ;;
        install_screen_service) install_screen_service ;;
        usb_auto_mount) usb_auto_mount ;;
        update_repo) update_repo ;;
        android_rules) android_rules ;;
        webcam_setup) webcam_setup ;;
        base_image_config) base_image_config ;;
        armbian_resize) armbian_resize ;;
        affinity_setup) affinity_setup ;;
        uart_dma_fix) uart_dma_fix ;;
        integrations_repair) integrations_repair ;;
        *)
            ui_err "Unknown command '$COMMAND'."
            printf 'Run %s --help for the command list.\n' "$0" >&2
            exit 1
            ;;
    esac
fi
