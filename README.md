# truenas-postinit.sh

Post-init script for TrueNAS SCALE that ensures Docker and all apps come up cleanly after every reboot.

## Problem

TrueNAS SCALE apps (Docker containers) sometimes fail to start after a reboot due to:

- Docker service not starting properly
- Corrupted image layers in the overlay2 storage
- Stale Docker network database files
- Middleware losing track of app state
- Race conditions between pool imports and service starts

This script handles all of these automatically.

## How It Works

The script runs in 7 phases after every boot:

### Phase 0: Lock and Wait (180s)

Acquires an exclusive file lock so only one instance can run at a time. Clears any stale error logs from previous boots. Then waits 3 minutes for pools, networking, and system services to fully initialize before doing anything.

### Phase 1: Network Wait (up to 60s)

Pings 1.1.1.1 repeatedly until the network is up. Apps need network access to pull images and start properly. Continues even if the network doesn't come up.

### Phase 2: Docker Health Check

Checks if Docker is running and responsive. If not, attempts escalating repairs:

- **Attempt 1**: Reset systemd failed state, restart Docker services.
- **Attempt 2**: Same as above, plus remove the stale network database (`local-kv.db`).
- **Attempt 3**: Full wipe of the Docker data directory (`/mnt/.ix-apps/docker`), then restart. All images will need to be re-pulled.

If Docker still won't start after 3 attempts, the script exits with a fatal error.

### Phase 3: Middleware Restart

Restarts `middlewared` so TrueNAS rediscovers all apps and their current state. Uses a non-blocking stop/start approach: stops middleware in the background, waits up to 30 seconds, force-kills if it hangs, then starts fresh. This prevents the script from getting stuck on a hung middleware process.

### Wait Period (300s)

After middleware is up, waits 5 minutes for apps and images to settle before attempting to deploy anything.

### Phase 4: Deploy Stopped Apps

Checks all apps and deploys any that are stopped or crashed. Automatically detects whether Docker images are present:

- **Images present** (5+ images): Uses `app.start` (fast, no image pull needed).
- **Images missing** (fewer than 5): Uses `app.redeploy` which pulls fresh images from registries.

### Phase 5: Wait for Deployment (up to 300s)

Monitors all apps waiting for them to reach RUNNING state. Two automatic interventions:

- **At 90 seconds**: If corrupted image layers are detected (errors like "layer does not exist" or "failed to register layer" that appeared during *this boot only*), performs a full Docker wipe and redeploys all apps. This only happens once per boot.
- **At 180 seconds**: Any apps still stuck in STOPPED or CRASHED state are redeployed as a final attempt.

### Phase 6: Final Sync

Restarts middleware one last time to ensure the TrueNAS UI accurately reflects the state of all apps. Logs the final state of every app.

## Installation

1. Copy the script to persistent storage:
   ```bash
   cp truenas-postinit.sh /mnt/main/app_storage/truenas-postinit.sh
   chmod +x /mnt/main/app_storage/truenas-postinit.sh
   ```

2. Configure in TrueNAS UI:
   - Go to **System Settings > Advanced > Init/Shutdown Scripts**
   - Click **Add**
   - **Description**: fix-apps
   - **Type**: Script
   - **Script**: `/mnt/main/app_storage/truenas-postinit.sh`
   - **When**: Post Init
   - **Timeout**: 1500
   - **Enabled**: checked
   - Click **Save**

## Monitoring

### Watch the log in real-time

```bash
tail -f /var/log/truenas-postinit.log
```

Press Ctrl+C to stop following.

### View last 30 lines

```bash
tail -30 /var/log/truenas-postinit.log
```

### View the full log

```bash
cat /var/log/truenas-postinit.log
```

### Check if the script is currently running

```bash
ps aux | grep truenas-postinit
```

### Check current app states

```bash
midclt call app.query | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    print(a['name'], a['state'])
"
```

### Check Docker health

```bash
systemctl is-active docker.service
docker info
docker images | wc -l
```

### Check for image layer errors

```bash
cat /var/log/app_lifecycle.log
```

### View script progress in the TrueNAS UI

Go to the **Jobs** panel (top right corner). The init script appears as `initshutdownscript.execute_init_tasks` with a progress percentage.

## Manual Redeploy Commands

If the script completes but some apps are still stopped, you can redeploy them manually. Redeploy pulls fresh images and restarts the app.

### Redeploy a single app

```bash
midclt call app.redeploy <app-name>
```

### Redeploy multiple specific apps

```bash
for app in immich nextcloud home-assistant netdata; do
    echo "Redeploying $app..."
    midclt call app.redeploy "$app" > /dev/null 2>&1
    sleep 5
done
```

### Redeploy all stopped apps

```bash
for app in $(midclt call app.query | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    if a['state'] in ('STOPPED', 'CRASHED'):
        print(a['name'])
"); do
    echo "Redeploying $app..."
    midclt call app.redeploy "$app" > /dev/null 2>&1
    sleep 5
done
```

### Redeploy all apps (nuclear option)

Use this when images are missing or corrupted across the board:

```bash
for app in $(midclt call app.query | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    print(a['name'])
"); do
    echo "Redeploying $app..."
    midclt call app.redeploy "$app" > /dev/null 2>&1
    sleep 5
done
```

### Redeploy a single app with a corrupted image

If a specific app keeps failing due to a corrupted cached layer:

```bash
docker rmi <image-name>:<tag>
midclt call app.redeploy <app-name>
```

Example:

```bash
docker rmi ghcr.io/coder/code-server:4.108.2
midclt call app.redeploy code-server
```

### Monitor redeploy progress

After issuing redeploy commands, watch the apps come up:

```bash
watch -n 10 'midclt call app.query | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    print(a[\"name\"], a[\"state\"])
"'
```

Watch the Docker image count climb as images are pulled:

```bash
watch -n 10 'echo "Images: $(docker images -q | wc -l)"; echo "---"; docker images --format "{{.Repository}}:{{.Tag}}" | sort'
```

## Log Format

The log file is at `/var/log/truenas-postinit.log` and is automatically pruned to the last 7 days. Each entry is timestamped:

```
2026-02-11 10:22:42 Post-init script started (PID 8808)
2026-02-11 10:22:42 Phase 0: Waiting 180s for system and pools to settle...
2026-02-11 10:25:42 Phase 1: Waiting for network (up to 60s)...
2026-02-11 10:25:42 Network is up after 1s.
```

A successful run ends with:

```
All apps running successfully.
=========================================
Post-init script complete
=========================================
```

If some apps failed:

```
WARNING: Some apps not running: nextcloud code-server
=========================================
Post-init script complete
=========================================
```

## Troubleshooting

### Script ran but apps are still stopped

Check if images exist:

```bash
docker images | wc -l
```

If the count is low (under 5), images were wiped. Redeploy manually:

```bash
midclt call app.redeploy <app-name>
```

### Script appears stuck

Check which phase it's in:

```bash
tail -5 /var/log/truenas-postinit.log
```

If it's been on the same phase for more than 10 minutes, kill it and recover manually:

```bash
pkill -f truenas-postinit
systemctl kill middlewared
sleep 5
systemctl start middlewared
```

### Docker won't start (rate-limited by systemd)

```bash
systemctl reset-failed docker.service
systemctl start containerd.service
sleep 5
systemctl start docker.service
```

### Apps show "No Applications Installed"

App configs are stored separately from Docker data. Check they exist:

```bash
ls /mnt/.ix-apps/app_configs/
```

If the configs are there, restart middleware to rediscover them:

```bash
systemctl restart middlewared
```

### Corrupted layers keep reappearing

Clear the lifecycle log and redeploy the affected app:

```bash
> /var/log/app_lifecycle.log
docker rmi <image-name>
midclt call app.redeploy <app-name>
```

### Full manual recovery

If everything is broken, perform a clean recovery:

```bash
# Stop all apps
for app in $(midclt call app.query | python3 -c "import sys,json; [print(a['name']) for a in json.load(sys.stdin)]"); do
    midclt call app.stop "$app" > /dev/null 2>&1
done
sleep 10

# Stop Docker
systemctl stop docker.service
systemctl stop docker.socket
systemctl stop containerd.service
sleep 5

# Wipe and recreate Docker data
rm -rf /mnt/.ix-apps/docker
mkdir -p /mnt/.ix-apps/docker

# Clear error logs
> /var/log/app_lifecycle.log

# Start Docker fresh
systemctl reset-failed docker.service
systemctl start containerd.service
sleep 5
systemctl start docker.service
sleep 10

# Restart middleware
systemctl restart middlewared
sleep 30

# Redeploy all apps
for app in $(midclt call app.query | python3 -c "import sys,json; [print(a['name']) for a in json.load(sys.stdin)]"); do
    echo "Redeploying $app..."
    midclt call app.redeploy "$app" > /dev/null 2>&1
    sleep 5
done
```

## Safety Features

- **Exclusive lock**: Only one instance runs at a time. Concurrent attempts exit immediately.
- **Current-boot-only layer detection**: Stale errors from previous boots are cleared on startup and cannot trigger Docker wipes.
- **Non-blocking middleware restart**: Middleware is stopped in the background with a 30-second deadline. If it hangs, it's force-killed with SIGKILL before starting fresh. The script can never get stuck on a hung middleware process.
- **Rate-limit handling**: All Docker start/stop operations call `systemctl reset-failed` first to clear systemd rate-limit blocks.
- **Graceful app shutdown**: Apps are stopped before any Docker wipe to prevent data corruption.
- **Single wipe per boot**: The Docker wipe in Phase 5 can only trigger once, preventing destructive loops.
- **Smart deploy strategy**: Automatically detects whether images are present and chooses between `app.start` (fast) and `app.redeploy` (pulls images).

## File Locations

| File | Purpose |
|------|---------|
| `/mnt/main/app_storage/truenas-postinit.sh` | The script |
| `/var/log/truenas-postinit.log` | Script log (pruned to 7 days) |
| `/var/log/app_lifecycle.log` | TrueNAS app lifecycle errors |
| `/var/run/truenas-postinit.lock` | Lock file for single-instance enforcement |
| `/mnt/.ix-apps/docker` | Docker data directory (images, layers) |
| `/mnt/.ix-apps/app_configs/` | App configurations (survives Docker wipes) |

## License

MIT License. See [LICENSE](LICENSE) for details.


midclt call app.redeploy immich > /dev/null 2>&1
midclt call app.redeploy nextcloud > /dev/null 2>&1