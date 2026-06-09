# Vi-MTProxy (Cascade + WARP)

[🇬🇧 English](#english) | [🇷🇺 Русский](#русский)

---

<a name="english"></a>

A quick installation of MTProxy in Docker containers with cascade support via WARP and masquerading as a normal HTTPS site.

Two operating modes:
- **Single** — one VPS. Optionally, Telegram traffic goes through a local Cloudflare WARP.
- **Cascade** — First-server → Second-server → WARP → Telegram (bypass blocking).

## Domain Fronting Masquerading

The proxy masquerades as a regular HTTPS site:

1. mtg (`nineseconds/mtg:2`) listens on port **443** (or custom port).
2. The Telegram client connects with the correct `secret` → mtg proxies to Telegram.
3. Any other traffic (browser, DPI scanner) → mtg redirects to **Nginx** with a stub site.
4. Nginx serves a legitimate HTTPS response with a Let's Encrypt SSL certificate.
5. For traffic analysis systems (DPI), the server looks like a standard HTTPS website.

During installation, **3 stub designs** are available:
- Spinning Loader
- Pulse Loader
- Progress Bar

## Client Types

- **Managed fronting** — uses your domain with SSL. Domain fronting: non-Telegram traffic → Nginx with a stub site.
- **External FakeTLS** — uses an external domain (google.com, etc.) as a TLS mask. Does not require your own domain.

## Links

If a managed domain is available, links are generated with the domain:
```
tg://proxy?server=proxy.example.com&port=443&secret=...
```

---

## Quick Start

### First Server (Main)

```bash
bash <(curl -sSL https://raw.githubusercontent.com/ViPunch/Vi-MTProxy/master/setup.sh)
```

On first run:
1. Select the mode — single or cascade.
2. Configure Managed fronting domain (domain, email for SSL, stub design).
3. The script will install Docker, pull `nineseconds/mtg:2`, and set up Nginx + Let's Encrypt.
4. Create the first client and generate the Telegram link.

After installation, manage the proxy with a single command:

```bash
vi-mtpro
```

---

### Second Server (Cascade Mode Only)

```bash
bash <(curl -sSL https://raw.githubusercontent.com/ViPunch/Vi-MTProxy/master/tunnel.sh)
```

The script will install WARP and gost, and start a SOCKS5 tunnel on port 1080. After that, return to the First Server — the cascade will start working.

---

## Features of setup.sh

- Runs mtg in isolated **Docker containers**.
- Configures **Managed fronting domain** with automatic HTTPS and a stub website.
- Supports two client types: **Managed fronting** and **External FakeTLS**.
- Asks if a website already exists on the server (does not touch existing nginx).
- Shows ready-to-use `tg://` links with **domains** for all clients.
- Runs `mtg doctor` after client creation.
- Links and unlinks EU server without client recreation.
- Updates mtg (`docker pull` of the new image).
- Enables/disables local WARP.
- Deletes individual clients or everything completely.

## Features of tunnel.sh

- Installs WARP and gost with a single command.
- Shows tunnel status.
- Completely removes the tunnel.

---

## Requirements

- Ubuntu 24.04 / Debian
- Root access
- Docker (installed automatically)
- For managed fronting domain: the domain must be pre-configured to resolve to your server's IP.

---

<a name="русский"></a>
# Vi-MTPro (Docker + Cascade + WARP)

Быстрая установка MTProxy в Docker-контейнерах с поддержкой каскада через WARP и маскировкой под обычный HTTPS-сайт.

Два режима работы:
- **Одиночный** — один VPS. По желанию трафик в Telegram идёт через локальный Cloudflare WARP
- **Каскад** — Первый-сервер → Второй-сервер → WARP → Telegram (обход блокировок)

## Маскировка (Domain Fronting)

Прокси маскируется под обычный HTTPS-сайт:

1. mtg (`nineseconds/mtg:2`) слушает на порту **443** (или пользовательском)
2. Telegram-клиент подключается с правильным `secret` → mtg проксирует в Telegram
3. Любой другой трафик (браузер, DPI-сканер) → mtg перенаправляет на **Nginx** с заглушкой
4. Nginx отдаёт легитимный HTTPS-ответ с SSL-сертификатом Let's Encrypt
5. Для систем анализа трафика (DPI) сервер выглядит как обычный HTTPS веб-сайт

При установке доступны **3 дизайна заглушки** на выбор:
- Вращающийся круг (Spinning Loader)
- Пульсирующая точка (Pulse Loader)
- Линия загрузки (Progress Bar)

## Типы клиентов

- **Managed fronting** — использует ваш домен с SSL. Domain fronting: не-Telegram трафик → Nginx с заглушкой
- **External FakeTLS** — использует внешний домен (google.com и т.д.) как TLS-маску. Не требует свой домен

## Ссылки

При наличии managed domain ссылки формируются с доменом:
```
tg://proxy?server=proxy.example.com&port=443&secret=...
```

---

## Быстрый старт

### Первый-сервер (основной)

```bash
bash <(curl -sSL https://raw.githubusercontent.com/ViPunch/Vi-MTProxy/master/setup.sh)
```

При первом запуске:
1. Выберите режим — одиночный или каскад
2. Настройте Managed fronting domain (домен, email для SSL, дизайн заглушки)
3. Скрипт установит Docker, загрузит `nineseconds/mtg:2`, настроит Nginx + Let's Encrypt
4. Создаст первого клиента и выдаст ссылку для Telegram

После установки управляйте прокси одной командой:

```bash
vi-mtpro
```

---

### Второй-сервер (только для режима каскада)

```bash
bash <(curl -sSL https://raw.githubusercontent.com/ViPunch/Vi-MTProxy/master/tunnel.sh)
```

Скрипт установит WARP и gost, поднимет SOCKS5-туннель на порту 1080. После этого вернитесь на Первый-сервер — каскад заработает.

---

## Что умеет setup.sh

- Запускать mtg в изолированных **Docker-контейнерах**
- Настраивать **Managed fronting domain** с автоматическим HTTPS и сайтом-заглушкой
- Поддерживать два типа клиентов: **Managed fronting** и **External FakeTLS**
- Спрашивать, есть ли уже сайт на сервере (не трогает существующий nginx)
- Показывать готовые `tg://` ссылки с **доменом** для всех клиентов
- Прогонять `mtg doctor` после создания клиента
- Привязывать и отвязывать EU-сервер без пересоздания клиентов
- Обновлять mtg (`docker pull` нового образа)
- Включать/выключать локальный WARP
- Удалять отдельных клиентов или всё целиком

## Что умеет tunnel.sh

- Устанавливать WARP и gost одной командой
- Показывать статус туннеля
- Полностью удалять туннель

---

## Требования

- Ubuntu 24.04 / Debian
- Root-доступ
- Docker (устанавливается автоматически)
- Для managed fronting-domain: домен должен заранее резолвиться в IP вашего сервера
