#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# 3x-ui + VLESS + XHTTP + REALITY + ML-DSA-65 installer (v5)
# Ubuntu / Debian, fresh VPS recommended.
#
# Optional environment variables:
#   XUI_VERSION=v3.6.0
#   SNI=google.com
#   INBOUND_PORT=55207
#   XHTTP_PATH=/
#   REMARK=my-server
#   TELEGRAM_BOT_TOKEN=123456789:AA...
#   TELEGRAM_CHAT_ID=123456789
# ------------------------------------------------------------

XUI_VERSION="${XUI_VERSION:-v3.6.0}"
XHTTP_PATH="${XHTTP_PATH:-/}"
REMARK="${REMARK:-vless-xhttp-reality}"
[[ "$XHTTP_PATH" == /* ]] || XHTTP_PATH="/$XHTTP_PATH"

OFFICIAL_INSTALLER="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh"
XUI_BIN="/usr/local/x-ui/x-ui"
INSTALL_RESULT="/etc/x-ui/install-result.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}OK:${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Запусти скрипт от root: sudo bash $0"
[[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Эта версия скрипта рассчитана на Ubuntu/Debian. Обнаружено: ${ID:-unknown}" ;;
esac

XUI_ALREADY_INSTALLED=0
if [[ -e /etc/x-ui/x-ui.db || -x "$XUI_BIN" ]]; then
  XUI_ALREADY_INSTALLED=1
  log "3x-ui уже установлен — пропускаю установку и продолжаю настройку inbound"
fi

log "Устанавливаю зависимости"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl jq openssl ca-certificates iproute2

random_alnum() {
  local len="$1" raw
  raw="$(openssl rand -hex "$len")"
  printf '%s' "${raw:0:$len}"
}

port_is_busy() {
  local p="$1"
  ss -ltnH 2>/dev/null | awk -v p="$p" '$4 ~ (":" p "$") {found=1} END {exit !found}'
}

random_free_port() {
  local p
  for _ in $(seq 1 100); do
    p=$(shuf -i 20000-60000 -n 1)
    if ! port_is_busy "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

SERVER_IP=""
for url in \
  https://api4.ipify.org \
  https://ipv4.icanhazip.com \
  https://4.ident.me; do
  SERVER_IP=$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    break
  fi
  SERVER_IP=""
done
[[ -n "$SERVER_IP" ]] || die "Не удалось определить публичный IPv4 сервера"
ok "Публичный IP: $SERVER_IP"

if (( XUI_ALREADY_INSTALLED == 0 )); then
  PANEL_USER="$(random_alnum 12)"
  PANEL_PASS="$(random_alnum 20)"
  PANEL_PATH="$(random_alnum 20)"
  PANEL_PORT="$(random_free_port)" || die "Не удалось подобрать свободный порт панели"

  log "Устанавливаю 3x-ui ${XUI_VERSION} через официальный installer"
  curl -fsSL "$OFFICIAL_INSTALLER" | env \
    XUI_NONINTERACTIVE=1 \
    XUI_USERNAME="$PANEL_USER" \
    XUI_PASSWORD="$PANEL_PASS" \
    XUI_PANEL_PORT="$PANEL_PORT" \
    XUI_WEB_BASE_PATH="$PANEL_PATH" \
    XUI_SSL_MODE=none \
    XUI_DB_TYPE=sqlite \
    XUI_ENABLE_FAIL2BAN=false \
    XUI_SERVER_IP="$SERVER_IP" \
    bash -s -- "$XUI_VERSION"
else
  ok "Использую существующий 3x-ui"
fi

[[ -x "$XUI_BIN" ]] || die "3x-ui не найден: $XUI_BIN отсутствует"
[[ -r "$INSTALL_RESULT" ]] || die "Не найден $INSTALL_RESULT (нужен API token от установки 3x-ui)"

# The official installer writes shell-escaped values here with mode 600.
# shellcheck disable=SC1090
source "$INSTALL_RESULT"

: "${XUI_PANEL_PORT:?XUI_PANEL_PORT missing}"
: "${XUI_WEB_BASE_PATH:?XUI_WEB_BASE_PATH missing}"
: "${XUI_API_TOKEN:?XUI_API_TOKEN missing}"

BASE_PATH="${XUI_WEB_BASE_PATH#/}"
BASE_PATH="${BASE_PATH%/}"
API_BASE="http://127.0.0.1:${XUI_PANEL_PORT}/${BASE_PATH}"

# Do not expose the plain-HTTP admin panel to the Internet.
log "Привязываю web-панель к localhost"
"$XUI_BIN" setting -listenIP "127.0.0.1" >/dev/null
systemctl restart x-ui

for _ in $(seq 1 30); do
  if systemctl is-active --quiet x-ui; then
    break
  fi
  sleep 1
done
systemctl is-active --quiet x-ui || die "x-ui не запустился"

case "$(uname -m)" in
  x86_64|amd64) XRAY_ARCH="amd64" ;;
  aarch64|arm64) XRAY_ARCH="arm64" ;;
  *) die "Пока поддерживаются amd64 и arm64. Архитектура: $(uname -m)" ;;
esac
XRAY="/usr/local/x-ui/bin/xray-linux-${XRAY_ARCH}"
[[ -x "$XRAY" ]] || die "Xray binary не найден: $XRAY"

log "Генерирую UUID и REALITY ключи через API 3x-ui"
UUID="$($XRAY uuid | head -n1 | tr -d '[:space:]')"
[[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || UUID="$(cat /proc/sys/kernel/random/uuid)"

api_get() {
  local path="$1"
  curl -fsS --max-time 15 \
    -H "Authorization: Bearer ${XUI_API_TOKEN}" \
    -H 'Accept: application/json' \
    "${API_BASE}${path}"
}

X25519_JSON="$(api_get '/panel/api/server/getNewX25519Cert')" \
  || die "3x-ui API: не удалось сгенерировать X25519 ключи"

if [[ "$(jq -r '.success // false' <<<"$X25519_JSON")" != "true" ]]; then
  echo "$X25519_JSON" | jq . 2>/dev/null || echo "$X25519_JSON"
  die "3x-ui API не сгенерировал X25519 ключи"
fi

PRIVATE_KEY="$(jq -r '.obj.privateKey // empty' <<<"$X25519_JSON")"
PUBLIC_KEY="$(jq -r '.obj.publicKey // empty' <<<"$X25519_JSON")"

if [[ ${#PRIVATE_KEY} -ne 43 || ${#PUBLIC_KEY} -ne 43 ]]; then
  echo "3x-ui X25519 API diagnostics:" >&2
  echo "  privateKey length: ${#PRIVATE_KEY}" >&2
  echo "  publicKey length: ${#PUBLIC_KEY}" >&2
  die "Некорректный ответ getNewX25519Cert"
fi
ok "X25519 ключи сгенерированы через 3x-ui API"

MLDSA_JSON="$(api_get '/panel/api/server/getNewmldsa65')" \
  || die "3x-ui API: не удалось сгенерировать ML-DSA-65 ключи"

if [[ "$(jq -r '.success // false' <<<"$MLDSA_JSON")" != "true" ]]; then
  echo "$MLDSA_JSON" | jq . 2>/dev/null || echo "$MLDSA_JSON"
  die "3x-ui API не сгенерировал ML-DSA-65 ключи"
fi

MLDSA_SEED="$(jq -r '.obj.seed // empty' <<<"$MLDSA_JSON")"
MLDSA_VERIFY="$(jq -r '.obj.verify // empty' <<<"$MLDSA_JSON")"

if [[ -z "$MLDSA_SEED" || -z "$MLDSA_VERIFY" ]]; then
  echo "3x-ui ML-DSA-65 API diagnostics:" >&2
  echo "  seed length: ${#MLDSA_SEED}" >&2
  echo "  verify length: ${#MLDSA_VERIFY}" >&2
  die "Некорректный ответ getNewmldsa65"
fi
ok "ML-DSA-65 ключи сгенерированы через 3x-ui API"

SHORT_ID="$(openssl rand -hex 2)"
CLIENT_EMAIL="client-$(openssl rand -hex 3)"

# With ML-DSA-65, REALITY target certificate chain should be > 3500 bytes.
check_sni() {
  local domain="$1" out cert_len
  out="$($XRAY tls ping "$domain" 2>&1 || true)"
  cert_len="$(awk -F': +' '/Certificate chain.s total length:/ {print $2}' <<<"$out" | awk '{print $1}' | tail -n1)"
  [[ "$cert_len" =~ ^[0-9]+$ ]] || return 1
  (( cert_len > 3500 )) || return 1
  grep -q "Handshake succeeded" <<<"$out" || return 1
  echo "$cert_len"
}

if [[ -n "${SNI:-}" ]]; then
  log "Проверяю указанный REALITY SNI: $SNI"
  CERT_LEN="$(check_sni "$SNI")" || die "SNI '$SNI' не прошёл проверку для ML-DSA-65 (нужен успешный TLS handshake и chain > 3500 bytes)"
else
  SNI=""
  for candidate in google.com github.io; do
    log "Проверяю REALITY target: $candidate"
    if CERT_LEN="$(check_sni "$candidate")"; then
      SNI="$candidate"
      break
    fi
  done
  [[ -n "$SNI" ]] || die "Не нашёл подходящий REALITY target. Запусти с SNI=your-domain.example"
fi
ok "REALITY target: ${SNI}:443, certificate chain: ${CERT_LEN} bytes"
REALITY_TARGET="${SNI}:443"

if [[ -n "${INBOUND_PORT:-}" ]]; then
  [[ "$INBOUND_PORT" =~ ^[0-9]+$ ]] || die "INBOUND_PORT должен быть числом"
  (( INBOUND_PORT >= 1 && INBOUND_PORT <= 65535 )) || die "Некорректный INBOUND_PORT"
  port_is_busy "$INBOUND_PORT" && die "Порт $INBOUND_PORT уже занят"
else
  INBOUND_PORT="$(random_free_port)" || die "Не удалось подобрать свободный inbound port"
fi

log "Создаю VLESS + XHTTP + REALITY inbound на порту ${INBOUND_PORT}"
PAYLOAD="$(jq -nc \
  --arg uuid "$UUID" \
  --arg email "$CLIENT_EMAIL" \
  --argjson port "$INBOUND_PORT" \
  --arg path "$XHTTP_PATH" \
  --arg sni "$SNI" \
  --arg target "$REALITY_TARGET" \
  --arg privateKey "$PRIVATE_KEY" \
  --arg publicKey "$PUBLIC_KEY" \
  --arg sid "$SHORT_ID" \
  --arg seed "$MLDSA_SEED" \
  --arg verify "$MLDSA_VERIFY" \
  --arg remark "$REMARK" \
  '{
    enable: true,
    remark: $remark,
    listen: "",
    port: $port,
    protocol: "vless",
    expiryTime: 0,
    total: 0,
    settings: {
      clients: [{
        id: $uuid,
        flow: "",
        email: $email,
        limitIp: 0,
        totalGB: 0,
        expiryTime: 0,
        enable: true,
        tgId: "",
        subId: "",
        reset: 0
      }],
      decryption: "none",
      encryption: "none"
    },
    streamSettings: {
      network: "xhttp",
      security: "reality",
      externalProxy: [],
      realitySettings: {
        show: false,
        xver: 0,
        target: $target,
        serverNames: [$sni],
        privateKey: $privateKey,
        minClientVer: "",
        maxClientVer: "",
        maxTimediff: 0,
        shortIds: [$sid],
        mldsa65Seed: $seed,
        settings: {
          publicKey: $publicKey,
          fingerprint: "chrome",
          serverName: $sni,
          spiderX: "/",
          mldsa65Verify: $verify
        }
      },
      xhttpSettings: {
        path: $path,
        host: "",
        mode: "auto",
        xPaddingBytes: "100-1000",
        scMaxEachPostBytes: "1000000",
        scMaxBufferedPosts: 30,
        scStreamUpServerSecs: "20-80",
        headers: {}
      }
    },
    sniffing: {
      enabled: true,
      destOverride: ["http", "tls", "quic"],
      metadataOnly: false,
      routeOnly: false
    }
  }')"

RESPONSE="$(curl -fsS \
  -X POST "${API_BASE}/panel/api/inbounds/add" \
  -H "Authorization: Bearer ${XUI_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data-binary "$PAYLOAD")" || die "3x-ui API вернул HTTP ошибку"

if [[ "$(jq -r '.success // false' <<<"$RESPONSE")" != "true" ]]; then
  echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
  die "3x-ui не создал inbound"
fi

# Verify that Xray actually started listening on the new inbound.
for _ in $(seq 1 15); do
  port_is_busy "$INBOUND_PORT" && break
  sleep 1
done
if ! port_is_busy "$INBOUND_PORT"; then
  journalctl -u x-ui -n 60 --no-pager >&2 || true
  die "Inbound создан в панели, но Xray не слушает TCP/${INBOUND_PORT}"
fi
ok "Xray слушает TCP/${INBOUND_PORT}"

# If UFW is already active, open only the proxy port.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${INBOUND_PORT}/tcp" >/dev/null
  ok "UFW: открыт TCP/${INBOUND_PORT}"
fi

urlencode() {
  jq -nr --arg v "$1" '$v|@uri'
}

PATH_ENC="$(urlencode "$XHTTP_PATH")"
REMARK_ENC="$(urlencode "$REMARK")"
SPX_ENC="%2F"

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${INBOUND_PORT}?type=xhttp&encryption=none&path=${PATH_ENC}&host=&mode=auto&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=${SPX_ENC}&pqv=${MLDSA_VERIFY}#${REMARK_ENC}"

printf '%s\n' "$VLESS_LINK" > /root/vless.txt
chmod 600 /root/vless.txt

# Optional Telegram delivery. Do not hardcode the bot token in a public repo.
send_vless_to_telegram() {
  local response

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0
  fi

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    warn "Telegram: нужны обе переменные TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID; отправка пропущена"
    return 0
  fi

  log "Отправляю VLESS ссылку в Telegram"

  response="$(curl -fsS --max-time 15 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${VLESS_LINK}" \
    2>/dev/null)" || {
      warn "Telegram: не удалось отправить VLESS ссылку"
      return 0
    }

  if [[ "$(jq -r '.ok // false' <<<"$response" 2>/dev/null)" == "true" ]]; then
    ok "VLESS ссылка отправлена в Telegram"
  else
    warn "Telegram API не подтвердил отправку ссылки"
  fi
}

send_vless_to_telegram

cat <<EOF

${GREEN}============================================================${NC}
${GREEN} ГОТОВО${NC}
${GREEN}============================================================${NC}

VLESS link:

${VLESS_LINK}

Ссылка также сохранена в:
  /root/vless.txt

Параметры:
  Server:     ${SERVER_IP}
  Port:       ${INBOUND_PORT}
  UUID:       ${UUID}
  Transport:  XHTTP
  Path:       ${XHTTP_PATH}
  Mode:       auto
  Security:   REALITY
  SNI:        ${SNI}
  Short ID:   ${SHORT_ID}
  ML-DSA-65:  enabled

3x-ui установлен, но web-панель слушает только 127.0.0.1.
Для доступа с компьютера сделай SSH tunnel:

  ssh -L ${XUI_PANEL_PORT}:127.0.0.1:${XUI_PANEL_PORT} root@${SERVER_IP}

и открой:

  http://127.0.0.1:${XUI_PANEL_PORT}/${BASE_PATH}/

Panel username: ${XUI_USERNAME}
Panel password: ${XUI_PASSWORD}

${YELLOW}Важно:${NC} если у VPS есть firewall/security group у провайдера,
разреши входящий TCP порт ${INBOUND_PORT}.
EOF
