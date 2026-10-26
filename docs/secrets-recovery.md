# Secrets recovery

A database backup on its own can't bring back a working Fleet. Enrolled
devices also trust four secrets that were generated when Fleet was deployed:

| Secret | Where it lives on the server | What breaks without it |
|---|---|---|
| Fleet server private key (`FLEET_SERVER_PRIVATE_KEY`) | `/etc/fleet/env` | Fleet can't decrypt MDM assets stored in the database (APNs cert, ABM token, SCEP CA, …). Apple MDM stops working until everything is re-uploaded and devices re-enroll |
| WSTEP CA certificate + key | `/etc/fleet/wstep.crt`, `wstep.key` | Windows devices enrolled in MDM no longer trust the server and must re-enroll |
| osquery enroll secret | `/etc/fleet/enroll_secret` | New hosts can't enroll with the existing installers and packages |

**If these are lost, a restored database is unusable for MDM.** Keep two
independent copies of them:

1. **The OpenTofu state** (encrypted with `state_passphrase`). Day to day
   this is the source of truth.
2. **The nightly restic backup**, which snapshots `/etc/fleet` next to the
   MySQL dump (encrypted with `backup_password`).

The other generated values (MySQL passwords, JWT key, SSH key) don't need
recovering. A rebuild with a fresh database user gets new ones; the only
cost of a new JWT key is that users sign in again.

## Scenario 1: new operator, state still exists

You have the state (local copy or the remote backend) and its passphrase.

```bash
export TF_VAR_state_passphrase='…'
scripts/export-secrets.sh state ~/fleet-secrets
```

This writes `server_private_key`, `enroll_secret`, `wstep.crt`, `wstep.key`
and a ready-to-use `recovery.tfvars`. Store them in a password manager or
encrypted vault, then delete the directory. Nothing more is needed: `tofu apply`
with the state keeps using the same secrets.

Do this once after every new deployment, so a copy exists outside both the
state and the backups.

## Scenario 2: state lost, backups exist

You have the restic password and the backup bucket keys, but no state (and
perhaps no server).

1. Get the secrets out of the latest backup. This needs the
   [restic CLI](https://restic.readthedocs.io/en/stable/020_installation.html):

   ```bash
   export RESTIC_REPOSITORY='s3:https://hel1.your-objectstorage.com/my-fleet-backups/fleet'
   export RESTIC_PASSWORD='…' AWS_ACCESS_KEY_ID='…' AWS_SECRET_ACCESS_KEY='…'
   scripts/export-secrets.sh backup ~/fleet-secrets
   ```

2. Deploy with the recovered secrets. In a fresh checkout with a **new**
   `state_passphrase`, your usual `terraform.tfvars` and the `backup_*`
   variables:

   ```bash
   tofu init
   tofu apply -var-file=terraform.tfvars -var-file=$HOME/fleet-secrets/recovery.tfvars
   ```

   Keep passing `recovery.tfvars` on every later apply, or copy its four
   values into your secret store as `TF_VAR_*` variables. Without them, a
   future server replacement would generate new secrets.

   If the old server, volume or Primary IPs still exist in Hetzner, the apply
   fails on name conflicts. Either delete them (turn off their protection in
   the console first), or `tofu import` them, which the restore drill
   (`docs/restore.md`) covers.

3. Restore the database from the same backup: see `docs/restore.md`.

4. Check: `tofu output -raw enroll_secret` matches the old value, and an
   enrolled Windows or macOS host checks in without re-enrolling.

## What to keep in your password manager

| Item | Why |
|---|---|
| `state_passphrase` | Reads the state (scenario 1) |
| `backup_password` + backup bucket keys | Reads the backups (scenario 2) |
| The `export-secrets.sh` output | A third copy, independent of both |
| Hetzner API token | Redeploys |
