#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://rani0380.github.io/2026_nationalskills/cloud-course/downloads/challenge2-practice/module2"
APP_DIR="/opt/practice-lattice-service"

sudo dnf install -y python3 python3-pip
sudo mkdir -p "$APP_DIR"
sudo curl -fsSL "$BASE_URL/service.py" -o "$APP_DIR/service.py"
sudo curl -fsSL "$BASE_URL/requirements.txt" -o "$APP_DIR/requirements.txt"
sudo python3 -m venv "$APP_DIR/venv"
sudo "$APP_DIR/venv/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt"
sudo chown -R ec2-user:ec2-user "$APP_DIR"
sudo curl -fsSL "$BASE_URL/practice-lattice-service.service" -o /etc/systemd/system/practice-lattice-service.service
sudo systemctl daemon-reload
sudo systemctl enable --now practice-lattice-service
sudo systemctl --no-pager status practice-lattice-service
