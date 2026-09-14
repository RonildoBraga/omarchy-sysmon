#!/usr/bin/env bash
# Remove sysmon-fand. Run from this folder: sudo ./uninstall.sh
#
# Stopping the service first hands each channel back to the hardware, or holds
# its fail-safe speed (see README.md). Your /etc/sysmon-fand/ config is kept.

set -uo pipefail

((EUID == 0)) || { echo "uninstall.sh: run with sudo" >&2; exit 1; }

systemctl disable --now sysmon-fand.service 2>/dev/null || true
rm -f /usr/local/bin/sysmon-fand /usr/local/bin/sysmon-fand-detect /etc/systemd/system/sysmon-fand.service
systemctl daemon-reload
echo "Removed sysmon-fand. Kept /etc/sysmon-fand/; delete it if you no longer need it."
