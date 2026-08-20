#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://rani0380.github.io/2026_nationalskills/cloud-course/downloads/challenge2-practice/module1"
sudo dnf install -y python3 python3-pip
sudo mkdir -p /opt/practice-orders
sudo curl -fsSL "$BASE_URL/app.py" -o /opt/practice-orders/app.py
sudo curl -fsSL "$BASE_URL/requirements.txt" -o /opt/practice-orders/requirements.txt
sudo python3 -m venv /opt/practice-orders/venv
sudo /opt/practice-orders/venv/bin/pip install --no-cache-dir -r /opt/practice-orders/requirements.txt
sudo chown -R ec2-user:ec2-user /opt/practice-orders
sudo curl -fsSL "$BASE_URL/practice-orders.service" -o /etc/systemd/system/practice-orders.service
sudo systemctl daemon-reload
sudo systemctl enable --now practice-orders
sudo systemctl --no-pager status practice-orders
