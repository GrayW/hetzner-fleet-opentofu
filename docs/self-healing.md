# Health checks and self-healing

The four containers run as Podman quadlets (systemd units). Each one restarts
on its own after a crash or a reboot, and each starts only when the services it
depends on are actually ready, not just started.

## Start order

```
fleet-db (MySQL)  ─┐
                   ├─ healthy ─> fleet-migrate ─> fleet-server ─ healthy ─> fleet-caddy
fleet-redis       ─┘
```

`Notify=healthy` makes systemd treat a unit as started only after its first
passing health check. `After=` on the next unit then waits for that, so:

- Migrations (`fleet prepare db`, the `ExecStartPre` of `fleet-server`) never
  run against a MySQL that is still initialising.
- Caddy starts after Fleet is healthy. It uses `Wants=`, not `Requires=`, so it
  keeps running, and renewing certificates, while Fleet restarts.

## Health checks

| Container | Check | Interval | Marked unhealthy after |
|---|---|---|---|
| `fleet-db` | `mysqladmin ping -h 127.0.0.1` | 10s | 6 failures (120s grace at start) |
| `fleet-redis` | `redis-cli ping` returns `PONG` | 10s | 3 failures (30s grace at start) |
| `fleet-server` | `GET /healthz` (BusyBox `wget`; the image has no `curl`) | 15s | 4 failures (60s grace at start) |
| `fleet-caddy` | none, restart on exit only | | |

The MySQL check uses TCP on purpose: the image's first-run init server listens
on the socket only, so a socket ping would report healthy too early.

Fleet's `/healthz` also checks its MySQL and Redis connections. A short MySQL or
Redis outage doesn't restart Fleet: it reconnects by itself within seconds.
Only an outage longer than about a minute gets Fleet restarted.

An unhealthy container is killed (`HealthOnFailure=kill`) and `Restart=always`
starts it again. `fleet-server` has no start limit, so it keeps retrying
through a long MySQL outage and recovers once MySQL is back.

Check health on the server:

```bash
podman ps --format '{{.Names}}\t{{.Status}}'
podman healthcheck run fleet-server && echo healthy
systemctl list-units 'fleet-*'
```

## Expected recovery time

These are estimates from the settings above, not measurements. Replace them
with your own numbers from the test below.

| Event | Expected time to healthy |
|---|---|
| MySQL process killed | about 30s (Fleet reconnects without a restart) |
| Redis process killed | about 15s |
| Fleet process killed | about 45s (20s restart delay, no-op migrations, first check) |
| Caddy process killed | about 5s |
| Server reboot | about 2 minutes after boot, mostly MySQL start and migrations |

On a brand-new server the first start also pulls images and creates the
database, so allow up to 10 minutes.

## Recovery test

Run this on a test server, not production. Each step should end with all four
containers healthy and `https://<domain>/healthz` returning 200, with no manual
action.

```bash
SSH="ssh -i .fleet_ed25519 root@<ip>"
URL=https://<domain>/healthz

# Wait for Fleet and print the elapsed time.
wait_healthy() {
  t=$(date +%s)
  until curl -fsS -m 5 "$URL" >/dev/null 2>&1; do sleep 2; done
  echo "healthy after $(( $(date +%s) - t ))s"
}

# 1. Kill each container's main process.
for c in fleet-db fleet-redis fleet-server fleet-caddy; do
  echo "== $c"
  $SSH "kill -9 \$(podman inspect -f '{{.State.Pid}}' $c)"
  sleep 3
  wait_healthy
done

# 2. Reboot.
$SSH reboot
sleep 10
wait_healthy

# 3. Confirm everything is up.
$SSH "podman ps --format '{{.Names}}\t{{.Status}}'"
```

## Measured recovery times

Record each test run here.

| Date | Fleet version | Server type | MySQL kill | Redis kill | Fleet kill | Caddy kill | Reboot | Notes |
|---|---|---|---|---|---|---|---|---|
| _not yet run_ | | | | | | | | |

## Existing servers

These units are written by cloud-init, and existing servers don't run it again.
To pick them up, replace the server. The data volume and Primary IPs are
reattached, so data, TLS certificates and DNS are kept:

```bash
tofu apply -var protect_resources=false
tofu taint hcloud_server.fleet
tofu apply -var protect_resources=false
tofu apply
```
