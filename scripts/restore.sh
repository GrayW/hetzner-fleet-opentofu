#!/usr/bin/env bash
# Restore the Fleet database from an off-host restic backup onto the running
# server, then wait for Fleet to report healthy. Prints the elapsed time, to
# record as the RTO. See docs/restore.md.
#
#   scripts/restore.sh [snapshot]     # default: latest
#
# Needs TF_VAR_state_passphrase (it reads the server IP and URL from tofu
# outputs) and a server deployed with the backup_* variables set.
#
# Refuses to restore when the snapshot's FLEET_SERVER_PRIVATE_KEY differs from
# the server's: that database would be unusable for MDM. Recover the old
# secrets first (docs/secrets-recovery.md), or set FORCE=1 to restore anyway.
set -euo pipefail

snap=${1:-latest}
force=${FORCE:-0}
root=$(cd "$(dirname "$0")/.." && pwd)

ip=$(tofu -chdir="$root" output -raw ipv4_address)
url=$(tofu -chdir="$root" output -raw fleet_url)
start=$(date +%s)

echo "Restoring snapshot '$snap' to root@$ip …"
ssh -i "$root/.fleet_ed25519" "root@$ip" "SNAP='$snap' FORCE='$force' bash -s" <<'REMOTE'
set -Eeuo pipefail
die() { echo "error: $*" >&2; exit 1; }

[ -f /etc/fleet/backup.env ] || die "backups aren't configured on this server (no /etc/fleet/backup.env). Set the backup_* variables and replace the server."
image=$(grep -o 'docker.io/restic/restic:[^ ]*' /usr/local/bin/fleet-backup | head -1)
restic() {
  podman run --rm -i --security-opt label=disable --env-file /etc/fleet/backup.env \
    -v /var/cache/restic:/cache "$image" --cache-dir /cache "$@"
}
mysql_root() {
  podman exec -i fleet-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$@"' sh "$@"
}

echo "Checking the snapshot's Fleet server key …"
snap_key=$(restic dump "$SNAP" /etc/fleet/env | sed -n 's/^FLEET_SERVER_PRIVATE_KEY=//p')
cur_key=$(sed -n 's/^FLEET_SERVER_PRIVATE_KEY=//p' /etc/fleet/env)
[ -n "$snap_key" ] || die "snapshot $SNAP has no FLEET_SERVER_PRIVATE_KEY in /etc/fleet/env"
if [ "$snap_key" != "$cur_key" ]; then
  [ "$FORCE" = 1 ] || die "the snapshot's FLEET_SERVER_PRIVATE_KEY differs from this server's. The restored DB would be unusable for MDM. Redeploy with the recovered secrets (docs/secrets-recovery.md), or rerun with FORCE=1."
  echo "warning: server key mismatch, continuing because FORCE=1" >&2
fi

echo "Stopping Fleet and the backup timer …"
systemctl stop fleet-backup.timer fleet-server.service

echo "Replacing the fleet database …"
mysql_root -e 'DROP DATABASE IF EXISTS fleet; CREATE DATABASE fleet;'
restic dump "$SNAP" /backup/fleet.sql | mysql_root

echo "Flushing Redis caches …"
podman exec fleet-redis redis-cli FLUSHALL >/dev/null

echo "Starting Fleet (runs migrations first) …"
systemctl start fleet-server.service fleet-backup.timer
REMOTE

echo "Waiting for $url/healthz …"
for _ in $(seq 1 60); do
  if curl -fsS -m 5 "$url/healthz" >/dev/null 2>&1; then
    echo "Fleet is healthy. Restore took $(($(date +%s) - start))s."
    exit 0
  fi
  sleep 10
done
echo "error: Fleet not healthy after 10 minutes; check: podman logs fleet-server" >&2
exit 1
