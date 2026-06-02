#!/bin/bash
# truenas-postinit.sh
# Post-init script for TrueNAS SCALE
#
# Phase 0 - Acquires exclusive lock (prevents concurrent runs).
#           Clears stale lifecycle log. Waits for system to settle.
# HD Ping - Verifies ZFS pool health. Waits up to 60s for all pools ONLINE.
# Phase 1 - Waits for network connectivity.
# Phase 2 - Stops Docker, wipes Docker data, restarts Docker clean.
#           This ensures no corrupted layers carry over between boots.
# Phase 3 - Restarts middleware so TrueNAS rediscovers apps.
# Phase 4 - Redeploys all apps (pulls fresh images).
# Phase 5 - Waits for apps to finish deploying.
#           Redeploys stuck apps at 180s as a final attempt.
# Phase 6 - Final middleware restart to sync UI.
#
# Logs: /var/log/truenas-postinit.log (pruned to 7 days)
#
# Install:
#   1. Copy to /mnt/main/app_storage/truenas-postinit.sh
#   2. chmod +x /mnt/main/app_storage/truenas-postinit.sh
#   3. TrueNAS UI > System Settings > Advanced > Init/Shutdown Scripts
#   4. Add: Type=Script, Script=/mnt/main/app_storage/truenas-postinit.sh
#      When=Post Init, Timeout=1500, Enabled=true

# ---- Exclusive lock to prevent concurrent runs ----
LOCKFILE="/var/run/truenas-postinit.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Another instance is already running. Exiting." >> /var/log/truenas-postinit.log
    exit 0
fi

LOG="/var/log/truenas-postinit.log"
LIFECYCLE_LOG="/var/log/app_lifecycle.log"
DOCKER_DIR="/mnt/.ix-apps/docker"
NETWORK_WAIT=60
HD_PING_WAIT=60
DOCKER_WAIT=30
MIDDLEWARE_WAIT=90
APP_DEPLOY_WAIT=300
LOG_RETENTION_DAYS=7

# Timeout for midclt calls (seconds). Prevents any single call from blocking.
MIDCLT_TIMEOUT=15
# Shorter timeout for the middleware ready check (called in a tight loop).
MIDCLT_PROBE_TIMEOUT=5

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

prune_log() {
    if [ ! -f "$LOG" ]; then
        return
    fi
    cutoff=$(date -d "-${LOG_RETENTION_DAYS} days" '+%Y-%m-%d %H:%M:%S')
    tmp="${LOG}.tmp"
    while IFS= read -r line; do
        ts=$(echo "$line" | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
        if [ -n "$ts" ] && [ "$ts" \> "$cutoff" ]; then
            echo "$line"
        fi
    done < "$LOG" > "$tmp"
    mv "$tmp" "$LOG"
}

check_docker() {
    systemctl is-active --quiet docker.service && docker info > /dev/null 2>&1
}

kill_docker() {
    log "Stopping Docker services..."
    systemctl reset-failed docker.service 2>/dev/null
    systemctl reset-failed containerd.service 2>/dev/null
    systemctl stop docker.service 2>/dev/null
    systemctl stop docker.socket 2>/dev/null
    systemctl stop containerd.service 2>/dev/null
    sleep 3
    pkill -9 dockerd 2>/dev/null
    pkill -9 containerd 2>/dev/null
    sleep 2
}

start_docker() {
    log "Starting Docker services..."
    systemctl reset-failed docker.service 2>/dev/null
    systemctl reset-failed containerd.service 2>/dev/null
    systemctl start containerd.service
    sleep 5
    systemctl start docker.service
}

# Restart middleware without hanging.
# Uses stop+kill+start instead of restart, with polling to confirm it's down.
restart_middleware() {
    log "Restarting middleware..."

    # Stop middleware in the background
    systemctl stop middlewared 2>/dev/null &
    local stop_pid=$!

    # Wait up to 30s for stop to complete
    for i in $(seq 1 30); do
        if ! kill -0 "$stop_pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # If stop is still running, force-kill everything
    if kill -0 "$stop_pid" 2>/dev/null; then
        log "Middleware stop timed out after 30s. Force-killing..."
        kill "$stop_pid" 2>/dev/null
        systemctl kill -s KILL middlewared 2>/dev/null
        pkill -9 -f middlewared 2>/dev/null
        sleep 3
    fi

    # Verify it's actually dead
    for i in $(seq 1 10); do
        if ! systemctl is-active --quiet middlewared; then
            break
        fi
        pkill -9 -f middlewared 2>/dev/null
        sleep 1
    done

    log "Middleware stopped. Starting fresh..."
    systemctl reset-failed middlewared 2>/dev/null
    systemctl start middlewared 2>/dev/null

    # Wait for it to become responsive
    log "Waiting for middleware to respond (up to ${MIDDLEWARE_WAIT}s)..."
    for i in $(seq 1 "$MIDDLEWARE_WAIT"); do
        if timeout "$MIDCLT_PROBE_TIMEOUT" midclt call app.query > /dev/null 2>&1; then
            log "Middleware is ready after ${i}s."
            return 0
        fi
        sleep 1
    done

    log "ERROR: Middleware not responding after ${MIDDLEWARE_WAIT}s."
    return 1
}

get_non_running_apps() {
    timeout "$MIDCLT_TIMEOUT" midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        if a['state'] not in ('RUNNING',):
            print(a['name'])
except:
    pass
"
}

get_stopped_apps() {
    timeout "$MIDCLT_TIMEOUT" midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        if a['state'] in ('STOPPED', 'CRASHED'):
            print(a['name'])
except:
    pass
"
}

get_all_apps() {
    timeout "$MIDCLT_TIMEOUT" midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        print(a['name'])
except:
    pass
"
}

ping_hd() {
    log "Pool status:"
    zpool list -H -o name,health 2>/dev/null | while IFS=$'\t' read -r pool health; do
        log "  $pool: $health"
    done
}

log_app_states() {
    timeout "$MIDCLT_TIMEOUT" midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        print(a['name'] + ' ' + a['state'])
except:
    pass
" | while read -r line; do
        log "  $line"
    done
}

# ---- Prune old logs ----
prune_log

# Clear stale lifecycle log
> "$LIFECYCLE_LOG" 2>/dev/null

log "========================================="
log "Post-init script started (PID $$)"
log "========================================="

# ---- Phase 0: Wait for system to settle ----
log "Phase 0: Waiting 180s for system and pools to settle..."
sleep 180

# ---- HD Ping: Verify ZFS pool health ----
log "HD Ping: Checking ZFS pool health (up to ${HD_PING_WAIT}s)..."
for i in $(seq 1 "$HD_PING_WAIT"); do
    pool_count=$(zpool list -H -o name 2>/dev/null | wc -l)
    if [ "$pool_count" -gt 0 ]; then
        non_online=$(zpool list -H -o health 2>/dev/null | grep -cv "^ONLINE$")
        if [ "$non_online" -eq 0 ]; then
            log "HD Ping: All ${pool_count} ZFS pool(s) ONLINE after ${i}s."
            break
        fi
    fi
    if [ "$i" -eq "$HD_PING_WAIT" ]; then
        log "WARNING: ZFS pools not fully ONLINE after ${HD_PING_WAIT}s. Continuing anyway."
    fi
    sleep 1
done
ping_hd

# ---- Phase 1: Network wait ----
log "Phase 1: Waiting for network (up to ${NETWORK_WAIT}s)..."
for i in $(seq 1 "$NETWORK_WAIT"); do
    if ping -c 1 -W 2 1.1.1.1 > /dev/null 2>&1; then
        log "Network is up after ${i}s."
        break
    fi
    if [ "$i" -eq "$NETWORK_WAIT" ]; then
        log "ERROR: Network not available after ${NETWORK_WAIT}s. Continuing anyway."
    fi
    sleep 1
done

sleep 10

# ---- Phase 2: Clean Docker wipe ----
# Always wipe Docker data to eliminate corrupted layers.
# Images are re-pulled during Phase 4 redeploy.
log "Phase 2: Wiping Docker data for clean start..."

kill_docker

log "Removing Docker data directory..."
rm -rf "$DOCKER_DIR"
mkdir -p "$DOCKER_DIR"
log "Docker data directory recreated."

start_docker

log "Waiting for Docker to respond (up to ${DOCKER_WAIT}s)..."
docker_ok=0
for i in $(seq 1 "$DOCKER_WAIT"); do
    if check_docker; then
        log "Docker is running after ${i}s."
        docker_ok=1
        break
    fi
    sleep 1
done

if [ "$docker_ok" -eq 0 ]; then
    log "Docker did not start after wipe. Retrying..."
    kill_docker
    sleep 5
    start_docker
    for i in $(seq 1 "$DOCKER_WAIT"); do
        if check_docker; then
            log "Docker is running on retry."
            docker_ok=1
            break
        fi
        sleep 1
    done
fi

if [ "$docker_ok" -eq 0 ]; then
    log "FATAL: Docker failed to start after clean wipe."
    log "Check: journalctl -u docker.service -b --no-pager"
    log "========================================="
    exit 1
fi

# ---- Phase 3: Restart middleware to rediscover apps ----
log "Phase 3: Restarting middleware to sync apps..."
restart_middleware
if [ $? -ne 0 ]; then
    log "FATAL: Cannot proceed without middleware."
    log "========================================="
    exit 1
fi

sleep 10

# ---- Phase 4: Redeploy all apps ----
log "Phase 4: Redeploying all apps (pulling fresh images)..."

all_apps=$(get_all_apps)
if [ -z "$all_apps" ]; then
    log "No apps found."
else
    log "Apps to redeploy: $(echo $all_apps | tr '\n' ' ')"
    for app in $all_apps; do
        log "Redeploying $app..."
        timeout "$MIDCLT_TIMEOUT" midclt call app.redeploy "$app" > /dev/null 2>&1
        sleep 5
    done
fi

# ---- Phase 5: Wait for apps to finish deploying ----
log "Phase 5: Waiting for apps to finish deploying (up to ${APP_DEPLOY_WAIT}s)..."

for i in $(seq 1 "$APP_DEPLOY_WAIT"); do
    not_running=$(get_non_running_apps)

    if [ -z "$not_running" ]; then
        log "All apps are running."
        break
    fi

    if [ $((i % 30)) -eq 0 ]; then
        log "Still waiting on: $(echo $not_running | tr '\n' ' ')"
    fi

    # At 180s, redeploy anything still stopped or crashed
    if [ "$i" -eq 180 ]; then
        stuck=$(get_stopped_apps)
        if [ -n "$stuck" ]; then
            log "Redeploying stuck apps at 180s: $(echo $stuck | tr '\n' ' ')"
            for app in $stuck; do
                timeout "$MIDCLT_TIMEOUT" midclt call app.redeploy "$app" > /dev/null 2>&1
                sleep 5
            done
        fi
    fi

    sleep 1
done

# ---- Phase 6: Final middleware restart to sync UI ----
log "Phase 6: Final middleware restart for UI sync..."
restart_middleware

log "Final app states:"
log_app_states

not_running=$(get_non_running_apps)
if [ -n "$not_running" ]; then
    log "WARNING: Some apps not running: $(echo $not_running | tr '\n' ' ')"
else
    log "All apps running successfully."
fi

# ---- Phase 7: Final recovery for any stragglers ----
log "Phase 7: Sleeping 600s before final app recovery..."
sleep 600

stopped=$(get_stopped_apps)
if [ -n "$stopped" ]; then
    log "Starting stopped apps: $(echo $stopped | tr '\n' ' ')"
    for app in $stopped; do
        log "Starting $app..."
        timeout "$MIDCLT_TIMEOUT" midclt call app.start "$app" > /dev/null 2>&1
        sleep 5
    done

    # Give them time to come up
    sleep 60

    log "App states after final recovery:"
    log_app_states
else
    log "All apps already running. No recovery needed."
fi

log "========================================="
log "Post-init script complete"
log "========================================="
exit 0
