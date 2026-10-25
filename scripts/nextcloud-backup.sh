#!/usr/bin/env bash
# Nightly Nextcloud backup to a Hetzner Storage Box with restic.
# Install: sudo install -m 700 scripts/nextcloud-backup.sh /usr/local/sbin/
set -euo pipefail
STACK=/home/nextcloud/nextcloud-proxmox   # runs as root, so no ~
STAGE=/var/backups/nextcloud
cd "$STACK"
set -a; . ./.env; . /root/.restic.env; set +a
mkdir -p "$STAGE" && chmod 700 "$STAGE"

occ() { docker compose exec -T -u www-data nextcloud php occ "$@"; }
trap 'occ maintenance:mode --off >/dev/null' EXIT

# 1. Consistent database dump (Nextcloud paused for a minute or two)
occ maintenance:mode --on
docker compose exec -T db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$STAGE/db.dump"
occ maintenance:mode --off

# 2. Ship everything to the Storage Box
HTML=/var/lib/docker/volumes/${COMPOSE_PROJECT_NAME}_nextcloud_html/_data
restic backup --tag nextcloud \
  "$STAGE" "$NEXTCLOUD_DATA_PATH" "$STACK" \
  "$HTML/config" "$HTML/custom_apps" "$HTML/themes" \
  --exclude "$NEXTCLOUD_DATA_PATH/*/cache" \
  --exclude "$NEXTCLOUD_DATA_PATH/appdata_*/preview"

# 3. Retention: 7 daily, 4 weekly, 6 monthly
restic forget --tag nextcloud --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# 4. Weekly integrity check (Sundays)
if [ "$(date +%u)" = 7 ]; then restic check --read-data-subset=5%; fi
