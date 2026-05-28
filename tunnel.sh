#!/usr/bin/env bash
set -euo pipefail

# ─── Константы ────────────────────────────────────────────────────────────────
GOST_BIN="/usr/local/bin/gost"
GOST_SERVICE="/etc/systemd/system/gost-tunnel.service"
WARP_SOCKS="127.0.0.1:40000"
LOG_FILE="/var/log/tunnel-setup.log"

# ─── Утилиты ──────────────────────────────────────────────────────────────────
die() { echo "ОШИБКА: $*" >&2; exit 1; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
step() { echo ""; echo "=== $* ==="; log "Шаг: $*"; }

check_root() {
    [[ "$EUID" -ne 0 ]] && die "Запустите скрипт от root: sudo bash $0"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Не удалось определить ОС. Поддерживаются Debian/Ubuntu."
    fi
    source /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        die "Неподдерживаемый дистрибутив: $ID. Поддерживаются Debian/Ubuntu."
    fi
    log "ОС: $PRETTY_NAME"
}

# ─── Установка зависимостей ──────────────────────────────────────────────────
install_dependencies() {
    step "Установка зависимостей"
    apt-get update -qq
    apt-get install -y curl wget ufw gnupg lsb-release jq
    log "Зависимости установлены"
}

# ─── Установка gost ───────────────────────────────────────────────────────────
install_gost_binary() {
    step "Проверка gost"

    if [[ -x "$GOST_BIN" ]]; then
        log "gost уже установлен: $("$GOST_BIN" -V 2>&1 | head -1)"
        echo "gost уже установлен"
        return 0
    fi

    log "Скачиваю gost..."
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) die "Неподдерживаемая архитектура: $arch" ;;
    esac
    echo "Архитектура: $arch"

    local api_url="https://api.github.com/repos/ginuerzh/gost/releases/latest"
    echo "Получаю информацию о релизе gost..."
    local release_json
    release_json=$(curl -sSf "$api_url") || die "Не удалось получить информацию о релизе gost"

    local download_url
    download_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("linux.*'"$arch"'.*\\.tar\\.gz$")) | .browser_download_url' | head -1)

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        download_url=$(echo "$release_json" \
            | grep -o '"browser_download_url": *"[^"]*"' \
            | grep -o 'https://[^"]*' \
            | grep "linux" \
            | grep "$arch" \
            | grep '\.tar\.gz$' \
            | head -1)
    fi

    [[ -z "$download_url" ]] && die "Не найден подходящий релиз gost для linux/$arch"
    echo "Скачиваю: $download_url"

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN

    curl -sSfL "$download_url" -o "$tmpdir/gost.tar.gz" || die "Ошибка скачивания gost"
    tar -xzf "$tmpdir/gost.tar.gz" -C "$tmpdir"

    local bin
    bin=$(find "$tmpdir" -type f -name "gost" | head -1)
    [[ -z "$bin" ]] && die "Бинарник gost не найден в архиве"

    cp "$bin" "$GOST_BIN"
    chmod +x "$GOST_BIN"
    echo "gost установлен: $("$GOST_BIN" -V 2>&1 | head -1)"
    log "gost установлен"
}

# ─── Установка WARP ──────────────────────────────────────────────────────────
install_warp() {
    step "Проверка WARP"

    if command -v warp-cli &>/dev/null; then
        echo "WARP уже установлен"
        log "WARP уже установлен"
        return 0
    fi

    log "Устанавливаю WARP..."
    echo "Устанавливаю Cloudflare WARP..."

    # Добавляем ключ и репозиторий
    echo "Добавляю репозиторий Cloudflare..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null

    echo "Обновляю списки пакетов..."
    apt-get update -qq

    echo "Устанавливаю cloudflare-warp..."
    apt-get install -y cloudflare-warp || die "Ошибка установки cloudflare-warp"

    echo "WARP установлен"
    log "WARP установлен"
}

# ─── Настройка WARP ──────────────────────────────────────────────────────────
configure_warp() {
    step "Настройка WARP"

    # Проверяем текущий статус
    local current_status
    current_status=$(warp-cli status 2>/dev/null || echo "Unknown")
    echo "Текущий статус WARP: $current_status"

    if echo "$current_status" | grep -q "Connected"; then
        echo "WARP уже подключен"
        log "WARP уже подключен"
        return 0
    fi

    # Регистрация
    if ! echo "$current_status" | grep -q "Registered"; then
        echo "Регистрирую WARP..."
        log "Регистрация WARP..."
        warp-cli registration new || die "Ошибка регистрации WARP"
        echo "WARP зарегистрирован"
    else
        echo "WARP уже зарегистрирован"
    fi

    # Переключаем в proxy режим
    echo "Переключаю в proxy режим..."
    warp-cli mode proxy || die "Ошибка переключения WARP в proxy режим"

    # Подключаем
    echo "Подключаю WARP..."
    warp-cli connect || die "Ошибка подключения WARP"

    # Ждем подключения
    echo "Ожидаю подключения WARP (до 30 секунд)..."
    local attempts=0
    while (( attempts < 15 )); do
        if warp-cli status 2>/dev/null | grep -q "Connected"; then
            echo "WARP подключен!"
            log "WARP подключен"
            return 0
        fi
        sleep 2
        (( attempts++ ))
        echo "Попытка $attempts/15..."
    done

    die "WARP не подключился за 30 секунд. Проверьте: warp-cli status"
}

# ─── Проверка порта WARP ─────────────────────────────────────────────────────
check_warp_port() {
    step "Проверка порта WARP"

    echo "Проверяю порт 40000..."
    local attempts=0
    while (( attempts < 15 )); do
        if ss -lntp 2>/dev/null | grep -q "127.0.0.1:40000"; then
            echo "WARP proxy слушает на 127.0.0.1:40000"
            log "Порт 40000 активен"
            return 0
        fi
        sleep 2
        (( attempts++ ))
        echo "Попытка $attempts/15..."
    done

    die "WARP proxy не слушает на 127.0.0.1:40000 через 30 секунд"
}

# ─── Создать туннель ──────────────────────────────────────────────────────────
create_tunnel() {
    if [[ -f "$GOST_SERVICE" ]]; then
        echo "Туннель уже установлен. Сначала удалите его (пункт 3)."
        return 0
    fi

    step "Создание туннеля"

    check_os
    install_dependencies
    install_warp
    configure_warp
    check_warp_port
    install_gost_binary

    step "Настройка firewall"
    ufw allow 1080/tcp > /dev/null 2>&1 || true
    ufw --force enable > /dev/null 2>&1 || true
    echo "Порт 1080 открыт"

    step "Создание systemd сервиса"
    cat > "$GOST_SERVICE" <<EOF
[Unit]
Description=Gost SOCKS5 Tunnel (→ WARP)
After=network.target

[Service]
ExecStart=$GOST_BIN -L=socks5://:1080 -F=socks5://$WARP_SOCKS
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now gost-tunnel
    echo "Сервис gost-tunnel создан и запущен"

    # Проверяем что gost запустился
    sleep 2
    if ! systemctl is-active --quiet gost-tunnel; then
        echo "ОШИБКА: Сервис gost-tunnel не запустился"
        echo "Логи: journalctl -u gost-tunnel -n 20"
        journalctl -u gost-tunnel -n 20
        die "Сервис gost-tunnel не запустился"
    fi

    log "Туннель создан и запущен"

    echo ""
    echo "============================================================"
    echo "Туннель создан!"
    echo "gost слушает SOCKS5 на порту 1080."
    echo "Трафик форвардится через WARP."
    echo ""
    echo "Вернитесь на RU-сервер — каскад готов к работе."
    echo "============================================================"
}

# ─── Статус туннеля ───────────────────────────────────────────────────────────
tunnel_status() {
    echo ""
    echo "--- WARP ---"
    warp-cli status 2>/dev/null || echo "warp-cli не найден."
    echo ""
    echo "--- gost-tunnel ---"
    systemctl status gost-tunnel --no-pager -l 2>/dev/null || echo "Сервис не найден."
    echo ""
    echo "--- Порт 1080 ---"
    if ss -lntp 2>/dev/null | grep -q ":1080"; then
        echo "SOCKS5 слушает на порту 1080"
    else
        echo "Порт 1080 не слушается"
    fi
}

# ─── Удалить туннель ──────────────────────────────────────────────────────────
delete_tunnel() {
    read -rp "Удалить туннель? Это действие необратимо. [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }

    step "Удаление туннеля"

    systemctl stop gost-tunnel 2>/dev/null || true
    systemctl disable gost-tunnel 2>/dev/null || true
    rm -f "$GOST_SERVICE"
    rm -f "$GOST_BIN"
    ufw delete allow 1080/tcp > /dev/null 2>&1 || true

    echo "Отключаю WARP..."
    warp-cli disconnect 2>/dev/null || true
    warp-cli registration delete 2>/dev/null || true
    apt-get remove -y cloudflare-warp 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    systemctl daemon-reload
    echo "Туннель удалён."
    log "Туннель удалён"
    exit 0
}

# ─── Удалить всё ─────────────────────────────────────────────────────────────
delete_all() {
    read -rp "Удалить всё (gost + WARP + пакеты)? Это действие необратимо. [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }

    step "Удаление всего"

    systemctl stop gost-tunnel 2>/dev/null || true
    systemctl disable gost-tunnel 2>/dev/null || true
    rm -f "$GOST_SERVICE"
    rm -f "$GOST_BIN"
    ufw delete allow 1080/tcp > /dev/null 2>&1 || true

    echo "Отключаю и удаляю WARP..."
    warp-cli disconnect 2>/dev/null || true
    warp-cli registration delete 2>/dev/null || true
    apt-get remove -y cloudflare-warp 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    # Удаляем лог
    rm -f "$LOG_FILE"

    systemctl daemon-reload
    echo "Всё удалено."
    log "Всё удалено"
    exit 0
}

# ─── Главное меню ─────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        echo ""
        echo "=== MTProxy Tunnel (EU) ==="
        echo "1) Создать туннель (установить gost + WARP)"
        echo "2) Статус туннеля"
        echo "3) Удалить туннель"
        echo "4) Удалить всё (gost + WARP + пакеты)"
        echo "0) Выход"
        echo ""
        read -rp "Выбор: " choice
        case "$choice" in
            1) create_tunnel ;;
            2) tunnel_status ;;
            3) delete_tunnel ;;
            4) delete_all ;;
            0) exit 0 ;;
            *) echo "Неверный выбор." ;;
        esac
    done
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
check_root
mkdir -p "$(dirname "$LOG_FILE")"
main_menu
