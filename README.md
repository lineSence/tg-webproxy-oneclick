# tg-webproxy-oneclick

Разворачивает [Telegram WEB proxy](https://github.com/telegramdesktop/tproxy-server) одной командой.

WEB proxy — экспериментальный тип прокси от разработчиков Telegram Desktop. Клиент шифрует трафик как для обычного MTProxy и отправляет его через WebView по HTTPS или WebSocket на порт 443. Снаружи сервер выглядит как обычный сайт.

## Быстрый старт

1. Возьмите VPS: x86_64, Debian 12+ или Ubuntu 22.04+, не меньше 1 ГБ RAM, публичный IPv4.
2. Создайте у DNS-провайдера A-запись `proxy.example.com → IP сервера` (без CDN).
3. Откройте входящие TCP 80 и 443 в файрволе хостинга. Порты 2398, 8080, 8081 и 8888 открывать **не нужно**.
4. На сервере выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/lineSence/tg-webproxy-oneclick/main/install.sh \
  | sudo bash -s -- --domain proxy.example.com --email you@example.com
```

Через 5–15 минут скрипт выведет адрес сервера, секрет, ссылку `https://t.me/webproxy?...` и QR-код. Эти данные также сохраняются в `/root/tg-webproxy.txt`.

## Что делает скрипт

1. Проверяет архитектуру, ОС, systemd и объём памяти.
2. Проверяет, что домен указывает на этот сервер и порты 80/443 свободны.
3. Генерирует 128-битный секрет. При повторном запуске берёт существующий, чтобы старые ссылки продолжили работать.
4. Скачивает официальный `tproxy-server` на проверенном коммите (можно выбрать другой через `--ref`).
5. **Собирает уникальный сайт-прикрытие.** Тематика, название, палитра, шрифт, вёрстка и тексты выбираются случайно. Upstream намеренно не содержит готовый сайт, потому что одинаковый сайт у многих серверов стал бы сигнатурой для блокировки.
6. Запускает официальный `deploy/install.sh`: Caddy с Let's Encrypt, MTProxy, relay, nftables и systemd-сервисы. Секрет передаётся через stdin, поэтому не виден в списке процессов.
7. Выводит ссылку и QR-код, затем проверяет состояние сервисов.

## Команды

```bash
sudo bash install.sh status      # сервисы, readyz, разрывы Middle-End
sudo bash install.sh link        # показать ссылку и QR снова
sudo bash install.sh update      # обновить relay из upstream
sudo bash install.sh uninstall   # удалить всё
```

Если вы запускали через `curl | bash`, замените `install.sh` на
`<(curl -fsSL https://raw.githubusercontent.com/lineSence/tg-webproxy-oneclick/main/install.sh)`, например: `sudo bash <(curl -fsSL https://raw.githubusercontent.com/lineSence/tg-webproxy-oneclick/main/install.sh) status`.

## Опции

| Опция | Описание |
|---|---|
| `--domain HOST` | домен прокси (обязательно) |
| `--email EMAIL` | e-mail для Let's Encrypt, по умолчанию `admin@HOST` |
| `--secret HEX` | свой секрет из 32 hex-символов |
| `--base-path SLUG\|none` | путь транспорта; по умолчанию случайный |
| `--site-dir DIR` | свой статический сайт вместо сгенерированного |
| `--site-upstream URL` | свой сайт-приложение на loopback, например `http://127.0.0.1:3000` |
| `--ref REF` | ветка, тег или коммит `tproxy-server` |
| `--workers N`, `--max-connections N` | параметры MTProxy |
| `--skip-dns-check`, `--force`, `-y` | пропустить проверку DNS, игнорировать занятые порты, не задавать вопросов |

## Развёртывание при создании VPS (cloud-init)

```yaml
#cloud-config
runcmd:
  - curl -fsSL https://raw.githubusercontent.com/lineSence/tg-webproxy-oneclick/main/install.sh | bash -s -- --domain proxy.example.com --email you@example.com -y
```

Ссылку потом можно взять в `/root/tg-webproxy.txt`. Условие: A-запись должна появиться до первой загрузки сервера.

## Клиенты

Тип прокси WEB поддерживают только новые клиенты. Сейчас это Telegram Desktop; клиент для Android экспериментальный, для iOS пока только план. Статус клиентов смотрите в [upstream](https://github.com/telegramdesktop/tproxy-server#6-configure-a-telegram-client).

## Решение проблем

- **Прокси подключается, но сообщения не идут.** Выполните `status`. Если разрывов Middle-End много, сервер находится за NAT: пропишите `MTPROXY_NAT_ARGS=--nat-info LOCAL_IP:PUBLIC_IP` в `/etc/mtproxy/mtproxy.env` и выполните `systemctl restart mtproxy`.
- **Не выдаётся сертификат.** Проверьте A-запись и доступность порта 80 извне, затем посмотрите `journalctl -u caddy`.
- Полный лог установки: `/var/log/tg-webproxy-install.log`.

## Лицензия

MIT для этого скрипта. `tproxy-server`, MTProxy и Caddy распространяются под своими лицензиями.
