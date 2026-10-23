# Upgrading a v0.1.0 deployment to v0.2.0

v0.2.0 changes infrastructure under a running server. `user_data` changes are
ignored on existing servers (`ignore_changes = [user_data]`), so a plain
`tofu apply` creates the new resources but doesn't reconfigure the server.
Follow the steps below once per deployment.

## Data volume (#58)

v0.2.0 moves everything under `/var/lib/fleet` (MySQL, Redis, Caddy certs,
vulndb) onto a Hetzner volume. Expect a few minutes of downtime while the data
is copied.

1. Take a manual backup first, such as a Hetzner snapshot of the server in the
   console.

2. Create and attach the volume. Hetzner formats it as ext4. This doesn't
   touch the running stack.

   ```bash
   tofu apply
   DEV=$(tofu output -raw data_volume_device)
   SSH="ssh -i .fleet_ed25519 root@$(tofu output -raw ipv4_address)"
   ```

3. Stop the stack, copy the data, and swap the mount. Run this on the server:

   ```bash
   $SSH DEV="$DEV" 'bash -s' <<'SCRIPT'
   set -euo pipefail
   systemctl stop fleet-caddy fleet-server fleet-redis fleet-db
   mkdir -p /mnt/fleet-data
   mount "$DEV" /mnt/fleet-data
   rsync -aHAX /var/lib/fleet/ /mnt/fleet-data/
   umount /mnt/fleet-data
   mv /var/lib/fleet /var/lib/fleet.pre-volume
   mkdir /var/lib/fleet
   echo "$DEV /var/lib/fleet ext4 defaults,nofail 0 2" >> /etc/fstab
   mount /var/lib/fleet
   # Same guard new servers get: never start on the bare root disk.
   sed -i '/^\[Unit\]/a RequiresMountsFor=/var/lib/fleet' /etc/containers/systemd/fleet-*.container
   systemctl daemon-reload
   systemctl start fleet-db fleet-redis fleet-server fleet-caddy
   SCRIPT
   ```

4. Check that Fleet comes back with its data, and that hosts still check in:

   ```bash
   $SSH 'findmnt /var/lib/fleet && systemctl is-active fleet-db fleet-redis fleet-server fleet-caddy'
   ```

   Then log in to `https://<domain>`.

5. When you're satisfied, free the old copy on the root disk:

   ```bash
   $SSH 'rm -rf /var/lib/fleet.pre-volume'
   ```

**Rollback** (before step 5): stop the stack, `umount /var/lib/fleet`, remove
the fstab line and the `RequiresMountsFor` lines, then
`rmdir /var/lib/fleet && mv /var/lib/fleet.pre-volume /var/lib/fleet` and start
the stack again.
