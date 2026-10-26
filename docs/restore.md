# Restore and restore drill

## Which recovery do you need?

| What happened | What to do | Data loss |
|---|---|---|
| Server broken (bad config, OS trouble), data volume fine | Replace the server: `protect_resources=false`, `tofu taint hcloud_server.fleet`, apply. The volume and Primary IPs are reattached | None |
| Database corrupted or volume lost, server or state still there | `scripts/restore.sh` (below) | Since the last nightly backup |
| Everything lost, including the state | [secrets-recovery.md](secrets-recovery.md) scenario 2, then `scripts/restore.sh` | Since the last nightly backup |

## Restoring the database

```bash
export TF_VAR_state_passphrase='…'
scripts/restore.sh            # latest snapshot
scripts/restore.sh 1a2b3c4d   # a specific one; list them with restic snapshots
```

The script connects to the server over SSH and:

1. Checks that the snapshot's `FLEET_SERVER_PRIVATE_KEY` matches the
   server's, and refuses if it doesn't: that database would be unusable for
   MDM. Fix this by deploying with the recovered secrets
   ([secrets-recovery.md](secrets-recovery.md)), not with `FORCE=1`, unless
   you're sure.
2. Stops Fleet and the backup timer.
3. Drops and recreates the `fleet` database, then loads the snapshot's dump
   (`restic dump … | mysql`). The `fleet` MySQL user keeps its grants.
4. Flushes Redis and starts Fleet, which runs `fleet prepare db` first, so a
   backup from an older Fleet version is migrated forward.
5. Waits for `https://<domain>/healthz` and prints the elapsed time.

The server must have been deployed with the `backup_*` variables set; the
script reads the repository and credentials from `/etc/fleet/backup.env`.

If the server was replaced, its SSH host key changed. Clear the old entry
first: `ssh-keygen -R "$(tofu output -raw ipv4_address)"`.

## Restore drill

Run this on a test deployment before trusting the backups. It replays the
worst common case: server **and** data volume gone, restored from the
off-host backup. The Primary IPs are kept so DNS doesn't change.

**Before you start**

- Backups configured, and at least one host enrolled (ideally one macOS or
  Windows host enrolled in MDM, and one Linux host).
- Take a fresh backup and note what to check afterwards:

  ```bash
  SSH="ssh -i .fleet_ed25519 root@$(tofu output -raw ipv4_address)"
  $SSH 'systemctl start fleet-backup && journalctl -u fleet-backup -n 5 --no-pager'
  ```

  Note the number of hosts, a recent policy or query result, and the admin
  login.

**Drill** (start a timer now)

1. Destroy the server and its data volume:

   ```bash
   tofu apply -var protect_resources=false
   tofu destroy -var protect_resources=false \
     -target=hcloud_server.fleet -target=hcloud_volume.fleet_data
   ```

2. Redeploy. This turns protection back on, creates a fresh, empty Fleet,
   and reuses the same IPs:

   ```bash
   tofu apply
   ssh-keygen -R "$(tofu output -raw ipv4_address)"
   $SSH 'cloud-init status --wait'
   ```

   **Don't** complete Fleet's setup page on the empty instance. The restore
   brings back the users.

3. Restore:

   ```bash
   scripts/restore.sh
   ```

4. Verify, then stop the timer:
   - Log in with the old admin account. The host count matches.
   - Within a few minutes, enrolled hosts report again (*Last seen* updates)
     **without re-enrolling**. That proves the enroll secret, server key and
     WSTEP CA survived.
   - On an MDM host, send a harmless command (for example, refetch) and see
     it acknowledged.

Caddy requests a new TLS certificate because the volume was new. Let's
Encrypt allows 5 duplicate certificates a week, so don't run the drill more
than a few times a week against the same domain.

## Measured RTO

Record each drill here. The figure is the time from step 1 to step 4
complete.

| Date | Fleet version | DB dump size | Restore script time | Total drill time (RTO) | Notes |
|---|---|---|---|---|---|
| _not yet run_ | | | | | |
