# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project uses [Semantic Versioning](https://semver.org/). While the version
is `0.x`, minor releases may include breaking changes; each one will say so
explicitly and include upgrade notes.

## [Unreleased]

### Added
- `protect_resources` variable (default `true`) that enables Hetzner delete and
  rebuild protection on the server (#15).
- Hetzner data volume (`hcloud_volume.fleet_data`, ext4) mounted at
  `/var/lib/fleet`, so MySQL, Redis, Caddy certs and vulndb survive server
  replacement. New `data_volume_size` variable (default 20 GB) and
  `data_volume_id` / `data_volume_device` outputs. Container units refuse to
  start if the volume isn't mounted (#58).
- Explicit Primary IPs (`hcloud_primary_ip.ipv4` / `.ipv6`) with
  `auto_delete = false` and delete protection following `protect_resources`,
  so a replacement server keeps its addresses and DNS (#59).
- `server_backups` variable (default `false`) for Hetzner's automated daily
  server-disk backups, about 20% extra on the server price. They don't cover
  the data volume (#62).
- OpenTofu state and plan encryption (AES-GCM, PBKDF2 passphrase) with a
  required `state_passphrase` variable, plus `backend.tf.example` for keeping
  state in Hetzner Object Storage (#16).
- Opt-in nightly off-host backups: `mysqldump` plus `/etc/fleet` in one
  restic snapshot (pinned `restic/restic` image), 7/4/6 retention, systemd
  timer at 03:00 UTC, optional healthcheck ping on start, success and failure.
  New `backup_*` and `restic_version` variables, a `backups` output and a
  `next_steps` warning while disabled. `tofu plan` warns if the repo is in
  the server's location (#4).

### Changed
- **Breaking:** `tofu destroy` and server replacement now fail by default.
  Upgrade note: the next `tofu apply` turns protection on in place (no server
  restart). To tear down, set `protect_resources = false`, apply, then destroy.
- **Upgrade required for existing servers:** `tofu apply` creates and attaches
  the data volume but doesn't move data onto it. Follow
  [docs/upgrade-0.2.md](docs/upgrade-0.2.md) to copy `/var/lib/fleet` over
  (a few minutes of downtime).
- **Upgrade required for existing servers:** import the server's existing
  Primary IPs **before** the first v0.2.0 apply, or tofu moves the server to
  new addresses. Steps in [docs/upgrade-0.2.md](docs/upgrade-0.2.md#primary-ips-59).
- **Breaking:** state encryption is enforced. Every `tofu` command, including
  `init`, needs `TF_VAR_state_passphrase`. Existing unencrypted state must be
  converted once: see [docs/upgrade-0.2.md](docs/upgrade-0.2.md#state-encryption-16).
  Terraform can no longer read the state.
- hcloud provider constraint raised to `~> 1.70`.

## [0.1.0] - 2026-10-23

First tagged release. A working single-server Fleet deployment on Hetzner Cloud
for labs, testing, and small fleets (up to ~50 devices). **Not yet hardened for
production**: see `PLAN.md` for the road to 1.0.

> Before tagging, delete any line below whose pull request has not merged.

### Added
- OpenTofu configuration that provisions one Hetzner Cloud server running
  openSUSE Leap 16 with Fleet, MySQL 8.0, Redis 7 and Caddy 2 as Podman
  systemd quadlets, configured through cloud-init.
- Automatic TLS via Caddy and Let's Encrypt.
- Generated secrets: MySQL passwords, JWT key, osquery enroll secret, Fleet
  server private key, and a Windows MDM (WSTEP) CA certificate and key.
- Hetzner firewall (SSH, HTTP, HTTPS, ICMP) and a generated ED25519 SSH key.
- Optional Hetzner Object Storage bucket for Fleet software installers.
- Outputs for DNS records, SSH command, Fleet URL, enroll secret and next steps.
- `LICENSE` file (#34).
- GitHub Actions CI: `tofu fmt`, `tofu validate` and `tflint`, plus a check
  that no state, tfvars or key files are committed (#18).
- Dependabot for GitHub Actions and Terraform providers.
- Committed `.terraform.lock.hcl` (#17).
- Input validation for `domain`, `admin_email`, `fleet_version`,
  `server_type` and `location` (#19).
- `admin_cidrs` variable to restrict SSH access (#23).

### Changed
- MySQL and Redis images are pinned to exact versions (#1).
- Removed the deprecated `--default-authentication-plugin` MySQL flag (#6).
- README quick start now clones this repository; corrected stale
  "MariaDB" wording in comments.

[Unreleased]: https://github.com/GrayW/hetzner-fleet-opentofu/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/GrayW/hetzner-fleet-opentofu/releases/tag/v0.1.0
