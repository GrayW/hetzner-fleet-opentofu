# Fleet MDM on Hetzner Cloud

Deploy a [Fleet](https://fleetdm.com) instance on Hetzner Cloud. Suitable for testing, device management labs, and small fleets (≤ 50 devices).

**Transparency:** This was created with the assistance of Claude Code

## Stack

| Layer | Component |
|---|---|
| OS | openSUSE Leap 16 |
| Containers | Podman with systemd quadlets |
| Database | MySQL 8.0 |
| Cache | Redis 7 |
| Reverse proxy / TLS | Caddy 2 (automatic Let's Encrypt) |
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
git clone https://github.com/your-org/hetzner-fleet
cd hetzner-fleet
tofu init
```

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
| `domain` | `fleet.example.com` | **Required.** Public hostname; Caddy requests a cert for this |
| `admin_email` | `admin@example.com` | **Required.** Let's Encrypt expiry notification address |
| `server_type` | `cpx22` | Hetzner server type (2 vCPU / 4 GB). See note below |
| `location` | `nbg1` | Datacenter: `nbg1` Nuremberg · `fsn1` Falkenstein · `hel1` Helsinki · `ash` Ashburn · `hil` Hillsboro · `sin` Singapore |
| `image_name` | `opensuse-16` | Hetzner system image name |
| `fleet_version` | `v4.86.0` | Fleet Docker image tag — always pin, never use `latest` |
| `fleet_license_key` | `""` | Fleet Premium license. Leave empty for Community Edition |
| `s3_access_key` | `""` | Hetzner Object Storage key (optional — enables software packages) |
| `s3_secret_key` | `""` | Hetzner Object Storage secret |

> **Server type note:** If `tofu apply` fails with `resource_unavailable`, try `cx23`.

---

## Outputs

| Output | Description |
|---|---|
| `ipv4_address` | Server IPv4 — add as DNS `A` record |
| `ipv6_address` | Server IPv6 — add as DNS `AAAA` record |
| `ssh_command` | Ready-to-paste SSH command using the generated key |
| `fleet_url` | Fleet HTTPS URL |
| `enroll_secret` | osquery enroll secret (sensitive — use `tofu output -raw enroll_secret`) |
| `wstep_cert` | Windows MDM WSTEP CA certificate (PEM) — back this up |
| `dns_records` | Summary of DNS records to create |
| `next_steps` | Post-deploy checklist |

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

```bash
tofu destroy
```

Then remove the DNS records for your domain manually.

---

## Security notes

- All secrets (MySQL passwords, JWT key, enroll secret, WSTEP private key) are generated locally by OpenTofu and never leave your machine except as cloud-init user-data sent over HTTPS to Hetzner.
- Sensitive files on the server (`wstep.key`, `enroll_secret`) are `0600 root:root`. Fleet reads them inside the container via Podman secrets (tmpfs mounts), so the container runs as a non-root user with no access to the host filesystem.
- `terraform.tfvars` and `terraform.tfstate` are gitignored — never commit them.
