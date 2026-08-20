#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || "$1" != http*://* ]]; then
  echo "Usage: $0 http://SERVICE_DNS_NAME"
  exit 2
fi

BASE_URL="https://rani0380.github.io/2026_nationalskills/cloud-course/downloads/challenge2-practice/module2"
APP_DIR="/opt/practice-lattice-client"
INVENTORY_URL="${1%/}"

sudo dnf install -y python3 python3-pip
sudo mkdir -p "$APP_DIR"
sudo curl -fsSL "$BASE_URL/client.py" -o "$APP_DIR/client.py"
sudo curl -fsSL "$BASE_URL/requirements.txt" -o "$APP_DIR/requirements.txt"
sudo python3 -m venv "$APP_DIR/venv"
sudo "$APP_DIR/venv/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt"
sudo chown -R ec2-user:ec2-user "$APP_DIR"
printf 'INVENTORY_URL=%s\n' "$INVENTORY_URL" | sudo tee /etc/practice-lattice-client.env >/dev/null
sudo chmod 0644 /etc/practice-lattice-client.env
sudo curl -fsSL "$BASE_URL/practice-lattice-client.service" -o /etc/systemd/system/practice-lattice-client.service
sudo systemctl daemon-reload
sudo systemctl enable --now practice-lattice-client
sudo systemctl --no-pager status practice-lattice-client
