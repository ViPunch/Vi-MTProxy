#!/usr/bin/env bash
set -euo pipefail

# ─── Константы ────────────────────────────────────────────────────────────────
MTG_DIR="/etc/mtg"
MTG_IMAGE="nineseconds/mtg:2"
CLIENTS_CONF="$MTG_DIR/clients.conf"
MODE_FILE="$MTG_DIR/mode"
EU_IP_FILE="$MTG_DIR/eu_ip"
FRONTING_DOMAIN_FILE="$MTG_DIR/fronting_domain"
EMAIL_FILE="$MTG_DIR/email"
WARP_FILE="$MTG_DIR/warp"
SITE_OWN_FILE="$MTG_DIR/site_own"
WARP_SOCKS="127.0.0.1:40000"

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

HTTPS_PORTS=(443 8443 2053 2083 2087 2096)

# ─── Утилиты ──────────────────────────────────────────────────────────────────
die() { echo "ОШИБКА: $*" >&2; exit 1; }
menu_clear() { echo ""; }
pause() { read -rp "Нажмите Enter для продолжения..." _; }

get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org || echo "UNKNOWN"
}

get_local_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || get_public_ip
}

read_fronting_domain() {
    cat "$FRONTING_DOMAIN_FILE" 2>/dev/null || echo ""
}

read_mode() {
    cat "$MODE_FILE" 2>/dev/null || echo ""
}

read_eu_ip() {
    cat "$EU_IP_FILE" 2>/dev/null || echo ""
}

warp_enabled() {
    [[ -f "$WARP_FILE" ]]
}

site_is_own() {
    [[ -f "$SITE_OWN_FILE" ]]
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

conf_field() {
    local line="$1" field="$2"
    echo "$line" | cut -d: -f"$field"
}

# ─── Docker ───────────────────────────────────────────────────────────────────
pull_mtg_image() {
    echo "Загружаю Docker-образ $MTG_IMAGE..."
    docker pull "$MTG_IMAGE" || die "Ошибка загрузки Docker-образа $MTG_IMAGE"
    echo "Образ загружен."
}

generate_secret() {
    local domain="$1"
    docker run --rm "$MTG_IMAGE" generate-secret --hex "$domain" 2>/dev/null
}

start_container() {
    local name="$1"
    docker run -d \
        --name "mtg-${name}" \
        --restart always \
        --network host \
        -v "$MTG_DIR/${name}.toml:/config.toml:ro" \
        "$MTG_IMAGE" run /config.toml >/dev/null \
        || die "Ошибка запуска контейнера mtg-${name}"
}

stop_container() {
    local name="$1"
    docker rm -f "mtg-${name}" 2>/dev/null || true
}

restart_container() {
    local name="$1"
    stop_container "$name"
    start_container "$name"
}

container_running() {
    local name="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "mtg-${name}"
}

run_mtg_doctor() {
    local name="$1"
    docker run --rm --network host \
        -v "$MTG_DIR/${name}.toml:/config.toml:ro" \
        "$MTG_IMAGE" doctor /config.toml
}

# ─── Конфиг клиентов ──────────────────────────────────────────────────────────
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

port_in_use() {
    local port="$1"
    [[ -f "$CLIENTS_CONF" ]] || return 1
    cut -d: -f3 "$CLIENTS_CONF" 2>/dev/null | grep -qx "$port"
}

system_port_in_use() {
    local port="$1"
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[[\]:])${port}$"
}

random_free_port() {
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

write_client_record() {
    local name="$1" secret="$2" port="$3" sni="$4" ctype="$5"
    echo "${name}:${secret}:${port}:${sni}:${ctype}"
}

read_client_sni() {
    local line="$1"
    conf_field "$line" 4
}

read_client_type() {
    local line="$1"
    local ctype
    ctype=$(conf_field "$line" 5)
    if [[ "$ctype" == "managed" || "$ctype" == "external" ]]; then
        echo "$ctype"
        return 0
    fi
    local csni managed_domain
    csni=$(read_client_sni "$line")
    managed_domain=$(read_fronting_domain)
    if [[ -n "$managed_domain" && "$csni" == "$managed_domain" ]]; then
        echo "managed"
    else
        echo "external"
    fi
}

client_type_label() {
    local ctype="$1"
    if [[ "$ctype" == "managed" ]]; then
        echo "Managed fronting"
    else
        echo "External FakeTLS"
    fi
}

pick_client_profile() {
    local managed_domain="$1"
    local mode_choice sni_choice sni_domain i

    echo "" >&2
    echo "Выберите режим клиента:" >&2
    if [[ -n "$managed_domain" ]]; then
        echo "  1) Managed fronting domain: $managed_domain" >&2
        echo "  2) External FakeTLS domain" >&2
        echo "" >&2
        read -rp "Ваш выбор [1/2]: " mode_choice
        mode_choice="${mode_choice:-1}"
        if [[ "$mode_choice" == "1" ]]; then
            echo "managed:$managed_domain"
            return 0
        elif [[ "$mode_choice" != "2" ]]; then
            die "Некорректный выбор режима клиента."
        fi
    else
        echo "  1) External FakeTLS domain" >&2
        echo "" >&2
        read -rp "Ваш выбор [1]: " mode_choice
        mode_choice="${mode_choice:-1}"
        [[ "$mode_choice" == "1" ]] || die "Managed fronting сначала нужно настроить отдельно."
    fi

    echo "" >&2
    echo "Выберите внешний FakeTLS-домен (Enter — случайный):" >&2
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

    echo "external:$sni_domain"
}

# ─── Nginx & SSL ──────────────────────────────────────────────────────────────
install_web_dependencies() {
    apt-get install -y nginx certbot python3-certbot-nginx || die "Ошибка установки nginx/certbot"
}

create_stub_page() {
    local tpl_choice="$1"
    mkdir -p /var/www/html

    case "$tpl_choice" in
        1)
            cat > /var/www/html/index.html <<'STUBEOF'
<!DOCTYPE html>
<html>
<head>
<title>Under Construction</title>
<style>
  body { background: #121212; color: #fff; font-family: sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; }
  .loader { border: 4px solid #333; border-top: 4px solid #3498db; border-radius: 50%; width: 50px; height: 50px; animation: spin 1s linear infinite; margin-bottom: 20px; }
  @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
  h1 { font-weight: 300; }
</style>
</head>
<body>
  <div class="loader"></div>
  <h1>System Update in Progress...</h1>
</body>
</html>
STUBEOF
            ;;
        2)
            cat > /var/www/html/index.html <<'STUBEOF'
<!DOCTYPE html>
<html>
<head>
<title>Maintenance</title>
<style>
  body { background: #0f172a; color: #cbd5e1; font-family: sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; }
  .pulse { width: 60px; height: 60px; background-color: #3b82f6; border-radius: 50%; animation: pulse 1.5s ease-in-out infinite; margin-bottom: 30px; }
  @keyframes pulse { 0% { transform: scale(0.8); box-shadow: 0 0 0 0 rgba(59, 130, 246, 0.7); } 70% { transform: scale(1); box-shadow: 0 0 0 20px rgba(59, 130, 246, 0); } 100% { transform: scale(0.8); box-shadow: 0 0 0 0 rgba(59, 130, 246, 0); } }
  h1 { font-weight: 400; letter-spacing: 1px; }
</style>
</head>
<body>
  <div class="pulse"></div>
  <h1>Service Maintenance</h1>
</body>
</html>
STUBEOF
            ;;
        *)
            cat > /var/www/html/index.html <<'STUBEOF'
<!DOCTYPE html>
<html>
<head>
<title>Loading</title>
<style>
  body { background: #18181b; color: #e4e4e7; font-family: monospace; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; }
  .progress-container { width: 300px; height: 4px; background: #3f3f46; border-radius: 2px; overflow: hidden; margin-bottom: 20px; }
  .progress-bar { width: 50%; height: 100%; background: #10b981; animation: progress 2s infinite ease-in-out; transform-origin: left; }
  @keyframes progress { 0% { transform: scaleX(0); } 50% { transform: scaleX(1); } 100% { transform: scaleX(0); transform-origin: right; } }
  h1 { font-size: 1.2rem; text-transform: uppercase; letter-spacing: 2px; }
</style>
</head>
<body>
  <div class="progress-container"><div class="progress-bar"></div></div>
  <h1>Initializing environment...</h1>
</body>
</html>
STUBEOF
            ;;
    esac
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

configure_nginx_stub() {
    local domain="$1" email="$2" tpl_choice="$3"

    install_web_dependencies
    create_stub_page "$tpl_choice"

    cat > "/etc/nginx/sites-available/${domain}" <<EOF
server {
    listen 80;
    server_name $domain;
    root /var/www/html;
    index index.html;
}
EOF
    ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx

    # Получаем SSL сертификат
    certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email" \
        || die "Не удалось выпустить Let's Encrypt сертификат для $domain"

    # Перебиндим nginx на localhost — mtg займёт внешний порт
    sed -i 's/listen 443 ssl/listen 127.0.0.1:443 ssl/g' "/etc/nginx/sites-available/${domain}"
    sed -i '/listen \[::\]:443 ssl/d' "/etc/nginx/sites-available/${domain}"
    systemctl restart nginx

    touch "$SITE_OWN_FILE"
    echo "Заглушка и SSL настроены. Nginx слушает на 127.0.0.1:443."
}

# ─── Managed fronting domain — полная настройка ───────────────────────────────
setup_managed_fronting_domain() {
    local current_domain="${1:-$(read_fronting_domain)}"
    local public_ip domain email
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

    read -rp "Введите Email для SSL сертификата: " email
    [[ -z "$email" ]] && die "Email не может быть пустым"

    echo ""
    echo "У вас уже работает HTTPS сайт на этом сервере (на порту 443)?"
    echo "  1) Нет, установить заглушку (прокси займёт порт 443)"
    echo "  2) Да, сайт уже есть (прокси займёт другой порт)"
    echo ""
    read -rp "Ваш выбор [1/2]: " site_choice

    set_server_hostname "$domain"

    if [[ "$site_choice" == "1" ]]; then
        echo ""
        echo "Выберите дизайн для сайта-заглушки:"
        echo "  1) Вращающийся круг (Spinning Loader)"
        echo "  2) Пульсирующая точка (Pulse Loader)"
        echo "  3) Линия загрузки (Progress Bar)"
        echo ""
        read -rp "Ваш выбор [1-3]: " tpl_choice
        tpl_choice="${tpl_choice:-1}"
        configure_nginx_stub "$domain" "$email" "$tpl_choice"
    fi

    echo "$domain" > "$FRONTING_DOMAIN_FILE"
    echo "$email" > "$EMAIL_FILE"

    # Если домен изменился — обновляем секреты managed-клиентов
    if [[ -n "$current_domain" && "$current_domain" != "$domain" ]]; then
        replace_client_secrets_for_domain "$current_domain" "$domain"
    fi

    echo "Managed fronting-домен настроен: $domain"
}

replace_client_secrets_for_domain() {
    local old_domain="$1" new_domain="$2"
    [[ -f "$CLIENTS_CONF" ]] && [[ -s "$CLIENTS_CONF" ]] || return 0

    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport csni ctype
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        csni=$(read_client_sni "$line")
        ctype=$(read_client_type "$line")

        if [[ "$ctype" == "managed" && "$csni" == "$old_domain" ]]; then
            local new_secret
            new_secret=$(generate_secret "$new_domain") || die "Ошибка генерации секрета для $new_domain"
            echo "$(write_client_record "$cname" "$new_secret" "$cport" "$new_domain" "$ctype")" >> "$tmpfile"
            write_toml "$cname" "$new_secret" "$cport" "$ctype"
            restart_container "$cname"
            echo "Обновлён клиент: $cname"
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$CLIENTS_CONF"
    mv "$tmpfile" "$CLIENTS_CONF"
}

# ─── WARP ─────────────────────────────────────────────────────────────────────
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

configure_warp() {
    local current_status registration_output
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
                echo "WARP уже зарегистрирован."
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

enable_warp() {
    install_warp
    configure_warp
    touch "$WARP_FILE"
    echo "Локальный WARP включён."
}

# ─── Генерация toml ──────────────────────────────────────────────────────────
write_toml() {
    local name="$1" secret="$2" port="$3" ctype="${4:-external}"
    local mode toml_path local_ip managed_domain
    mode=$(read_mode)
    toml_path="$MTG_DIR/${name}.toml"
    local_ip=$(get_local_ip)
    managed_domain=$(read_fronting_domain)

    cat > "$toml_path" <<EOF
secret = "$secret"
bind-to = "${local_ip}:${port}"
forward-secrecy = false
EOF

    # Domain fronting для managed-клиентов
    if [[ "$ctype" == "managed" && -n "$managed_domain" ]]; then
        cat >> "$toml_path" <<EOF

[domain-fronting]
ip = "127.0.0.1"
port = 443
EOF
    fi

    # Сетевой прокси (каскад или WARP)
    if [[ "$mode" == "cascade" ]]; then
        local eu_ip
        eu_ip=$(read_eu_ip)
        cat >> "$toml_path" <<EOF

[network]
proxies = ["socks5://${eu_ip}:1080"]
EOF
    elif warp_enabled; then
        cat >> "$toml_path" <<EOF

[network]
proxies = ["socks5://${WARP_SOCKS}"]
EOF
    fi

    # Защита
    cat >> "$toml_path" <<EOF

[defense.anti-replay]
enabled = true
max-size = "1mib"
error-rate = 0.001

[defense.doppelganger]
drs = true
EOF
}

# ─── Добавление клиента ──────────────────────────────────────────────────────
add_client() {
    local default_name="${1:-}"
    local default_port="${2:-}"
    local default_profile="${3:-}"
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

    # Порт
    local port
    if [[ -z "$default_port" ]]; then
        read -rp "Введите порт [Enter — случайный HTTPS-порт]: " port
        if [[ -z "$port" ]]; then
            port=$(random_free_port) || { echo "Все HTTPS-порты заняты, введите порт вручную."; return 1; }
            echo "Выбран случайный порт: $port"
        fi
    else
        port="$default_port"
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo "Некорректный порт."
        return 1
    fi
    if port_in_use "$port"; then
        echo "Порт $port уже занят другим клиентом."
        return 1
    fi

    # Профиль клиента
    local client_profile client_type sni_domain
    if [[ -z "$default_profile" ]]; then
        client_profile=$(pick_client_profile "$managed_domain")
    else
        client_profile="$default_profile"
    fi
    client_type=${client_profile%%:*}
    sni_domain=${client_profile#*:}

    # Генерация секрета
    echo "Генерирую секрет..."
    local secret
    secret=$(generate_secret "$sni_domain")
    if [[ -z "$secret" ]]; then
        die "Ошибка генерации секрета"
    fi
    echo "Секрет: $secret"

    # Сохранение
    mkdir -p "$MTG_DIR"
    write_client_record "$name" "$secret" "$port" "$sni_domain" "$client_type" >> "$CLIENTS_CONF"
    write_toml "$name" "$secret" "$port" "$client_type"

    ufw allow "${port}/tcp" > /dev/null 2>&1 || true
    ufw --force enable > /dev/null 2>&1 || true

    # Запуск контейнера
    start_container "$name"
    sleep 2

    echo ""
    echo "Проверяю конфигурацию mtg..."
    if ! run_mtg_doctor "$name"; then
        echo ""
        echo "ВНИМАНИЕ: mtg doctor нашёл проблему для клиента '$name'."
        echo "Ссылка ниже всё равно выведена, но сначала исправьте замечания doctor."
    fi

    # Ссылка
    local server_addr
    if [[ "$client_type" == "managed" && -n "$managed_domain" ]]; then
        server_addr="$managed_domain"
    else
        server_addr=$(get_public_ip)
    fi
    echo ""
    echo "Клиент $name создан. Тип: $(client_type_label "$client_type")."
    echo "tg://proxy?server=${server_addr}&port=${port}&secret=${secret}"
    echo ""
}

# ─── Управление клиентами ────────────────────────────────────────────────────
list_clients() {
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "Клиентов нет."
        return
    fi
    printf "\n%-3s %-20s %-8s %-18s %-10s %s\n" "#" "Имя" "Порт" "Тип" "Docker" "Секрет"
    printf "%-3s %-20s %-8s %-18s %-10s %s\n" "---" "--------------------" "--------" "------------------" "----------" "------"
    local i=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname cport csecret ctype docker_status
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        ctype=$(read_client_type "$line")
        if container_running "$cname"; then
            docker_status="✓ UP"
        else
            docker_status="✗ DOWN"
        fi
        printf "%-3s %-20s %-8s %-18s %-10s %s\n" "$i" "$cname" "$cport" "$ctype" "$docker_status" "${csecret:0:16}..."
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

    local line port
    line=$(grep "^${name}:" "$CLIENTS_CONF")
    port=$(conf_field "$line" 3)

    stop_container "$name"
    rm -f "$MTG_DIR/${name}.toml"

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

    local public_ip managed_domain
    public_ip=$(get_public_ip)
    managed_domain=$(read_fronting_domain)
    echo ""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport csni ctype server_addr
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        csni=$(read_client_sni "$line")
        ctype=$(read_client_type "$line")

        if [[ "$ctype" == "managed" && -n "$managed_domain" ]]; then
            server_addr="$managed_domain"
        else
            server_addr="$public_ip"
        fi
        echo "Клиент: $cname  Тип: $(client_type_label "$ctype")  SNI: $csni"
        echo "tg://proxy?server=${server_addr}&port=${cport}&secret=${csecret}"
        echo ""
    done < "$CLIENTS_CONF"
}

# ─── Статус ───────────────────────────────────────────────────────────────────
show_status() {
    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        echo "Клиентов нет."
        return
    fi

    echo ""
    echo "=== Статус Nginx ==="
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo "Nginx: РАБОТАЕТ"
    else
        echo "Nginx: не запущен"
    fi
    echo ""

    echo "=== Docker-контейнеры ==="
    docker ps --filter "name=mtg-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker не доступен"
    echo ""

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csni ctype cport
        cname=$(conf_field "$line" 1)
        cport=$(conf_field "$line" 3)
        csni=$(read_client_sni "$line")
        ctype=$(read_client_type "$line")
        echo ""
        echo "--- mtg-${cname} ---"
        echo "Тип: $(client_type_label "$ctype")  SNI: $csni  Порт: $cport"
        if container_running "$cname"; then
            echo "Контейнер: РАБОТАЕТ"
            echo "Последние логи:"
            docker logs --tail 10 "mtg-${cname}" 2>&1 || true
        else
            echo "Контейнер: НЕ ЗАПУЩЕН"
        fi
    done < "$CLIENTS_CONF"
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
        stop_container "$cname"
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
        restart_container "$cname"
        echo "Перезапущен: mtg-${cname}"
    done < "$CLIENTS_CONF"
}

update_mtg() {
    force_stop_all
    echo ""
    pull_mtg_image
    echo ""

    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        return 0
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname
        cname=$(conf_field "$line" 1)
        start_container "$cname" && echo "Запущен: mtg-${cname}" || echo "Ошибка: mtg-${cname}"
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

    rewrite_all_clients
    echo "EU-сервер привязан: $eu_ip"
}

unbind_eu_server() {
    echo "single" > "$MODE_FILE"

    if [[ ! -f "$CLIENTS_CONF" ]] || [[ ! -s "$CLIENTS_CONF" ]]; then
        rm -f "$EU_IP_FILE"
        echo "EU-сервер отвязан. Режим: одиночный."
        return 0
    fi

    rewrite_all_clients
    rm -f "$EU_IP_FILE"
    echo "EU-сервер отвязан. Режим: одиночный. Трафик идёт напрямую."
}

remove_all() {
    read -rp "Удалить всё? Это действие необратимо. [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }

    # Останавливаем и удаляем все Docker-контейнеры mtg
    if [[ -f "$CLIENTS_CONF" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local cname
            cname=$(conf_field "$line" 1)
            stop_container "$cname"
        done < "$CLIENTS_CONF"
    fi

    # Удаляем WARP если был включён
    if [[ -f "$WARP_FILE" ]] || command -v warp-cli &>/dev/null; then
        cleanup_warp
    fi

    # Удаляем nginx заглушку если мы её ставили
    if site_is_own; then
        local domain
        domain=$(read_fronting_domain)
        rm -f "/etc/nginx/sites-enabled/${domain}" 2>/dev/null || true
        rm -f "/etc/nginx/sites-available/${domain}" 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
    fi

    # Удаляем старые systemd-юниты (миграция с предыдущей версии)
    for unit_file in /etc/systemd/system/mtg-*.service; do
        [[ -f "$unit_file" ]] || continue
        local svc_name
        svc_name=$(basename "$unit_file" .service)
        systemctl stop "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "$unit_file"
    done

    rm -f /usr/local/bin/vi-mtpro
    rm -f /usr/local/lib/vi-mtpro.sh
    rm -f /usr/local/bin/mtg
    rm -rf "$MTG_DIR"
    systemctl daemon-reload 2>/dev/null || true
    echo "Удалено."
    exit 0
}

rewrite_all_clients() {
    [[ -f "$CLIENTS_CONF" ]] && [[ -s "$CLIENTS_CONF" ]] || return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local cname csecret cport ctype
        cname=$(conf_field "$line" 1)
        csecret=$(conf_field "$line" 2)
        cport=$(conf_field "$line" 3)
        ctype=$(read_client_type "$line")
        write_toml "$cname" "$csecret" "$cport" "$ctype"
        restart_container "$cname"
    done < "$CLIENTS_CONF"
}

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

configure_fronting_domain_menu() {
    setup_managed_fronting_domain
    pause
}

manage_menu() {
    while true; do
        local mode
        mode=$(read_mode)
        menu_clear
        echo ""
        echo "=== Управление ==="
        echo "1) Перезапустить все контейнеры"
        echo "2) Обновить mtg (pull новый образ)"
        echo "3) Принудительная остановка всех контейнеров"
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
    apt-get install -y curl wget ufw docker.io

    pull_mtg_image

    mkdir -p "$MTG_DIR"
    echo "single" > "$MODE_FILE"
    touch "$CLIENTS_CONF"

    echo ""
    local use_managed_domain
    read -rp "Настроить Managed fronting domain с автоматическим HTTPS? [Y/n]: " use_managed_domain
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
    local managed_domain first_port
    managed_domain=$(read_fronting_domain)
    if [[ -n "$managed_domain" ]]; then
        if site_is_own; then
            # Мы поставили заглушку — порт 443 свободен для mtg
            first_port="443"
        else
            # Сайт уже был — берём случайный порт
            first_port=$(random_free_port) || first_port="8443"
        fi
        add_client "default" "$first_port" "managed:$managed_domain"
    else
        add_client "default"
    fi

    echo ""
    echo "Установка завершена. Режим: одиночный$(warp_enabled && echo " + WARP")."
    echo "Для управления используйте команду: vi-mtpro"
}

setup_cascade() {
    echo "Устанавливаю зависимости..."
    apt-get update -qq
    apt-get install -y curl wget ufw docker.io

    pull_mtg_image

    local eu_ip
    read -rp "Введите IP EU-сервера: " eu_ip
    [[ -z "$eu_ip" ]] && die "IP EU-сервера не может быть пустым"

    mkdir -p "$MTG_DIR"
    echo "cascade" > "$MODE_FILE"
    echo "$eu_ip" > "$EU_IP_FILE"
    touch "$CLIENTS_CONF"

    echo ""
    local use_managed_domain
    read -rp "Настроить Managed fronting domain с автоматическим HTTPS? [Y/n]: " use_managed_domain
    if [[ -z "$use_managed_domain" || "$use_managed_domain" == "y" || "$use_managed_domain" == "Y" ]]; then
        setup_managed_fronting_domain
    fi

    echo ""
    echo "Создаём первого клиента:"
    local managed_domain first_port
    managed_domain=$(read_fronting_domain)
    if [[ -n "$managed_domain" ]]; then
        if site_is_own; then
            first_port="443"
        else
            first_port=$(random_free_port) || first_port="8443"
        fi
        add_client "default" "$first_port" "managed:$managed_domain"
    else
        add_client "default"
    fi

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
        rewrite_all_clients
        echo ""
        echo "Режим изменён на каскад. EU-сервер: $eu_ip"
        echo "Не забудьте запустить tunnel.sh на EU-сервере!"
    fi
}

# ─── Главное меню ─────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        local mode eu_ip mode_label fronting_domain
        mode=$(read_mode)
        eu_ip=$(read_eu_ip)

        if [[ "$mode" == "cascade" ]]; then
            mode_label="каскад (EU: ${eu_ip:-не задан})"
        else
            mode_label="одиночный"
        fi
        fronting_domain=$(read_fronting_domain)

        menu_clear
        echo ""
        echo "=== Vi-MTProxy (Docker) ==="
        echo "Режим: $mode_label"
        if [[ -n "$fronting_domain" ]]; then
            echo "Managed fronting domain: $fronting_domain"
        fi
        if warp_enabled; then
            echo "WARP: ВКЛ"
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
    echo "=== Vi-MTProxy Setup (Docker) ==="
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

    rewrite_all_clients

    echo "EU-сервер привязан: $eu_ip"
    echo "Все контейнеры перезапущены."
    exit 0
fi

main_menu
