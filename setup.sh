#!/usr/bin/env bash
set -euo pipefail

# ─── Константы ────────────────────────────────────────────────────────────────
MTG_DIR="/etc/mtg"
MTG_BIN="/usr/local/bin/mtg"
CLIENTS_CONF="$MTG_DIR/clients.conf"
MODE_FILE="$MTG_DIR/mode"
EU_IP_FILE="$MTG_DIR/eu_ip"
FRONTING_DOMAIN_FILE="$MTG_DIR/fronting_domain"
WARP_FILE="$MTG_DIR/warp"          # флаг: локальный WARP включён (одиночный режим)
WARP_SOCKS="127.0.0.1:40000"       # SOCKS5 от WARP в proxy-режиме

SNI_LIST=(
    "www.google.com"
    "www.cloudflare.com"
    "www.amazon.com"
    "www.microsoft.com"
    "www.apple.com"
    "www.youtube.com"
    "www.facebook.com"
    "www.twitter.com"
    "www.discord.com"
    "www.twitch.tv"
    "www.github.com"
    "www.wikipedia.org"
    "www.reddit.com"
    "www.vk.ru"
    "www.yandex.ru"
    "www.mail.ru"
    "www.zoom.us"
    "www.ok.ru"
    "www.slack.com"
    "www.rambler.ru"
)

# Порты, типичные для HTTPS/TLS-сервисов — меньше выделяются для DPI.
HTTPS_PORTS=(443 8443 2053 2083 2087 2096)

# ─── Утилиты ──────────────────────────────────────────────────────────────────
die() { echo "ОШИБКА: $*" >&2; exit 1; }

# Терминал не очищаем — меню просто печатается следующим блоком,
# чтобы весь предыдущий вывод (ссылки и т.д.) оставался на экране.
menu_clear() { echo ""; }
pause() { read -rp "Нажмите Enter для продолжения..." _; }

kill_service() {
    local svc="$1"
    # Находим PID и убиваем напрямую
    local pid
    pid=$(systemctl show -p MainPID "$svc" 2>/dev/null | cut -d= -f2)
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 0.5
    fi
    systemctl reset-failed "$svc" 2>/dev/null || true
    systemctl stop "$svc" 2>/dev/null || true
}

get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org || echo "UNKNOWN"
}

read_fronting_domain() {
    cat "$FRONTING_DOMAIN_FILE" 2>/dev/null || echo ""
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

resolve_domain_ipv4() {
    local domain="$1"
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | sort -u
}

domain_points_to_ip() {
    local domain="$1" expected_ip="$2"
    resolve_domain_ipv4 "$domain" | grep -qx "$expected_ip"
}

set_server_hostname() {
    local domain="$1"
    local public_ip
    public_ip=$(get_public_ip)
    [[ -z "$public_ip" || "$public_ip" == "UNKNOWN" ]] && die "Не удалось определить публичный IP сервера"

    hostnamectl set-hostname "$domain"
    cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 localhost.localdomain

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
$public_ip $domain ${domain%%.*}
EOF
}

install_https_dependencies() {
    apt-get install -y nginx certbot python3-certbot-nginx || die "Ошибка установки nginx/certbot"
}

configure_nginx_fronting() {
    local domain="$1"
    mkdir -p /var/www/vi-mtpro-fronting
    cat > /var/www/vi-mtpro-fronting/index.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>$domain</title></head>
<body><h1>$domain</h1><p>HTTPS fronting is ready.</p></body>
</html>
EOF

    cat > /etc/nginx/sites-available/vi-mtpro-fronting.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    root /var/www/vi-mtpro-fronting;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/vi-mtpro-fronting.conf /etc/nginx/sites-enabled/vi-mtpro-fronting.conf
    rm -f /etc/nginx/sites-enabled/default
    nginx -t || die "Конфиг nginx не прошёл проверку"
    systemctl enable --now nginx || die "Не удалось запустить nginx"
    systemctl reload nginx || die "Не удалось перезагрузить nginx"
}

ensure_https_certificate() {
    local domain="$1"
    certbot --nginx \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$domain" || die "Не удалось выпустить Let's Encrypt сертификат для $domain"
    systemctl reload nginx || die "Не удалось перезагрузить nginx после certbot"
}

run_mtg_doctor() {
    local name="$1"
    "$MTG_BIN" doctor "$MTG_DIR/${name}.toml"
}

secret_sni() {
    local secret="$1"
    local pad_len=$(( (4 - ${#secret} % 4) % 4 ))
    local padded="$secret"
    local i
    for (( i = 0; i < pad_len; i++ )); do
        padded+="="
    done

    printf '%s' "$padded" \
        | tr '_-' '/+' \
        | base64 -d 2>/dev/null \
        | tail -c +18 2>/dev/null || true
}

replace_client_secret_for_sni() {
    local old_sni="$1" new_sni="$2"
    [[ -f "$CLIENTS_CONF" ]] && [[ -s "$CLIENTS_CONF" ]] || return 0

    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport csni new_secret embedded_sni
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        csni=$(conf_field "$line" 4)
        embedded_sni=$(secret_sni "$csecret")

        if [[ "$csni" == "$old_sni" || "$embedded_sni" == "$old_sni" ]]; then
            new_secret=$($MTG_BIN generate-secret "$new_sni" 2>/dev/null) || die "Ошибка генерации секрета для $new_sni"
            echo "${cname}:${new_secret}:${cport}:${new_sni}" >> "$tmpfile"
            write_toml "$cname" "$new_secret" "$cport"
            kill_service "mtg-${cname}"
            systemctl start "mtg-${cname}" 2>/dev/null || true
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$CLIENTS_CONF"
    mv "$tmpfile" "$CLIENTS_CONF"
}

sync_client_secret_for_sni() {
    local target_sni="$1"
    [[ -f "$CLIENTS_CONF" ]] && [[ -s "$CLIENTS_CONF" ]] || return 0

    local tmpfile changed=false
    tmpfile=$(mktemp)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport csni new_secret embedded_sni
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        csni=$(conf_field "$line" 4)
        embedded_sni=$(secret_sni "$csecret")

        if [[ "$csni" == "$target_sni" && "$embedded_sni" != "$target_sni" ]]; then
            new_secret=$($MTG_BIN generate-secret "$target_sni" 2>/dev/null) || die "Ошибка генерации секрета для $target_sni"
            echo "${cname}:${new_secret}:${cport}:${target_sni}" >> "$tmpfile"
            write_toml "$cname" "$new_secret" "$cport"
            kill_service "mtg-${cname}"
            systemctl start "mtg-${cname}" 2>/dev/null || true
            changed=true
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$CLIENTS_CONF"
    mv "$tmpfile" "$CLIENTS_CONF"

    if [[ "$changed" == true ]]; then
        echo "Обновлены client secrets для managed domain: $target_sni"
    fi
}

setup_managed_fronting_domain() {
    local current_domain="${1:-$(read_fronting_domain)}"
    local public_ip domain
    public_ip=$(get_public_ip)
    [[ -z "$public_ip" || "$public_ip" == "UNKNOWN" ]] && die "Не удалось определить публичный IP сервера"

    echo ""
    if [[ -n "$current_domain" ]]; then
        echo "Текущий managed domain: $current_domain"
    fi
    read -rp "Введите fronting-домен, уже указывающий на этот сервер: " domain
    domain="${domain,,}"
    [[ -z "$domain" ]] && die "Домен не может быть пустым"
    is_valid_domain "$domain" || die "Некорректный домен"
    domain_points_to_ip "$domain" "$public_ip" || die "Домен $domain должен резолвиться в $public_ip до продолжения"

    set_server_hostname "$domain"
    install_https_dependencies
    configure_nginx_fronting "$domain"
    ensure_https_certificate "$domain"

    echo "$domain" > "$FRONTING_DOMAIN_FILE"
    if [[ -n "$current_domain" && "$current_domain" != "$domain" ]]; then
        replace_client_secret_for_sni "$current_domain" "$domain"
    fi
    sync_client_secret_for_sni "$domain"

    echo "Managed fronting-домен настроен: $domain"
}

pick_client_sni() {
    local managed_domain="$1"
    local sni_choice sni_domain i

    if [[ -n "$managed_domain" ]]; then
        echo "" >&2
        echo "Выберите режим SNI:" >&2
        echo "  0) Managed domain (рекомендуется): $managed_domain" >&2
        echo "  1) FakeTLS из списка / вручную" >&2
        echo "" >&2
        read -rp "Ваш выбор [0/1]: " sni_choice
        sni_choice="${sni_choice:-0}"
        if [[ "$sni_choice" == "0" ]]; then
            echo "$managed_domain"
            return 0
        elif [[ "$sni_choice" != "1" ]]; then
            echo "Некорректный выбор. Использую managed domain: $managed_domain" >&2
            echo "$managed_domain"
            return 0
        fi
    fi

    echo "" >&2
    echo "Выберите SNI-домен (Enter — случайный):" >&2
    echo "  0) Случайный из списка" >&2
    i=1
    for sni in "${SNI_LIST[@]}"; do
        printf " %2d) %-30s" "$i" "$sni" >&2
        if (( i % 2 == 0 )); then echo "" >&2; fi
        (( i++ ))
    done
    echo "" >&2
    echo " 21) Ввести вручную" >&2
    echo "" >&2

    read -rp "Ваш выбор [0-21]: " sni_choice
    sni_choice="${sni_choice:-0}"
    if [[ "$sni_choice" == "0" ]]; then
        sni_domain="${SNI_LIST[$((RANDOM % ${#SNI_LIST[@]}))]}"
        echo "Выбран случайный SNI: $sni_domain" >&2
    elif [[ "$sni_choice" == "21" ]]; then
        read -rp "Введите домен: " sni_domain
        if [[ -z "$sni_domain" || "$sni_domain" =~ [[:space:]] ]]; then
            die "Некорректный домен."
        fi
    elif [[ "$sni_choice" =~ ^[0-9]+$ ]] && (( sni_choice >= 1 && sni_choice <= 20 )); then
        sni_domain="${SNI_LIST[$((sni_choice - 1))]}"
    else
        die "Некорректный выбор."
    fi

    echo "$sni_domain"
}

read_mode() {
    cat "$MODE_FILE" 2>/dev/null || echo ""
}

read_eu_ip() {
    cat "$EU_IP_FILE" 2>/dev/null || echo ""
}

# Включён ли локальный WARP (одиночный режим через socks5://127.0.0.1:40000)
warp_enabled() {
    [[ -f "$WARP_FILE" ]]
}

# Читает поле из строки clients.conf: <name>:<secret>:<port>:<sni>
conf_field() {
    local line="$1" field="$2"
    echo "$line" | cut -d: -f"$field"
}

iter_clients() {
    [[ -f "$CLIENTS_CONF" ]] || return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "$line"
    done < "$CLIENTS_CONF"
}

client_exists() {
    local name="$1"
    grep -q "^${name}:" "$CLIENTS_CONF" 2>/dev/null
}

# Порт уже занят другим клиентом?
port_in_use() {
    local port="$1"
    [[ -f "$CLIENTS_CONF" ]] || return 1
    cut -d: -f3 "$CLIENTS_CONF" 2>/dev/null | grep -qx "$port"
}

system_port_in_use() {
    local port="$1"
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[\[\]:])${port}$"
}

# Случайный свободный порт из HTTPS_PORTS; пусто, если все заняты.
random_free_port() {
    # Перебираем порты в случайном порядке, возвращаем первый свободный.
    local ports=("${HTTPS_PORTS[@]}")
    local n=${#ports[@]} i j tmp
    for (( i = n - 1; i > 0; i-- )); do
        j=$(( RANDOM % (i + 1) ))
        tmp="${ports[i]}"; ports[i]="${ports[j]}"; ports[j]="$tmp"
    done
    for p in "${ports[@]}"; do
        if ! port_in_use "$p" && ! system_port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# ─── Установка mtg ────────────────────────────────────────────────────────────
install_mtg_binary() {
    echo "Скачиваю mtg..."
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) die "Неподдерживаемая архитектура: $arch" ;;
    esac

    local api_url="https://api.github.com/repos/9seconds/mtg/releases/latest"
    local release_json
    release_json=$(curl -sSf "$api_url") || die "Не удалось получить информацию о релизе mtg"

    # Ищем URL: содержит linux и нужную архитектуру, не содержит -v3 или -v9
    local download_url
    download_url=$(echo "$release_json" \
        | grep -o '"browser_download_url": *"[^"]*"' \
        | grep -o 'https://[^"]*' \
        | grep "linux" \
        | grep "$arch" \
        | grep -v '\-v3\b' \
        | grep -v '\-v9\b' \
        | grep '\.tar\.gz$' \
        | head -1)

    [[ -z "$download_url" ]] && die "Не найден подходящий релиз mtg для linux/$arch"

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    curl -sSfL "$download_url" -o "$tmpdir/mtg.tar.gz" || die "Ошибка скачивания mtg"
    tar -xzf "$tmpdir/mtg.tar.gz" -C "$tmpdir"

    local bin
    bin=$(find "$tmpdir" -type f -name "mtg" | head -1)
    [[ -z "$bin" ]] && die "Бинарник mtg не найден в архиве"

    cp "$bin" "$MTG_BIN"
    chmod +x "$MTG_BIN"
    echo "mtg установлен: $("$MTG_BIN" --version 2>&1 | head -1)"
}

# ─── Установка WARP (локально, для одиночного режима) ─────────────────────────
install_warp() {
    if command -v warp-cli &>/dev/null; then
        echo "WARP уже установлен."
        return 0
    fi

    echo "Устанавливаю Cloudflare WARP..."
    apt-get install -y gnupg lsb-release > /dev/null 2>&1 || true

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt-get update -qq
    apt-get install -y cloudflare-warp || die "Ошибка установки cloudflare-warp"
    echo "WARP установлен."
}

cleanup_warp() {
    command -v warp-cli &>/dev/null && warp-cli disconnect 2>/dev/null || true
    command -v warp-cli &>/dev/null && warp-cli registration delete 2>/dev/null || true
    apt-get purge -y cloudflare-warp > /dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    apt-get update -qq || true
}

# Регистрация + proxy-режим + подключение. Идемпотентно.
configure_warp() {
    local current_status
    local registration_output
    current_status=$(warp-cli status 2>/dev/null || echo "Unknown")

    if echo "$current_status" | grep -q "Connected"; then
        echo "WARP уже подключён."
    else
        if ! echo "$current_status" | grep -q "Registered"; then
            echo "Регистрирую WARP..."
            registration_output=$(warp-cli registration new 2>&1) || true
            if echo "$registration_output" | grep -q "Success"; then
                :
            elif echo "$registration_output" | grep -q "Old registration is still around"; then
                echo "WARP уже зарегистрирован, пропускаю повторную регистрацию."
            else
                echo "$registration_output"
                die "Ошибка регистрации WARP"
            fi
        fi
        echo "Переключаю WARP в proxy-режим..."
        warp-cli mode proxy || die "Ошибка переключения WARP в proxy-режим"
        echo "Подключаю WARP..."
        warp-cli connect || die "Ошибка подключения WARP"
    fi

    # Ждём, пока SOCKS5 на 127.0.0.1:40000 поднимется
    echo "Ожидаю WARP proxy на ${WARP_SOCKS}..."
    local attempts=0
    while (( attempts < 15 )); do
        if ss -lntp 2>/dev/null | grep -q "${WARP_SOCKS}"; then
            echo "WARP proxy слушает на ${WARP_SOCKS}."
            return 0
        fi
        sleep 2
        (( attempts++ ))
    done
    die "WARP proxy не слушает на ${WARP_SOCKS} за 30 секунд. Проверьте: warp-cli status"
}

# Включает локальный WARP: ставит, настраивает, поднимает флаг.
enable_warp() {
    install_warp
    configure_warp
    touch "$WARP_FILE"
    echo "Локальный WARP включён."
}

# ─── Генерация конфига toml ───────────────────────────────────────────────────
write_toml() {
    local name="$1" secret="$2" port="$3"
    local mode
    mode=$(read_mode)
    local toml_path="$MTG_DIR/${name}.toml"

    if [[ "$mode" == "cascade" ]]; then
        local eu_ip
        eu_ip=$(read_eu_ip)
        cat > "$toml_path" <<EOF
secret = "$secret"
bind-to = "0.0.0.0:$port"
tolerate-time-skewness = "5s"

[network]
proxies = ["socks5://${eu_ip}:1080"]

[defense.anti-replay]
enabled = true
max-size = "1mib"
error-rate = 0.001

[defense.doppelganger]
drs = true
EOF
    elif warp_enabled; then
        cat > "$toml_path" <<EOF
secret = "$secret"
bind-to = "0.0.0.0:$port"
tolerate-time-skewness = "5s"

[network]
proxies = ["socks5://${WARP_SOCKS}"]

[defense.anti-replay]
enabled = true
max-size = "1mib"
error-rate = 0.001

[defense.doppelganger]
drs = true
EOF
    else
        cat > "$toml_path" <<EOF
secret = "$secret"
bind-to = "0.0.0.0:$port"
tolerate-time-skewness = "5s"

[defense.anti-replay]
enabled = true
max-size = "1mib"
error-rate = 0.001

[defense.doppelganger]
drs = true
EOF
    fi
}

# ─── Systemd-юнит ─────────────────────────────────────────────────────────────
write_service() {
    local name="$1"
    cat > "/etc/systemd/system/mtg-${name}.service" <<EOF
[Unit]
Description=MTG Proxy - $name
After=network.target

[Service]
ExecStart=$MTG_BIN run $MTG_DIR/${name}.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# ─── Добавление клиента ───────────────────────────────────────────────────────
add_client() {
    local default_name="${1:-}"
    local managed_domain
    managed_domain=$(read_fronting_domain)

    # Имя клиента
    local name
    if [[ -z "$default_name" ]]; then
        read -rp "Введите имя клиента (без пробелов) [по умолчанию: default]: " name
        name="${name:-default}"
    else
        name="$default_name"
    fi

    # Убираем \r на случай Windows-переносов
    name=$(echo "$name" | tr -d '\r')

    if [[ "$name" =~ [[:space:]:] ]]; then
        echo "Имя не должно содержать пробелы или двоеточие."
        return 1
    fi
    if ! echo "$name" | grep -qP '^[a-zA-Z0-9_-]+$'; then
        echo "Имя должно содержать только латинские буквы, цифры, дефис и подчеркивание."
        return 1
    fi
    if client_exists "$name"; then
        echo "Клиент '$name' уже существует."
        return 1
    fi

    # Порт. Enter → случайный свободный порт из HTTPS-диапазона.
    local port
    read -rp "Введите порт [Enter — случайный HTTPS-порт]: " port
    if [[ -z "$port" ]]; then
        port=$(random_free_port) || { echo "Все HTTPS-порты заняты, введите порт вручную."; return 1; }
        echo "Выбран случайный порт: $port"
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo "Некорректный порт."
        return 1
    fi
    if port_in_use "$port"; then
        echo "Порт $port уже занят другим клиентом."
        return 1
    fi
    if system_port_in_use "$port"; then
        echo "Порт $port уже занят другим сервисом на сервере."
        return 1
    fi

    local sni_domain
    sni_domain=$(pick_client_sni "$managed_domain")

    # Генерация секрета
    echo "Генерирую секрет..."
    local secret

    secret=$("$MTG_BIN" generate-secret "$sni_domain" 2>/dev/null)
    if [[ -z "$secret" ]]; then
        die "Ошибка генерации секрета"
    fi
    echo "Секрет: $secret"

    # Сохранение
    mkdir -p "$MTG_DIR"
    echo "${name}:${secret}:${port}:${sni_domain}" >> "$CLIENTS_CONF"

    write_toml "$name" "$secret" "$port"
    write_service "$name"

    ufw allow "${port}/tcp" > /dev/null 2>&1 || true
    ufw --force enable > /dev/null 2>&1 || true

    systemctl daemon-reload
    systemctl enable --now "mtg-${name}"

    echo ""
    echo "Проверяю конфигурацию mtg..."
    if ! run_mtg_doctor "$name"; then
        echo ""
        echo "ВНИМАНИЕ: mtg doctor нашёл проблему для клиента '$name'."
        echo "Ссылка ниже всё равно выведена, но сначала исправьте замечания doctor."
    fi

    local public_ip
    public_ip=$(get_public_ip)
    echo ""
    echo "Клиент $name создан."
    echo "tg://proxy?server=${public_ip}&port=${port}&secret=${secret}"
    echo ""
}

# ─── Управление клиентами ─────────────────────────────────────────────────────
list_clients() {
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "Клиентов нет."
        return
    fi
    printf "\n%-3s %-20s %-8s %s\n" "#" "Имя" "Порт" "Секрет"
    printf "%-3s %-20s %-8s %s\n" "---" "--------------------" "--------" "------"
    local i=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname cport csecret
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        printf "%-3s %-20s %-8s %s\n" "$i" "$cname" "$cport" "${csecret:0:16}..."
        (( i++ ))
    done < "$CLIENTS_CONF"
    echo ""
}

delete_client() {
    list_clients
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        return
    fi

    local name
    read -rp "Введите имя клиента для удаления: " name
    if ! client_exists "$name"; then
        echo "Клиент '$name' не найден."
        return 1
    fi

    local line
    line=$(grep "^${name}:" "$CLIENTS_CONF")
    local port
    port=$(conf_field "$line" 3)

    kill_service "mtg-${name}"
    systemctl disable "mtg-${name}" 2>/dev/null || true
    rm -f "/etc/systemd/system/mtg-${name}.service" "$MTG_DIR/${name}.toml"

    # Удаляем строку из clients.conf
    local tmpfile
    tmpfile=$(mktemp)
    grep -v "^${name}:" "$CLIENTS_CONF" > "$tmpfile" || true
    mv "$tmpfile" "$CLIENTS_CONF"

    ufw delete allow "${port}/tcp" > /dev/null 2>&1 || true

    echo "Клиент '$name' удалён."
}

manage_clients() {
    while true; do
        menu_clear
        echo ""
        echo "=== Управление клиентами ==="
        echo "1) Список клиентов"
        echo "2) Добавить клиента"
        echo "3) Удалить клиента"
        echo "0) Назад"
        echo ""
        read -rp "Выбор: " choice

        case "$choice" in
            1) list_clients; pause ;;
            2) add_client; pause ;;
            3) delete_client; pause ;;
            0) return ;;
            *) echo "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ─── Показать ссылки ──────────────────────────────────────────────────────────
show_links() {
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "Клиентов нет."
        return
    fi

    local public_ip
    public_ip=$(get_public_ip)
    echo ""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport csni
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        csni=$(conf_field "$line" 4)
        echo "Клиент: $cname  SNI: $csni"
        echo "tg://proxy?server=${public_ip}&port=${cport}&secret=${csecret}"
        echo ""
    done < "$CLIENTS_CONF"
}

# ─── Статус сервисов ──────────────────────────────────────────────────────────
show_status() {
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "Клиентов нет."
        return
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname
        cname=$(conf_field "$line" 1)
        echo ""
        echo "--- mtg-${cname} ---"
        systemctl status "mtg-${cname}" --no-pager -l 2>/dev/null || echo "Сервис не найден."
        echo ""
        echo "doctor:"
        run_mtg_doctor "$cname" 2>/dev/null || true
    done < "$CLIENTS_CONF"
}

configure_fronting_domain_menu() {
    setup_managed_fronting_domain
    pause
}

# ─── Управление (рестарт / обновление / удаление) ────────────────────────────
force_stop_all() {
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "Клиентов нет."
        return 0
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname
        cname=$(conf_field "$line" 1)
        kill_service "mtg-${cname}"
        echo "Остановлен: mtg-${cname}"
    done < "$CLIENTS_CONF"
}

restart_all() {
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "Клиентов нет."
        return 0
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname
        cname=$(conf_field "$line" 1)
        kill_service "mtg-${cname}"
        systemctl start "mtg-${cname}" && echo "Перезапущен: mtg-${cname}" || echo "Ошибка: mtg-${cname}"
    done < "$CLIENTS_CONF"
}

update_mtg() {
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "Клиентов нет."
        return 0
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname
        cname=$(conf_field "$line" 1)
        kill_service "mtg-${cname}"
    done < "$CLIENTS_CONF"

    install_mtg_binary

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname
        cname=$(conf_field "$line" 1)
        systemctl start "mtg-${cname}" && echo "Запущен: mtg-${cname}" || echo "Ошибка: mtg-${cname}"
    done < "$CLIENTS_CONF"
}

bind_eu_server() {
    local eu_ip
    read -rp "Введите IP EU-сервера: " eu_ip
    [[ -z "$eu_ip" ]] && { echo "IP не может быть пустым."; return 1; }

    echo "cascade" > "$MODE_FILE"
    echo "$eu_ip" > "$EU_IP_FILE"

    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "EU-сервер привязан: $eu_ip. Клиентов пока нет."
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        write_toml "$cname" "$csecret" "$cport"
        kill_service "mtg-${cname}"
        systemctl start "mtg-${cname}" 2>/dev/null || true
    done < "$CLIENTS_CONF"

    echo "EU-сервер привязан: $eu_ip"
}

unbind_eu_server() {
    echo "single" > "$MODE_FILE"

    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        rm -f "$EU_IP_FILE"
        echo "EU-сервер отвязан. Режим: одиночный."
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        write_toml "$cname" "$csecret" "$cport"
        kill_service "mtg-${cname}"
        systemctl start "mtg-${cname}" 2>/dev/null || true
    done < "$CLIENTS_CONF"

    rm -f "$EU_IP_FILE"
    echo "EU-сервер отвязан. Режим: одиночный. Трафик идёт напрямую."
}

remove_all() {
    read -rp "Удалить всё? Это действие необратимо. [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }

    if [[ -f "$CLIENTS_CONF" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local cname
            cname=$(conf_field "$line" 1)
            kill_service "mtg-${cname}"
            systemctl disable "mtg-${cname}" 2>/dev/null || true
            rm -f "/etc/systemd/system/mtg-${cname}.service" "$MTG_DIR/${cname}.toml"
        done < "$CLIENTS_CONF"
    fi

    # Для чистой установки удаляем и конфигурацию, и пакет WARP.
    if [[ -f "$WARP_FILE" ]] || command -v warp-cli &>/dev/null; then
        cleanup_warp
    fi

    rm -f "$MTG_BIN"
    rm -f /usr/local/bin/vi-mtpro
    rm -f /usr/local/lib/vi-mtpro.sh
    rm -f /etc/nginx/sites-enabled/vi-mtpro-fronting.conf
    rm -f /etc/nginx/sites-available/vi-mtpro-fronting.conf
    rm -rf "$MTG_DIR"
    echo "Удалено."
    exit 0
}

# Перезаписывает toml всех клиентов и перезапускает их сервисы.
rewrite_all_clients() {
    [[ -f "$CLIENTS_CONF" ]] && [[ -s "$CLIENTS_CONF" ]] || return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        write_toml "$cname" "$csecret" "$cport"
        kill_service "mtg-${cname}"
        systemctl start "mtg-${cname}" 2>/dev/null || true
    done < "$CLIENTS_CONF"
}

# Включить / выключить локальный WARP в одиночном режиме.
toggle_warp() {
    if warp_enabled; then
        read -rp "Отключить локальный WARP? Трафик пойдёт напрямую. [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }
        rm -f "$WARP_FILE"
        command -v warp-cli &>/dev/null && warp-cli disconnect 2>/dev/null || true
        rewrite_all_clients
        echo "Локальный WARP отключён."
    else
        read -rp "Включить локальный WARP (трафик в Telegram через Cloudflare WARP)? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }
        enable_warp
        rewrite_all_clients
        echo "Локальный WARP включён."
    fi
}

manage_menu() {
    while true; do
        local mode
        mode=$(read_mode)
        menu_clear
        echo ""
        echo "=== Управление ==="
        echo "1) Перезапустить все сервисы"
        echo "2) Обновить mtg"
        echo "3) Принудительная остановка всех сервисов"
        if [[ "$mode" == "cascade" ]]; then
            echo "4) Привязать EU-сервер"
            echo "5) Отвязать EU-сервер"
            echo "6) Настроить / сменить fronting-домен"
            echo "7) Удалить всё"
        else
            if warp_enabled; then
                echo "4) Локальный WARP: ВКЛ (выключить)"
            else
                echo "4) Локальный WARP: ВЫКЛ (включить)"
            fi
            echo "5) Настроить / сменить fronting-домен"
            echo "6) Удалить всё"
        fi
        echo "0) Назад"
        echo ""
        read -rp "Выбор: " choice

        case "$choice" in
            1) restart_all; pause ;;
            2) update_mtg; pause ;;
            3) force_stop_all; pause ;;
            4)
                if [[ "$mode" == "cascade" ]]; then
                    bind_eu_server; pause
                else
                    toggle_warp; pause
                fi
                ;;
            5)
                if [[ "$mode" == "cascade" ]]; then
                    unbind_eu_server; pause
                else
                    configure_fronting_domain_menu
                fi
                ;;
            6)
                if [[ "$mode" == "cascade" ]]; then
                    configure_fronting_domain_menu
                else
                    remove_all
                fi
                ;;
            7)
                if [[ "$mode" == "cascade" ]]; then
                    remove_all
                else
                    echo "Неверный выбор."; sleep 1
                fi
                ;;
            0) return ;;
            *) echo "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ─── Первоначальная установка ─────────────────────────────────────────────────
setup_single() {
    echo "Устанавливаю зависимости..."
    apt-get update -qq
    apt-get install -y curl wget ufw

    install_mtg_binary

    mkdir -p "$MTG_DIR"
    echo "single" > "$MODE_FILE"
    touch "$CLIENTS_CONF"

    echo ""
    local use_managed_domain
    read -rp "Настроить managed fronting-домен с автоматическим HTTPS? [Y/n]: " use_managed_domain
    if [[ -z "$use_managed_domain" || "$use_managed_domain" == "y" || "$use_managed_domain" == "Y" ]]; then
        setup_managed_fronting_domain
    fi

    echo ""
    local use_warp
    read -rp "Использовать локальный WARP (трафик в Telegram через Cloudflare WARP)? [y/N]: " use_warp
    if [[ "$use_warp" == "y" || "$use_warp" == "Y" ]]; then
        enable_warp
    fi

    echo ""
    echo "Создаём первого клиента:"
    add_client "default"

    echo ""
    echo "Установка завершена. Режим: одиночный$(warp_enabled && echo " + WARP")."
    echo "Для управления используйте команду: vi-mtpro"
}

setup_cascade() {
    echo "Устанавливаю зависимости..."
    apt-get update -qq
    apt-get install -y curl wget ufw

    install_mtg_binary

    local eu_ip
    read -rp "Введите IP EU-сервера: " eu_ip
    [[ -z "$eu_ip" ]] && die "IP EU-сервера не может быть пустым"

    mkdir -p "$MTG_DIR"
    echo "cascade" > "$MODE_FILE"
    echo "$eu_ip" > "$EU_IP_FILE"
    touch "$CLIENTS_CONF"

    echo ""
    local use_managed_domain
    read -rp "Настроить managed fronting-домен с автоматическим HTTPS? [Y/n]: " use_managed_domain
    if [[ -z "$use_managed_domain" || "$use_managed_domain" == "y" || "$use_managed_domain" == "Y" ]]; then
        setup_managed_fronting_domain
    fi

    echo ""
    echo "Создаём первого клиента:"
    add_client "default"

    echo ""
    echo "============================================================"
    echo ""
    echo "Скопируйте tunnel.sh на EU-сервер и запустите:"
    echo "  bash tunnel.sh"
    echo ""
    echo "Скрипт настроит gost + WARP на EU-сервере."
    echo "После завершения каскад будет работать."
    echo "Для управления используйте команду: vi-mtpro"
    echo "============================================================"
}

# ─── Смена режима ────────────────────────────────────────────────────────────
switch_mode() {
    local mode
    mode=$(read_mode)

    echo ""
    if [[ "$mode" == "cascade" ]]; then
        echo "Текущий режим: каскад"
        echo "1) Переключить на одиночный"
        echo "0) Отмена"
    else
        echo "Текущий режим: одиночный"
        echo "1) Переключить на каскад"
        echo "0) Отмена"
    fi
    echo ""
    read -rp "Выбор: " choice
    [[ "$choice" != "1" ]] && return

    if [[ "$mode" == "cascade" ]]; then
        unbind_eu_server
    else
        echo "cascade" > "$MODE_FILE"
        local eu_ip
        read -rp "Введите IP EU-сервера: " eu_ip
        [[ -z "$eu_ip" ]] && { echo "IP не может быть пустым."; echo "single" > "$MODE_FILE"; return 1; }
        echo "$eu_ip" > "$EU_IP_FILE"

        # Перезаписываем toml для всех клиентов
        if [[ -f "$CLIENTS_CONF" ]] && [[ -s "$CLIENTS_CONF" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local cname csecret cport
                cname=$(conf_field "$line" 1)
                csecret=$(conf_field "$line" 2)
                cport=$(conf_field "$line" 3)
                write_toml "$cname" "$csecret" "$cport"
                kill_service "mtg-${cname}"
                systemctl start "mtg-${cname}" 2>/dev/null || true
            done < "$CLIENTS_CONF"
        fi

        echo ""
        echo "Режим изменён на каскад. EU-сервер: $eu_ip"
        echo "Не забудьте запустить tunnel.sh на EU-сервере!"
    fi
}

# ─── Главное меню ─────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        local mode
        mode=$(read_mode)
        local eu_ip
        eu_ip=$(read_eu_ip)

        local mode_label
        if [[ "$mode" == "cascade" ]]; then
            mode_label="каскад (EU: ${eu_ip:-не задан})"
        else
            mode_label="одиночный"
        fi
        local fronting_domain
        fronting_domain=$(read_fronting_domain)

        menu_clear
        echo ""
        echo "=== MTProxy Setup ==="
        echo "Режим: $mode_label"
        if [[ -n "$fronting_domain" ]]; then
            echo "Managed domain: $fronting_domain"
        fi
        echo "---"
        echo "1) Управление клиентами (добавить / список / удалить)"
        echo "2) Показать ссылки клиентов"
        echo "3) Статус сервисов"
        echo "4) Управление (рестарт / удаление / обновление)"
        echo "5) Сменить режим (одиночный / каскад)"
        echo "0) Выход"
        echo ""
        read -rp "Выбор: " choice

        case "$choice" in
            1) manage_clients ;;
            2) show_links; pause ;;
            3) show_status; pause ;;
            4) manage_menu ;;
            5) switch_mode; pause ;;
            0) exit 0 ;;
            *) echo "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && die "Запустите скрипт от root: sudo bash $0"

# При первом запуске через curl сохраняем скрипт и регистрируем команду vi-mtpro
SELF="/usr/local/lib/vi-mtpro.sh"
if [[ ! -f "$SELF" ]]; then
    SCRIPT_URL="https://raw.githubusercontent.com/ViPunch/Vi-MTProxy/master/setup.sh"
    curl -sSfL "$SCRIPT_URL" -o "$SELF" 2>/dev/null && chmod +x "$SELF" || cp "$0" "$SELF" 2>/dev/null || true
fi
if [[ -f "$SELF" ]]; then
    cat > /usr/local/bin/vi-mtpro <<'EOF'
#!/usr/bin/env bash
exec bash /usr/local/lib/vi-mtpro.sh "$@"
EOF
    chmod +x /usr/local/bin/vi-mtpro
fi

if [[ ! -f "$MODE_FILE" ]]; then
    echo ""
    echo "=== MTProxy Setup ==="
    echo "Выберите режим:"
    echo "1) Одиночный (без каскада) — всё на одном сервере"
    echo "2) Каскад — этот сервер (RU) → второй сервер (EU) → WARP"
    echo ""
    read -rp "Выбор [1/2]: " mode_choice
    case "$mode_choice" in
        1) setup_single ;;
        2) setup_cascade ;;
        *) die "Неверный выбор" ;;
    esac
fi

# Быстрый вызов через аргументы командной строки
if [[ $# -ge 2 && "$1" == "set-eu" ]]; then
    eu_ip="$2"
    [[ -z "$eu_ip" ]] && die "IP не может быть пустым"

    echo "$eu_ip" > "$EU_IP_FILE"
    echo "cascade" > "$MODE_FILE"

    if [[ -f "$CLIENTS_CONF" ]] && [[ -s "$CLIENTS_CONF" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local cname csecret cport
            cname=$(conf_field "$line" 1)
            csecret=$(conf_field "$line" 2)
            cport=$(conf_field "$line" 3)
            write_toml "$cname" "$csecret" "$cport"
            kill_service "mtg-${cname}"
            systemctl start "mtg-${cname}" 2>/dev/null || true
        done < "$CLIENTS_CONF"
    fi

    echo "EU-сервер привязан: $eu_ip"
    echo "Все сервисы перезапущены."
    exit 0
fi

main_menu
