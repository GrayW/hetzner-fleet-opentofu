# Upgrading a v0.1.0 deployment to v0.2.0

v0.2.0 changes infrastructure under a running server. `user_data` changes are
ignored on existing servers (`ignore_changes = [user_data]`), so a plain
`tofu apply` creates the new resources but doesn't reconfigure the server.
Follow the steps below once per deployment, in order: state encryption,
then the Primary IP imports, then the data volume.

## State encryption (#16)

v0.2.0 encrypts the state and refuses to read unencrypted state, so convert
it once **before** anything else. Back up the current state first.

1. Back up and set the passphrase:

   ```bash
   cp terraform.tfstate terraform.tfstate.pre-encryption
   export TF_VAR_state_passphrase='a-long-random-passphrase'
   ```

2. In `main.tf`, temporarily comment out the two `enforced = true` lines in the
   `encryption` block. Enforcement also blocks the one-time fallback below.

3. Re-initialise and rewrite the state encrypted. The `TF_ENCRYPTION` override
   lets this one run read the old plaintext state:

   ```bash
   tofu init
   TF_ENCRYPTION='method "unencrypted" "migrate" {}
   state {
     method = method.aes_gcm.main
     fallback {
       method = method.unencrypted.migrate
     }
   }' tofu apply -refresh-only
   ```

4. Restore `main.tf` (`git checkout main.tf`), check that `tofu plan` works,
   and confirm the state is no longer readable plaintext:

   ```bash
   grep -c '"mysql_root"' terraform.tfstate   # expect 0
   ```

5. Delete `terraform.tfstate.pre-encryption` and any `terraform.tfstate.backup`
   once you're satisfied. They hold the secrets in plaintext.

## Primary IPs (#59)

v0.2.0 manages the server's IPv4 and IPv6 as explicit Primary IPs with
`auto_delete = false`, so a rebuilt server keeps its addresses. Your server
already has Primary IPs that Hetzner created automatically. Import them so the
addresses stay the same and DNS doesn't change. Do this **before** the first
`tofu apply` of v0.2.0; otherwise tofu creates new IPs and moves the server
onto them (a power-off and an address change).

1. Find the IDs of the server's current Primary IPs:

   ```bash
   tofu show -json | jq -r '.values.root_module.resources[]
     | select(.address == "hcloud_server.fleet") | .values.public_net[0]
     | "ipv4=\(.ipv4) ipv6=\(.ipv6)"'
   ```

2. Import them:

   ```bash
   tofu import hcloud_primary_ip.ipv4 <ipv4-id>
   tofu import hcloud_primary_ip.ipv6 <ipv6-id>
   ```

3. Check the plan. It should only rename the IPs, set `auto_delete = false`
   and turn on delete protection. **No changes to `hcloud_server.fleet`'s
   `public_net`, and nothing replaced**:

   ```bash
   tofu plan
   ```

   Don't apply yet. Continue with the data volume steps below; their
   `tofu apply` applies both changes.

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
