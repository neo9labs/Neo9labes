#!/bin/bash
# Script location $HOME/Neo9labs/img-config/set-printer-model.sh

# Define the flag file path
FLAG_FILE="/boot/.Neo9labs.txt"

# Toolhead variant (empty = standard ribbon, "typec" = Type-C toolhead cable).
toolhead_variant="${toolhead_variant:-}"

# Function to select an option
select_option() {
    local -n ref=$1
    echo -e "$2"
    select opt in "${@:3}"; do
        if [[ -n $opt ]]; then
            ref=$opt
            break
        else
            echo -e "Invalid option, please try again."
        fi
    done
}

# Warn (do not silently proceed) when the detected/selected board is a known
# unsupported revision. ZNP-K1 V2.3 boards have different extruder detection and
# config layout (issues #405, #437).
warn_if_unsupported_board() {
    local detected=""
    if command -v gpioinfo >/dev/null 2>&1; then
        detected="$(gpioinfo 2>/dev/null | grep -iE 'expander|pca95|aw9523|tca64' | head -n1 || true)"
    fi
    # Explicit board selection from the CLI/env (e.g. --pcb_version 2.3).
    if [[ "$pcb_version" == "2.3" ]]; then
        printf '%b\n' "WARNING: ZNP-K1 V2.3 boards are not officially supported yet."
        printf '%b\n' "         Extruder detection and Z-offset persistence may fail (issue #405)."
        printf '%b\n' "         Continuing at your own risk. See the wiki for known limitations."
        if [[ "${auto_yes:-false}" != "true" ]]; then
            read -r -p "Continue anyway? (y/N): " _c
            [[ "$_c" =~ ^[Yy]$ ]] || exit 1
        fi
    fi
}

# Headless operation checks
if [ "$auto_yes" = "true" ]; then
    if [[ "$model_key" = "n4" || "$model_key" = "n4pro" ]] && [[ -z "$motor_current" || -z "$pcb_version" ]]; then
        echo "Headless mode for n4 and n4pro requires --motor_current and --pcb_version."
        exit 1
    elif [ -z "$model_key" ]; then
        echo "Headless mode requires --printer_model."
        exit 1
    fi
else
    # Interactive mode for model selection
    echo "Please select your printer model:"
    select _ in "Neo9labs" "Neo9labs Pro" "Neo9labs Plus" "Neo9labs Max"; do
        case $REPLY in
            1) model_key="n4";;
            2) model_key="n4pro";;
            3) model_key="n4plus";;
            4) model_key="n4max";;
            *) echo "Invalid selection. Please try again."; continue;;
        esac
        break
    done
    # Interactive mode for motor current and PCB version if applicable
    if [[ "$model_key" = "n4" || "$model_key" = "n4pro" ]]; then
        [ -z "$motor_current" ] && select_option motor_current "Select the stepper motor current:" "0.8" "1.2"
        [ -z "$pcb_version" ] && select_option pcb_version "Select the PCB version:" "1.0" "1.1"
    fi
    # Type-C toolhead variant (issues #417, #437). It changes the toolhead wiring
    # / ADXL configuration, so it must be recorded explicitly.
    if [[ -z "$toolhead_variant" ]]; then
        select_option toolhead_variant "Select the toolhead cable variant:" "Standard" "Type-C"
    fi
fi

warn_if_unsupported_board

# Normalise the Type-C selection.
case "$toolhead_variant" in
    typec|type-c|Type-C|"Type-C"|"type c") toolhead_variant="typec" ;;
    *) toolhead_variant="" ;;
esac

# Define FLAG_LINE before generating configuration
if [[ "$model_key" = "n4" || "$model_key" = "n4pro" ]]; then
    FLAG_LINE="${model_key}-${motor_current}A-v${pcb_version}"
else
    pcb_version="2.0"
    FLAG_LINE="${model_key}-v${pcb_version}"
fi
[[ -n "$toolhead_variant" ]] && FLAG_LINE="${FLAG_LINE}-${toolhead_variant}"

# Capitalize the 1st and 3rd letters of the model_key
FLAG_LINE=$(echo "$FLAG_LINE" | sed -E 's/^(n)(4)(.)(.*)/\U\1\2\3\E\4/')

echo "DEBUG: FLAG_LINE is $FLAG_LINE"

# Function to update the flag file
update_flag_file() {
    local flag_value=$1
    # Remove existing lines starting with N4 (case-insensitive), then add the new line
    sudo sed -i '/^n4/I d' "$FLAG_FILE"
    echo "$flag_value" | sudo tee -a "$FLAG_FILE" > /dev/null
}

update_flag_file "$FLAG_LINE"

# Check the contents of the FLAG_FILE
#echo "DEBUG: Contents of $FLAG_FILE"
#sudo cat "$FLAG_FILE"
sync
exit 0
