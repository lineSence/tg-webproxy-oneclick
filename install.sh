#!/usr/bin/env bash
# tg-webproxy-oneclick — развёртывание Telegram WEB proxy (tproxy-server) одной командой.
#
#   curl -fsSL https://raw.githubusercontent.com/lineSence/tg-webproxy-oneclick/main/install.sh \
#     | sudo bash -s -- --domain proxy.example.com --email you@example.com
#
# Обёртка над официальным telegramdesktop/tproxy-server: проверяет сервер и DNS,
# генерирует секрет и уникальный сайт-прикрытие, запускает upstream-установщик
# и выводит готовую ссылку t.me/webproxy (+ QR-код).
set -euo pipefail
umask 077

VERSION=0.2.0
UPSTREAM_REPO="${TWP_UPSTREAM_REPO:-https://github.com/telegramdesktop/tproxy-server}"
# Проверенный коммит upstream. Переопределяется --ref (ветка, тег или коммит).
UPSTREAM_REF_DEFAULT=c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8
SRC_DIR=/opt/tproxy-server-src
SITE_ROOT=/srv/tproxy-site
STATE_FILE=/root/tg-webproxy.txt
LOG_FILE=/var/log/tg-webproxy-install.log
UNITS=(caddy.service tproxy-server.service mtproxy.service tproxy-firewall.service
	refresh-mtproxy-config.timer refresh-mtproxy-config.service)

command=install
domain=
email=
secret=
base_path=
site_dir=
site_upstream=
ref="$UPSTREAM_REF_DEFAULT"
workers=1
max_connections=4096
skip_dns_check=
force=
assume_yes=
acme_forwards=()
FORWARDS_FILE=/etc/tg-webproxy/acme-forwards

c_red=; c_green=; c_yellow=; c_bold=; c_reset=
if [[ -t 1 ]]; then
	c_red=$'\e[31m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_bold=$'\e[1m'; c_reset=$'\e[0m'
fi
info() { printf '%s==>%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die() { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

usage() {
	cat <<USAGE
tg-webproxy-oneclick $VERSION — Telegram WEB proxy одной командой

Использование:
  install.sh [install] --domain HOST [--email EMAIL] [опции]
  install.sh status | link | update | uninstall

Опции install:
  --domain HOST          домен, A-запись которого указывает на этот сервер (обязательно)
  --email EMAIL          e-mail для Let's Encrypt (по умолчанию admin@HOST)
  --secret HEX           32 hex-символа; по умолчанию генерируется (или берётся существующий)
  --base-path SLUG|none  путь транспорта; по умолчанию случайный (рекомендуется)
  --site-dir DIR         свой статический сайт-прикрытие вместо сгенерированного
  --site-upstream URL    свой сайт-приложение, напр. http://127.0.0.1:3000
  --ref REF              ветка/тег/коммит tproxy-server (по умолчанию ${UPSTREAM_REF_DEFAULT:0:12})
  --workers N            воркеры MTProxy (по умолчанию 1)
  --max-connections N    соединений на воркер (по умолчанию 4096)
  --acme-forward HOST=PORT  пересылать ACME HTTP-01 для другого домена на этом
                         сервере (напр. Hysteria с acme.http.altPort) на 127.0.0.1:PORT;
                         можно указывать несколько раз
  --skip-dns-check       не проверять, что домен указывает на этот сервер
  --force                продолжить, даже если порты 80/443 заняты другим ПО
  -y, --yes              не задавать вопросов
USAGE
}

parse_args() {
	if [[ $# -gt 0 && "$1" != -* ]]; then
		command="$1"; shift
	fi
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--domain|--hostname) domain="${2:-}"; shift 2 ;;
			--email) email="${2:-}"; shift 2 ;;
			--secret) secret="${2:-}"; shift 2 ;;
			--base-path) base_path="${2:-}"; shift 2 ;;
			--site-dir) site_dir="${2:-}"; shift 2 ;;
			--site-upstream) site_upstream="${2:-}"; shift 2 ;;
			--ref) ref="${2:-}"; shift 2 ;;
			--workers) workers="${2:-}"; shift 2 ;;
			--max-connections) max_connections="${2:-}"; shift 2 ;;
			--acme-forward) acme_forwards+=("${2:-}"); shift 2 ;;
			--skip-dns-check) skip_dns_check=1; shift ;;
			--force) force=1; shift ;;
			-y|--yes) assume_yes=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) usage >&2; die "неизвестный аргумент: $1" ;;
		esac
	done
}

# Вопросы читаем из /dev/tty: при `curl | bash` stdin занят самим скриптом.
ask() {
	local prompt="$1" answer=
	[[ -n "$assume_yes" ]] && return 1
	[[ -r /dev/tty ]] || return 1
	read -r -p "$prompt" answer </dev/tty || return 1
	printf '%s' "$answer"
}

confirm() {
	[[ -n "$assume_yes" ]] && return 0
	local answer
	answer="$(ask "$1 [y/N] ")" || return 1
	[[ "$answer" =~ ^[YyДд] ]]
}

require_root() { [[ "${EUID}" -eq 0 ]] || die "запустите от root: curl ... | sudo bash -s -- ..."; }

preflight() {
	info "Проверка сервера"
	[[ "$(uname -m)" == x86_64 ]] || die "нужен x86_64-сервер (официальный MTProxy собирается только под него)"
	command -v systemctl >/dev/null || die "нужен systemd"
	[[ -r /etc/os-release ]] || die "не удалось определить ОС"
	# shellcheck disable=SC1091
	. /etc/os-release
	local major="${VERSION_ID%%.*}"
	case "${ID:-}" in
		debian) [[ "$major" -ge 12 ]] || die "нужен Debian 12+, найден $PRETTY_NAME" ;;
		ubuntu) [[ "$major" -ge 22 ]] || die "нужна Ubuntu 22.04+, найдена $PRETTY_NAME" ;;
		*) die "поддерживаются только Debian 12+ и Ubuntu 22.04+, найдена ${PRETTY_NAME:-неизвестная ОС}" ;;
	esac
	local mem_mb
	mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
	[[ "$mem_mb" -ge 700 ]] || warn "мало памяти (${mem_mb} МБ): сборка Go/MTProxy может упасть, добавьте swap"
}

validate_args() {
	if [[ -z "$domain" ]]; then
		domain="$(ask "Домен прокси (A-запись на этот сервер), напр. proxy.example.com: ")" ||
			die "укажите --domain"
	fi
	domain="${domain,,}"
	domain="${domain#https://}"; domain="${domain%%/*}"
	if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ || "$domain" != *.* ]]; then
		die "некорректный домен: $domain (IDN вводите в виде xn--...)"
	fi
	[[ -n "$email" ]] || email="admin@$domain"
	[[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "некорректный e-mail: $email"
	[[ "$workers" =~ ^[1-9][0-9]*$ ]] || die "--workers должно быть положительным числом"
	[[ "$max_connections" =~ ^[1-9][0-9]*$ ]] || die "--max-connections должно быть положительным числом"
	[[ -z "$site_dir" || -z "$site_upstream" ]] || die "--site-dir и --site-upstream взаимоисключающие"
	local fwd
	for fwd in "${acme_forwards[@]}"; do
		[[ "$fwd" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?=[1-9][0-9]{0,4}$ ]] ||
			die "--acme-forward ожидает HOST=PORT, получено: $fwd"
		[[ "${fwd%%=*}" != "$domain" ]] || die "--acme-forward не может указывать на сам домен прокси"
		case "${fwd#*=}" in 2398|8080|8081|8888) die "порт ${fwd#*=} занят компонентами прокси, выберите другой" ;; esac
	done
	if [[ -n "$site_dir" ]]; then
		[[ -f "$site_dir/index.html" ]] || die "в $site_dir нет index.html"
		site_dir="$(cd "$site_dir" && pwd -P)"
	fi
}

install_prereqs() {
	info "Установка базовых пакетов"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends ca-certificates curl git openssl iproute2 coreutils >/dev/null
	apt-get install -y -qq --no-install-recommends qrencode >/dev/null 2>&1 || true
}

public_ipv4() {
	local probe ip
	for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
		ip="$(curl -4 -fsS --max-time 10 "$probe" 2>/dev/null | tr -d '[:space:]')" || continue
		[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
	done
	return 1
}

check_dns() {
	[[ -n "$skip_dns_check" ]] && { warn "проверка DNS пропущена"; return; }
	info "Проверка DNS для $domain"
	local ip resolved
	ip="$(public_ipv4)" || { warn "не удалось узнать публичный IP, проверка DNS пропущена"; return; }
	resolved="$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u | tr '\n' ' ')"
	[[ -n "$resolved" ]] || die "домен $domain не резолвится. Добавьте A-запись: $domain -> $ip"
	if [[ " $resolved " != *" $ip "* ]]; then
		die "$domain указывает на ${resolved% } вместо $ip. Исправьте A-запись (без CDN/прокси) или используйте --skip-dns-check"
	fi
	info "DNS в порядке: $domain -> $ip"
}

check_ports() {
	local port owners
	for port in 80 443; do
		owners="$(ss -Hltnp "sport = :$port" 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | tr '\n' ' ')"
		[[ -z "$owners" || "$owners" == "caddy " ]] && continue
		if [[ "$owners" == *hysteria* ]]; then
			hysteria_hint "$port"
			[[ -n "$force" ]] || die "порт $port занят Hysteria"
		fi
		if [[ -n "$force" ]]; then
			warn "порт $port занят: $owners(--force, продолжаем)"
		else
			die "порт $port занят: $owners. Освободите его или используйте --force (Caddy заменит конфигурацию)"
		fi
	done
	if [[ -e /etc/caddy/Caddyfile && ! -f /etc/tproxy-server/config.json ]]; then
		warn "существующий /etc/caddy/Caddyfile будет сохранён в резервную копию и заменён"
		confirm "Продолжить?" || die "отменено"
	fi
}

hysteria_hint() {
	cat >&2 <<HINT
${c_yellow}[!]${c_reset} TCP-порт $1 занят Hysteria. Порты общие для всего сервера, поддомен не помогает.
    Hysteria (QUIC) использует UDP 443 и с Caddy (TCP 80/443) не конфликтует — нужно
    только убрать её TCP-слушатели:

    1) В config.yaml Hysteria перенесите ACME HTTP-01 на локальный порт:
         acme:
           listenHost: 127.0.0.1
           type: http
           http:
             altPort: 8880
    2) Уберите masquerade.listenHTTP / listenHTTPS (TCP 80/443), если они есть.
    3) systemctl restart hysteria-server   # имя сервиса может отличаться
    4) Запустите установку с пересылкой ACME для домена Hysteria:
         ... --acme-forward ИМЯ.ДОМЕНА.HYSTERIA=8880
       Caddy будет принимать проверки Let's Encrypt на :80 и отдавать их Hysteria,
       так что её сертификат продолжит продлеваться.
HINT
}

apply_acme_forwards() {
	if [[ ${#acme_forwards[@]} -eq 0 && -f "$FORWARDS_FILE" ]]; then
		mapfile -t acme_forwards <"$FORWARDS_FILE"
	fi
	[[ ${#acme_forwards[@]} -gt 0 ]] || return 0
	local fwd host port
	install -d -m 0755 /etc/tg-webproxy
	printf '%s\n' "${acme_forwards[@]}" >"$FORWARDS_FILE"
	{
		echo
		echo "# tg-webproxy-oneclick: ACME HTTP-01 для других сервисов на этом сервере"
		for fwd in "${acme_forwards[@]}"; do
			host="${fwd%%=*}"; port="${fwd#*=}"
			cat <<CADDY
http://$host {
	handle /.well-known/acme-challenge/* {
		reverse_proxy 127.0.0.1:$port
	}
	handle {
		respond 404
	}
}
CADDY
		done
	} >>/etc/caddy/Caddyfile
	TPROXY_HOSTNAME="$domain" TPROXY_SITE_ROOT="$SITE_ROOT" ACME_EMAIL="$email" \
		/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
	systemctl restart caddy.service
	for fwd in "${acme_forwards[@]}"; do
		info "ACME HTTP-01 для ${fwd%%=*} -> 127.0.0.1:${fwd#*=}"
	done
}

resolve_secret() {
	if [[ -z "$secret" && -f /etc/tproxy-server/profiles.json ]]; then
		secret="$(sed -n 's/.*"secret":"\([0-9a-f]\{32,34\}\)".*/\1/p' /etc/tproxy-server/profiles.json | head -n1)"
		[[ -n "$secret" ]] && info "Используется существующий секрет (ссылки останутся рабочими)"
	fi
	[[ -n "$secret" ]] || secret="$(openssl rand -hex 16)"
	secret="${secret,,}"
	[[ "$secret" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] || die "секрет должен состоять из 32 hex-символов"
}

fetch_upstream() {
	info "Загрузка tproxy-server ($ref)"
	if [[ ! -d "$SRC_DIR/.git" ]]; then
		rm -rf "$SRC_DIR"
		git clone -q "$UPSTREAM_REPO" "$SRC_DIR"
	fi
	git -C "$SRC_DIR" fetch -q --tags origin
	git -C "$SRC_DIR" checkout -q --force "$ref" 2>/dev/null ||
		git -C "$SRC_DIR" checkout -q --force "origin/$ref" ||
		die "не удалось переключиться на $ref"
	info "Коммит upstream: $(git -C "$SRC_DIR" rev-parse --short HEAD)"
}

# ---------- генератор сайта-прикрытия ----------
# Upstream намеренно не содержит шаблон сайта: одинаковый сайт у многих операторов
# стал бы сигнатурой. Поэтому каждый запуск собирает уникальный сайт из случайных
# частей: тематика, название, палитра, шрифт, структура и тексты.

rand() { echo $(( $(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % $1 )); }
pick() { local -a a=("$@"); printf '%s' "${a[$(rand ${#a[@]})]}"; }

generate_site() {
	local out="$1"
	local -a themes=(photo coffee design garden bikes books)
	local theme; theme="$(pick "${themes[@]}")"
	local name tagline service1 service2 service3 about
	case "$theme" in
		photo)
			name="$(pick "Светотень" "Кадр" "Экспозиция" "Северный свет" "Плёнка") $(pick "Студия" "Фотостудия" "Мастерская")"
			tagline="$(pick "Портреты и репортажи" "Семейная и предметная съёмка" "Фотография с характером")"
			service1="Портретная съёмка"; service2="Предметная съёмка"; service3="Ретушь и печать"
			about="Мы снимаем людей, вещи и события с $(pick 2011 2014 2016 2018). Работаем в студии и на выезде." ;;
		coffee)
			name="$(pick "Зерно" "Обжарка" "Ристретто" "Утро" "Медная турка") $(pick "Кофейня" "Coffee" "Бар")"
			tagline="$(pick "Спешелти-кофе и домашняя выпечка" "Свежая обжарка каждую неделю" "Кофе, который хочется повторить")"
			service1="Кофе с собой"; service2="Зерно свежей обжарки"; service3="Каппинги по выходным"
			about="Небольшая кофейня, открытая в $(pick 2015 2017 2019 2021) году. Сами обжариваем зерно и печём круассаны." ;;
		design)
			name="$(pick "Линия" "Контур" "Модуль" "Сетка" "Пиксель") $(pick "Design" "Бюро" "Лаб")"
			tagline="$(pick "Айдентика и веб-дизайн" "Дизайн интерфейсов для малого бизнеса" "Логотипы, сайты, упаковка")"
			service1="Фирменный стиль"; service2="Дизайн сайтов"; service3="Упаковка и полиграфия"
			about="Небольшая команда дизайнеров. С $(pick 2013 2016 2019) года сделали больше $(pick 80 120 150 200) проектов." ;;
		garden)
			name="$(pick "Зелёный" "Садовый" "Клевер" "Липа" "Папоротник") $(pick "двор" "угол" "дом")"
			tagline="$(pick "Ландшафтный дизайн и уход за садом" "Растения, которые приживаются" "Сад без лишних хлопот")"
			service1="Проект участка"; service2="Посадка и озеленение"; service3="Сезонный уход"
			about="Помогаем обустроить сады и дворы с $(pick 2010 2012 2015 2018) года." ;;
		bikes)
			name="$(pick "Спица" "Каденс" "Педаль" "Втулка" "Цепь") $(pick "Веломастерская" "Bike Shop" "Гараж")"
			tagline="$(pick "Ремонт и сборка велосипедов" "Обслуживание любой сложности" "Велосипеды, которые едут")"
			service1="Сезонное ТО"; service2="Сборка колёс"; service3="Подбор велосипеда"
			about="Мастерская для тех, кто ездит каждый день. Работаем с $(pick 2012 2014 2017 2020) года." ;;
		books)
			name="$(pick "Переплёт" "Закладка" "Полка" "Абзац" "Страница") $(pick "Книжная лавка" "Букинист" "Books")"
			tagline="$(pick "Новые и букинистические книги" "Маленький магазин больших историй" "Книги, которые мы прочитали сами")"
			service1="Подборки книг"; service2="Заказ редких изданий"; service3="Книжный клуб"
			about="Независимый книжный магазин, открытый в $(pick 2009 2013 2016 2019) году." ;;
	esac
	local -a hues=(12 28 145 160 200 215 250 280 330 355)
	local hue; hue="$(pick "${hues[@]}")"
	local font; font="$(pick "Georgia, serif" "'Trebuchet MS', sans-serif" "Verdana, sans-serif" "'Palatino Linotype', Palatino, serif" "system-ui, sans-serif" "'Segoe UI', Roboto, sans-serif")"
	local radius; radius="$(pick 0 4 8 12 18)px"
	local width; width="$(pick 880 960 1040 1120)px"
	local city; city="$(pick "Москва" "Санкт-Петербург" "Казань" "Екатеринбург" "Новосибирск" "Нижний Новгород" "Самара" "Пермь")"
	local phone; phone="+7 ($(pick 495 812 843 343 383 831 846 342)) $(printf '%03d-%02d-%02d' "$(rand 1000)" "$(rand 100)" "$(rand 100)")"
	local year; year="$(date +%Y)"
	local copyright="$year"
	[[ "$(rand 2)" -eq 0 ]] || copyright="$((year - 1 - $(rand 6)))–$year"
	local css; css="styles-$(openssl rand -hex 3).css"
	local cls; cls="$(pick site page wrap main-box container)"

	mkdir -p "$out"
	cat >"$out/$css" <<CSS
:root{--h:$hue;--accent:hsl(var(--h) 55% 40%);--bg:hsl(var(--h) 30% 97%);--fg:hsl(var(--h) 20% 15%)}
*{box-sizing:border-box}body{margin:0;font-family:$font;background:var(--bg);color:var(--fg);line-height:$(pick 1.5 1.6 1.65 1.7)}
.$cls{max-width:$width;margin:0 auto;padding:0 $(pick 16 20 24)px}
header{padding:$(pick 20 28 36)px 0;border-bottom:1px solid hsl(var(--h) 20% 85%)}
header a.logo{font-size:$(pick 20 22 24 26)px;font-weight:700;color:var(--accent);text-decoration:none}
nav a{margin-left:$(pick 14 18 22)px;color:var(--fg);text-decoration:none}nav{float:right;margin-top:4px}
.hero{padding:$(pick 48 64 80)px 0}.hero h1{font-size:$(pick 34 38 42 46)px;margin:0 0 12px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax($(pick 200 220 240)px,1fr));gap:$(pick 16 20 24)px;margin-bottom:48px}
.card{background:#fff;border-radius:$radius;padding:$(pick 18 22 26)px;box-shadow:0 1px 3px hsl(var(--h) 20% 70% / .4)}
.btn{display:inline-block;background:var(--accent);color:#fff;padding:10px 18px;border-radius:$radius;text-decoration:none}
footer{padding:28px 0;color:hsl(var(--h) 10% 45%);font-size:14px;border-top:1px solid hsl(var(--h) 20% 85%)}
CSS
	page() {
		local file="$1" title="$2" body="$3"
		cat >"$out/$file" <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<meta name="description" content="$name — $tagline">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/$css">
</head>
<body>
<header><div class="$cls"><a class="logo" href="/">$name</a>
<nav><a href="/">Главная</a><a href="/about.html">О нас</a><a href="/contacts.html">Контакты</a></nav></div></header>
<main class="$cls">
$body
</main>
<footer><div class="$cls">© $copyright $name · $city · <a href="/privacy.html">Политика конфиденциальности</a></div></footer>
</body>
</html>
HTML
	}
	page index.html "$name — $tagline" "<section class=\"hero\"><h1>$tagline</h1><p>$about</p><a class=\"btn\" href=\"/contacts.html\">$(pick "Связаться" "Записаться" "Написать нам" "Узнать больше")</a></section>
<section class=\"cards\"><div class=\"card\"><h3>$service1</h3><p>$(pick "Подробно обсудим задачу и предложим решение." "Делаем аккуратно и в срок." "Работаем по предварительной записи.")</p></div>
<div class=\"card\"><h3>$service2</h3><p>$(pick "Честные цены без скрытых доплат." "Индивидуальный подход к каждому." "Можно заказать заранее.")</p></div>
<div class=\"card\"><h3>$service3</h3><p>$(pick "Спросите нас о сезонных предложениях." "Подробности — по телефону." "Расписание уточняйте в контактах.")</p></div></section>"
	page about.html "О нас — $name" "<section class=\"hero\"><h1>О нас</h1><p>$about</p><p>$(pick "Мы ценим качество и спокойный темп." "Нам важно, чтобы клиенты возвращались." "Каждый проект ведёт один человек от начала до конца.")</p></section>"
	page contacts.html "Контакты — $name" "<section class=\"hero\"><h1>Контакты</h1><p>$city</p><p>Телефон: $phone</p><p>$(pick "Пн–Пт 10:00–19:00" "Ежедневно 9:00–21:00" "Вт–Вс 11:00–20:00")</p></section>"
	page privacy.html "Политика конфиденциальности — $name" "<section class=\"hero\"><h1>Политика конфиденциальности</h1><p>Сайт не собирает персональные данные и не использует сторонние системы аналитики. Сведения, которые вы сообщаете по телефону, используются только для ответа на ваш запрос.</p></section>"
	page 404.html "Страница не найдена — $name" "<section class=\"hero\"><h1>404</h1><p>Такой страницы нет. <a href=\"/\">Вернуться на главную</a>.</p></section>"
	cat >"$out/favicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="$(rand 12)" fill="hsl($hue,55%,40%)"/><text x="16" y="22" font-size="16" text-anchor="middle" fill="#fff" font-family="sans-serif">${name:0:1}</text></svg>
SVG
	printf 'User-agent: *\nAllow: /\n' >"$out/robots.txt"
	chmod -R a+rX "$out"
	info "Сгенерирован сайт-прикрытие: «$name» ($theme)"
}

run_upstream_installer() {
	local -a args=(--hostname "$domain" --email "$email"
		--mtproxy-workers "$workers" --mtproxy-max-connections "$max_connections")
	[[ -n "$base_path" ]] && args+=(--base-path "$base_path")
	if [[ -n "$site_upstream" ]]; then
		args+=(--site-upstream "$site_upstream")
	elif [[ -n "$site_dir" ]]; then
		args+=(--site-dir "$site_dir")
	elif [[ ! -f "$SITE_ROOT/index.html" ]]; then
		local generated; generated="$(mktemp -d /tmp/tproxy-site.XXXXXX)"
		generate_site "$generated"
		args+=(--site-dir "$generated")
	else
		info "Сохраняется существующий сайт в $SITE_ROOT"
	fi
	info "Запуск официального установщика (5–15 минут: сборка MTProxy и relay)"
	install -m 0600 /dev/null "$LOG_FILE"
	# Секрет передаётся через stdin, чтобы не светиться в списке процессов.
	if ! (cd "$SRC_DIR" && ./deploy/install.sh "${args[@]}" <<<"$secret") 2>&1 | tee -a "$LOG_FILE"; then
		die "установка не удалась, лог: $LOG_FILE"
	fi
}

save_and_print() {
	local server psecret link
	server="$(sed -n 's/^Proxy server: *//p' "$LOG_FILE" | tail -n1)"
	psecret="$(sed -n 's/^Proxy secret: *//p' "$LOG_FILE" | tail -n1)"
	link="$(sed -n 's/^Proxy link: *//p' "$LOG_FILE" | tail -n1)"
	[[ -n "$link" ]] || die "установщик не вывел ссылку, см. $LOG_FILE"
	install -m 0600 /dev/null "$STATE_FILE"
	cat >"$STATE_FILE" <<STATE
# Telegram WEB proxy — $(date -u +%Y-%m-%dT%H:%M:%SZ)
Proxy server: $server
Proxy secret: $psecret
Proxy link:   $link
STATE
	print_link
}

print_link() {
	[[ -f "$STATE_FILE" ]] || die "прокси ещё не установлен ($STATE_FILE не найден)"
	local link; link="$(sed -n 's/^Proxy link: *//p' "$STATE_FILE")"
	echo
	printf '%s%s%s\n' "$c_bold" "Telegram WEB proxy готов" "$c_reset"
	grep -E '^Proxy (server|secret):' "$STATE_FILE"
	printf 'Ссылка: %s%s%s\n' "$c_green" "$link" "$c_reset"
	if command -v qrencode >/dev/null; then qrencode -t ansiutf8 "$link"; fi
	echo "Данные сохранены в $STATE_FILE"
	echo "Клиент должен поддерживать тип прокси WEB (сейчас — Telegram Desktop; Android — экспериментально)."
}

cmd_status() {
	local unit ok=0
	for unit in caddy tproxy-firewall mtproxy tproxy-server refresh-mtproxy-config.timer; do
		printf '%-32s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
	done
	if curl -fsS --max-time 5 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
		echo "relay readyz                     ok"
	else
		echo "relay readyz                     FAIL"; ok=1
	fi
	local drops
	drops="$(journalctl -u mtproxy --since -5min 2>/dev/null | grep -c 'Disconnected from RPC Middle-End' || true)"
	echo "Middle-End разрывов за 5 мин:    $drops"
	[[ "$drops" -lt 5 ]] || warn "частые разрывы Middle-End: проверьте MTPROXY_NAT_ARGS в /etc/mtproxy/mtproxy.env"
	return "$ok"
}

cmd_update() {
	[[ -d "$SRC_DIR/.git" ]] || die "исходники не найдены в $SRC_DIR, выполните install"
	[[ "$ref" != "$UPSTREAM_REF_DEFAULT" ]] || ref="$(git -C "$SRC_DIR" remote show origin | sed -n 's/.*HEAD branch: //p')"
	fetch_upstream
	(cd "$SRC_DIR" && ./deploy/update-relay.sh)
	info "relay обновлён"
}

cmd_uninstall() {
	confirm "Удалить Telegram WEB proxy, Caddy, MTProxy и их конфигурацию?" || die "отменено"
	local unit
	for unit in "${UNITS[@]}"; do systemctl disable --now "$unit" 2>/dev/null || true; done
	nft delete table inet tproxy_backend 2>/dev/null || true
	rm -f /etc/systemd/system/{caddy,tproxy-server,mtproxy,tproxy-firewall,refresh-mtproxy-config}.service \
		/etc/systemd/system/refresh-mtproxy-config.timer
	rm -rf /etc/systemd/system/caddy.service.d
	systemctl daemon-reload
	rm -f /usr/local/bin/tproxy-server* /usr/local/bin/caddy /usr/local/sbin/refresh-mtproxy-config
	rm -rf /etc/tg-webproxy /etc/tproxy-server /etc/mtproxy /opt/MTProxy "$SRC_DIR" "$STATE_FILE"
	if confirm "Удалить также сайт-прикрытие $SITE_ROOT и данные Caddy (сертификаты)?"; then
		rm -rf "$SITE_ROOT" /var/lib/caddy /etc/caddy
	fi
	info "Удалено. Пользователи caddy/tproxy/mtproxy и Go в /opt/go* оставлены."
}

main() {
	parse_args "$@"
	case "$command" in
		install)
			require_root; preflight; validate_args; install_prereqs
			check_dns; check_ports; resolve_secret; fetch_upstream
			run_upstream_installer; apply_acme_forwards; save_and_print
			cmd_status || warn "не все проверки прошли, см. вывод выше" ;;
		status) require_root; cmd_status ;;
		link) require_root; print_link ;;
		update) require_root; cmd_update ;;
		uninstall) require_root; cmd_uninstall ;;
		help) usage ;;
		*) usage >&2; exit 2 ;;
	esac
}

main "$@"
