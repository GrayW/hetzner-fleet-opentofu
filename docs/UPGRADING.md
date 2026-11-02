# Upgrading Fleet

The `fleet_version` variable only affects the initial cloud-init provisioning.
Because `hcloud_server.fleet` ignores changes to `user_data`, changing
`fleet_version` and running `tofu apply` reports "No changes" and does not
upgrade the running server.

## Upgrade in place

Use the helper script from the repository root (requires the generated SSH
key and root access):

    ssh -i .fleet_ed25519 root@<ip> 'bash -s' -- v4.93.0 < scripts/upgrade.sh

The script:

1. Pulls the new `fleetdm/fleet` image
2. Updates the `Image=` line in `/etc/containers/systemd/fleet-server.container`
3. Restarts `fleet-server.service`; its `ExecStartPre` hook runs
   `fleet prepare db`, so database migrations apply automatically

Afterwards, keep `fleet_version` in `terraform.tfvars` in sync with what is
actually deployed so the repo reflects reality (it will not trigger any
infrastructure change).

## Rebuilding from scratch

To re-provision the server with a fresh install (e.g. to test cloud-init from
scratch), first back up anything you need, then:

    tofu taint hcloud_server.fleet
    tofu apply

WARNING: this destroys the server and its MySQL volume. If the
`prevent_destroy` lifecycle guard is enabled, OpenTofu will refuse until you
remove it deliberately.
