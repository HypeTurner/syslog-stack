#!/usr/bin/env bash
# Отправляет тестовое сообщение по TCP и UDP. Использование: ./scripts/send-test.sh [IP_сервера]
set -euo pipefail
TARGET="${1:-127.0.0.1}"
MSG="syslog-stack test $(date -Is)"
logger -n "$TARGET" -P 514 -T -t syslog-stack-test "TCP: $MSG"
logger -n "$TARGET" -P 514 -d -t syslog-stack-test "UDP: $MSG"
echo "Отправлено на $TARGET:514. Проверь в Grafana -> Explore: {job=\"syslog\", app=\"syslog-stack-test\"}"
