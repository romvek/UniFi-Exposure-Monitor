#!/usr/bin/env bash
# =============================================================================
# setup.sh — UniFi Exposure Monitor Bootstrap
#
# Run this once on your host to install dependencies, set up the monitor
# script, configure log rotation, and install the cron job.
#
# Usage: bash setup.sh
# Requires: root, Debian/Ubuntu
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/unifi-monitor"
SCRIPT_NAME="unifi_monitor.sh"
REPO_URL="https://github.com/romvek/UniFi-Exposure-Monitor.git"   # Update this

echo "=== UniFi Exposure Monitor Setup ==="

# --- Detect OS ---
if [[ ! -f /etc/debian_version ]]; then
    echo "Unsupported OS. Use Debian or Ubuntu."
    exit 1
fi

# --- [1/4] Install dependencies ---
echo "[1/4] Installing dependencies (curl, dnsutils, git)..."
apt-get update -qq
apt-get install -y -qq curl dnsutils git
echo "      Done."

# --- [2/4] Clone or pull repo ---
echo "[2/4] Setting up install directory at ${INSTALL_DIR}..."
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "      Repo already exists, pulling latest..."
    git -C "$INSTALL_DIR" pull --quiet
else
    echo "      Cloning repo..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
echo "      Done."

# --- [3/4] Set up log rotation ---
echo "[3/4] Configuring log rotation..."
cat > /etc/logrotate.d/unifi-monitor <<EOF
/var/log/unifi_monitor.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
EOF
echo "      Done."

# --- [4/4] Install cron job ---
echo "[4/4] Installing cron job..."
cat > /etc/cron.d/unifi-monitor <<EOF
# UniFi Exposure Monitor
# Uncomment the desired schedule and comment out the rest

# Once daily at 9am (active)
0 9 * * * root ${INSTALL_DIR}/${SCRIPT_NAME} >> /var/log/unifi_monitor.log 2>&1

# Every 6 hours
# 0 */6 * * * root ${INSTALL_DIR}/${SCRIPT_NAME} >> /var/log/unifi_monitor.log 2>&1

# Every hour
# 0 * * * * root ${INSTALL_DIR}/${SCRIPT_NAME} >> /var/log/unifi_monitor.log 2>&1

# Every 12 hours
# 0 */12 * * * root ${INSTALL_DIR}/${SCRIPT_NAME} >> /var/log/unifi_monitor.log 2>&1

# Every other day at 9am
# 0 9 */2 * * root ${INSTALL_DIR}/${SCRIPT_NAME} >> /var/log/unifi_monitor.log 2>&1

# Once a week on Monday at 9am
# 0 9 * * 1 root ${INSTALL_DIR}/${SCRIPT_NAME} >> /var/log/unifi_monitor.log 2>&1
EOF
chmod 644 /etc/cron.d/unifi-monitor
echo "      Done."

echo ""
echo "=== Setup Complete ==="
echo ""
echo "NEXT STEPS:"
echo "  1. Create your config file:"
echo "     cp ${INSTALL_DIR}/config.env.example ${INSTALL_DIR}/config.env"
echo "     nano ${INSTALL_DIR}/config.env"
echo ""
echo "  2. Run a manual test:"
echo "     ${INSTALL_DIR}/${SCRIPT_NAME}"
echo ""
echo "  3. Check the log:"
echo "     tail -f /var/log/unifi_monitor.log"
echo ""
echo "  4. Import grafana_dashboard.json into Grafana."
echo "     Grafana → Dashboards → Import → select your Prometheus datasource."
