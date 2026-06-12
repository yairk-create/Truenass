#!/bin/bash
# truenas-postinit.sh
# Post-init script for TrueNAS SCALE
#
# Phase 0 - Acquires exclusive lock (prevents concurrent runs).
#           Clears stale lifecycle log. Waits for system to settle.
# HD Ping - Verifies ZFS pool health. Waits up to 60s for all pools ONLINE.
#           Logs disk I/O latency via iostat; warns on read/write > 20ms.
# Phase 1 - Waits for network connectivity.
# Phase 2 - Checks Docker health, repairs with escalating fixes:
#           Attempt 1: Simple restart with reset-failed.
#           Attempt 2: Clear stale network database.
#           Attempt 3: Full Docker wipe (stop apps, stop Docker, wipe, restart).
# Phase 3 - Restarts middleware so TrueNAS rediscovers apps.
# Phase 4 - Redeploys all stopped/crashed apps (pulls fresh images if needed).
# Phase 5 - Waits for apps to deploy. If corrupted layers appear during
#           THIS boot, performs a clean Docker wipe and redeploys (once only).
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
MAX_RETRIES=3
NETWORK_WAIT=60
HD_PING_WAIT=60
HD_LATENCY_THRESHOLD_MS=20
DOCKER_WAIT=30
MIDDLEWARE_WAIT=90
APP_DEPLOY_WAIT=300
LOG_RETENTION_DAYS=7

# Timeout for midclt calls (seconds). Prevents any single call from blocking.
MIDCLT_TIMEOUT=15
# Shorter timeout for the middleware ready check (called in a tight loop).
MIDCLT_PROBE_TIMEOUT=5

SCRIPT_START=$(date '+%Y-%m-%d %H:%M:%S')

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

stop_all_apps() {
    log "Stopping all apps before Docker wipe..."
    local apps
    apps=$(timeout "$MIDCLT_TIMEOUT" midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        if a['state'] not in ('STOPPED',):
            print(a['name'])
except:
    pass
" 2>/dev/null)
    if [ -n "$apps" ]; then
        for app in $apps; do
            timeout "$MIDCLT_TIMEOUT" midclt call app.stop "$app" > /dev/null 2>&1
        done
        sleep 10
    fi
}

full_docker_wipe() {
    log "Performing full Docker wipe..."
    stop_all_apps
    kill_docker
    log "Removing Docker data directory..."
    rm -rf "$DOCKER_DIR"
    mkdir -p "$DOCKER_DIR"
    > "$LIFECYCLE_LOG" 2>/dev/null
    log "Docker data directory recreated. Images will re-pull on deploy."
    start_docker
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

ping_hd() {
    log "Pool status:"
    zpool list -H -o name,health 2>/dev/null | while IFS=$'\t' read -r pool health; do
        log "  $pool: $health"
    done
}

check_disk_latency() {
    if ! command -v iostat > /dev/null 2>&1; then
        log "  Disk latency check skipped (iostat not available)."
        return
    fi
    local output header r_col w_col
    output=$(iostat -dx 1 2 2>/dev/null)
    header=$(echo "$output" | grep -m1 "r_await")
    if [ -z "$header" ]; then
        log "  Disk latency check skipped (iostat format unrecognized)."
        return
    fi
    r_col=$(echo "$header" | tr -s ' ' '\n' | grep -n "^r_await$" | cut -d: -f1)
    w_col=$(echo "$header" | tr -s ' ' '\n' | grep -n "^w_await$" | cut -d: -f1)
    if [ -z "$r_col" ] || [ -z "$w_col" ]; then
        log "  Disk latency check skipped (await columns not found)."
        return
    fi
    log "  Disk I/O latency (threshold: ${HD_LATENCY_THRESHOLD_MS}ms):"
    echo "$output" | awk -v rc="$r_col" -v wc="$w_col" -v thr="$HD_LATENCY_THRESHOLD_MS" '
        /^Device/ { block++ }
        block==2 && /^[a-z]/ {
            ra = $rc + 0; wa = $wc + 0
            status = (ra > thr || wa > thr) ? "HIGH" : "OK"
            printf "    %s: read=%.2fms write=%.2fms [%s]\n", $1, ra, wa, status
        }
    ' | while read -r line; do
        log "$line"
    done
}

check_layer_errors_current_boot() {
    if [ ! -f "$LIFECYCLE_LOG" ]; then
        return 1
    fi
    file_mtime=$(stat -c '%Y' "$LIFECYCLE_LOG" 2>/dev/null)
    script_epoch=$(date -d "$SCRIPT_START" '+%s' 2>/dev/null)
    if [ -z "$file_mtime" ] || [ -z "$script_epoch" ]; then
        return 1
    fi
    if [ "$file_mtime" -lt "$script_epoch" ]; then
        return 1
    fi
    grep -q "layer does not exist\|failed to register layer" "$LIFECYCLE_LOG" 2>/dev/null
    return $?
}

# ---- Prune old logs ----
prune_log

# Clear stale lifecycle log so previous boot errors cannot affect this run
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
check_disk_latency

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

# ---- Phase 2: Docker health check and repair ----
log "Phase 2: Checking Docker health..."

if check_docker; then
    log "Docker is running and healthy."
else
    log "Docker is not healthy. Starting repair sequence."

    for attempt in $(seq 1 "$MAX_RETRIES"); do
        log "Repair attempt ${attempt}/${MAX_RETRIES}"

        kill_docker

        if [ "$attempt" -ge 2 ]; then
            log "Clearing stale Docker network database..."
            if [ -f "${DOCKER_DIR}/network/files/local-kv.db" ]; then
                rm -f "${DOCKER_DIR}/network/files/local-kv.db"
                log "Removed local-kv.db"
            fi
        fi

        if [ "$attempt" -ge 3 ]; then
            log "Full Docker wipe on attempt ${attempt}..."
            rm -rf "$DOCKER_DIR"
            mkdir -p "$DOCKER_DIR"
            log "Docker data directory recreated."
        fi

        start_docker

        log "Waiting for Docker to respond (up to ${DOCKER_WAIT}s)..."
        for i in $(seq 1 "$DOCKER_WAIT"); do
            if check_docker; then
                log "Docker is running after repair attempt ${attempt}."
                break 2
            fi
            sleep 1
        done

        log "Docker did not start on attempt ${attempt}."
    done

    if ! check_docker; then
        log "FATAL: Docker failed to start after ${MAX_RETRIES} attempts."
        log "Check: journalctl -u docker.service -b --no-pager"
        log "========================================="
        exit 1
    fi
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

# ---- Wait for apps and images to settle ----
log "Waiting 300s for apps and images to settle before deploying..."
sleep 300

# ---- Phase 4: Deploy all stopped/crashed apps ----
log "Phase 4: Deploying all stopped apps..."

stopped=$(get_stopped_apps)
if [ -z "$stopped" ]; then
    log "No stopped apps found."
else
    log "Stopped apps: $(echo $stopped | tr '\n' ' ')"

    image_count=$(docker images -q 2>/dev/null | wc -l)
    if [ "$image_count" -lt 5 ]; then
        log "Low image count ($image_count). Using redeploy to pull fresh images."
        for app in $stopped; do
            log "Redeploying $app..."
            timeout "$MIDCLT_TIMEOUT" midclt call app.redeploy "$app" > /dev/null 2>&1
            sleep 5
        done
    else
        log "Images present ($image_count). Using app.start."
        for app in $stopped; do
            log "Starting $app..."
            timeout "$MIDCLT_TIMEOUT" midclt call app.start "$app" > /dev/null 2>&1
            sleep 3
        done
    fi
fi

# ---- Phase 5: Wait for apps, handle issues ----
log "Phase 5: Waiting for apps to finish deploying (up to ${APP_DEPLOY_WAIT}s)..."
images_wiped=0

for i in $(seq 1 "$APP_DEPLOY_WAIT"); do
    not_running=$(get_non_running_apps)

    if [ -z "$not_running" ]; then
        log "All apps are running."
        break
    fi

    if [ $((i % 30)) -eq 0 ]; then
        log "Still waiting on: $(echo $not_running | tr '\n' ' ')"
    fi

    # At 90s, check for corrupted layers from THIS boot only (once)
    if [ "$i" -eq 90 ] && [ "$images_wiped" -eq 0 ]; then
        if check_layer_errors_current_boot; then
            log "Detected corrupted layers during this boot. Full Docker wipe..."
            full_docker_wipe
            images_wiped=1
            if check_docker; then
                log "Docker restarted clean. Restarting middleware..."
                restart_middleware
                sleep 10
                log "Redeploying all apps with fresh images..."
                for app in $(get_all_apps); do
                    timeout "$MIDCLT_TIMEOUT" midclt call app.redeploy "$app" > /dev/null 2>&1
                    sleep 5
                done
            else
                log "ERROR: Docker failed to restart after wipe."
            fi
        fi
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

log "========================================="
log "Post-init script complete"
log "========================================="
exit 0
