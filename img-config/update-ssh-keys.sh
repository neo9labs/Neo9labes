#!/usr/bin/env bash

# Verify that ssh config is correct before making any changes
if ! sudo sshd -t; then
    echo "sshd configuration is found to be incorrect before run, no changes done."
    exit 1
fi

NOW=$(date '+%F_%H:%M:%S')
OLD_DIR="/etc/ssh/keys_${NOW}.old"

# Creating the directory to store old keys
sudo mkdir -p "$OLD_DIR"
# Backup old keys (guard with nullglob-like existence check)
shopt -s nullglob
old_keys=(/etc/ssh/ssh_host*_key /etc/ssh/ssh_host*_key.pub)
if [[ ${#old_keys[@]} -gt 0 ]]; then
    sudo mv "${old_keys[@]}" "$OLD_DIR"
fi
shopt -u nullglob

# This will generate new keys and place them in the default location
sudo ssh-keygen -A
sync

# Check if ssh config is correct before restarting the service
if ! sudo sshd -t; then
    # Restore the old keys (must be done with privileges).
    sudo cp -a "$OLD_DIR"/. /etc/ssh/

    echo "sshd configuration check failed after key regeneration, we have tried to restore the old keys."
    echo "Please check the sshd configuration before rebooting the system."
    echo "Command to check the sshd configuration: sudo sshd -t"
    echo "You should have no errors."
    echo "You can find the old keys backed up in $OLD_DIR ."
    exit 1
fi

# Restarting the sshd service to apply changes
sudo systemctl restart sshd

echo "sshd key has been regenerated and service restarted, old keys are persisted in $OLD_DIR ."
echo "You may need to run 'ssh-keygen -R <hostname>' on your client machine(s) to remove the old keys from known_hosts file."
