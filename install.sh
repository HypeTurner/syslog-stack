#!/usr/bin/env bash
# Установка стека syslog-ng -> Alloy -> Loki -> Grafana.
# Запуск: sudo ./install.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
REPO_DIR="$PWD"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти от root: sudo ./install.sh"
command -v docker >/dev/null 2>&1 || die "Docker не найден"
docker compose version >/dev/null 2>&1 || die "Не найден плагин docker compose (v2)"

# --- .env ---
GENERATED_PW=""
if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  log "Создан .env из .env.example"
fi
if grep -q '^GRAFANA_ADMIN_PASSWORD=change_me$' .env; then
  GENERATED_PW="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
  sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${GENERATED_PW}|" .env
fi
set -a; . ./.env; set +a

# --- проверка занятых портов (только если стек ещё не запущен) ---
if [ -z "$(docker compose ps -q 2>/dev/null || true)" ]; then
  for spec in "tcp:514" "udp:514" "tcp:601" "tcp:${GRAFANA_PORT:-3000}"; do
    proto="${spec%%:*}"; port="${spec##*:}"
    flag="-ltn"; [ "$proto" = "udp" ] && flag="-lun"
    if ss -H $flag 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
      die "Порт ${port}/${proto} уже занят. Освободи его или поменяй GRAFANA_PORT в .env"
    fi
  done
fi

# --- каталог архива ---
mkdir -p "${ARCHIVE_DIR}"
chmod 750 "${ARCHIVE_DIR}"
log "Каталог архива: ${ARCHIVE_DIR}"

# --- буфер приёма UDP ---
WANT=33554432
CUR="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
if [ "$CUR" -lt "$WANT" ]; then
  echo "net.core.rmem_max = ${WANT}" > /etc/sysctl.d/99-syslog-stack.conf
  sysctl -q -p /etc/sysctl.d/99-syslog-stack.conf || warn "Не удалось применить sysctl"
  log "net.core.rmem_max увеличен до ${WANT}"
fi

# --- ежедневная чистка архива ---
chmod +x scripts/*.sh
cat > /etc/cron.daily/syslog-stack-archive <<CRON
#!/bin/sh
exec "${REPO_DIR}/scripts/archive-maintenance.sh"
CRON
chmod 755 /etc/cron.daily/syslog-stack-archive
log "Установлено задание /etc/cron.daily/syslog-stack-archive"

# --- запуск ---
log "Загрузка образов и запуск..."
docker compose pull
docker compose up -d
sleep 5
docker compose ps

echo
log "Готово."
echo "  Grafana : http://$(hostname -I | awk '{print $1}'):${GRAFANA_PORT:-3000}   (логин: admin)"
if [ -n "$GENERATED_PW" ]; then
  echo "  Пароль  : ${GENERATED_PW}   (сохранён в ${REPO_DIR}/.env)"
else
  echo "  Пароль  : см. GRAFANA_ADMIN_PASSWORD в ${REPO_DIR}/.env"
fi
echo "  Приём   : 514 udp/tcp, 601 tcp (RFC5424)"
echo "  Тест    : ./scripts/send-test.sh 127.0.0.1"
warn "Ограничь доступ к 514/601 по IP источников (см. README, раздел «Безопасность»)."
