# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project uses [Semantic Versioning](https://semver.org/). While the version
is `0.x`, minor releases may include breaking changes; each one will say so
explicitly and include upgrade notes.

## [Unreleased]

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
