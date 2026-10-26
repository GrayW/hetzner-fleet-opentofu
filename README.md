# Fleet MDM on Hetzner Cloud

Deploy a [Fleet](https://fleetdm.com) instance on Hetzner Cloud. Suitable for labs, testing, and small fleets (≤ 50 devices). **Not yet hardened for production** — see [PLAN.md](PLAN.md) for the road to 1.0.

**Transparency:** This was created with the assistance of Claude Code

**Important Note:** While I work for Fleet, this is a personal learning project and not an officially supported deployment method at this time.

## Stack

| Layer | Component |
|---|---|
| OS | openSUSE Leap 16 |
| Containers | Podman with systemd quadlets |
| Database | MySQL 8.0 |
| Cache | Redis 7 |
| Reverse proxy / TLS | Caddy 2 (automatic Let's Encrypt) |
| Persistent data | Hetzner volume at `/var/lib/fleet`, survives server replacement |
| Infra-as-code | OpenTofu (recommended) or Terraform |

---

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) ≥ 1.9 (or Terraform ≥ 1.9)
- A [Hetzner Cloud](https://console.hetzner.com) account with an API token
- A domain name with DNS you can edit (for the TLS certificate)

---

## Quick start (OpenTofu)

### 1. Clone and initialise

```bash
git clone https://github.com/GrayW/hetzner-fleet-opentofu
cd hetzner-fleet-opentofu
export TF_VAR_state_passphrase='a-long-random-passphrase'   # see State below
tofu init
```

Every `tofu` command needs `TF_VAR_state_passphrase` set, including `init`.

### 2. Create your tfvars file

```bash
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and set at minimum:

```hcl
hetzner_token = "your-hetzner-api-token"
domain        = "fleet.yourdomain.com"   # must resolve to the server IP after deploy
admin_email   = "you@example.com"        # used for Let's Encrypt expiry notifications
```

See [Variables](#variables) below for the full list.

### 3. Apply

```bash
tofu apply
```

OpenTofu will:
- Provision a `CPX22` server (2 vCPU / 4 GB RAM) in Nuremberg
- Create Object Storage in the same location
- Create a Firewall service with basic rules and apply it to the resources
- Generate all secrets (MySQL passwords, JWT key, enroll secret, Windows MDM WSTEP CA)
- Write a cloud-init payload that installs and starts Fleet, MySQL, Redis, and Caddy
- Output the IP addresses and next steps

### 4. Add DNS records

```
tofu output dns_records
```

Create the `A` and `AAAA` records your DNS provider shows. Caddy will not issue a TLS certificate until DNS resolves.

### 5. Wait for cloud-init (~5 minutes)

```bash
ssh -i .fleet_ed25519 root@<ipv4> 'cloud-init status --wait'
```

### 6. Open Fleet and complete setup

Navigate to `https://fleet.yourdomain.com`. Create the initial admin account, then retrieve the osquery enroll secret:

```bash
tofu output -raw enroll_secret
```

---

## Variables

All variables have safe defaults.

| Variable | Default | Description |
|---|---|---|
| `hetzner_token` | — | **Required.** Hetzner Cloud API token |
| `state_passphrase` | — | **Required.** Encrypts state and plans (min 16 chars). Pass as `TF_VAR_state_passphrase` |
| `domain` | `fleet.example.com` | **Required.** Public hostname; Caddy requests a cert for this |
| `admin_email` | `admin@example.com` | **Required.** Let's Encrypt expiry notification address |
| `server_type` | `cpx22` | Hetzner server type (2 vCPU / 4 GB). See note below |
| `location` | `nbg1` | Datacenter: `nbg1` Nuremberg · `fsn1` Falkenstein · `hel1` Helsinki · `ash` Ashburn · `hil` Hillsboro · `sin` Singapore |
| `image_name` | `opensuse-16` | Hetzner system image name |
| `fleet_version` | `v4.92.3` | Fleet Docker image tag — always pin, never use `latest` |
| `fleet_license_key` | `""` | Fleet Premium license. Leave empty for Community Edition |
| `s3_access_key` | `""` | Hetzner Object Storage key (optional — enables software packages) |
| `s3_secret_key` | `""` | Hetzner Object Storage secret |
| `data_volume_size` | `20` | Data volume size in GB (min 10). Can grow later, never shrink |
| `server_backups` | `false` | Hetzner daily server-disk backups (~20% extra on the server price). Doesn't cover the data volume |
| `backup_repository` | `""` | restic repo for nightly off-host backups. Empty disables them. See [Backups](#backups) |
| `backup_access_key` / `backup_secret_key` | `""` | Keys for the backup bucket (separate from `s3_*`) |
| `backup_password` | `""` | restic password (min 16 chars). Keep it outside the state |
| `backup_healthcheck_url` | `""` | Optional dead-man's-switch ping URL |
| `backup_keep_daily` / `_weekly` / `_monthly` | `7` / `4` / `6` | Retention |
| `restic_version` | `0.18.0` | restic image tag |
| `protect_resources` | `true` | Hetzner delete/rebuild protection on the server, delete protection on the volume. Set `false` and apply before `tofu destroy` |

> **Server type note:** If `tofu apply` fails with `resource_unavailable`, try `cx23`.

---

## Outputs

| Output | Description |
|---|---|
| `ipv4_address` | Server IPv4 (persistent Primary IP) — add as DNS `A` record |
| `ipv6_address` | Server IPv6 — add as DNS `AAAA` record |
| `data_volume_device` | Device path of the data volume on the server |
| `ssh_command` | Ready-to-paste SSH command using the generated key |
| `fleet_url` | Fleet HTTPS URL |
| `enroll_secret` | osquery enroll secret (sensitive — use `tofu output -raw enroll_secret`) |
| `wstep_cert` | Windows MDM WSTEP CA certificate (PEM) — back this up |
| `backups` | Off-host backup status (`DISABLED` until configured) |
| `dns_records` | Summary of DNS records to create |
| `next_steps` | Post-deploy checklist |

---

## Backups

Off-host backups are **off by default**. Until you set `backup_repository`,
`tofu output backups` says `DISABLED` and losing the server's location loses
all Fleet data.

When enabled, a systemd timer runs nightly at 03:00 UTC (up to 10 minutes
of random delay; missed runs catch up after boot):

1. `mysqldump --single-transaction` of the `fleet` database
2. one [restic](https://restic.net) snapshot of the dump plus `/etc/fleet`
   (the Fleet server key, WSTEP CA and enroll secret a restore needs)
3. retention: 7 daily, 4 weekly, 6 monthly (`backup_keep_*` variables)

restic encrypts everything with `backup_password` before upload.

### Set up

1. Create a bucket in Hetzner Object Storage in a **different location** from
   the server (`tofu plan` warns if it's the same). Hetzner keys can access
   every bucket in their project, so for real separation put the bucket in a
   separate Hetzner project with its own keys.
2. Store the restic password and bucket keys in a password manager. With those
   two you can restore even if this state is lost; without the password the
   backups are unreadable.
3. Set the variables, secrets via the environment:

   ```bash
   export TF_VAR_backup_password='…' TF_VAR_backup_access_key='…' TF_VAR_backup_secret_key='…'
   ```

   ```hcl
   backup_repository      = "s3:https://hel1.your-objectstorage.com/my-fleet-backups/fleet"
   backup_healthcheck_url = "https://hc-ping.com/<uuid>"   # optional, recommended
   ```

4. Optional but recommended: create a daily check at healthchecks.io (or an
   Uptime Kuma push monitor) and set `backup_healthcheck_url`. The script pings
   `/start`, then success or `/fail`, so both failed and missed runs alert.

Backup settings are written by cloud-init when the server is created. To turn
backups on or change them for an existing server, replace the server. Data
and IPs are kept (see [Teardown](#teardown)):

```bash
tofu apply -var protect_resources=false
tofu taint hcloud_server.fleet
tofu apply -var protect_resources=false
tofu apply
```

### Check

```bash
ssh -i .fleet_ed25519 root@<ip> 'systemctl start fleet-backup && journalctl -u fleet-backup -n 30'
ssh -i .fleet_ed25519 root@<ip> 'systemctl list-timers fleet-backup.timer'
```

---

## State

The state holds every generated secret (MySQL passwords, Fleet server key,
WSTEP CA key, enroll secret). It's encrypted with OpenTofu state encryption
(AES-GCM, key derived from `state_passphrase` via PBKDF2), and so are saved
plan files. Unencrypted state is refused.

- Keep the passphrase in a password manager, separate from the state.
  Without it the state can't be read, though the off-host backups can still
  restore Fleet.
- Upgrading from v0.1.0 (unencrypted state): see
  [docs/upgrade-0.2.md](docs/upgrade-0.2.md#state-encryption-16).
- Local state is the default. To keep state off your laptop, copy
  [`backend.tf.example`](backend.tf.example) to `backend.tf` (Hetzner Object
  Storage, S3 API) and run `tofu init -migrate-state`.
- Encryption is OpenTofu-only. Terraform can't read this state.

---

## Windows MDM

Windows MDM (WSTEP) is enabled automatically. OpenTofu generates a self-signed CA certificate and private key, stores them in Terraform state, and injects them into the server at provision time via Podman secrets. Back up the `wstep_cert` output — losing it breaks Windows MDM re-enrolment.

---

## Object Storage (optional)

Fleet can store software installer packages in Hetzner Object Storage (S3-compatible). To enable:

1. Create access keys at [console.hetzner.com](https://console.hetzner.com) → Object Storage → Access Keys
2. Add to `terraform.tfvars`:
   ```hcl
   s3_access_key = "your-access-key"
   s3_secret_key = "your-secret-key"
   ```
3. Re-run `tofu apply` — the bucket is created and Fleet is configured automatically.

The bucket name and endpoint are derived from `var.location` automatically (Hetzner requires the S3 region to equal the datacenter location name, e.g. `nbg1`).

---

## Useful SSH commands

```bash
# Tail Fleet logs
ssh -i .fleet_ed25519 root@<ip> 'podman logs -f fleet-server'

# Check all Fleet services
ssh -i .fleet_ed25519 root@<ip> 'systemctl list-units "fleet-*"'

# Monitor cloud-init progress
ssh -i .fleet_ed25519 root@<ip> 'cloud-init status --wait && cloud-init analyze'
```

---

## Teardown

### OpenTofu

Hetzner delete and rebuild protection is on by default (`protect_resources = true`),
so `tofu destroy` fails until you turn it off:

```bash
tofu apply -var protect_resources=false
tofu destroy
```

The apply step is what lifts protection on Hetzner's side. Setting the
variable at destroy time alone isn't enough, because a destroy doesn't update
resources before deleting them.

`tofu destroy` deletes the data volume too, so all Fleet data is lost. To
rebuild the server but keep the data, replace only the server instead:

```bash
tofu apply -var protect_resources=false
tofu taint hcloud_server.fleet
tofu apply -var protect_resources=false
```

The volume is reattached to the new server and mounted at `/var/lib/fleet`.
Set `protect_resources` back to `true` afterwards. The server's Primary IPs
are kept and reassigned, so DNS doesn't change. A full `tofu destroy` deletes
the IPs too.

Then remove the DNS records for your domain manually.

---

## Security notes

- All secrets (MySQL passwords, JWT key, enroll secret, WSTEP private key) are generated locally by OpenTofu and never leave your machine except as cloud-init user-data sent over HTTPS to Hetzner.
- Sensitive files on the server (`wstep.key`, `enroll_secret`) are `0600 root:root`. Fleet reads them inside the container via Podman secrets (tmpfs mounts), so the container runs as a non-root user with no access to the host filesystem.
- `terraform.tfvars` and `terraform.tfstate` are gitignored — never commit them.

## License

[MIT](LICENSE)
