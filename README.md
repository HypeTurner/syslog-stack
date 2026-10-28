# syslog-stack

Централизованный сбор логов: **syslog-ng → Grafana Alloy → Loki → Grafana**.

Подходит для bare-metal серверов, виртуалок, гипервизоров и сетевого оборудования.
Всё запускается в Docker Compose, ставится двумя командами.

## Быстрая установка

Требования: Linux, Docker Engine + плагин Docker Compose v2, root.

```bash
git clone "https://github.com/HypeTurner/syslog-stack" /opt/syslog-stack
cd /opt/syslog-stack && sudo bash install.sh
```

## Схема

```
Сетевое оборудование ─┐
Серверы (rsyslog) ────┼─► syslog-ng ─┬─► файловый архив /srv/syslog/archive/<host>/<дата>.log
Виртуалки/гипервизоры ┘  514 udp/tcp │
                         601 tcp     └─► Alloy :1514 (RFC5424/TCP, дисковый буфер 2 ГБ) ─► Loki ─► Grafana
```

|Компонент|Порт (хост)|Назначение|
|-|-|-|
|syslog-ng|514/udp, 514/tcp, 601/tcp|приём логов, буфер, файловый архив|
|Alloy|127.0.0.1:12345|UI для отладки (наружу не публикуется)|
|Loki|внутри сети Docker|хранение и поиск|
|Grafana|`GRAFANA_PORT` (по умолчанию 3000)|интерфейс, логин `admin`|

## Проверка

```bash
./scripts/send-test.sh 127.0.0.1
```

В Grafana → Explore → источник Loki → запрос `{job="syslog", app="syslog-stack-test"}`.

## Подключение источников

**Linux (rsyslog)** — файл `/etc/rsyslog.d/90-forward.conf`:

```
*.* action(type="omfwd" target="IP_СЕРВЕРА_ЛОГОВ" port="514" protocol="tcp"
           queue.type="LinkedList" queue.filename="fwd" queue.maxdiskspace="1g"
           queue.saveonshutdown="on" action.resumeRetryCount="-1")
```

затем `systemctl restart rsyslog`.

**Сетевое оборудование, ESXi, Proxmox и т.п.** — в настройках указать syslog-сервер `IP:514` (UDP или TCP).
На устройствах включить NTP и единый часовой пояс (лучше UTC), иначе события будет трудно сопоставлять.

**Windows** — NXLog или аналог с отправкой на `IP:514`/`601`.

## Хранение и очистка

|Что|Где настраивается|По умолчанию|
|-|-|-|
|Поиск в Grafana (Loki)|`LOKI_RETENTION`|744h (31 день)|
|Сжатие файлового архива|`ARCHIVE_COMPRESS_AFTER_DAYS`|2 дня|
|Удаление файлового архива|`ARCHIVE_RETENTION_DAYS`|180 дней|
|Дисковый буфер syslog-ng|`syslog-ng/syslog-ng.conf` (`disk-buf-size`)|2 ГБ|

Архив ротируется по дням самим syslog-ng (имя файла содержит дату), а `scripts/archive-maintenance.sh`
раз в сутки сжимает и удаляет старые файлы. После изменения `LOKI_RETENTION` выполни `docker compose up -d`.

**Каталог архива и данные Loki лучше держать на отдельном диске/разделе.**
Данные Loki лежат в Docker volume `syslog-stack_loki-data`; чтобы вынести на другой диск - необходимо заменить volume на bind-mount в `docker-compose.yml`.

## Обслуживание

```bash
docker compose ps                 # состояние
docker compose logs -f syslog-ng  # логи компонента (также alloy, loki, grafana)
docker compose pull && docker compose up -d   # обновление (после правки версий в .env)
docker compose down               # остановить (данные сохраняются)
docker compose down -v            # остановить и УДАЛИТЬ данные Loki/Grafana
```

## Структура репозитория

```
install.sh                      установка одной командой
docker-compose.yml              стек
.env.example                    настройки (копируется в .env)
syslog-ng/syslog-ng.conf        приём, архив, отправка в Alloy
alloy/config.alloy              syslog-приёмник и relabel меток
loki/loki.yaml                  хранилище и retention
grafana/provisioning/...        автоподключение Loki в Grafana
scripts/archive-maintenance.sh  сжатие/удаление архива (cron.daily)
scripts/send-test.sh            тестовая отправка
```

