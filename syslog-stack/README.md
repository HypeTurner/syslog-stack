# syslog-stack

Централизованный сбор логов: **syslog-ng → Grafana Alloy → Loki → Grafana**.

Подходит для bare-metal серверов, виртуалок, гипервизоров и сетевого оборудования.
Всё запускается в Docker Compose, ставится двумя командами.

> Вместо Promtail используется **Grafana Alloy**: Promtail достиг EOL, Alloy — его прямой преемник.

## Быстрая установка

Требования: Linux, Docker Engine + плагин Docker Compose v2, root.

```bash
git clone <URL_ЭТОГО_РЕПОЗИТОРИЯ> /opt/syslog-stack
cd /opt/syslog-stack && sudo ./install.sh
```

Скрипт сам:
- создаст `.env` и сгенерирует пароль Grafana (выведет в конце и сохранит в `.env`);
- проверит, что порты 514, 601 и порт Grafana свободны;
- создаст каталог архива и увеличит `net.core.rmem_max` (буфер UDP);
- поставит ежедневную чистку архива в `/etc/cron.daily/syslog-stack-archive`;
- скачает образы и запустит стек.

Перед установкой можно отредактировать `.env.example` (порт Grafana, сроки хранения, каталог архива).
Если `.env` уже есть, скрипт его не перезаписывает.

## Схема

```
Сетевое оборудование ─┐
Серверы (rsyslog) ────┼─► syslog-ng ─┬─► файловый архив /srv/syslog/archive/<host>/<дата>.log
Виртуалки/гипервизоры ┘  514 udp/tcp │
                         601 tcp     └─► Alloy :1514 (RFC5424/TCP, дисковый буфер 2 ГБ) ─► Loki ─► Grafana
```

| Компонент | Порт (хост) | Назначение |
|---|---|---|
| syslog-ng | 514/udp, 514/tcp, 601/tcp | приём логов, буфер, файловый архив |
| Alloy | 127.0.0.1:12345 | UI для отладки (наружу не публикуется) |
| Loki | внутри сети Docker | хранение и поиск |
| Grafana | `GRAFANA_PORT` (по умолчанию 3000) | интерфейс, логин `admin` |

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

**Сетевое оборудование, ESXi, Proxmox и т.п.** — в настройках укажи syslog-сервер `IP:514` (UDP или TCP).
На устройствах включи NTP и единый часовой пояс (лучше UTC), иначе события будет трудно сопоставлять.

**Windows** — NXLog или аналог с отправкой на `IP:514`/`601`.

## Хранение и очистка

| Что | Где настраивается | По умолчанию |
|---|---|---|
| Поиск в Grafana (Loki) | `LOKI_RETENTION` | 744h (31 день) |
| Сжатие файлового архива | `ARCHIVE_COMPRESS_AFTER_DAYS` | 2 дня |
| Удаление файлового архива | `ARCHIVE_RETENTION_DAYS` | 180 дней |
| Дисковый буфер syslog-ng | `syslog-ng/syslog-ng.conf` (`disk-buf-size`) | 2 ГБ |

Архив ротируется по дням самим syslog-ng (имя файла содержит дату), а `scripts/archive-maintenance.sh`
раз в сутки сжимает и удаляет старые файлы. После изменения `LOKI_RETENTION` выполни `docker compose up -d`.

**Каталог архива и данные Loki лучше держать на отдельном диске/разделе.**
Данные Loki лежат в Docker volume `syslog-stack_loki-data`; чтобы вынести на другой диск, замени volume на bind-mount в `docker-compose.yml`.

## Установка на хост, где уже работает Zabbix

Совместима, но учти:
- Если на хосте уже есть Grafana, этот стек использует свой контейнер `grafana-logs` на порту `GRAFANA_PORT` (поменяй, если занят). Можно после установки удалить сервис `grafana` из compose и подключить Loki (`http://loki:3100`) как источник в существующую Grafana, при условии, что она в одной Docker-сети с Loki.
- Loki постоянно пишет на диск. Не клади его данные и архив на тот же раздел, что БД Zabbix.
- Лимиты памяти заданы переменными `LOKI_MEM_LIMIT` и `GRAFANA_MEM_LIMIT`.
- Добавь в Zabbix проверку свободного места на разделе с архивом и данными Loki.
- Падение хоста означает потерю и мониторинга, и логов для разбора. Для серьёзной инфраструктуры лучше отдельная ВМ.
- Порты Zabbix (80/443/10051) с этим стеком не пересекаются. `install.sh` прервётся, если 514/601 заняты (например, другим syslog).

## Безопасность

Docker обходит правила `ufw`/`firewalld` для published-портов, поэтому ограничивай источники через цепочку `DOCKER-USER`:

```bash
# разрешить только свою сеть, остальное на 514/601 отбросить
iptables -I DOCKER-USER -p udp --dport 514 ! -s 10.0.0.0/8 -j DROP
iptables -I DOCKER-USER -p tcp --dport 514 ! -s 10.0.0.0/8 -j DROP
iptables -I DOCKER-USER -p tcp --dport 601 ! -s 10.0.0.0/8 -j DROP
```

(замени `10.0.0.0/8` на свою сеть и сохрани правила штатным для дистрибутива способом).
Plain syslog не шифруется. Для критичных сегментов настрой TLS в syslog-ng (порт 6514).
Доступ к Grafana лучше закрыть за reverse proxy с HTTPS.

## Обслуживание

```bash
docker compose ps                 # состояние
docker compose logs -f syslog-ng  # логи компонента (также alloy, loki, grafana)
docker compose pull && docker compose up -d   # обновление (после правки версий в .env)
docker compose down               # остановить (данные сохраняются)
docker compose down -v            # остановить и УДАЛИТЬ данные Loki/Grafana
```

## Замечания по эксплуатации

- **Метки в Loki.** Используются только `host`, `app`, `severity`, `facility`. Не выноси в метки IP, пользователей, ID сессий: это взорвёт кардинальность и замедлит Loki.
- **Парсинг логов сетевого оборудования** (Cisco, MikroTik, FortiGate и др.) в стек не включён: формат у каждого вендора свой. Парсить удобно в Alloy (`loki.process`) или в syslog-ng.
- **Источник IP в Docker.** Если все устройства без hostname в заголовке отображаются с одним адресом (шлюз Docker), запусти syslog-ng с `network_mode: host`, а в `syslog-ng.conf` замени `alloy` на `127.0.0.1` и опубликуй Alloy как `127.0.0.1:1514:1514`.
- **Версии образов** заданы в `.env`. Перед боевым использованием убедись, что теги существуют, и зафиксируй актуальные.
- **Старые рабочие логи на самом сервере** (journald, /var/log) этим стеком не собираются: они уходят через rsyslog. Для файлов приложений можно поставить Alloy на сам хост.

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
