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
    apt-get install -y curl wget ufw

    echo "Устанавливаю WARP..."
    bash <(curl -sSL https://gist.githubusercontent.com/hamid-gh98/dc5dd9b0cc5b0412af927b1ccdb294c7/raw/install_warp_proxy.sh) -y \
        || die "Ошибка установки WARP"

    echo "Проверяю WARP..."
    local warp_ip
    warp_ip=$(curl -s --max-time 10 --socks5 "$WARP_SOCKS" https://api.ipify.org 2>/dev/null || echo "")
    if [[ -z "$warp_ip" ]]; then
        die "WARP не работает: не удалось получить IP через socks5://$WARP_SOCKS"
    fi
    echo "WARP работает. Внешний IP через WARP: $warp_ip"

    install_gost_binary

    ufw allow 1080/tcp > /dev/null 2>&1 || true
    ufw --force enable > /dev/null 2>&1 || true

    cat > "$GOST_SERVICE" <<EOF
[Unit]
Description=Gost SOCKS5 Tunnel (→ WARP)
After=network.target warp-proxy.service
Wants=warp-proxy.service

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
    echo "--- warp-proxy ---"
    systemctl status warp-proxy --no-pager -l 2>/dev/null || echo "Сервис не найден."
    echo ""
    echo "--- gost-tunnel ---"
    systemctl status gost-tunnel --no-pager -l 2>/dev/null || echo "Сервис не найден."
}

# ─── Удалить туннель ──────────────────────────────────────────────────────────
delete_tunnel() {
    read -rp "Удалить туннель? Это действие необратимо. [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено."; return; }

    systemctl stop gost-tunnel warp-proxy 2>/dev/null || true
    systemctl disable gost-tunnel warp-proxy 2>/dev/null || true
    rm -f "$GOST_SERVICE"
    rm -f "$GOST_BIN"
    ufw delete allow 1080/tcp > /dev/null 2>&1 || true

    # Удаление WARP
    if command -v warp &>/dev/null; then
        warp u 2>/dev/null || true
    fi

    systemctl daemon-reload
    echo "Туннель удалён."
}

# ─── Главное меню ─────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        echo ""
        echo "=== MTProxy Tunnel (EU) ==="
        echo "1) Создать туннель (установить gost + WARP)"
        echo "2) Статус туннеля"
        echo "3) Удалить туннель"
        echo "0) Выход"
        echo ""
        read -rp "Выбор: " choice
        case "$choice" in
            1) create_tunnel ;;
            2) tunnel_status ;;
            3) delete_tunnel ;;
            0) exit 0 ;;
            *) echo "Неверный выбор." ;;
        esac
    done
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && die "Запустите скрипт от root: sudo bash $0"

main_menu
