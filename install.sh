#!/usr/bin/env bash
# Install + start the Strix Halo fan-control daemon.
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root:  sudo ./install.sh" >&2
  exit 1
fi

cd "$(dirname "$0")"

echo ">> installing daemon + unit"
install -m 0755 strix-halo-fand         /usr/local/bin/strix-halo-fand
install -m 0644 strix-halo-fand.service /etc/systemd/system/strix-halo-fand.service

echo ">> enabling service"
systemctl daemon-reload
systemctl enable --now strix-halo-fand.service

sleep 3
systemctl --no-pager --full status strix-halo-fand.service | head -n 8 || true

cat <<'NOTE'

Done. The daemon is running and set to start on boot.

  status:   systemctl status strix-halo-fand
  logs:     journalctl -u strix-halo-fand -f
  stop:     systemctl stop strix-halo-fand      (reverts the fan to firmware auto)

IMPORTANT: this ships with the register offsets for the Bosgame M5 (IT5570 EC).
If you are on a different board, VERIFY the offsets first -- see the README
section "Adapting to your board". Getting them wrong means writing to the wrong
EC registers.
NOTE
