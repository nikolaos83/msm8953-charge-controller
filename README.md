# MSM8953 Charge Controller

A smart charge controller script for devices based on the MSM8953 chipset (and potentially others with similar sysfs interfaces). This script runs as a background service to maintain a battery State-of-Charge (SoC), preventing overcharging and improving battery longevity. It also includes a highly configurable, staged power-saving system for when the device is running on battery.

## Features

- **PI Controller:** Smoothly adjusts the USB input current to hold the battery at a target SoC.
- **Staged Power Saving:** Progressively applies power-saving measures (CPU governor, core shutdown, etc.) as the battery drains.
- **Highly Configurable:** A comprehensive configuration section allows you to tweak every aspect of the script's behavior.
- **Status Feedback:** Uses the device's indicator LED to provide visual feedback on its status.
- **Emergency Shutdown:** Safely powers off the device at a critical battery level to protect the battery.
- **Systemd Service:** Installs as a proper systemd service for reliable background operation.

## Quick Install

Run the following command on your device to install the service. You will be prompted for your password to install the system files.

```bash
curl -sSL https://raw.githubusercontent.com//msm8953-charge-controller/main/install.sh | sudo bash
```

## Configuration

After installation, the script and its configuration can be found at . You can edit this file to change thresholds, PI gains, and power-saving behavior.

