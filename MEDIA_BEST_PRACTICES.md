# Media Stack Best Practices — Manual Steps

This document covers manual configuration steps that are not yet automated via Ansible or GitOps.
These should be completed after the media stack is deployed and the `media-config` Ansible role has run.

> **Note:** Jellyfin initial setup (wizard, libraries, API key) and Seerr initialization
> (Jellyfin/Radarr/Sonarr connections) are now automated by the `media-config` role.

## 1. Add Indexers to Prowlarr

Prowlarr manages indexers centrally and syncs them to Radarr, Sonarr, Lidarr, and Readarr.

- Open https://prowlarr.ruddenchaux.xyz
- Go to **Indexers > Add Indexer**
- Add your tracker accounts (requires personal credentials for each tracker)
- Prowlarr will auto-sync indexers to all connected *arr apps

## 2. Configure FlareSolverr in Prowlarr

FlareSolverr is deployed as an internal service for bypassing Cloudflare-protected indexer sites.

- Open https://prowlarr.ruddenchaux.xyz
- Go to **Settings > Indexers**
- Add a new **Tag** (e.g., `flaresolverr`)
- Add a new **Indexer Proxy**: type **FlareSolverr**
  - Host: `http://flaresolverr.media.svc.cluster.local:8191`
  - Tag: `flaresolverr`
- Apply the `flaresolverr` tag to any indexer that requires Cloudflare bypass

## 3. Configure Subtitle Providers in Bazarr

Bazarr needs at least one subtitle provider account to download subtitles.

- Open https://bazarr.ruddenchaux.xyz
- Go to **Settings > Providers**
- Add providers (e.g., OpenSubtitles.com, Subscene, Addic7ed)
- Each provider requires its own account credentials
- Go to **Settings > Languages** and configure desired subtitle languages

## 4. Configure Health Notifications

Set up notifications for download failures, disk space warnings, and health check alerts.

For each *arr app (Radarr, Sonarr, Prowlarr, Lidarr, Readarr):
- Go to **Settings > Connect**
- Add a notification connection (Discord webhook, email, Gotify, etc.)
- Enable notifications for: Health Issues, Download Failures, Import Failures

Example Discord webhook setup:
- Create a webhook in your Discord server
- Add the webhook URL in each *arr app's notification settings

## 5. Config PVC Backup Strategy

Config PVCs contain application databases and settings. Losing them means reconfiguring everything.

Options:
- **Velero**: Full cluster backup including PVCs. Install via Helm, configure S3-compatible backend
- **CronJob + restic**: Lightweight backup of specific PVC paths to remote storage
- **Manual snapshots**: `kubectl exec` into pods and backup SQLite databases

Recommended approach for this single-node setup:
1. Create a CronJob that mounts config PVCs read-only
2. Use `restic` or `rclone` to push backups to cloud storage (e.g., Backblaze B2, Wasabi)
3. Schedule daily backups with 7-day retention

## 6. Readarr Retirement Note

Readarr development has stalled significantly. The project has had minimal updates and the `develop` branch is the only release channel.

Plan accordingly:
- Keep using the current pinned version (`amd64-0.4.18-develop`)
- Monitor the project for activity: https://github.com/Readarr/Readarr
- Consider alternatives if the project is officially abandoned
- Do not invest heavily in Readarr-specific automation

## 7. Recyclarr Verification

After deployment, verify Recyclarr is working:

```bash
# Check CronJob exists
kubectl get cronjob -n media

# Trigger a manual run
kubectl create job recyclarr-manual --from=cronjob/recyclarr -n media

# Check logs
kubectl logs job/recyclarr-manual -n media

# Verify quality profiles were applied
# Radarr: Settings > Quality Profiles — should see "HD Bluray + WEB" profile
# Sonarr: Settings > Quality Profiles — should see "WEB-1080p" profile
```
