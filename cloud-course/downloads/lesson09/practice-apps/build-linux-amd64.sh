#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
mkdir -p dist
for app in user product stress; do
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "dist/$app" "./cmd/$app"
  sha256sum "dist/$app"
done
file dist/*