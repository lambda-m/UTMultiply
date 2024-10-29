#!/bin/bash

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Help Message
show_help() {
    echo -e "${CYAN}Usage: $0 [options]${RESET}"
    echo -e "${CYAN}Clone a UTM template VM with a new hostname, configure SSH, and set up networking.${RESET}"
    echo -e "${CYAN}Options:${RESET}"
    echo -e "  ${CYAN}-h, --help${RESET}        Show this help message."
    echo -e "  ${CYAN}-a, --all-vms${RESET}     Allow cloning of any VM, not just templates."
    echo -e "${YELLOW}Warning: Cloning non-template VMs may cause issues if the VM is not set up for cloning, e.g., static IP configuration, missing QEMU guest agent, etc.${RESET}"
    exit 0
}


# Parse Options
include_all_vms=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -a|--all-vms)
            include_all_vms=true
            echo -e "${YELLOW}Warning: Cloning non-template VMs may cause issues if the VM is not set up for cloning (e.g., static IP, missing QEMU guest agent).${RESET}"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done


# Spinner
spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Fetch Template VMs or All VMs based on the include_all_vms flag
fetch_templates() {
    echo -ne "${YELLOW}Fetching list of VMs...${RESET}"
    if [ "$include_all_vms" = true ]; then
        # Fetch all VMs
        vm_names=$(osascript <<END
tell application "UTM"
    set allVMNames to ""
    repeat with vm in virtual machines
        set allVMNames to allVMNames & name of vm & linefeed
    end repeat
    return allVMNames
end tell
END
)
    else
        # Fetch only Template VMs
        vm_names=$(osascript <<END
tell application "UTM"
    set templateNames to ""
    repeat with vm in virtual machines
        if name of vm starts with "Template" then
            set templateNames to templateNames & name of vm & linefeed
        end if
    end repeat
    return templateNames
end tell
END
)
    fi
    IFS=$'\n' read -r -d '' -a template_array <<< "$vm_names"
    echo -e " ${GREEN}[Done]${RESET}"
}


# Display Templates and Get User Selection
select_template() {
    echo -e "\n${CYAN}Select Template:${RESET}"
    for i in "${!template_array[@]}"; do
        printf "  %2d. %s\n" "$((i + 1))" "${template_array[$i]}"
    done
    echo -e "\n"
    while true; do
        read -p "Please enter a number [Default: 1]: " selection
        selection=${selection:-1}
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection > 0 && selection <= ${#template_array[@]} )); then
            selected_template="${template_array[$((selection - 1))]}"
            echo -e "${GREEN}You selected: $selected_template${RESET}"
            break
        else
            echo -e "${RED}Invalid selection. Try again.${RESET}"
        fi
    done
}

# Get Unique Hostname
get_hostname() {
    existing_vms=($(utmctl list | awk '{for (i=3; i<=NF; i++) printf $i" "; print ""}'))
    while true; do
        read -p "Please enter a new hostname for $selected_template: " new_hostname
        if [[ " ${existing_vms[@]} " =~ " $new_hostname " ]]; then
            echo -e "${RED}Error: A VM with the name '$new_hostname' already exists. Choose a different name.${RESET}"
        elif [[ "$new_hostname" =~ ^[a-z0-9-]+$ ]]; then
            echo -e "${GREEN}Hostname is valid: $new_hostname${RESET}"
            break
        else
            echo -e "${RED}Invalid hostname. Use only lowercase letters, numbers, and dashes.${RESET}"
        fi
    done
}

# Clone VM
clone_vm() {
    echo -ne "${YELLOW}Cloning $selected_template as $new_hostname...${RESET}"
    utmctl clone "$selected_template" --name "$new_hostname" & spinner
    echo -e "${GREEN}[Done]${RESET}"
}

# Randomize MAC
randomize_mac() {
    echo -ne "${YELLOW}Randomizing MAC address...${RESET}"
    osascript <<END
tell application "UTM"
    set vm to virtual machine named "$new_hostname"
    set config to configuration of vm
    set item 1 of network interfaces of config to {address:""}
    update configuration of vm with config
end tell
END
    echo -e "${GREEN}[Done]${RESET}"
}

# Start VM and Check Status
start_vm() {
    echo -ne "${YELLOW}Starting VM...${RESET}"
    utmctl start "$new_hostname" & spinner
    for attempt in {1..10}; do
        vm_status=$(utmctl status "$new_hostname" 2>/dev/null)
        if [[ "$vm_status" == "started" ]]; then
            echo -e "${GREEN}[Done]${RESET}"
            return 0
        fi
        sleep 5
    done
    echo -e "${RED}[Failed]${RESET}"
    exit 1
}

# Retrieve IP Address
get_ip_address() {
    echo -ne "${YELLOW}Retrieving IP address...${RESET}"
    sleep 10
    for i in {1..10}; do
        ipv4_address=$(utmctl ip-address "$new_hostname" 2>/dev/null | head -n 1)
        if [[ -n "$ipv4_address" ]]; then
            echo -e "${GREEN}[Done]${RESET}"
            return 0
        fi
        sleep 4
    done
    echo -e "${RED}[Failed]${RESET}"
    exit 1
}

# Change Hostname on VM
change_vm_hostname() {
    echo -ne "${YELLOW}Setting hostname on the VM...${RESET}"
    # SSH into the VM and update hostname across key configuration files
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ipv4_address" <<EOF > /dev/null 2>&1
sudo hostnamectl set-hostname $new_hostname || sudo hostname $new_hostname
echo "$new_hostname" | sudo tee /etc/hostname
sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/" /etc/hosts
EOF
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}[Done]${RESET}"
    else
        echo -e "${RED}[Failed]${RESET}"
        exit 1
    fi
}


# Update SSH Config
update_ssh_config() {
    echo -ne "${YELLOW}Updating SSH config...${RESET}"
    ssh_config_entry="\nHost $new_hostname\n  HostName $ipv4_address\n  User maarten\n  IdentityFile ~/.ssh/id_ecdsa\n  StrictHostKeyChecking no\n"
    if grep -q "^Host $new_hostname$" ~/.ssh/config; then
        sed -i '' "/^Host $new_hostname$/,/^$/d" ~/.ssh/config
    fi
    echo -e "$ssh_config_entry" >> ~/.ssh/config
    echo -e "${GREEN}[Done]${RESET}"
}

# Main Execution Flow
fetch_templates
select_template
get_hostname
clone_vm
randomize_mac
start_vm
get_ip_address
change_vm_hostname
update_ssh_config

# Final Summary
echo -e "\n${CYAN}Summary:${RESET}"
echo -e "${CYAN}  VM Name     : $new_hostname${RESET}"
echo -e "${CYAN}  IP Address  : $ipv4_address${RESET}"
echo -e "${CYAN}  SSH Command : ssh $new_hostname\n${RESET}"
