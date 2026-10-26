#!/usr/bin/env bash
# Export the secrets enrolled devices depend on (Fleet server private key,
# WSTEP CA cert + key, osquery enroll secret) and write recovery.tfvars, which
# puts them back through the override variables after a total loss of state.
# See docs/secrets-recovery.md.
#
#   scripts/export-secrets.sh state  <out-dir>
#       From tofu state. Needs TF_VAR_state_passphrase. Set FLEET_TOFU_DIR to
#       run against a checkout other than this one.
#
#   scripts/export-secrets.sh backup <out-dir>
#       From /etc/fleet in the latest restic backup. Needs the restic CLI and
#       RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID,
#       AWS_SECRET_ACCESS_KEY (the backup_* values).
#
# <out-dir> must be new or empty. Its files are plaintext secrets: move them
# into a password manager or encrypted storage, then delete them.
set -euo pipefail

usage() {
  sed -n '7,17p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ $# -eq 2 ] || usage
mode=$1
out=$2

umask 077
mkdir -p "$out"
if [ -n "$(ls -A "$out")" ]; then
  echo "error: $out is not empty" >&2
  exit 1
fi

case $mode in
  state)
    dir=${FLEET_TOFU_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
    tofu -chdir="$dir" output -raw server_private_key > "$out/server_private_key"
    tofu -chdir="$dir" output -raw enroll_secret > "$out/enroll_secret"
    tofu -chdir="$dir" output -raw wstep_cert > "$out/wstep.crt"
    tofu -chdir="$dir" output -raw wstep_key > "$out/wstep.key"
    ;;
  backup)
    command -v restic >/dev/null || { echo "error: restic CLI not found" >&2; exit 1; }
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    restic restore latest --include /etc/fleet --target "$tmp" >/dev/null
    src=$tmp/etc/fleet
    sed -n 's/^FLEET_SERVER_PRIVATE_KEY=//p' "$src/env" | tr -d '\n' > "$out/server_private_key"
    tr -d '\n' < "$src/enroll_secret" > "$out/enroll_secret"
    cp "$src/wstep.crt" "$out/wstep.crt"
    cp "$src/wstep.key" "$out/wstep.key"
    ;;
  *)
    usage
    ;;
esac

for f in server_private_key enroll_secret wstep.crt wstep.key; do
  if [ ! -s "$out/$f" ]; then
    echo "error: $f came back empty" >&2
    exit 1
  fi
done

{
  echo "# Recovered Fleet secrets. Plaintext: keep this file out of git and delete it after use."
  echo "fleet_server_private_key = \"$(cat "$out/server_private_key")\""
  echo "enroll_secret            = \"$(cat "$out/enroll_secret")\""
  echo "wstep_cert_pem = <<EOT"
  cat "$out/wstep.crt"
  echo "EOT"
  echo "wstep_key_pem = <<EOT"
  cat "$out/wstep.key"
  echo "EOT"
} > "$out/recovery.tfvars"

echo "Wrote server_private_key, enroll_secret, wstep.crt, wstep.key and recovery.tfvars to $out"
