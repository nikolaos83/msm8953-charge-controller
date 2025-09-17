#!/usr/bin/env bash
set -e

# Non-interactive installer for the Constant Charge service.

SOURCE_URL="https://raw.githubusercontent.com//msm8953-charge-controller/main/constant-charge.sh"
DEST_SCRIPT_PATH="/usr/local/sbin/constant-charge"
SERVICE_NAME="constant-charge"
SERVICE_FILE="/etc/systemd/system/
.service"
LOG_FILE="/var/log/
.log"

echo "--- Installing Constant Charge Service ---"

# 1. Download the main script
echo "Downloading script to 
...
"
curl -sSL "
" -o "
"
chmod +x "
"

# 2. Create the systemd service file with logging enabled
echo "Creating systemd service file..."
cat > "
" << EOL
[Unit]
Description=Constant Charge PI Controller Service
After=multi-user.target

[Service]
Type=simple
ExecStart=

Restart=always
RestartSec=10
StandardOutput=append:

StandardError=append:


[Install]
WantedBy=multi-user.target
EOL

# 3. Reload systemd and enable the service
echo "Enabling systemd service..."
systemctl daemon-reload
systemctl enable "
.service"

echo "--- Installation Complete! ---"
echo "To start the service, run: sudo systemctl start 
"
echo "To check status, run: sudo systemctl status 
"
echo "Logs are available at: 
"
