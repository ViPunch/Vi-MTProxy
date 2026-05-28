#!/usr/bin/env bash
set -euo pipefail

# ─── Константы ────────────────────────────────────────────────────────────────
GOST_BIN="/usr/local/bin/gost"
GOST_SERVICE="/etc/systemd/system/gost-tunnel.service"
WARP_SOCKS="127.0.0.1:40000"

# ─── Утилиты ──────────────────────────────────────────────────────────────────
die() { echo "ОШИБКА: $*" >&2; exit 1; }

# ─── Установка gost ───────────────────────────────────────────────────────────
install_gost_binary() {
    echo "Скачиваю gost..."
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) die "Неподдерживаемая архитектура: $arch" ;;
    esac

    local api_url="https://api.github.com/repos/ginuerzh/gost/releases/latest"
    local release_json
    release_json=$(curl -sSf "$api_url") || die "Не удалось получить информацию о релизе gost"

    local download_url
    download_url=$(echo "$release_json" \
        | grep -o '"browser_download_url": *"[^"]*"' \
        | grep -o 'https://[^"]*' \
        | grep "linux" \
        | grep "$arch" \
        | grep '\.tar\.gz$' \
        | head -1)

    [[ -z "$download_url" ]] && die "Не найден подходящий релиз gost для linux/$arch"

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    curl -sSfL "$download_url" -o "$tmpdir/gost.tar.gz" || die "Ошибка скачивания gost"
    tar -xzf "$tmpdir/gost.tar.gz" -C "$tmpdir"

    local bin
    bin=$(find "$tmpdir" -type f -name "gost" | head -1)
    [[ -z "$bin" ]] && die "Бинарник gost не найден в архиве"

    cp "$bin" "$GOST_BIN"
    chmod +x "$GOST_BIN"
    echo "gost установлен: $("$GOST_BIN" -V 2>&1 | head -1)"
}

# ─── Создать туннель ──────────────────────────────────────────────────────────
create_tunnel() {
    if [[ -f "$GOST_SERVICE" ]]; then
        echo "Туннель уже установлен. Сначала удалите его (пункт 3)."
        return
    fi

    echo "Устанавливаю зависимости..."
    apt-get update -qq
    apt-get install -y curl wget ufw gnupg lsb-release

    echo "Устанавливаю WARP..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
    apt-get update -qq
    apt-get install -y cloudflare-warp

    echo "Инициализирую WARP..."
    warp-cli registration new
    warp-cli mode proxy
    warp-cli connect

    echo "Проверяю WARP..."
    local attempts=0
    while (( attempts < 10 )); do
        if warp-cli status 2>/dev/null | grep -q "Connected"; then
            break
        fi
        sleep 2
        (( attempts++ ))
    done
    if ! warp-cli status 2>/dev/null | grep -q "Connected"; then
        die "WARP не подключился. Проверьте: warp-cli status"
    fi

    echo "Проверяю порт 40000..."
    local port_attempts=0
    while (( port_attempts < 10 )); do
        if ss -lntp 2>/dev/null | grep -q "127.0.0.1:40000"; then
            break
        fi
        sleep 2
        (( port_attempts++ ))
    done
    if ! ss -lntp 2>/dev/null | grep -q "127.0.0.1:40000"; then
        die "WARP proxy не слушает на 127.0.0.1:40000"
    fi
    echo "WARP работает на 127.0.0.1:40000"

    install_gost_binary

    ufw allow 1080/tcp > /dev/null 2>&1 || true
    ufw --force enable > /dev/null 2>&1 || true

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

    echo ""
    echo "============================================================"
    echo "Туннель создан."
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
}

# ─── Удалить туннель ──────────────────────────────────────────────────────────
delete_tunnel() {
    read -rp "Удалить туннель? Это действие необратимо. [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }

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
    exit 0
}

# ─── Удалить всё ─────────────────────────────────────────────────────────────
delete_all() {
    read -rp "Удалить всё (gost + WARP + пакеты)? Это действие необратимо. [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }

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

    systemctl daemon-reload
    echo "Всё удалено."
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
[[ "$EUID" -ne 0 ]] && die "Запустите скрипт от root: sudo bash $0"

main_menu
