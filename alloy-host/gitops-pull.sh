#!/usr/bin/env bash
# Pull the central Alloy config from origin/main and reload the running
# `alloy` docker container when it drifts.
#
# Runs on the grafana-stack LXC (105), where the Alloy docker compose service
# lives at /opt/homelab-observability. Mirrors the spirit of
# homeassistant-config/kiosk-host/gitops-pull.sh: timestamped leveled log with
# in-script rotation, flock against concurrent runs, branch guard, validation
# before reload, and a no-op fast path so Alloy isn't reloaded on every poll.
#
# Driven by a 5-minute timer (alloy-gitops.{service,timer} in this directory).
# Those units are bootstrap-only and deliberately NOT managed by this loop, so a
# broken update can't leave the host unable to fix itself. Bootstrap recipe is
# in this directory's README.

set -euo pipefail

readonly REPO_DIR="/opt/homelab-observability"
readonly LOCK_FILE="/run/alloy-gitops.lock"
readonly LOG_FILE="/var/log/alloy-gitops.log"
readonly LOG_MAX_BYTES=1048576
readonly CONTAINER="alloy"

log() {
  local level="$1"
  shift
  local ts line
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  line="[$ts] [$level] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$LOG_FILE"
}

rotate_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$LOG_FILE")
    if ((size >= LOG_MAX_BYTES)); then
      mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
  fi
}

main() {
  rotate_log

  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    log ERROR "No git repo at ${REPO_DIR}. Bootstrap: see alloy-host/README.md"
    exit 1
  fi
  cd "${REPO_DIR}"

  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ "${branch}" != "main" ]]; then
    log ERROR "Expected branch 'main', got '${branch}'. Aborting to avoid deploying the wrong branch."
    exit 1
  fi

  if ! git fetch --quiet origin main; then
    log ERROR "git fetch failed — check network or DNS"
    exit 1
  fi

  local old new
  old=$(git rev-parse HEAD)
  new=$(git rev-parse origin/main)
  if [[ "${old}" == "${new}" ]]; then
    log INFO "no-op, at ${new:0:7}"
    exit 0
  fi

  local changed
  changed=$(git diff --name-only "${old}" "${new}")
  log INFO "Updating ${old:0:7} → ${new:0:7}"
  git reset --hard --quiet origin/main

  # Validate the new config before reloading. Alloy does not auto-reload, so a
  # broken config on disk cannot affect the running process until we SIGHUP —
  # if validation fails we roll the working tree back and skip the reload, and
  # the collector keeps running its last-good in-memory config.
  if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    if ! docker exec "${CONTAINER}" alloy fmt /etc/alloy/config.alloy >/dev/null 2>&1; then
      log ERROR "alloy fmt failed on the new config — rolling back to ${old:0:7}, not reloading"
      git reset --hard --quiet "${old}"
      exit 1
    fi
  fi

  # Apply. A docker-compose.yml change recreates the container (which also picks
  # up any alloy/ change); an alloy/ change alone just needs a config reload via
  # SIGHUP (the ./alloy directory mount means the container sees the new files);
  # anything else (docs/scripts/terraform) is a no-op for the running collector.
  if grep -qx 'docker-compose.yml' <<<"${changed}"; then
    log INFO "docker-compose.yml changed → docker compose up -d"
    docker compose up -d >/dev/null
  elif grep -qE '^alloy/' <<<"${changed}"; then
    log INFO "alloy/ changed → reloading config (SIGHUP)"
    docker kill --signal=HUP "${CONTAINER}" >/dev/null
  else
    log INFO "update touched no alloy/ or compose files — nothing to reload"
  fi

  log INFO "Deployed ${new:0:7}"
}

main_locked() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    exit 0
  fi
  main
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_locked
fi
