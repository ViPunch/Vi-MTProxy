#!/usr/bin/env bash
set -euo pipefail

# ─── Константы ────────────────────────────────────────────────────────────────
MTG_DIR="/etc/mtg"
MTG_BIN="/usr/local/bin/mtg"
CLIENTS_CONF="$MTG_DIR/clients.conf"
MODE_FILE="$MTG_DIR/mode"
EU_IP_FILE="$MTG_DIR/eu_ip"

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

# Очищаем экран перед отрисовкой меню. Вывод действий показывается до
# следующей перерисовки и удерживается паузой "Нажмите Enter".
menu_clear() { clear 2>/dev/null || printf '\033[2J\033[H'; }
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

read_mode() {
    cat "$MODE_FILE" 2>/dev/null || echo ""
}

read_eu_ip() {
    cat "$EU_IP_FILE" 2>/dev/null || echo ""
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
        if ! port_in_use "$p"; then
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

    # SNI. Enter / 0 → случайный домен из списка.
    echo ""
    echo "Выберите SNI-домен (Enter — случайный):"
    echo "  0) Случайный из списка"
    local i=1
    for sni in "${SNI_LIST[@]}"; do
        printf " %2d) %-30s" "$i" "$sni"
        if (( i % 2 == 0 )); then echo ""; fi
        (( i++ ))
    done
    echo ""
    echo " 21) Ввести вручную"
    echo ""

    local sni_choice sni_domain
    read -rp "Ваш выбор [0-21]: " sni_choice
    sni_choice="${sni_choice:-0}"
    if [[ "$sni_choice" == "0" ]]; then
        sni_domain="${SNI_LIST[$((RANDOM % ${#SNI_LIST[@]}))]}"
        echo "Выбран случайный SNI: $sni_domain"
    elif [[ "$sni_choice" == "21" ]]; then
        read -rp "Введите домен: " sni_domain
        if [[ -z "$sni_domain" || "$sni_domain" =~ [[:space:]] ]]; then
            echo "Некорректный домен."
            return 1
        fi
    elif [[ "$sni_choice" =~ ^[0-9]+$ ]] && (( sni_choice >= 1 && sni_choice <= 20 )); then
        sni_domain="${SNI_LIST[$((sni_choice - 1))]}"
    else
        echo "Некорректный выбор."
        return 1
    fi

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

    rm -f "$MTG_BIN"
    rm -f /usr/local/bin/vi-mtpro
    rm -f /usr/local/lib/vi-mtpro.sh
    rm -rf "$MTG_DIR"
    echo "Удалено."
    exit 0
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
            echo "6) Удалить всё"
        else
            echo "4) Удалить всё"
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
                    remove_all
                fi
                ;;
            5)
                if [[ "$mode" == "cascade" ]]; then
                    unbind_eu_server; pause
                else
                    echo "Неверный выбор."; sleep 1
                fi
                ;;
            6)
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
    echo "Создаём первого клиента:"
    add_client "default"

    echo ""
    echo "Установка завершена. Режим: одиночный."
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

        menu_clear
        echo ""
        echo "=== MTProxy Setup ==="
        echo "Режим: $mode_label"
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
