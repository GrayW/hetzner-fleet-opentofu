#!/usr/bin/env bash
# Upgrade the running Fleet server in place, without re-provisioning.
#
# Changing var.fleet_version only re-renders the cloud-init user-data, which
# hcloud_server.fleet ignores (lifecycle.ignore_changes). Use this script to
# actually upgrade the running container.
#
# Usage (from the repo root, with the generated SSH key):
#   ssh -i .fleet_ed25519 root@<ip> 'bash -s' -- v4.93.0 < scripts/upgrade.sh
# Or copy it to the server and run: ./scripts/upgrade.sh v4.93.0
set -euo pipefail

CONTAINER_FILE=/etc/containers/systemd/fleet-server.container

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root." >&2
  exit 1
fi

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <fleet_version>   (e.g. $0 v4.93.0)" >&2
  exit 1
fi

NEW_VERSION="$1"
IMAGE="docker.io/fleetdm/fleet:${NEW_VERSION}"

if ! grep -q '^Image=docker\.io/fleetdm/fleet:v' "$CONTAINER_FILE"; then
  echo "ERROR: unexpected Image line in $CONTAINER_FILE; refusing to edit." >&2
  exit 1
fi

echo "Pulling ${IMAGE} ..."
podman pull "$IMAGE"

echo "Updating ${CONTAINER_FILE} ..."
sed -i "s|^Image=docker\.io/fleetdm/fleet:.*|Image=${IMAGE}|" "$CONTAINER_FILE"

echo "Restarting fleet-server (ExecStartPre runs the DB migration) ..."
systemctl daemon-reload
systemctl restart fleet-server.service

echo "Done. Check progress with:"
echo "  systemctl status fleet-server.service"
echo "  podman logs -f fleet-server"
