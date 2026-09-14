#!/usr/bin/env bash
# Install sysmon-fand. Run from this folder: sudo ./install.sh
#
# Installs the program and its service, but enables and starts nothing, and
# never overwrites an existing /etc/sysmon-fand/fand.conf.

set -euo pipefail

((EUID == 0)) || { echo "install.sh: run with sudo" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)

install -Dm755 "$here/sysmon-fand" /usr/local/bin/sysmon-fand
install -Dm755 "$here/sysmon-fand-detect" /usr/local/bin/sysmon-fand-detect
install -Dm644 "$here/sysmon-fand.service" /etc/systemd/system/sysmon-fand.service

if [[ -e /etc/sysmon-fand/fand.conf ]]; then
  echo "Kept your existing /etc/sysmon-fand/fand.conf"
else
  install -Dm644 "$here/fand.conf.example" /etc/sysmon-fand/fand.conf
  echo "Created /etc/sysmon-fand/fand.conf from the example (all commented out)"
fi

systemctl daemon-reload

cat <<'TEXT'

Installed. Nothing is running yet. Next:
  1. sysmon-fand-detect                        identify fans and PWM channels
  2. sudoedit /etc/sysmon-fand/fand.conf       describe your hardware
  3. sysmon-fand --check                       validate it against the hardware
  4. sysmon-fand --dry-run                     watch what it would do (Ctrl+C)
  5. sudo systemctl enable --now sysmon-fand
TEXT
