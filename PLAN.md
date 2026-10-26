# Plan: reliable single-server Fleet on Hetzner

Goal: a single-server deployment that survives reboots, crashes, disk pressure,
bad upgrades and loss of the server or the operator's laptop, and that a stranger
can deploy and recover from using only the README.

Out of scope for now: load balancer, multi-server / HA, external managed DB.

> Caveat: this plan was written from the README, `main.tf` and the issue list.
> `variables.tf` and `cloud-init.tftpl` were not reviewed, so items marked
> **verify** may already be partly done.

## Release train

| Version | Theme | Gate to ship |
|---|---|---|
| **v0.1.0** | Hygiene and first tag | CI green, lock file, LICENSE, pinned images, validation |
| **v0.2.0** | Data safety and recoverability | Restore drill passes on a fresh server |
| **v0.3.0** | Self-healing and upgrades | Reboot/crash test and upgrade test pass |
| **v0.4.0** | Detection and hardening | Alerts fire in a fault-injection test |
| **v1.0.0** | Release gate | Full end-to-end test (below) passes; runbook complete |

Conventions: one PR per work item, branch `feat/<slug>` or `fix/<slug>`, every PR
updates `CHANGELOG.md` under `[Unreleased]`, PR description lists acceptance
criteria and how they were tested. Breaking changes are called out with upgrade
notes (0.x allows them).

---

## v0.1.0: hygiene and first tag

| # | Item | Issues | Files | Acceptance criteria |
|---|---|---|---|---|
| 0.1 | CI + Dependabot | #18 | `.github/workflows/ci.yml`, `.github/dependabot.yml` | `fmt`, `validate`, `tflint` and hygiene jobs pass on a PR; a deliberately mis-formatted file fails |
| 0.2 | Commit lock file, then enable `-lockfile=readonly` in CI | #17, #24 | `.terraform.lock.hcl`, CI | Fresh clone + `tofu init` makes no changes to the lock file |
| 0.3 | LICENSE | #34 | `LICENSE` | File present; README links it |
| 0.4 | Pin MySQL and Redis image tags | #1 | `cloud-init.tftpl`, `variables.tf` | No `:latest` or floating major tags anywhere in the template; versions are variables with defaults |
| 0.5 | Remove deprecated MySQL auth flag | #6 | `cloud-init.tftpl` | Fresh deploy: Fleet connects and migrates; no deprecation warning in MySQL log |
| 0.6 | Variable validation | #19 | `variables.tf` | Bad `domain`, `admin_email`, `fleet_version` (must match `vX.Y.Z`), `server_type`, `location` each fail at `tofu plan` with a clear message |
| 0.7 | `admin_cidrs` for SSH | #23 | `variables.tf`, `main.tf`, README | Default requires an explicit value (or documented opt-in to open); firewall rule uses the variable; 80/443 stay open |
| 0.8 | README and comment fixes | n/a | `README.md`, `main.tf` | Quick start clones this repo; no "MariaDB" references; README says "lab/small, not yet hardened" |
| 0.9 | CHANGELOG, tag `v0.1.0` | n/a | `CHANGELOG.md` | Entries match what merged; release created |

Tag and release:
```
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
gh release create v0.1.0 --title "v0.1.0" --notes-file <(sed -n '/## \[0.1.0\]/,/^\[Unreleased\]/p' CHANGELOG.md)
```

---

## v0.2.0: data safety and recoverability

| # | Item | Issues | Acceptance criteria |
|---|---|---|---|
| 1.1 | **Data volume for MySQL**: `hcloud_volume` (ext4/xfs, `delete_protection = true`), attached to the server, mounted at `/var/lib/mysql` via cloud-init, in the same location | new | Server can be rebuilt and the volume reattached with data intact; `tofu destroy` refuses until protection is disabled |
| 1.2 | **Server protection**: `delete_protection` and `rebuild_protection` via a `protect_resources` variable (default `true`); replaces `prevent_destroy` | #15 | `tofu destroy` fails by default; setting the variable to `false`, applying, then destroying works; documented in Teardown |
| 1.3 | **Primary IPs** (IPv4 + IPv6), `auto_delete = false`, assigned via the server's `public_net` | new | Server replacement keeps the same addresses; DNS output unchanged after rebuild |
| 1.4 | **Off-host MySQL backups**: nightly `mysqldump --single-transaction` (or equivalent), encrypted, pushed with restic to Object Storage **in a different location** than the primary; retention policy; systemd timer; dead-man's-switch ping on success | #4 | A backup appears nightly; a missed backup raises an alert; backup credentials are separate from the Fleet installer bucket |
| 1.5 | **Secrets recovery**: documented and scripted export of the Fleet server private key, WSTEP key/cert and enroll secret; README states that losing them makes the DB backup unusable for MDM | new | Following the doc, a new operator on a new machine can recover and reach a working Fleet |
| 1.6 | **State encryption + remote backend guidance** | #16 | README shows a working `encryption` block and an example backend; state file in a test is unreadable without the passphrase |
| 1.7 | **Restore drill** (`docs/restore.md` + script) | new | Destroy server (protection off), apply, restore backup, Fleet comes up with prior data; the procedure is timed and the timing recorded in the doc |
| 1.8 | Optional Hetzner server backups variable (`backups = true`) as a secondary safety net | new | Variable works; cost note in README |

Upgrade notes for existing deployments (volume and IP changes) go in the CHANGELOG:
adding a volume and Primary IPs to a running server needs a manual data migration
and an address change. Write the steps, or state that a rebuild is required.

---

## v0.3.0: self-healing and upgrades

| # | Item | Issues | Acceptance criteria |
|---|---|---|---|
| 2.1 | **Fleet health check** on the quadlet (Fleet's health endpoint), plus MySQL and Redis health checks | #7 | `podman healthcheck run` reports healthy; unhealthy containers restart |
| 2.2 | **Start ordering and restart policy** (verify): MySQL healthy, then migrations, then Fleet, then Caddy; `Restart=always` | new | After `reboot` and after `kill -9` on each container, the stack is healthy without manual action within a stated time |
| 2.3 | **Resource limits**: container memory limits, deliberate `innodb_buffer_pool_size`, swap file | new | Under a memory-stress test MySQL is not OOM-killed |
| 2.4 | **Connection tuning**: MySQL max open conns to 25 with matching `max_connections`; Redis pool reduced | #2, #3 | Values are variables with documented defaults; no connection errors under a load test with the max supported device count |
| 2.5 | **Disk-full protection**: binlog retention (or disabled), journald cap, container log rotation, disk alert threshold | new | A 7-day soak shows bounded growth; settings visible in a test deploy |
| 2.6 | **Upgrade procedure** (`scripts/upgrade.sh` + README): pre-upgrade backup, pull image, `fleet prepare db`, restart, health check, rollback notes. Make `fleet_version` semantics explicit | #36 | Upgrade from the previous pinned Fleet version to the next succeeds on a test server with data |
| 2.7 | **Patching policy**: how OS updates are applied and when reboots occur | new | Documented; stack verified to come back after an update-triggered reboot |
| 2.8 | **MySQL version review**: check Fleet's supported MySQL versions and the 8.0 support timeline; plan a 8.4 migration if supported | new | Decision recorded in an ADR or README note |

---

## v0.4.0: detection and hardening

| # | Item | Issues | Acceptance criteria |
|---|---|---|---|
| 3.1 | **External monitoring guide and optional integration**: uptime check on Fleet health endpoint, TLS expiry, disk and memory alerts | new | Fault injection (stop Fleet; fill disk to threshold) produces an alert |
| 3.2 | **SSH hardening**: key-only, fail2ban or equivalent | #23 | Password auth rejected; repeated bad attempts banned |
| 3.3 | **Metadata endpoint exposure**: document that user-data secrets are readable from the host; block container access to the metadata IP after boot | new | A container cannot reach the metadata endpoint |
| 3.4 | **Resource labels** | #14 | All Hetzner resources carry `project`, `managed-by=opentofu`, `environment` labels |
| 3.5 | **Key file cleanup on destroy** (reproduce first) | #20 | After `tofu destroy`, `.fleet_ed25519` is gone, or the issue is closed as not reproducible |
| 3.6 | **S3 credentials via env vars** (note: they still land in user-data and state) | #25 | tfvars no longer needs the keys; docs state the remaining exposure |
| 3.7 | **Object Storage dependency doc**: software installs can fail if Object Storage is degraded while check-ins keep working | new | Section in README |
| 3.8 | **Docs**: MySQL TLS omission rationale | #8 | README section explains localhost-only traffic |

---

## v1.0.0 release gate

All of v0.2.0 to v0.4.0 merged, plus one clean run of this end-to-end test on a
fresh Hetzner project:

1. `tofu apply` from a clean clone; DNS set; Fleet reachable over HTTPS.
2. Enroll one macOS or Windows host and one Linux host.
3. Confirm a nightly-style backup runs and lands off-host.
4. Reboot the server; stack returns healthy unaided.
5. Run the upgrade script to the next Fleet version.
6. Disable protection, destroy everything except the volume and backups.
7. Re-apply, restore, confirm the enrolled hosts check in without re-enrolling.
8. Record timings (RTO) in the README.

Plus: runbook (`docs/runbook.md`) covering restore, upgrade, secret recovery,
rotation of the enroll secret; CI green on `main`.

---

## v0.2.0 decisions (2026-10-23)

- **Upgrades**: support in-place migration from v0.1.0. CHANGELOG documents copying
  `/var/lib/fleet` onto the new volume and `tofu import` of the existing
  auto-created Primary IPs (same addresses, no DNS change).
- **Volume (1.1, #58)**: one `hcloud_volume` mounted at `/var/lib/fleet` (MySQL,
  Redis, Caddy certs, vulndb), not `/var/lib/mysql`. Hetzner formats it once
  (`format = "ext4"`); cloud-init only mounts by `/dev/disk/by-id` and never runs mkfs.
- **Protection (1.2, #15)**: `protect_resources` variable (default `true`) sets
  Hetzner `delete_protection`/`rebuild_protection` on the server, volume and Primary
  IPs. Close #15 in favour of this; no `prevent_destroy`.
- **Primary IPs (1.3, #59)**: `auto_delete = false`; existing servers import theirs.
- **Backups (1.4, #4)**: opt-in (empty `backup_repository` means no timer, with a loud
  warning in `next_steps` and the README). Nightly 03:00 UTC systemd timer:
  `mysqldump --single-transaction` | `restic backup --stdin`, plus `/etc/fleet`.
  Retention 7 daily / 4 weekly / 6 monthly, set by variables. Target is Hetzner
  Object Storage in a different location; the operator creates the bucket and
  scoped keys by hand, so tofu never manages or destroys them. The restic password
  is an operator-supplied sensitive variable, never generated into state.
  Optional `backup_healthcheck_url` ping on success and `/fail` on error.
- **Secrets recovery (1.5, #60)**: sensitive outputs for `server_private_key` and
  `wstep_key`, plus `scripts/export-secrets.sh`; `/etc/fleet` is in the restic
  backup; optional override variables (`fleet_server_private_key`,
  `wstep_cert_pem`/`wstep_key_pem`, `enroll_secret`, default empty means generate)
  so a total loss of state is recoverable with only the restic password and
  bucket credentials. (`tls_*` resources can't be imported, so overrides are required.)
- **State (1.6, #16)**: encryption on and enforced in `main.tf`, required
  `state_passphrase`; CHANGELOG shows the one-time `fallback` migration.
  `backend.tf.example` for a Hetzner Object Storage s3 backend with `use_lockfile`;
  local stays the default.
- **Restore drill (1.7, #61)**: `docs/restore.md` + `scripts/restore.sh`; no target
  set in advance; the operator runs it on a real project and the measured RTO is recorded.
- **Server backups (1.8, #62)**: `server_backups` variable, default `false`.
- **PRs**: one per item, in order: protection, volume, Primary IPs, server
  backups, state encryption, MySQL backups, secrets recovery, restore drill.

## Open decisions (later releases)

1. **Deferred issues** (#26, #27, #10, #9, #11, #12, #5, #13): confirm they are
   post-1.0. Note #13 (image by id) can force server replacement when Hetzner
   publishes a new image; if done, add `image` to `ignore_changes`.
