#!/bin/bash
set -e

# Progress spinner function
spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  local msg="$2"
  
  printf "$msg "
  
  while [ "$(ps -p $pid | grep -c $pid)" -eq 1 ]; do
    local temp=${spinstr#?}
    printf "[%c]" "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b"
  done
  printf "   \b\b\b\b\b\b\033[32m[OK]\033[0m\n"
}

# Run command silently with progress indicator
run_with_progress() {
  local command="$1"
  local message="$2"
  
  # Run the command in background and capture its PID
  eval "$command" > /dev/null 2>&1 & 
  local pid=$!
  
  # Display spinner while command runs
  spinner $pid "$message"
  
  # Make sure the command finished successfully
  wait $pid
  if [ $? -ne 0 ]; then
    printf "\033[31m[FAILED]\033[0m\n"
    echo "Command failed: $command"
    exit 1
  fi
}

# Function to print colored status messages
status() {
  echo -e "\033[1;34m[*]\033[0m $1"
}

# Function to print completed steps
success() {
  echo -e "\033[1;32m[✓]\033[0m $1"
}

echo '                 _____ ______  ___   _   _ _____  ___  __   __  '
echo '                /  __ \| ___ \/ _ \ | \ | |_   _|/ _ \ \ \ / / '
echo '                | /  \/| |_/ / /_\ \|  \| | | | / /_\ \ \ V /  '
echo '                | |    |    /|  _  || . ` | | | |  _  | /   \ '
echo '                | \__/\| |\ \| | | || |\  |_| |_| | | |/ /^\ \ '
echo '                 \____/\_| \_\_| |_/\_| \_/\___/\_| |_/\/   \/ '
echo '                                              '
echo '==============================================================================='
echo '                   sFlow Traffic Monitor and Trigger                       '
echo '                      by Ali E. Mubarak (Craniax)                           '
echo '==============================================================================='
echo


# Exit if not root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

# Detect OS and version
OS=""
VERSION=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
  VERSION=$VERSION_ID
fi
echo "Detected OS: $OS $VERSION"

# sFlow package version tag
SFL_TAG="v2.0.53-1"
case "$OS" in
  ubuntu)
    case "$VERSION" in
      24.04|22.04) PKG="hsflowd-ubuntu22_2.0.53-1_amd64.deb";;
      20.04) PKG="hsflowd-ubuntu20_2.0.53-1_amd64.deb";;
      18.04) PKG="hsflowd-ubuntu18_2.0.53-1_amd64.deb";;
      *) echo "Unsupported Ubuntu version: $VERSION"; exit 1;;
    esac;;
  debian)
    case "$VERSION" in
      12) PKG="hsflowd-debian12_2.0.53-1_amd64.deb";;
      11) PKG="hsflowd-debian11_2.0.53-1_amd64.deb";;
      10) PKG="hsflowd-debian10_2.0.53-1_amd64.deb";;
      *) echo "Unsupported Debian version: $VERSION"; exit 1;;
    esac;;
  rhel|centos|almalinux)
    case "$VERSION" in
      9*) PKG="hsflowd-redhat9-2.0.53-1.x86_64.rpm";;
      *) echo "Unsupported RHEL/CentOS/AlmaLinux version: $VERSION"; exit 1;;
    esac;;
  *)
    echo "Unsupported OS: $OS"; exit 1;;
esac
URL="https://github.com/sflow/host-sflow/releases/download/${SFL_TAG}/${PKG}"

# Save original directory before any cd commands
ORIG_DIR="$(pwd)"

# Install dependencies
status "Installing dependencies"
if [[ "$OS" == ubuntu || "$OS" == debian ]]; then
  run_with_progress "apt-get update" "Updating package repositories..."
  run_with_progress "apt-get install -y wget curl tcpdump" "Installing required tools..."
elif [[ "$OS" == rhel || "$OS" == centos || "$OS" == almalinux ]]; then
  run_with_progress "yum install -y wget curl tcpdump" "Installing required tools..."
fi
success "Dependencies installed"

# Download and install hsflowd
status "Setting up hsflowd agent"
cd /tmp
if command -v wget >/dev/null 2>&1; then
  run_with_progress "wget -q \"$URL\" -O \"$PKG\"" "Downloading hsflowd package..."
else
  run_with_progress "curl -sL \"$URL\" -o \"$PKG\"" "Downloading hsflowd package..."
fi

# Install hsflowd
if [[ "$PKG" == *.deb ]]; then
  run_with_progress "dpkg -i \"$PKG\" || apt-get install -f -y" "Installing hsflowd package..."
elif [[ "$PKG" == *.rpm ]]; then
  run_with_progress "yum localinstall -y \"$PKG\"" "Installing hsflowd package..."
fi
rm -f "/tmp/$PKG"
success "hsflowd installed successfully"

# Return to original directory
cd "$ORIG_DIR"

# Select interface to monitor
echo ""
echo "Available network interfaces:"
echo "---------------------------"

# Get the list of interfaces with IPv4 addresses only
mapfile -t interfaces < <(ip -o addr show | grep -v "127.0.0.1" | grep -v "::" | grep inet | awk '{print $2 " - " $4}' | cut -d/ -f1 | sort -u)

# Display interfaces with numbers
for i in "${!interfaces[@]}"; do
  echo "$((i+1))) ${interfaces[$i]}"
done

# Prompt for interface selection
while true; do
  read -p "Select interface number to monitor [1]: " ifnum
  ifnum=${ifnum:-1}  # Default to 1 if empty
  if [[ "$ifnum" =~ ^[0-9]+$ ]] && [ "$ifnum" -ge 1 ] && [ "$ifnum" -le "${#interfaces[@]}" ]; then
    selected_if=$(echo "${interfaces[$((ifnum-1))]}" | awk '{print $1}')
    break
  else
    echo "Invalid selection. Please enter a number between 1 and ${#interfaces[@]}."
  fi
done

echo "Selected interface: $selected_if"

# Configure hsflowd
status "Configuring hsflowd for interface $selected_if"

HSFLOW_CONF="/etc/hsflowd.conf"

# Backup existing config if it exists
if [ -f "$HSFLOW_CONF" ]; then
  run_with_progress "cp \"$HSFLOW_CONF\" \"${HSFLOW_CONF}.bak\"" "Backing up existing configuration..."
fi

# Define the sFlow collector port to use
# Try to find an available port starting with 6343
SFLOW_PORT=6343

# Check if port is in use and try alternatives if needed
if ss -lun | grep -q ":$SFLOW_PORT "; then
  status "Port $SFLOW_PORT is in use, trying alternative ports"
  # Try a few alternative ports
  for alt_port in 6344 6345 6346 6347; do
    if ! ss -lun | grep -q ":$alt_port "; then
      SFLOW_PORT=$alt_port
      success "Selected available port: $SFLOW_PORT"
      break
    fi
  done
fi

# Make port available in JSON config for net_monitor.js
# First check if jq is installed
if command -v jq >/dev/null 2>&1; then
  run_with_progress "jq \".port = $SFLOW_PORT\" \"$(pwd)/config.json\" > \"$(pwd)/config.json.tmp\" && mv \"$(pwd)/config.json.tmp\" \"$(pwd)/config.json\"" "Updating config.json with port settings..."
else
  # Fallback for systems without jq - use sed with simple pattern replacement
  if grep -q '"port"' "$(pwd)/config.json"; then
    # Replace existing port value
    run_with_progress "sed -i.bak \"s/\\\"port\\\":[^,}]*/\\\"port\\\": $SFLOW_PORT/\" \"$(pwd)/config.json\"" "Updating config.json with port settings..."
  else
    # Add port to the JSON - insert before the last closing brace
    run_with_progress "sed -i.bak \"s/}$/,\\n  \\\"port\\\": $SFLOW_PORT\\n}/\" \"$(pwd)/config.json\"" "Updating config.json with port settings..."
  fi
  # Clean up backup file
  rm -f "$(pwd)/config.json.bak"
fi

# Create new configuration for our monitor with optimized settings
run_with_progress "cat > \"$HSFLOW_CONF\" <<EOF
sflow {
  # Send sFlow packets to our collector on port $SFLOW_PORT
  collector { ip=127.0.0.1 udpport=$SFLOW_PORT }
  # Sampling=1 captures all packets, polling=2 updates counters every 2 seconds
  sampling=1
  polling=2
  # Monitor the selected interface
  pcap { dev=$selected_if }
}
EOF" "Creating optimized hsflowd configuration..."

success "hsflowd configured to send data to port $SFLOW_PORT"

# Restart hsflowd service
status "Configuring sFlow monitoring service"
run_with_progress "systemctl restart hsflowd" "Restarting hsflowd service..."
run_with_progress "systemctl enable hsflowd" "Enabling hsflowd on boot..."
success "hsflowd service restarted successfully"

# Install Node.js 18 if missing
status "Checking Node.js runtime"
if ! command -v node >/dev/null 2>&1; then
  status "Node.js not found, installing Node.js 18"
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    run_with_progress "curl -fsSL https://deb.nodesource.com/setup_18.x | bash -" "Adding Node.js repository..."
    run_with_progress "apt-get install -y nodejs" "Installing Node.js runtime..."
  else
    run_with_progress "curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -" "Adding Node.js repository..."
    run_with_progress "yum install -y nodejs" "Installing Node.js runtime..."
  fi
  success "Node.js 18 installed successfully"
else
  success "Node.js is already installed"
fi

# Deploy project to /opt/net-monitor
status "Deploying sFlow Traffic Monitor"
INSTALL_DIR="/opt/net-monitor"

# Create all target directories
run_with_progress "mkdir -p \"$INSTALL_DIR/scripts\"" "Creating installation directories..."

# Manually copy files from current directory
run_with_progress "cp \"$(pwd)/net_monitor.js\" \"$INSTALL_DIR/\"" "Copying monitor script..."
run_with_progress "cp \"$(pwd)/package.json\" \"$INSTALL_DIR/\"" "Copying package configuration..."
run_with_progress "cp \"$(pwd)/README.md\" \"$INSTALL_DIR/\"" "Copying documentation..."
run_with_progress "cp \"$(pwd)/scripts\"/*.sh \"$INSTALL_DIR/scripts/\"" "Copying trigger scripts..."

# Create config.json directly (avoiding complex variable interpolation in run_with_progress)
status "Creating configuration file"
# Create a default config.json
cat > "$INSTALL_DIR/config.json" <<EOF
{
  // Interface name for display only
  "interface": "$selected_if",
  // Packets-per-second alert threshold
  "pps_threshold": 100000,
  // Megabits-per-second alert threshold
  "mbps_threshold": 900,
  // Port where sFlow datagrams are received
  "port": $SFLOW_PORT,
  // Graph update interval in ms
  "updateInterval": 1000,
  // Seconds to wait before firing OK script after traffic back to normal
  "ok_delay_secs": 60,
  // Trigger scripts per state (uncomment the states you wish to enable)
  "trigger_script": {
    "OK": "./scripts/reset.sh",
    // "WARNING": "./scripts/warning.sh",
    // "ABNORMAL": "./scripts/abnormal.sh",
    "CRITICAL": "./scripts/critical.sh"
  }
}
EOF
success "Configuration created with selected interface: $selected_if"

# Make executables
run_with_progress "chmod +x \"$INSTALL_DIR/net_monitor.js\" \"$INSTALL_DIR/scripts\"/*.sh" "Setting executable permissions..."
run_with_progress "ln -sf \"$INSTALL_DIR/net_monitor.js\" /usr/local/bin/net_monitor" "Creating command shortcut..."

# Create systemd service
status "Setting up systemd service"
SERVICE_FILE="/etc/systemd/system/net-monitor.service"
run_with_progress "cat > \"$SERVICE_FILE\" <<EOF
[Unit]
Description=sFlow Traffic Monitor and Trigger Service
After=network.target

[Service]
ExecStart=/usr/local/bin/net_monitor
Restart=always
User=root
WorkingDirectory=$INSTALL_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF" "Creating systemd service..."

# Enable and start service
run_with_progress "systemctl daemon-reload" "Reloading systemd configuration..."
run_with_progress "systemctl enable net-monitor" "Enabling service on boot..."
run_with_progress "systemctl start net-monitor" "Starting monitoring service..."

# Final restart of hsflowd to ensure it pick ups new config after install
run_with_progress "systemctl restart hsflowd" "Restarting hsflowd one last time..."

success "Installation complete!"
echo -e "\n\033[1;36mYour sFlow Traffic Monitor is running!\033[0m"
echo -e "\033[1;36mUse 'net_monitor' command to manually monitor traffic\033[0m"
echo -e "\033[1;36mService logs can be viewed with 'journalctl -u net-monitor'\033[0m\n"
echo -e "\033[1;36mConfiguration file: $INSTALL_DIR/config.json\033[0m"
echo -e "\033[1;36mTrigger script directory: $INSTALL_DIR/scripts/\033[0m"
