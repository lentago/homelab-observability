# alloy-host — gitops deploy for the central Alloy collector

These files make the **central Alloy** on the grafana-stack LXC (currently
**LXC 105**, `192.168.139.20`, on pve5) deploy itself from `origin/main`,
instead of being hand-patched. They mirror the kiosk's gitops loop
(`homeassistant-config/kiosk-host/`).

| File | Installed to | Role |
|---|---|---|
| `gitops-pull.sh` | run in place from the clone | fetch `origin/main`, validate, reload Alloy on drift |
| `alloy-gitops.service` | `/etc/systemd/system/` | oneshot that runs the script |
| `alloy-gitops.timer` | `/etc/systemd/system/` | fires the service every 5 min |

## Deploy model

`alloy-gitops.timer` fires every 5 minutes. `gitops-pull.sh`:

1. `flock`s against concurrent runs; refuses unless the checkout is on `main`.
2. `git fetch origin main`; **exits silently if already up to date** (no-op fast
   path — Alloy is never reloaded on a quiet poll).
3. On divergence: `git reset --hard origin/main`, then validates the new config
   with `alloy fmt` **inside the running container**. Alloy doesn't auto-reload,
   so a broken config on disk can't affect the live process — on a validation
   failure the script rolls the working tree back and skips the reload, leaving
   the last-good in-memory config running.
4. Applies the smallest reload for what changed:
   - `docker-compose.yml` changed → `docker compose up -d` (recreate).
   - `alloy/` changed → `docker kill --signal=HUP alloy` (config reload). The
     `./alloy` **directory** mount (see `docker-compose.yml`) means the
     container sees the new files; single-file mounts would not.
   - anything else (docs, scripts, terraform) → no reload.

Log: `/var/log/alloy-gitops.log` (timestamped, leveled, rotates at 1 MB).

The `alloy-gitops.{service,timer}` units are **bootstrap-only** — deliberately
not managed by the loop they drive, so a broken update can't leave the host
unable to fix itself.

## Bootstrap (one-time, on the LXC)

The Alloy compose dir at `/opt/homelab-observability` must be a real git clone.
Cloud-push tokens live in untracked, gitignored files (`.env`,
`alloy/ha_token`) and are preserved across the conversion.

```bash
cd /opt
# 1. Preserve the gitignored secrets from the existing hand-copied dir.
cp homelab-observability/.env /root/alloy-env.bak
cp homelab-observability/alloy/ha_token /root/alloy-ha_token.bak

# 2. Stop Alloy and swap the hand-copied dir for a fresh clone (the named
#    volume homelab-observability_alloy-data — the WAL — is NOT removed).
cd /opt/homelab-observability && docker compose down
cd /opt && mv homelab-observability homelab-observability.precutover
git clone https://github.com/PitziLabs/homelab-observability.git

# 3. Restore the secrets, then bring Alloy back up on the new dir mount.
cp /root/alloy-env.bak       homelab-observability/.env
cp /root/alloy-ha_token.bak  homelab-observability/alloy/ha_token
cd homelab-observability && docker compose up -d

# 4. Install + enable the gitops timer (bootstrap-only).
install -m 0644 alloy-host/alloy-gitops.service /etc/systemd/system/
install -m 0644 alloy-host/alloy-gitops.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now alloy-gitops.timer

# 5. Verify: a manual run should be a no-op once main is deployed.
systemctl start alloy-gitops.service
tail -n 5 /var/log/alloy-gitops.log

# Once verified, remove the old copy: rm -rf /opt/homelab-observability.precutover
```

## Quick commands

```bash
# Force an immediate pull (don't wait for the timer)
systemctl start alloy-gitops.service
# Watch the loop
tail -f /var/log/alloy-gitops.log
# Pause the loop while hand-iterating on the LXC
systemctl stop alloy-gitops.timer
```

Reach the LXC from the workstation: `ssh -J root@pve.local root@pve5 …` then
`pct exec 105 -- bash`, or `ssh root@pve.local 'ssh pve5 "pct exec 105 -- bash -s"'`
(stdin pipes through the whole chain).
