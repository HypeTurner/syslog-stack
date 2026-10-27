#!/usr/bin/env bash
# Ежедневное обслуживание файлового архива syslog-ng:
#  1) сжимает *.log старше ARCHIVE_COMPRESS_AFTER_DAYS
#  2) удаляет *.log.gz старше ARCHIVE_RETENTION_DAYS
#  3) удаляет пустые каталоги
# Параметры читаются из .env в корне репозитория. Вызывается из /etc/cron.daily.
set -euo pipefail

REPO_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
if [ -f "$REPO_DIR/.env" ]; then set -a; . "$REPO_DIR/.env"; set +a; fi

ARCHIVE_DIR="${ARCHIVE_DIR:-/srv/syslog/archive}"
COMPRESS_DAYS="${ARCHIVE_COMPRESS_AFTER_DAYS:-2}"
RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-180}"

[ -d "$ARCHIVE_DIR" ] || exit 0

find "$ARCHIVE_DIR" -type f -name '*.log' -mtime +"$COMPRESS_DAYS" -exec gzip -9 -f {} +
find "$ARCHIVE_DIR" -type f -name '*.log.gz' -mtime +"$RETENTION_DAYS" -delete
find "$ARCHIVE_DIR" -mindepth 1 -type d -empty -delete

logger -t syslog-stack "archive maintenance done (compress>${COMPRESS_DAYS}d, delete>${RETENTION_DAYS}d)"
