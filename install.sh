#!/opt/bin/sh
# =============================================================================
#  dropweb-xkeen v2 — VPN dropweb на Keenetic через XKeen 2 + mihomo
#
#  Что делает скрипт:
#    1. Проверяет Entware/OPKG и доставляет curl, python3, unzip, cron
#       (один opkg update на всё)
#    2. Спрашивает только ссылку на подписку из бота dropweb. HWID, модель,
#       порты и секрет API считаются сами и хранятся в
#       /opt/etc/dropweb-xkeen/settings.env (HWID переносится из v1)
#    3. Проверяет подписку ДО установки (заглушка = лимит устройств)
#    4. Ставит/обновляет XKeen 2 и mihomo без вопросов, включает ядро mihomo
#    5. Собирает конфиг из подписки: TCP через REDIRECT :1182 + UDP через
#       TPROXY :1181 (listeners), TUN выключен; ставит zashboard (с секретом)
#    6. Ставит веб-панель (файлы panel/ из репозитория): VPN вкл/выкл, проверка
#       связи, срок подписки, «Обновить сейчас», смена ссылки, подсказка с одной
#       кнопкой, когда подписка упёрлась в лимит устройств или кончилась, и
#       раздел «Обновление»
#    7. Ежечасно обновляет подписку (по содержимому, с горячей перезагрузкой;
#       если основной адрес недоступен — через запасные из заголовков
#       подписки) и ставит watchdog
#    8. Обновляет сам себя с GitHub: ночью по cron (AUTO_UPDATE=1) или кнопкой
#       в панели. /opt/sbin/dropweb-xkeen-update.sh запускает install.sh новой
#       версии и, если после него VPN или панель не работают, возвращает
#       прежнюю версию из снимка
#    9. Пускает игры и прочий UDP мимо mihomo: в него идёт только UDP, который
#       правила подписки могут отправить в VPN (QUIC, звонки Telegram,
#       WhatsApp, Discord, Meet), остальной — обычным NAT (UDP_BYPASS=1)
#
#  Использование (на роутере по SSH под root):
#     curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/enkinvsh/dropweb-xkeen/main/install.sh
#     sh /tmp/install.sh                              # спросит ссылку
#     SUB_URL='https://...' sh /tmp/install.sh -y     # без вопросов
#  Повторный запуск = обновление (HWID и ссылка сохраняются).
#  Новая версия выходит, когда в main поднимается DROPWEB_XKEEN_VERSION:
#  роутеры сравнивают её со своей и только тогда обновляются.
#
#  Удаление:
#     /opt/sbin/mihomo-vpn-uninstall.sh
# =============================================================================

set -eu

DROPWEB_XKEEN_VERSION="2.4.1"
SCRIPT_VERSION=$DROPWEB_XKEEN_VERSION

# XKeen иначе уходит в фон и сразу возвращает 0 — нам нужен честный код возврата.
export XKEEN_FOREGROUND=1
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Запоминаем и убираем из окружения: иначе его унаследуют панель и mihomo,
# которых этот скрипт перезапускает.
FROM_UPDATER=${DXK_UPDATE:-0}
unset DXK_UPDATE DXK_SELF_COPY

INSTALL_LOG=/opt/var/log/dropweb-xkeen-install.log
SETTINGS_DIR=/opt/etc/dropweb-xkeen
SETTINGS_FILE=$SETTINGS_DIR/settings.env
LEGACY_UPDATER=/opt/sbin/update-mihomo-sub.sh
LEGACY_PANEL=/opt/sbin/mihomo-panel.py
PANEL_DIR=/opt/share/dropweb-xkeen/panel
DEFAULT_UPDATE_URL=https://raw.githubusercontent.com/enkinvsh/dropweb-xkeen/main
SELF_UPDATER=/opt/sbin/dropweb-xkeen-update.sh
UDP_BYPASS_SH=/opt/sbin/dropweb-udp-bypass.sh
# «zz-»: ndm запускает хуки по алфавиту, наш должен идти после proxy.sh XKeen.
UDP_HOOK=/opt/etc/ndm/netfilter.d/zz-dropweb-udp.sh
XKEEN_INIT=/opt/etc/init.d/S05xkeen
CONF=/opt/etc/mihomo/config.yaml
PRECHECK_FILE=/tmp/dropweb-sub-check.$$
ZASH_TMP=/tmp/dropweb-zash.$$

trap 'rm -rf "$PRECHECK_FILE" "$PRECHECK_FILE.h" "$ZASH_TMP" /tmp/xkeen-install.sh' EXIT

# --- вывод ---
if [ -t 1 ]; then
  C_RED="\033[1;31m"; C_GRN="\033[1;32m"; C_YEL="\033[1;33m"; C_CYN="\033[1;36m"; C_RST="\033[0m"
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_RST=""
fi
# Цвета через %b, текст через %s: в ссылках/секретах бывают обратные слэши.
say()  { printf '%s\n' "$*"; }
hdr()  { printf '%b%s%b\n' "$C_CYN" "$*" "$C_RST"; }
ok()   { printf '%b[OK]%b %s\n' "$C_GRN" "$C_RST" "$*"; }
inf()  { printf '%b[..]%b %s\n' "$C_CYN" "$C_RST" "$*"; }
warn() { printf '%b[!!]%b %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '%b[XX]%b %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
die_log() {
  if [ -f "$INSTALL_LOG" ]; then
    say "--- последние строки $INSTALL_LOG ---" >&2
    tail -n 20 "$INSTALL_LOG" >&2 || true
  fi
  die "$1"
}

# ask "вопрос" "по умолчанию" -> REPLY_VALUE.
# Вопрос идёт в stderr, а ответ в глобальную переменную: вызов через $(...)
# проглатывал текст вопроса и он попадал в ответ (баг v1).
ASK_EOF=0
ask() {
  if [ -n "${2:-}" ]; then
    printf '%s [%s]: ' "$1" "$2" >&2
  else
    printf '%s: ' "$1" >&2
  fi
  REPLY_VALUE=""
  if ! IFS= read -r REPLY_VALUE; then ASK_EOF=1; fi
  [ -n "$REPLY_VALUE" ] || REPLY_VALUE=${2:-}
}

trim() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# Значение в одинарных кавычках для settings.env: ' -> '\''
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

usage() {
  cat <<'EOF_USAGE'
dropweb-xkeen — VPN dropweb на Keenetic через XKeen 2 + mihomo

Запуск (на роутере, под root):
  sh install.sh          спросит ссылку на подписку
  sh install.sh -y       без вопросов (ссылка из SUB_URL или из прошлой установки)
  sh install.sh -h       эта справка

Повторный запуск = обновление: HWID и ссылка сохраняются.

Переменные окружения (все необязательные):
  SUB_URL         ссылка на подписку из бота dropweb (https://...)
  HWID            идентификатор роутера (по умолчанию из MAC LAN, сохраняется)
  DEVICE_OS       заголовок x-device-os (KeeneticOS)
  DEVICE_MODEL    заголовок x-device-model (из ndmc, например «Keenetic Giga (KN-1011)»)
  OS_VERSION      заголовок x-ver-os (версия KeeneticOS из ndmc)
  USER_AGENT_HDR  User-Agent (clash.meta)
  PANEL_PORT      порт веб-панели (8181)
  API_PORT        порт API и дашборда mihomo (9090)
  API_SECRET      секрет API mihomo (генерируется)
  LAN_IP          адрес роутера в LAN (из br0, иначе 192.168.1.1)
  UPDATE_URL      откуда брать обновления и файлы панели: raw-адрес ветки
                  (https://raw.githubusercontent.com/enkinvsh/dropweb-xkeen/main)
  AUTO_UPDATE     1 — обновляться самому ночью (по умолчанию), 0 — только кнопкой
  UDP_BYPASS      1 — UDP, который подписка не шлёт в VPN (игры), мимо mihomo
                  (по умолчанию), 0 — весь UDP через mihomo, как до 2.4.0
  ASSUME_YES=1    то же, что -y

Пример:
  SUB_URL='https://....apigw.yandexcloud.net/...' sh install.sh -y

Удаление: /opt/sbin/mihomo-vpn-uninstall.sh
EOF_USAGE
}

# --- аргументы ---
ASSUME_YES="${ASSUME_YES:-0}"
for arg in "$@"; do
  case "$arg" in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный параметр: $arg (справка: sh install.sh -h)" ;;
  esac
done

# --- окружение ---
[ "$(id -u)" = "0" ] || die "Запускай от root: ssh root@192.168.1.1"
[ -x /opt/bin/opkg ] || die "OPKG/Entware не найден. Поставь Entware на флешку EXT4 — пошагово: https://github.com/enkinvsh/dropweb-xkeen#entware-с-нуля"
mkdir -p /opt/var/log
printf '\n===== dropweb-xkeen %s: %s =====\n' "$SCRIPT_VERSION" "$(date '+%F %T')" >>"$INSTALL_LOG"

INTERACTIVE=0
if [ "$ASSUME_YES" != 1 ]; then
  [ -t 0 ] || die "Нет терминала. Запусти так: SUB_URL='...' sh install.sh -y"
  INTERACTIVE=1
fi

# =============================================================================
# Настройки: env > settings.env > установка v1 > значения по умолчанию
# =============================================================================
ENV_SUB_URL=${SUB_URL:-}
ENV_HWID=${HWID:-}
ENV_DEVICE_OS=${DEVICE_OS:-}
ENV_OS_VERSION=${OS_VERSION:-}
ENV_DEVICE_MODEL=${DEVICE_MODEL:-}
ENV_USER_AGENT_HDR=${USER_AGENT_HDR:-}
ENV_PANEL_PORT=${PANEL_PORT:-}
ENV_API_PORT=${API_PORT:-}
ENV_API_SECRET=${API_SECRET:-}
ENV_LAN_IP=${LAN_IP:-}
ENV_UPDATE_URL=${UPDATE_URL:-}
ENV_AUTO_UPDATE=${AUTO_UPDATE:-}
ENV_UDP_BYPASS=${UDP_BYPASS:-}

SUB_URL=""; HWID=""; DEVICE_OS=""; OS_VERSION=""; DEVICE_MODEL=""
USER_AGENT_HDR=""; PANEL_PORT=""; API_PORT=""; API_SECRET=""; LAN_IP=""
UPDATE_URL=""; AUTO_UPDATE=""; PANEL_SOURCE=""; UDP_BYPASS=""

SETTINGS_ORIGIN="новая установка"
if [ -f "$SETTINGS_FILE" ]; then
  # shellcheck source=/dev/null
  . "$SETTINGS_FILE"
  SETTINGS_ORIGIN="сохранённые настройки ($SETTINGS_FILE)"
elif [ -f "$LEGACY_UPDATER" ]; then
  # v1 вшивал настройки прямо в скрипт обновления. HWID обязательно забираем:
  # новый HWID = новое устройство в лимите и заглушка вместо подписки.
  legacy_get() { sed -n "s/^$1=\"\(.*\)\"[[:space:]]*\$/\1/p" "$LEGACY_UPDATER" 2>/dev/null | head -n1; }
  # ask() в v1 записывал в значение и текст вопроса: «x-device-os [KeeneticOS]: KeeneticOS».
  # HWID не чистим: сервис знает роутер именно под этой строкой.
  legacy_clean() {
    lc=$(legacy_get "$1")
    case "$lc" in *"]: "*|*"): "*) lc=${lc##*: } ;; esac
    printf '%s' "$lc"
  }
  SUB_URL=$(legacy_clean SUB_URL)
  HWID=$(legacy_get HWID)
  DEVICE_OS=$(legacy_clean DEVICE_OS)
  DEVICE_MODEL=$(legacy_clean DEVICE_MODEL)
  # Заглушку v1 заменим настоящей моделью из ndmc.
  [ "$DEVICE_MODEL" != "Keenetic Router" ] || DEVICE_MODEL=""
  USER_AGENT_HDR=$(legacy_clean USER_AGENT_HDR)
  if [ -f "$LEGACY_PANEL" ]; then
    PANEL_PORT=$(sed -n 's/^PORT = \([0-9][0-9]*\).*/\1/p' "$LEGACY_PANEL" 2>/dev/null | head -n1)
  fi
  SETTINGS_ORIGIN="перенесены из установки v1"
fi
# settings.env хранит версию прошлой установки — текущая важнее.
DROPWEB_XKEEN_VERSION=$SCRIPT_VERSION

[ -z "$ENV_SUB_URL" ]        || SUB_URL=$ENV_SUB_URL
[ -z "$ENV_HWID" ]           || HWID=$ENV_HWID
[ -z "$ENV_DEVICE_OS" ]      || DEVICE_OS=$ENV_DEVICE_OS
[ -z "$ENV_OS_VERSION" ]     || OS_VERSION=$ENV_OS_VERSION
[ -z "$ENV_DEVICE_MODEL" ]   || DEVICE_MODEL=$ENV_DEVICE_MODEL
[ -z "$ENV_USER_AGENT_HDR" ] || USER_AGENT_HDR=$ENV_USER_AGENT_HDR
[ -z "$ENV_PANEL_PORT" ]     || PANEL_PORT=$ENV_PANEL_PORT
[ -z "$ENV_API_PORT" ]       || API_PORT=$ENV_API_PORT
[ -z "$ENV_API_SECRET" ]     || API_SECRET=$ENV_API_SECRET
[ -z "$ENV_LAN_IP" ]         || LAN_IP=$ENV_LAN_IP
[ -z "$ENV_UPDATE_URL" ]     || UPDATE_URL=$ENV_UPDATE_URL
[ -z "$ENV_AUTO_UPDATE" ]    || AUTO_UPDATE=$ENV_AUTO_UPDATE
[ -z "$ENV_UDP_BYPASS" ]     || UDP_BYPASS=$ENV_UDP_BYPASS
# 2.1.x хранила только адрес панели (PANEL_SOURCE=<ветка>/panel): адрес ветки — на уровень выше.
if [ -z "$UPDATE_URL" ]; then
  case "$PANEL_SOURCE" in http://?*/panel|https://?*/panel) UPDATE_URL=${PANEL_SOURCE%/panel} ;; esac
fi

# $1 байт случайности в hex (не больше 16). busybox od в свежем Entware
# не знает -A/-t, поэтому берём uuid ядра; od — только запасной путь.
rand_hex() {
  rh=$(tr -d '-' </proc/sys/kernel/random/uuid 2>/dev/null || true)
  [ -n "$rh" ] || rh=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' || true)
  printf '%s' "$rh" | cut -c1-$(($1 * 2))
}

lan_mac() {
  lm=""
  if [ -r /sys/class/net/br0/address ]; then lm=$(cat /sys/class/net/br0/address 2>/dev/null || true); fi
  if [ -z "$lm" ] || [ "$lm" = "00:00:00:00:00:00" ]; then
    lm=""
    for lm_f in /sys/class/net/*/address; do
      [ -r "$lm_f" ] || continue
      case "$lm_f" in /sys/class/net/lo/address) continue ;; esac
      lm_a=$(cat "$lm_f" 2>/dev/null || true)
      if [ -n "$lm_a" ] && [ "$lm_a" != "00:00:00:00:00:00" ]; then lm=$lm_a; break; fi
    done
  fi
  printf '%s' "$lm"
}

# HWID из MAC LAN: при переустановке получится тот же, а сохранённый не меняется вовсе.
gen_hwid() {
  gh_mac=$(lan_mac)
  gh_hex=""
  if [ -n "$gh_mac" ] && command -v sha256sum >/dev/null 2>&1; then
    gh_hex=$(printf '%s' "$gh_mac" | sha256sum | cut -c1-16)
  fi
  [ -n "$gh_hex" ] || gh_hex=$(rand_hex 8)
  printf 'keenetic-%s' "$gh_hex"
}

NDM_VERSION=""
if { [ -z "$DEVICE_MODEL" ] || [ -z "$OS_VERSION" ]; } && command -v ndmc >/dev/null 2>&1; then
  NDM_VERSION=$(ndmc -c 'show version' 2>/dev/null | tr -d '\r' || true)
fi
ndm_field() { printf '%s\n' "$NDM_VERSION" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -n1; }

[ -n "$HWID" ]           || HWID=$(gen_hwid)
[ -n "$DEVICE_OS" ]      || DEVICE_OS="KeeneticOS"
if [ -z "$DEVICE_MODEL" ]; then
  nd_dev=$(ndm_field device)
  nd_hw=$(ndm_field hw_id)
  if [ -n "$nd_dev" ] && [ -n "$nd_hw" ]; then
    DEVICE_MODEL="$nd_dev ($nd_hw)"
  elif [ -n "$nd_dev" ]; then
    DEVICE_MODEL=$nd_dev
  else
    DEVICE_MODEL="Keenetic Router"
  fi
fi
[ -n "$OS_VERSION" ]     || OS_VERSION=$(ndm_field release)
[ -n "$USER_AGENT_HDR" ] || USER_AGENT_HDR="clash.meta"
[ -n "$PANEL_PORT" ]     || PANEL_PORT=8181
[ -n "$API_PORT" ]       || API_PORT=9090
[ -n "$API_SECRET" ]     || API_SECRET=$(rand_hex 16)
if [ -z "$LAN_IP" ] && command -v ip >/dev/null 2>&1; then
  LAN_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
fi
[ -n "$LAN_IP" ]         || LAN_IP="192.168.1.1"
[ -n "$UPDATE_URL" ]     || UPDATE_URL=$DEFAULT_UPDATE_URL
UPDATE_URL=${UPDATE_URL%/}
[ "$AUTO_UPDATE" = 0 ]   || AUTO_UPDATE=1
[ "$UDP_BYPASS" = 0 ]    || UDP_BYPASS=1

case "$PANEL_PORT" in ''|*[!0-9]*) die "PANEL_PORT должен быть числом (сейчас: $PANEL_PORT)" ;; esac
case "$UPDATE_URL" in http://?*|https://?*) ;; *) die "UPDATE_URL должен быть адресом http(s):// (сейчас: $UPDATE_URL)" ;; esac
case "$API_PORT" in ''|*[!0-9]*) die "API_PORT должен быть числом (сейчас: $API_PORT)" ;; esac
[ -n "$API_SECRET" ] || die "Не смог сгенерировать секрет API (/dev/urandom недоступен?)"

# =============================================================================
# Ссылка на подписку — единственный вопрос
# =============================================================================
sub_url_ok() { case "$1" in https://?*) return 0 ;; *) return 1 ;; esac; }
sub_url_host() {
  uh=${1#https://}; uh=${uh%%/*}; uh=${uh%%\?*}; uh=${uh##*@}; uh=${uh%%:*}
  printf '%s' "$uh"
}

say ""
hdr "==========================================================="
hdr " dropweb-xkeen $SCRIPT_VERSION — VPN dropweb на Keenetic"
hdr "==========================================================="
say ""

if [ "$INTERACTIVE" = 1 ]; then
  [ -z "$SUB_URL" ] || inf "Нашёл ссылку из прошлой установки — Enter оставит её."
  sub_default=$SUB_URL
  sub_url_ok "$sub_default" || sub_default=""
  while :; do
    ask "Ссылка на подписку из бота dropweb" "$sub_default"
    SUB_URL=$(trim "$REPLY_VALUE")
    if sub_url_ok "$SUB_URL"; then break; fi
    [ "$ASK_EOF" = 0 ] || die "Ввод закончился, а ссылки нет. Запусти так: SUB_URL='https://...' sh install.sh -y"
    warn "Нужна ссылка, которая начинается с https:// — возьми её в боте dropweb."
  done
else
  [ -n "$SUB_URL" ] || die "Нет ссылки на подписку. Запусти так: SUB_URL='https://...' sh install.sh -y"
  sub_url_ok "$SUB_URL" || die "Ссылка на подписку должна начинаться с https:// (сейчас: $SUB_URL)"
fi
case "$(sub_url_host "$SUB_URL")" in
  *dropweb.org) warn "домен *.dropweb.org блокируется в РФ — возьми свежую ссылку в боте dropweb" ;;
esac

say ""
inf "Параметры ($SETTINGS_ORIGIN):"
say "  ссылка       : $SUB_URL"
say "  HWID         : $HWID"
say "  device-os    : $DEVICE_OS"
say "  ver-os       : ${OS_VERSION:-—}"
say "  device-model : $DEVICE_MODEL"
say "  user-agent   : $USER_AGENT_HDR"
say "  панель       : порт $PANEL_PORT"
say "  API mihomo   : порт $API_PORT"
say "  адрес в LAN  : $LAN_IP"
if [ "$AUTO_UPDATE" = 1 ]; then
  say "  обновления   : сами, ночью ($UPDATE_URL)"
else
  say "  обновления   : только кнопкой в панели ($UPDATE_URL)"
fi
if [ "$UDP_BYPASS" = 1 ]; then
  say "  UDP          : в mihomo только то, что подписка шлёт в VPN, игры напрямую"
else
  say "  UDP          : весь через mihomo (UDP_BYPASS=0)"
fi
say "  (любой параметр можно задать переменной окружения, см. sh install.sh -h)"
say ""

if [ "$INTERACTIVE" = 1 ]; then
  ask "Продолжить установку? [Y/n]" ""
  case "$REPLY_VALUE" in
    n|N|no|No|NO|н|Н|нет|Нет|НЕТ) die "Отменено." ;;
  esac
fi

# Сохраняем сразу: даже если установка упадёт дальше, HWID уже не потеряется.
save_settings() {
  mkdir -p "$SETTINGS_DIR"
  ss_tmp="$SETTINGS_FILE.tmp.$$"
  (
    umask 077
    {
      printf '# dropweb-xkeen: настройки (пишет install.sh, читают скрипты в /opt/sbin)\n'
      printf 'DROPWEB_XKEEN_VERSION=%s\n' "$(shq "$DROPWEB_XKEEN_VERSION")"
      printf 'SUB_URL=%s\n' "$(shq "$SUB_URL")"
      printf 'HWID=%s\n' "$(shq "$HWID")"
      printf 'DEVICE_OS=%s\n' "$(shq "$DEVICE_OS")"
      printf 'OS_VERSION=%s\n' "$(shq "$OS_VERSION")"
      printf 'DEVICE_MODEL=%s\n' "$(shq "$DEVICE_MODEL")"
      printf 'USER_AGENT_HDR=%s\n' "$(shq "$USER_AGENT_HDR")"
      printf 'PANEL_PORT=%s\n' "$(shq "$PANEL_PORT")"
      printf 'API_PORT=%s\n' "$(shq "$API_PORT")"
      printf 'API_SECRET=%s\n' "$(shq "$API_SECRET")"
      printf 'LAN_IP=%s\n' "$(shq "$LAN_IP")"
      printf 'UPDATE_URL=%s\n' "$(shq "$UPDATE_URL")"
      printf 'AUTO_UPDATE=%s\n' "$(shq "$AUTO_UPDATE")"
      printf 'UDP_BYPASS=%s\n' "$(shq "$UDP_BYPASS")"
    } >"$ss_tmp"
  )
  chmod 600 "$ss_tmp"
  mv "$ss_tmp" "$SETTINGS_FILE"
}
save_settings
ok "Настройки сохранены: $SETTINGS_FILE"

# =============================================================================
# Пакеты Entware
# =============================================================================
inf "Проверяю пакеты Entware..."
need_pkgs=""
[ -x /opt/bin/curl ]    || need_pkgs="$need_pkgs curl"
[ -x /opt/bin/python3 ] || need_pkgs="$need_pkgs python3"
[ -x /opt/bin/unzip ]   || need_pkgs="$need_pkgs unzip"
if [ ! -e /opt/etc/init.d/S05crond ] && [ ! -e /opt/etc/init.d/S10cron ] && ! command -v crond >/dev/null 2>&1; then
  need_pkgs="$need_pkgs cron"
fi
if [ -n "$need_pkgs" ]; then
  inf "Ставлю:$need_pkgs"
  /opt/bin/opkg update >>"$INSTALL_LOG" 2>&1 || warn "opkg update завершился с ошибкой — пробую ставить так"
  # shellcheck disable=SC2086 # список пакетов: разбиение на слова нужно
  /opt/bin/opkg install $need_pkgs >>"$INSTALL_LOG" 2>&1 || warn "opkg install завершился с ошибкой — подробности в $INSTALL_LOG"
fi
[ -x /opt/bin/curl ]    || die_log "Не смог поставить curl (opkg install curl)."
[ -x /opt/bin/python3 ] || die_log "Не смог поставить python3 (нужен для веб-панели): opkg install python3"
[ -x /opt/bin/unzip ]   || warn "unzip не поставился — дашборд zashboard будет пропущен."
ok "Entware, curl, python3 на месте."

# =============================================================================
# Проверка подписки до установки XKeen
# =============================================================================
# fetch_sub <url> <повторы>
fetch_sub() {
  fs_url=$1; fs_retry=$2
  set -- -H "x-hwid: $HWID" -H "x-device-os: $DEVICE_OS"
  if [ -n "$OS_VERSION" ]; then set -- "$@" -H "x-ver-os: $OS_VERSION"; fi
  set -- "$@" -H "x-device-model: $DEVICE_MODEL" -A "$USER_AGENT_HDR"
  rm -f "$PRECHECK_FILE" "$PRECHECK_FILE.h"
  curl -fsS --connect-timeout 15 --max-time 90 --retry "$fs_retry" --retry-delay 5 "$@" -D "$PRECHECK_FILE.h" -o "$PRECHECK_FILE" "$fs_url"
}

# Зеркала, которые сервис прислал раньше для этой же ссылки (их помнит
# update-mihomo-sub.sh). Основной домен провайдер может заблокировать: так
# 2026-10-24 у Ростелекома dropweb.site перестал отвечать, часовое обновление
# брало подписку с зеркала, а обновление dropweb-xkeen падало на этой проверке
# и откатывалось.
known_mirrors() {
  [ -f /opt/etc/dropweb-xkeen/sub-state.env ] || return 0
  (
    SUB_STATE_URL=""; SUB_MIRRORS=""
    # shellcheck source=/dev/null
    . /opt/etc/dropweb-xkeen/sub-state.env
    [ "$SUB_STATE_URL" = "$SUB_URL" ] || exit 0
    for u in $(printf '%s' "$SUB_MIRRORS" | tr ',' ' '); do
      [ "$u" != "$SUB_URL" ] || continue
      case "$u" in https://*) printf '%s\n' "$u" ;; esac
    done
  )
}

# Значение заголовка ответа подписки (последнее, без учёта регистра имени).
precheck_hdr() {
  awk -v k="$1" 'BEGIN{k=tolower(k)} {sub(/\r$/,""); i=index($0,":"); if(i>1 && tolower(substr($0,1,i-1))==k){v=substr($0,i+1); sub(/^[ \t]+/,"",v); val=v}} END{printf "%s", val}' "$PRECHECK_FILE.h" 2>/dev/null
}

inf "Проверяю подписку..."
if ! fetch_sub "$SUB_URL" 2 2>>"$INSTALL_LOG"; then
  sub_ok=0
  # Без повторов: заблокированное зеркало иначе съест по минуте.
  for u in $(known_mirrors); do
    if fetch_sub "$u" 0 2>>"$INSTALL_LOG"; then
      sub_ok=1
      warn "Основная ссылка не открылась, подписку отдало зеркало $(printf '%s' "$u" | cut -d/ -f3)"
      break
    fi
  done
  [ "$sub_ok" = 1 ] || die_log "Не скачалась подписка: проверь ссылку/интернет"
fi
if grep -qE 'Приложение не поддерживается|превысили лимит|лимит устройств|00000000-0000-0000-0000-000000000000' "$PRECHECK_FILE"; then
  # Панель dropweb кладёт в заголовок прямую ссылку на страницу устройств в кабинете.
  devices_url=$(precheck_hdr dropweb-device-remove)
  case "$devices_url" in https://*) ;; *) devices_url="" ;; esac
  if [ -n "$devices_url" ]; then
    die "Сервис вернул заглушку: все места для устройств на подписке заняты. Освободи место: $devices_url — и запусти установку снова (sh /tmp/install.sh -y). HWID роутера: $HWID"
  fi
  die "Сервис вернул заглушку: лимит устройств исчерпан или HWID не принят. Удали старое устройство в боте dropweb (Устройства) и запусти установку снова. HWID роутера: $HWID"
fi
grep -Eq '^(proxies|proxy-providers):' "$PRECHECK_FILE" || die "Сервис вернул не конфиг mihomo — проверь ссылку (нужна ссылка на подписку из бота dropweb)."
rm -f "$PRECHECK_FILE"
ok "Подписка отдаётся, HWID принят."

# =============================================================================
# XKeen 2 + mihomo
# =============================================================================
# Только сборки с parse_auto_opt умеют `xkeen -i auto` без вопросов.
xkeen_has_auto() { [ -x /opt/sbin/xkeen ] && grep -q 'parse_auto_opt' /opt/sbin/xkeen; }

# Установщик XKeen в конце запускает интерактивное меню (exec xkeen -i) —
# отрезаем его, чтобы только распаковать файлы, а ставить уже через -i auto.
fetch_xkeen_files() {
  inf "Скачиваю XKeen ($1)..."
  curl -fsSL --connect-timeout 15 --max-time 120 https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh -o /tmp/xkeen-install.sh \
    || die "Не скачался установщик XKeen с GitHub — проверь интернет на роутере."
  grep -qx 'exec /opt/sbin/xkeen -i' /tmp/xkeen-install.sh \
    || die "Формат установщика XKeen изменился — поставь XKeen руками (https://github.com/jameszeroX/XKeen) и запусти меня снова."
  sed -i 's#^exec /opt/sbin/xkeen -i$#exit 0#' /tmp/xkeen-install.sh
  (cd /tmp && sh /tmp/xkeen-install.sh "--$1" </dev/null >>"$INSTALL_LOG" 2>&1) \
    || warn "Установщик XKeen ($1) завершился с ошибкой — подробности в $INSTALL_LOG"
  rm -f /tmp/xkeen-install.sh
}

need_full_install=0
if ! xkeen_has_auto; then
  fetch_xkeen_files stable
  if ! xkeen_has_auto; then
    inf "Стабильный XKeen не умеет ставиться без вопросов — беру 2.0.1 Beta"
    fetch_xkeen_files beta
  fi
  xkeen_has_auto || die_log "Не получилось получить XKeen с установкой без вопросов (xkeen -i auto)."
  need_full_install=1
fi
[ -f "$XKEEN_INIT" ]    || need_full_install=1
[ -x /opt/sbin/mihomo ] || need_full_install=1
[ -x /opt/sbin/yq ]     || need_full_install=1

if [ "$need_full_install" = 1 ]; then
  inf "Ставлю XKeen + mihomo + yq (пару минут)..."
  /opt/sbin/xkeen -i auto cores=mihomo geo=off geoipset=off cron=off autostart=on </dev/null >>"$INSTALL_LOG" 2>&1 \
    || die_log "Установка XKeen (xkeen -i auto) не удалась."
  ok "XKeen установлен."
else
  inf "XKeen уже стоит — обновляю mihomo..."
  /opt/sbin/xkeen -um auto </dev/null >>"$INSTALL_LOG" 2>&1 || warn "не смог обновить mihomo, оставляю текущий"
fi

/opt/sbin/xkeen -mihomo </dev/null >>"$INSTALL_LOG" 2>&1 || true
grep -Eq '^[[:space:]]*name_client="mihomo"' "$XKEEN_INIT" 2>/dev/null \
  || die_log "XKeen не переключился на ядро mihomo ($XKEEN_INIT). Попробуй вручную: xkeen -mihomo"
[ -x /opt/sbin/mihomo ] || die_log "/opt/sbin/mihomo отсутствует."
[ -x /opt/sbin/yq ]     || die_log "/opt/sbin/yq отсутствует."
ok "Ядро XKeen: mihomo ($(/opt/sbin/mihomo -v 2>/dev/null | head -n1 || true))"

# =============================================================================
# Уборка после v1
# =============================================================================
# Только наш python-процесс: killall python3 убил бы чужие сервисы на роутере.
for py_pid in $(pidof python3 2>/dev/null || true); do
  if tr '\0' ' ' <"/proc/$py_pid/cmdline" 2>/dev/null | grep -q 'mihomo-panel\.py'; then
    kill "$py_pid" 2>/dev/null || true
  fi
done
rm -f /opt/etc/init.d/S97mihomo /opt/sbin/mihomo-start.sh

# =============================================================================
# Скрипты на роутере. Все heredoc в кавычках: настройки читаются из
# settings.env во время работы, а не вшиваются при установке.
# =============================================================================
mkdir -p /opt/etc/mihomo /opt/backups/mihomo /opt/var/run /opt/etc/init.d /opt/sbin

write_updater() {
cat >/opt/sbin/update-mihomo-sub.sh <<'EOF_UPDATER'
#!/opt/bin/sh
# dropweb-xkeen: обновление подписки (cron раз в час и кнопка в веб-панели).
# Коды выхода: 0 ок/без изменений, 1 не скачалось, 2 заглушка/не конфиг mihomo,
# 3 mihomo -t не принял конфиг, 4 нет settings.env, 5 уже идёт другое обновление.
# Итог каждого запуска пишется в sub-state.env: по нему панель объясняет
# человеку без SSH, что случилось (лимит устройств, срок оплаты, сайт недоступен).
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
export XKEEN_FOREGROUND=1

SETTINGS=/opt/etc/dropweb-xkeen/settings.env
STATE=/opt/etc/dropweb-xkeen/sub-state.env
CONF_DIR=/opt/etc/mihomo
CONF=$CONF_DIR/config.yaml
RAW=$CONF_DIR/.sub.raw.yaml
HDR=$CONF_DIR/.sub.headers
TMP=$CONF_DIR/.config.new.yaml
BACKUP_DIR=/opt/backups/mihomo
LOG=/opt/var/log/mihomo-sub-update.log
LOCK=/tmp/update-mihomo-sub.lock

mkdir -p "$CONF_DIR" "$BACKUP_DIR" /opt/var/log
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 262144 ]; then
  tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

if [ ! -f "$SETTINGS" ]; then
  log "ERR: нет $SETTINGS — запусти install.sh заново"
  echo "ERR: нет $SETTINGS" >&2
  exit 4
fi
# shellcheck source=/dev/null
. "$SETTINGS"
: "${SUB_URL:=}" "${HWID:=}" "${DEVICE_OS:=KeeneticOS}" "${OS_VERSION:=}" "${DEVICE_MODEL:=Keenetic Router}"
: "${USER_AGENT_HDR:=clash.meta}" "${API_PORT:=9090}" "${API_SECRET:=}"

# Значения из заголовков сервиса — в одинарных кавычках: файл читается через «.».
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

SUB_STATE_URL=""; SUB_RESULT=""; SUB_RESULT_AT=""; SUB_LAST_OK=""; SUB_USED_URL=""
SUB_EXPIRE=""; SUB_MIRRORS=""; SUB_DEVICES_URL=""; SUB_CABINET_URL=""; SUB_ANNOUNCE=""
if [ -f "$STATE" ]; then
  # shellcheck source=/dev/null
  . "$STATE"
fi
# Зеркала и срок оплаты принадлежат конкретной подписке: ссылку сменили — забываем.
if [ "$SUB_STATE_URL" != "$SUB_URL" ]; then
  SUB_RESULT=""; SUB_RESULT_AT=""; SUB_LAST_OK=""; SUB_USED_URL=""
  SUB_EXPIRE=""; SUB_MIRRORS=""; SUB_DEVICES_URL=""; SUB_CABINET_URL=""; SUB_ANNOUNCE=""
fi
SUB_STATE_URL=$SUB_URL

save_state() {
  st_tmp="$STATE.tmp.$$"
  (
    umask 077
    {
      printf '# dropweb-xkeen: итог последнего обновления подписки (пишет update-mihomo-sub.sh, читает панель)\n'
      printf 'SUB_STATE_URL=%s\n' "$(shq "$SUB_STATE_URL")"
      printf 'SUB_RESULT=%s\n' "$(shq "$SUB_RESULT")"
      printf 'SUB_RESULT_AT=%s\n' "$(shq "$SUB_RESULT_AT")"
      printf 'SUB_LAST_OK=%s\n' "$(shq "$SUB_LAST_OK")"
      printf 'SUB_USED_URL=%s\n' "$(shq "$SUB_USED_URL")"
      printf 'SUB_EXPIRE=%s\n' "$(shq "$SUB_EXPIRE")"
      printf 'SUB_MIRRORS=%s\n' "$(shq "$SUB_MIRRORS")"
      printf 'SUB_DEVICES_URL=%s\n' "$(shq "$SUB_DEVICES_URL")"
      printf 'SUB_CABINET_URL=%s\n' "$(shq "$SUB_CABINET_URL")"
      printf 'SUB_ANNOUNCE=%s\n' "$(shq "$SUB_ANNOUNCE")"
    } >"$st_tmp"
  ) && mv "$st_tmp" "$STATE"
}
# finish <итог для панели> <код выхода>
finish() {
  SUB_RESULT=$1
  SUB_RESULT_AT=$(date +%s)
  save_state
  exit "$2"
}

# Значение заголовка ответа (последнее, имя без учёта регистра).
hdr_get() {
  awk -v k="$1" 'BEGIN{k=tolower(k)} {sub(/\r$/,""); i=index($0,":"); if(i>1 && tolower(substr($0,1,i-1))==k){v=substr($0,i+1); sub(/^[ \t]+/,"",v); val=v}} END{printf "%s", val}' "$HDR" 2>/dev/null
}
url_host() { uh=${1#https://}; printf '%s' "${uh%%/*}"; }

# Блокировка без вечных хвостов: чужой lock снимаем, если его процесс умер.
# Код 5 нужен панели: «уже обновляется» — не то же самое, что «без изменений».
if ! mkdir "$LOCK" 2>/dev/null; then
  p=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    echo "уже идёт обновление (pid $p)" >&2
    exit 5
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 5
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK" "$RAW" "$TMP" "$HDR"' EXIT
trap 'exit 1' INT TERM

# 1. Скачать: своя ссылка, затем зеркала из прошлого ответа сервиса.
# Домен подписки в РФ могут заблокировать (так было с *.dropweb.org),
# а зеркала сервис присылает в заголовках самой подписки.
set -- -H "x-hwid: $HWID" -H "x-device-os: $DEVICE_OS"
if [ -n "$OS_VERSION" ]; then set -- "$@" -H "x-ver-os: $OS_VERSION"; fi
set -- "$@" -H "x-device-model: $DEVICE_MODEL" -A "$USER_AGENT_HDR"

# fetch_from <url> <повторы> <заголовки curl...>
fetch_from() {
  ff_url=$1; ff_retry=$2; shift 2
  rm -f "$RAW" "$HDR"
  curl -fsS --connect-timeout 15 --max-time 90 --retry "$ff_retry" --retry-delay 5 "$@" -D "$HDR" -o "$RAW" "$ff_url" 2>>"$LOG"
}

used=""
if fetch_from "$SUB_URL" 2 "$@"; then
  used=$SUB_URL
else
  log "WARN: основная ссылка ($(url_host "$SUB_URL")) не скачалась — пробую зеркала"
  # Зеркала без повторов: заблокированный домен иначе съест минуты на каждом.
  for u in $(printf '%s' "$SUB_MIRRORS" | tr ',' ' '); do
    [ "$u" != "$SUB_URL" ] || continue
    case "$u" in https://*) ;; *) continue ;; esac
    if fetch_from "$u" 0 "$@"; then
      used=$u
      log "скачал с зеркала $(url_host "$u")"
      break
    fi
  done
fi
if [ -z "$used" ]; then
  log "ERR: подписка не скачалась; текущий конфиг не трогаю"
  finish fetch_failed 1
fi
SUB_USED_URL=$used

# 2. Что сервис сообщил о подписке. Берём и из заглушки: в ней ссылка на устройства.
hv=$(hdr_get subscription-userinfo | sed -n 's/.*expire=\([0-9][0-9]*\).*/\1/p')
[ -z "$hv" ] || SUB_EXPIRE=$hv
SUB_DEVICES_URL=$(hdr_get dropweb-device-remove)
SUB_CABINET_URL=$(hdr_get dropweb-cabinet | cut -d, -f1 | tr -d ' ')
SUB_ANNOUNCE=$(hdr_get announce)
hm=$(printf '%s,%s' "$(hdr_get dropweb-sub-mirrors)" "$(hdr_get fallback-url)" \
  | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep '^https://' \
  | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')
[ -z "$hm" ] || SUB_MIRRORS=$hm

# 3. Не конфиг mihomo (страница ошибки, не та ссылка)
if ! yq -e '((.proxies // []) | length) > 0' "$RAW" >/dev/null 2>&1; then
  log "ERR: в подписке нет proxies — это не конфиг mihomo"
  finish not_config 2
fi

# 4. Заглушка вместо подписки. Лимит отличаем от прочих заглушек по
# x-hwid-max-devices-reached: true (2026-10-19 так ответила живая панель dropweb).
if grep -qE 'Приложение не поддерживается|превысили лимит|лимит устройств|00000000-0000-0000-0000-000000000000' "$RAW" \
  || ! yq -e '[(.proxies // [])[] | select(.server == "0.0.0.0")] | length == 0' "$RAW" >/dev/null 2>&1; then
  if [ "$(hdr_get x-hwid-max-devices-reached)" = "true" ] || grep -qE 'превысили лимит|лимит устройств' "$RAW"; then
    log "ERR: заглушка — все места для устройств заняты (HWID $HWID); текущий конфиг не трогаю"
    finish device_limit 2
  fi
  log "ERR: заглушка — сервис не принял HWID $HWID; текущий конфиг не трогаю"
  finish stub 2
fi

# 5. Наши правки поверх шаблона dropweb.
# В шаблоне allow-lan: false, а с ним redir-port/tproxy-port слушают только
# 127.0.0.1 — REDIRECT приходит на LAN-адрес и отбивается. Записи listeners
# слушают 0.0.0.0 независимо от allow-lan, поэтому порты XKeen задаём там.
# mixed-port остаётся только для самого роутера. TUN на роутере ломает маршрутизацию.
# log-level warning: S05xkeen запускает mihomo без перенаправления вывода
# (start_verbose=on), и он пишет в лог того, кто его перезапустил (установка,
# watchdog, обновление), — при info это строка на каждое соединение, лог растёт
# на флешке без конца (2026-10-20 в логе установки было 2146 таких строк). Живые логи в
# дашборде от уровня не зависят: подписчики API получают все события.
export API_PORT API_SECRET
EXPR='
.tun.enable = false |
."log-level" = "warning" |
.tun."auto-route" = false |
.tun."auto-redirect" = false |
.tun."auto-detect-interface" = false |
del(."tproxy-port") | del(."redir-port") |
."allow-lan" = false |
."find-process-mode" = "off" |
.listeners = (((.listeners // []) | map(select(.type != "tproxy" and .type != "redir"))) + [
  {"name": "xkeen-tproxy", "type": "tproxy", "port": 1181, "udp": true},
  {"name": "xkeen-redir", "type": "redir", "port": 1182}
]) |
."external-controller" = "0.0.0.0:" + strenv(API_PORT) |
.secret = strenv(API_SECRET) |
."external-ui" = "zash" |
."external-ui-url" = "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip"
'
if ! { cp "$RAW" "$TMP" && yq -i "$EXPR" "$TMP"; } >>"$LOG" 2>&1; then
  log "ERR: yq не смог применить правки — это не конфиг mihomo"
  finish not_config 2
fi

# 6. Проверка mihomo
if ! mihomo -t -d "$CONF_DIR" -f "$TMP" >>"$LOG" 2>&1; then
  log "ERR: mihomo -t не принял конфиг; текущий не трогаю"
  finish bad_config 3
fi

# 7. Сравнение всего содержимого (не только имён нод)
SUB_LAST_OK=$(date +%s)
if [ -f "$CONF" ] && cmp -s "$TMP" "$CONF"; then
  log "без изменений"
  finish unchanged 0
fi

# 8. Бэкап и замена
if [ -f "$CONF" ]; then
  cp "$CONF" "$BACKUP_DIR/config.yaml.$(date '+%Y%m%d-%H%M%S').bak"
fi
# shellcheck disable=SC2012 # имена бэкапов наши, без пробелов; нужна сортировка по времени
ls -t "$BACKUP_DIR"/config.yaml.*.bak 2>/dev/null | sed -n '6,$p' | while read -r f; do rm -f "$f"; done
mv "$TMP" "$CONF"
chmod 600 "$CONF"
log "конфиг обновлён"

# 9. Горячая перезагрузка без обрыва соединений
if pidof mihomo >/dev/null 2>&1 && [ ! -f "$CONF_DIR/.disabled" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X PUT \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_SECRET" \
    --data "{\"path\":\"$CONF\"}" \
    "http://127.0.0.1:$API_PORT/configs?force=true" 2>/dev/null) || code="000"
  case "$code" in
    200|204) log "горячая перезагрузка OK ($code)" ;;
    *)
      log "WARN: горячая перезагрузка не прошла (http=$code) — xkeen -restart"
      xkeen -restart </dev/null >>"$LOG" 2>&1
      log "xkeen -restart rc=$?"
      ;;
  esac
fi
# В новом конфиге могут быть другие IP-правила — пересобираем обход UDP.
if [ -x /opt/sbin/dropweb-udp-bypass.sh ]; then
  /opt/sbin/dropweb-udp-bypass.sh build >>"$LOG" 2>&1
fi

finish updated 0
EOF_UPDATER
}

write_watchdog() {
cat >/opt/sbin/mihomo-watchdog.sh <<'EOF_WATCHDOG'
#!/opt/bin/sh
# dropweb-xkeen: watchdog (cron раз в минуту). Если mihomo упал, XKeen сам его
# не поднимет — перезапускаем, пока VPN не выключен вручную (.disabled / автозапуск off).
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
export XKEEN_FOREGROUND=1
LOG=/opt/var/log/mihomo-watchdog.log
LOCK=/tmp/mihomo-watchdog.lock

[ -f /opt/etc/mihomo/.disabled ] && exit 0
# Во время обновления mihomo перезапускает install.sh — не мешаем ему.
[ -d /tmp/dxk-update.lock ] && exit 0
grep -Eq '^[[:space:]]*start_auto="on"' /opt/etc/init.d/S05xkeen 2>/dev/null || exit 0
# Обход UDP: XKeen стирает наше правило, когда пересобирает свои цепочки,
# а списки меняются вместе с подпиской.
if [ -x /opt/sbin/dropweb-udp-bypass.sh ]; then
  /opt/sbin/dropweb-udp-bypass.sh check >/dev/null 2>&1
fi
pidof mihomo >/dev/null 2>&1 && exit 0
# Дать S05xkeen спокойно отработать при загрузке роутера.
uptime_s=$(cut -d. -f1 /proc/uptime)
[ "${uptime_s:-0}" -lt 240 ] && exit 0

mkdir -p /opt/var/log
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 262144 ]; then
  tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  p=$(cat "$LOCK/pid" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && exit 0
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 1' INT TERM

# Только через XKeen: он же вешает iptables-правила на нужный порт.
log "mihomo не запущен — xkeen -restart"
xkeen -restart </dev/null >>"$LOG" 2>&1
log "rc=$?"
EOF_WATCHDOG
}

write_panic() {
cat >/opt/sbin/mihomo-panic.sh <<'EOF_PANIC'
#!/opt/bin/sh
# dropweb-xkeen: аварийное выключение VPN. Интернет идёт напрямую,
# выключение переживает перезагрузку (флаг .disabled + автозапуск XKeen off).
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
export XKEEN_FOREGROUND=1
LOG=/opt/var/log/mihomo-panic.log

mkdir -p /opt/var/log
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 262144 ]; then
  tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
say() {
  printf '%s\n' "$*"
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

say "PANIC: выключаю VPN"

# 1. Флаг: watchdog, обновление и панель его уважают
mkdir -p /opt/etc/mihomo
date '+выключено %F %T' >/opt/etc/mihomo/.disabled
say "1/5 флаг /opt/etc/mihomo/.disabled поставлен"

# 2. Чтобы после перезагрузки XKeen не поднял mihomo сам
if [ -x /opt/sbin/xkeen ]; then
  xkeen -auto off </dev/null >/dev/null 2>&1
  say "2/5 автозапуск XKeen выключен"
else
  say "2/5 xkeen не найден — пропускаю"
fi

# 3. Штатная остановка XKeen (снимает свои iptables/ip rule), не дольше 30 с
if [ -x /opt/sbin/xkeen ]; then
  ( xkeen -stop </dev/null >>"$LOG" 2>&1 ) &
  xk_pid=$!
  i=0
  while [ "$i" -lt 30 ] && kill -0 "$xk_pid" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$xk_pid" 2>/dev/null; then
    kill -9 "$xk_pid" 2>/dev/null
    say "3/5 xkeen -stop завис — прерван через 30 с"
  else
    say "3/5 xkeen -stop выполнен"
  fi
  wait "$xk_pid" 2>/dev/null
fi

# 4. Добить mihomo, если остался
if pidof mihomo >/dev/null 2>&1; then
  killall mihomo 2>/dev/null
  sleep 1
  killall -9 mihomo 2>/dev/null
  say "4/5 mihomo остановлен вручную"
else
  say "4/5 mihomo не запущен"
fi

# 5. Страховка: снять только то, что принадлежит XKeen.
# Чужие ip rule не трогаем — v1 удалял все fwmark-правила и ломал политики Keenetic.
for ipt in iptables ip6tables; do
  command -v "$ipt" >/dev/null 2>&1 || continue
  for t in nat mangle; do
    for ch in PREROUTING OUTPUT; do
      "$ipt" -w -t "$t" -S "$ch" 2>/dev/null | grep -- '-j xkeen' | sed 's/^-A /-D /' | while read -r rule; do
        # shellcheck disable=SC2086 # rule — список аргументов iptables, разбиение нужно
        "$ipt" -w -t "$t" $rule 2>/dev/null
      done
    done
    for c in xkeen xkeen_out xkeen_force xkeen_killswitch; do
      "$ipt" -w -t "$t" -F "$c" 2>/dev/null
      "$ipt" -w -t "$t" -X "$c" 2>/dev/null
    done
  done
done
if command -v ip >/dev/null 2>&1; then
  for f in 4 6; do
    while ip -"$f" rule del fwmark 0x111 lookup 111 2>/dev/null; do :; done
    ip -"$f" route flush table 111 2>/dev/null
  done
fi
say "5/5 правила XKeen сняты"

# Итог. cron не трогаем: watchdog и обновление сами смотрят на флаг.
mpid=$(pidof mihomo 2>/dev/null)
left=0
for ipt in iptables ip6tables; do
  command -v "$ipt" >/dev/null 2>&1 || continue
  for t in nat mangle; do
    n=$("$ipt" -w -t "$t" -S 2>/dev/null | grep -c -- '-j xkeen')
    left=$((left + ${n:-0}))
  done
done
say "mihomo: ${mpid:-не запущен}"
say "правил -j xkeen осталось: $left"
say "VPN выключен; останется выключенным и после перезагрузки. Включить: /opt/sbin/mihomo-resume.sh или кнопка в панели"
exit 0
EOF_PANIC
}

write_resume() {
cat >/opt/sbin/mihomo-resume.sh <<'EOF_RESUME'
#!/opt/bin/sh
# dropweb-xkeen: включить VPN обратно после mihomo-panic.sh.
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
export XKEEN_FOREGROUND=1
LOG=/opt/var/log/mihomo-panic.log

mkdir -p /opt/var/log
printf '[%s] RESUME: включаю VPN\n' "$(date '+%F %T')" >>"$LOG"
rm -f /opt/etc/mihomo/.disabled
xkeen -auto on </dev/null >>"$LOG" 2>&1
xkeen -restart </dev/null >>"$LOG" 2>&1

i=0
mpid=""
while [ "$i" -lt 10 ]; do
  mpid=$(pidof mihomo 2>/dev/null)
  [ -n "$mpid" ] && break
  sleep 1
  i=$((i + 1))
done

if [ -n "$mpid" ] && [ -x /opt/sbin/dropweb-udp-bypass.sh ]; then
  /opt/sbin/dropweb-udp-bypass.sh apply >/dev/null 2>&1
fi
if [ -n "$mpid" ]; then
  echo "VPN включён: mihomo pid $mpid"
  printf '[%s] RESUME: mihomo pid %s\n' "$(date '+%F %T')" "$mpid" >>"$LOG"
  exit 0
fi
echo "mihomo не поднялся — смотри $LOG и xkeen -diag"
printf '[%s] RESUME: mihomo не поднялся\n' "$(date '+%F %T')" >>"$LOG"
exit 1
EOF_RESUME
}

write_self_updater() {
cat >"$SELF_UPDATER" <<'EOF_SELFUPDATE'
#!/opt/bin/sh
# dropweb-xkeen: обновление самого dropweb-xkeen с GitHub.
#   check  узнать последнюю версию (панель показывает «Есть обновление»)
#   run    обновить сейчас, если вышла новая версия (кнопка в панели)
#   auto   cron ночью: при AUTO_UPDATE=1 то же, что run, но версию, которая
#          уже откатывалась, сам не ставит — ждёт следующую
# Обновление = install.sh новой версии и panel/ из того же коммита. Перед ним
# снимок наших файлов и mihomo; если после установки VPN или панель работают
# хуже, чем до неё, снимок возвращается на место.
# Итог пишется в update-state.env: по нему панель объясняет, что произошло.
# Коды выхода: 0 ок или обновлять нечего, 1 ошибка или откат, 2 неверный
# вызов, 3 уже идёт другое обновление.
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
export XKEEN_FOREGROUND=1

# install.sh перепишет этот файл, а sh читает скрипт по ходу выполнения —
# работаем из копии. Копию узнаём по пути, а не по переменной окружения:
# переменную унаследовали бы панель и mihomo, которых перезапускает install.sh,
# и следующий запуск из панели удалил бы как «копию» сам этот файл
# (так было в 2.3.0 на Hopper 2026-10-20).
unset DXK_SELF_COPY
case "$0" in
  /tmp/dxk-update.run.*) SELF_COPY=$0 ;;
  *)
    cp "$0" "/tmp/dxk-update.run.$$" || exit 1
    exec sh "/tmp/dxk-update.run.$$" "$@"
    ;;
esac

SETTINGS=/opt/etc/dropweb-xkeen/settings.env
STATE=/opt/etc/dropweb-xkeen/update-state.env
LOG=/opt/var/log/dropweb-xkeen-update.log
LOCK=/tmp/dxk-update.lock
WORK=/tmp/dxk-update
SNAP=/opt/backups/dropweb-xkeen/snapshot
CONF=/opt/etc/mihomo/config.yaml
DEFAULT_URL=https://raw.githubusercontent.com/enkinvsh/dropweb-xkeen/main
# Всё, что меняет повторный install.sh. Чего из списка не было до обновления,
# откат удаляет.
SNAP_PATHS="/opt/sbin/update-mihomo-sub.sh /opt/sbin/mihomo-watchdog.sh /opt/sbin/mihomo-panic.sh
/opt/sbin/mihomo-resume.sh /opt/sbin/mihomo-vpn-uninstall.sh /opt/sbin/dropweb-xkeen-update.sh
/opt/sbin/mihomo /opt/etc/init.d/S05xkeen /opt/etc/init.d/S96mihomo-panel /opt/share/dropweb-xkeen
/opt/etc/dropweb-xkeen/settings.env /opt/etc/dropweb-xkeen/sub-state.env $CONF
/opt/etc/mihomo/.disabled /opt/var/spool/cron/crontabs/root
/opt/sbin/dropweb-udp-bypass.sh /opt/etc/ndm/netfilter.d/zz-dropweb-udp.sh"

mkdir -p /opt/var/log
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 262144 ]; then
  tail -n 800 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

MODE=${1:-}
case "$MODE" in
  check|run|auto) ;;
  *) echo "Использование: dropweb-xkeen-update.sh check|run|auto" >&2; rm -f "$SELF_COPY"; exit 2 ;;
esac

if ! mkdir "$LOCK" 2>/dev/null; then
  p=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    echo "уже идёт обновление (pid $p)"
    rm -f "$SELF_COPY"
    exit 3
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { rm -f "$SELF_COPY"; exit 3; }
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK" "$WORK" "$SELF_COPY"' EXIT
trap 'exit 1' INT TERM
# Панель запускает нас и сама перезапускается посреди обновления.
trap '' HUP

if [ ! -f "$SETTINGS" ]; then
  log "ERR: нет $SETTINGS — запусти install.sh заново"
  exit 1
fi
# shellcheck source=/dev/null
. "$SETTINGS"
: "${DROPWEB_XKEEN_VERSION:=0}" "${UPDATE_URL:=}" "${AUTO_UPDATE:=1}" "${PANEL_SOURCE:=}"
: "${PANEL_PORT:=8181}" "${API_PORT:=9090}" "${API_SECRET:=}"
# Первое обновление с 2.1.x: там вместо UPDATE_URL был только адрес панели.
if [ -z "$UPDATE_URL" ]; then
  case "$PANEL_SOURCE" in http://?*/panel|https://?*/panel) UPDATE_URL=${PANEL_SOURCE%/panel} ;; esac
fi
[ -n "$UPDATE_URL" ] || UPDATE_URL=$DEFAULT_URL
UPDATE_URL=${UPDATE_URL%/}
CUR=$DROPWEB_XKEEN_VERSION

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

UPD_CHECKED_AT=""; UPD_CHECK_ERR=""; UPD_LATEST=""; UPD_LATEST_COMMIT=""
UPD_RESULT=""; UPD_RESULT_AT=""; UPD_FROM=""; UPD_TO=""; UPD_MODE=""; UPD_PID=""; UPD_FAILED=""
if [ -f "$STATE" ]; then
  # shellcheck source=/dev/null
  . "$STATE"
fi

save_state() {
  {
    printf '# dropweb-xkeen: проверка и обновление (пишет dropweb-xkeen-update.sh, читает панель)\n'
    printf 'UPD_CHECKED_AT=%s\n' "$(shq "$UPD_CHECKED_AT")"
    printf 'UPD_CHECK_ERR=%s\n' "$(shq "$UPD_CHECK_ERR")"
    printf 'UPD_LATEST=%s\n' "$(shq "$UPD_LATEST")"
    printf 'UPD_LATEST_COMMIT=%s\n' "$(shq "$UPD_LATEST_COMMIT")"
    printf 'UPD_RESULT=%s\n' "$(shq "$UPD_RESULT")"
    printf 'UPD_RESULT_AT=%s\n' "$(shq "$UPD_RESULT_AT")"
    printf 'UPD_FROM=%s\n' "$(shq "$UPD_FROM")"
    printf 'UPD_TO=%s\n' "$(shq "$UPD_TO")"
    printf 'UPD_MODE=%s\n' "$(shq "$UPD_MODE")"
    printf 'UPD_PID=%s\n' "$(shq "$UPD_PID")"
    printf 'UPD_FAILED=%s\n' "$(shq "$UPD_FAILED")"
  } >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

finish() {
  UPD_RESULT=$1; UPD_RESULT_AT=$(date +%s); UPD_PID=""
  save_state
  exit "$2"
}

# $1 новее $2? Сравнение по числам через точку: 2.10.0 > 2.9.1.
ver_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN{n=split(a,x,".");m=split(b,y,".");k=n>m?n:m
    for(i=1;i<=k;i++){p=x[i]+0;q=y[i]+0;if(p>q)exit 0;if(p<q)exit 1};exit 1}'
}

# raw.githubusercontent.com держит файлы веточного адреса в кэше до 5 минут:
# фиксируем коммит через API, тогда install.sh и panel/ гарантированно из одного.
BASE=$UPDATE_URL; COMMIT=""
resolve() {
  case "$UPDATE_URL" in
    https://raw.githubusercontent.com/?*/?*/?*)
      r=${UPDATE_URL#https://raw.githubusercontent.com/}
      owner=${r%%/*}; r=${r#*/}; repo=${r%%/*}; ref=${r#*/}
      sha=$(curl -fsS --connect-timeout 15 --max-time 30 -H 'Accept: application/vnd.github.sha' \
        "https://api.github.com/repos/$owner/$repo/commits/$ref" 2>>"$LOG") || sha=""
      if printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
        BASE="https://raw.githubusercontent.com/$owner/$repo/$sha"; COMMIT=$sha
      else
        log "SHA ветки $ref не получен — качаю по ветке"
      fi
      ;;
  esac
}

get() { curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 -o "$2" "$BASE/$1" 2>>"$LOG"; }

NEW=""
do_check() {
  rm -rf "$WORK"
  mkdir -p "$WORK/panel"
  resolve
  if ! get install.sh "$WORK/install.sh"; then
    log "ERR: не скачался $BASE/install.sh"
    UPD_CHECK_ERR=fetch_failed; return 1
  fi
  NEW=$(sed -n 's/^DROPWEB_XKEEN_VERSION="\([^"]*\)".*/\1/p' "$WORK/install.sh" | head -n1)
  if [ -z "$NEW" ] || ! sh -n "$WORK/install.sh" 2>>"$LOG"; then
    log "ERR: скачанный install.sh битый"
    UPD_CHECK_ERR=bad_files; return 1
  fi
  UPD_CHECK_ERR=""; UPD_CHECKED_AT=$(date +%s); UPD_LATEST=$NEW; UPD_LATEST_COMMIT=$COMMIT
  return 0
}

net_ok() {
  mp=$(yq '."mixed-port" // ""' "$CONF" 2>/dev/null)
  [ -n "$mp" ] || return 1
  i=0
  while [ "$i" -lt 4 ]; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "http://127.0.0.1:$mp" \
      https://www.gstatic.com/generate_204 2>/dev/null)
    [ "$c" = 204 ] && return 0
    i=$((i + 1)); sleep 5
  done
  return 1
}

# $1=1 — требовать ещё и выход в интернет через mihomo (если он был до обновления).
health() {
  if [ ! -f /opt/etc/mihomo/.disabled ]; then
    i=0; up=0
    while [ "$i" -lt 30 ]; do
      if pidof mihomo >/dev/null 2>&1 && curl -s --noproxy '*' --max-time 3 -H "Authorization: Bearer $API_SECRET" \
        "http://127.0.0.1:$API_PORT/version" 2>/dev/null | grep -q version; then
        up=1; break
      fi
      i=$((i + 1)); sleep 2
    done
    [ "$up" = 1 ] || { log "проверка: mihomo или его API не поднялись"; return 1; }
    if ! iptables -w -t nat -S 2>/dev/null | grep -q -- '-j xkeen' \
      && ! iptables -w -t mangle -S 2>/dev/null | grep -q -- '-j xkeen'; then
      log "проверка: нет правил XKeen в iptables"; return 1
    fi
    if [ "$1" = 1 ] && ! net_ok; then log "проверка: нет интернета через mihomo"; return 1; fi
  fi
  i=0
  while [ "$i" -lt 20 ]; do
    curl -s --noproxy '*' --max-time 5 "http://127.0.0.1:$PANEL_PORT/status" 2>/dev/null | grep -q '"running"' && return 0
    i=$((i + 1)); sleep 1
  done
  log "проверка: панель не отвечает"
  return 1
}

snapshot() {
  rm -rf "$SNAP"
  mkdir -p "$SNAP" || return 1
  : >"$SNAP/.absent"
  for p in $SNAP_PATHS; do
    if [ -e "$p" ]; then
      mkdir -p "$SNAP$(dirname "$p")" && cp -a "$p" "$SNAP$p" || return 1
    else
      echo "$p" >>"$SNAP/.absent"
    fi
  done
  echo "$CUR" >"$SNAP/.version"
}

restore() {
  for p in $SNAP_PATHS; do
    if [ -e "$SNAP$p" ]; then
      rm -rf "$p"; mkdir -p "$(dirname "$p")"; cp -a "$SNAP$p" "$p"
    elif grep -qx "$p" "$SNAP/.absent"; then
      rm -rf "$p"
    fi
  done
  for c in /opt/etc/init.d/S05crond /opt/etc/init.d/S10cron; do
    if [ -x "$c" ]; then "$c" restart >>"$LOG" 2>&1; break; fi
  done
  if [ -f /opt/etc/mihomo/.disabled ]; then
    /opt/sbin/mihomo-panic.sh >>"$LOG" 2>&1
  else
    xkeen -auto on </dev/null >>"$LOG" 2>&1
    xkeen -restart </dev/null >>"$LOG" 2>&1
  fi
  if [ -x /opt/sbin/dropweb-udp-bypass.sh ]; then
    /opt/sbin/dropweb-udp-bypass.sh build >>"$LOG" 2>&1
  fi
  /opt/etc/init.d/S96mihomo-panel restart >>"$LOG" 2>&1
  # shellcheck source=/dev/null
  . "$SETTINGS"
}

do_update() {
  if ! get panel/mihomo-panel.py "$WORK/panel/mihomo-panel.py" || ! get panel/index.html "$WORK/panel/index.html"; then
    log "ERR: не скачались файлы панели из $BASE"
    finish fetch_failed 1
  fi
  if ! python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' \
    "$WORK/panel/mihomo-panel.py" 2>>"$LOG" || ! grep -qi '<html' "$WORK/panel/index.html"; then
    log "ERR: скачанные файлы панели битые"
    finish bad_files 1
  fi
  need_net=0
  if [ ! -f /opt/etc/mihomo/.disabled ] && net_ok; then need_net=1; fi
  if ! snapshot; then
    log "ERR: не смог сохранить снимок в $SNAP — не обновляю"
    finish failed 1
  fi
  UPD_FROM=$CUR; UPD_TO=$NEW; UPD_MODE=$MODE; UPD_PID=$$; UPD_RESULT=running; UPD_RESULT_AT=$(date +%s)
  save_state
  log "обновляю $CUR → $NEW (${COMMIT:-$BASE}, $MODE)"
  if DXK_UPDATE=1 sh "$WORK/install.sh" -y </dev/null >>"$LOG" 2>&1; then
    # shellcheck source=/dev/null
    . "$SETTINGS"
    if health "$need_net"; then
      log "обновлено до $NEW"
      UPD_FAILED=""
      finish updated 0
    fi
  else
    log "install.sh $NEW завершился с ошибкой"
  fi
  log "новая версия не заработала — возвращаю $CUR из снимка"
  UPD_FAILED=${COMMIT:-$NEW}
  restore
  if health "$need_net"; then
    log "откат на $CUR выполнен"
    finish rolled_back 1
  fi
  log "ERR: после отката проверка тоже не проходит"
  finish rollback_failed 1
}

if ! do_check; then
  save_state
  [ "$MODE" = run ] && finish "$UPD_CHECK_ERR" 1
  exit 1
fi
save_state
if ! ver_gt "$NEW" "$CUR"; then
  [ "$MODE" = run ] && log "последняя версия $NEW, у нас $CUR — обновлять нечего"
  [ "$MODE" = run ] && finish same 0
  exit 0
fi
case "$MODE" in
  check)
    echo "$NEW"
    exit 0
    ;;
  auto)
    if [ "$AUTO_UPDATE" != 1 ]; then
      log "вышла $NEW, автообновление выключено — жду кнопку в панели"
      exit 0
    fi
    if [ -n "$UPD_FAILED" ] && [ "$UPD_FAILED" = "${COMMIT:-$NEW}" ]; then
      log "версия $NEW уже откатывалась — жду следующую"
      exit 0
    fi
    ;;
esac
do_update
EOF_SELFUPDATE
}

# Панель — отдельные файлы репозитория (panel/), чтобы её вид можно было менять,
# не трогая этот скрипт. Берём panel/ рядом со скриптом (запуск из клона или из
# обновления — оно кладёт файлы того же коммита), иначе качаем из UPDATE_URL.
install_panel() {
  ip_stage=$PANEL_DIR.new
  ip_local=""
  case "$0" in */install.sh) ip_local=${0%/install.sh}/panel ;; install.sh) ip_local=./panel ;; esac
  if [ -z "$ip_local" ] || [ ! -f "$ip_local/mihomo-panel.py" ] || [ ! -f "$ip_local/index.html" ]; then
    ip_local=""
  fi
  rm -rf "$ip_stage"
  mkdir -p "$ip_stage" "$PANEL_DIR"
  for ip_f in mihomo-panel.py index.html; do
    if [ -n "$ip_local" ]; then
      cp "$ip_local/$ip_f" "$ip_stage/$ip_f" || return 1
    else
      curl -fsSL --connect-timeout 15 --max-time 60 --retry 2 -o "$ip_stage/$ip_f" "$UPDATE_URL/panel/$ip_f" 2>>"$INSTALL_LOG" || return 1
    fi
  done
  /opt/bin/python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' "$ip_stage/mihomo-panel.py" 2>>"$INSTALL_LOG" || return 1
  grep -qi '<html' "$ip_stage/index.html" || return 1
  for ip_f in mihomo-panel.py index.html; do
    mv -f "$ip_stage/$ip_f" "$PANEL_DIR/$ip_f" || return 1
  done
  chmod 755 "$PANEL_DIR/mihomo-panel.py"
  chmod 644 "$PANEL_DIR/index.html"
  rm -rf "$ip_stage"
  PANEL_FROM=${ip_local:-$UPDATE_URL/panel}
}

write_panel_init() {
cat >/opt/etc/init.d/S96mihomo-panel <<'EOF_PANEL_INIT'
#!/opt/bin/sh
# dropweb-xkeen: автозапуск веб-панели. Без rc.func: его stop делает killall python3.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
PIDFILE=/opt/var/run/mihomo-panel.pid
PANEL=/opt/share/dropweb-xkeen/panel/mihomo-panel.py
LOG=/opt/var/log/mihomo-panel.log
SETTINGS=/opt/etc/dropweb-xkeen/settings.env

is_panel_pid() {
  [ -n "$1" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -q 'mihomo-panel\.py'
}

is_running() {
  is_panel_pid "$(cat "$PIDFILE" 2>/dev/null)"
}

start() {
  if is_running; then
    echo "панель уже запущена (pid $(cat "$PIDFILE"))"
    return 0
  fi
  PANEL_PORT=8181
  if [ -f "$SETTINGS" ]; then
    # shellcheck source=/dev/null
    . "$SETTINGS"
  fi
  mkdir -p /opt/var/run /opt/var/log
  if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 262144 ]; then
    tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  nohup /opt/bin/python3 "$PANEL" "${PANEL_PORT:-8181}" >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  sleep 1
  if is_running; then
    echo "панель запущена (pid $(cat "$PIDFILE"), порт ${PANEL_PORT:-8181})"
    return 0
  fi
  echo "панель не запустилась — смотри $LOG"
  return 1
}

stop() {
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
  fi
  rm -f "$PIDFILE"
  # Старые экземпляры (v1 запускал через rc.func без pidfile).
  for p in $(pidof python3 2>/dev/null); do
    if is_panel_pid "$p"; then kill "$p" 2>/dev/null; fi
  done
  echo "панель остановлена"
  return 0
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep 1; start ;;
  status)
    if is_running; then
      echo "панель запущена (pid $(cat "$PIDFILE"))"
    else
      echo "панель не запущена"
      exit 3
    fi
    ;;
  *) echo "Использование: $0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF_PANEL_INIT
}

write_udp_bypass() {
cat >"$UDP_BYPASS_SH" <<'EOF_UDPBYPASS'
#!/opt/bin/sh
# dropweb-xkeen: игры и прочий UDP мимо mihomo.
# XKeen заворачивает в mihomo весь UDP из домашней сети, даже тот, который
# правила подписки отправляют напрямую. Для игр это лишний круг через
# прокси-процесс: у PS5 на Hopper 2026-10-21 пинг EA FC был 150–200 вместо
# 80–100, хотя mihomo и так вёл игру DIRECT.
# Поэтому в mihomo идёт только UDP, который правила подписки могут отправить
# не напрямую: на порты QUIC из sniffer (443) и на адреса из IP-правил
# с VPN-целью (звонки Telegram, WhatsApp, Discord, Meet). Остальной UDP
# выходит из цепочки xkeen и уходит обычным NAT. TCP не трогаем.
# Списки строятся из конфига mihomo и файлов его rule-provider. Если правило
# нельзя свести к адресам и портам (MATCH в VPN, NOT, GEOIP…), обход
# выключается и весь UDP, как раньше, идёт в mihomo.
#   build   пересобрать списки и применить
#   apply   вернуть правило (XKeen стирает цепочку xkeen при каждой пересборке)
#   check   watchdog: пересобрать, если конфиг или списки поменялись; вернуть правило
#   remove  снять правило и наборы (удаление dropweb-xkeen)
#   status  что сейчас включено
# UDP_BYPASS=0 в settings.env — весь UDP через mihomo.
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
SETTINGS=/opt/etc/dropweb-xkeen/settings.env
DIR=/opt/etc/dropweb-xkeen/udp-bypass
STATE=$DIR/state.env
MDIR=/opt/etc/mihomo
CONF=$MDIR/config.yaml
LOG=/opt/var/log/dropweb-udp-bypass.log
LOCK=/tmp/dxk-udp.lock
TAG=dropweb_udp_bypass

mkdir -p "$DIR" /opt/var/log
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 131072 ]; then
  tail -n 300 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

UDP_BYPASS=1
if [ -f "$SETTINGS" ]; then
  # shellcheck source=/dev/null
  . "$SETTINGS"
fi
: "${UDP_BYPASS:=1}"

# $1 — сколько секунд ждать чужой запуск.
take_lock() {
  n=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    p=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    if [ "$n" -ge "$1" ]; then
      # Пустой pid дольше ожидания — запуск умер между mkdir и записью pid.
      [ -z "$p" ] && [ "$n" -gt 0 ] && { rm -rf "$LOCK"; continue; }
      return 1
    fi
    n=$((n + 1)); sleep 1
  done
  echo $$ >"$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
  trap 'exit 1' INT TERM
}

ipt_of() { if [ "$1" = 6 ]; then echo ip6tables; else echo iptables; fi; }

# Наше правило встаёт перед socket --transparent (иначе перед TPROXY):
# так UDP мимо mihomo не получает метку XKeen.
rule_pos() {
  "$1" -w -t mangle -S xkeen 2>/dev/null | awk '
    /^-A / { n++ }
    /^-A / && /--transparent/ && !s { s = n }
    /^-A / && /-j TPROXY/ && !t { t = n }
    END { if (s) print s; else if (t) print t }'
}

drop_rules() {
  "$1" -w -t mangle -S xkeen 2>/dev/null | grep -- "$TAG" | sed 's/^-A /-D /' | while read -r r; do
    # shellcheck disable=SC2086 # r — список аргументов iptables
    "$1" -w -t mangle $r 2>/dev/null
  done
}

# Потоки, уже идущие через mihomo, сбрасываем так же, как XKeen после
# пересборки: по метке TPROXY. Иначе они висят до таймаута conntrack.
flush_udp() {
  command -v conntrack >/dev/null 2>&1 || return 0
  m=$("$1" -w -t mangle -S xkeen 2>/dev/null | sed -n 's/.*--tproxy-mark \(0x[0-9a-fA-F]*\).*/\1/p' | head -n1)
  [ -n "$m" ] || return 0
  if [ "$1" = ip6tables ]; then
    conntrack -D -f ipv6 -p udp -m "$((m))" >/dev/null 2>&1
  else
    conntrack -D -p udp -m "$((m))" >/dev/null 2>&1
  fi
  return 0
}

want_on() {
  [ "$UDP_BYPASS" != 0 ] || return 1
  [ ! -f "$MDIR/.disabled" ] || return 1
  [ -f "$STATE" ] && grep -q "^UDPB_ON='1'" "$STATE"
}

load_set() {
  # Имена переменных не пересекаются с apply_fam: в sh они общие, и прежнее
  # mark затирало маркер правила — правило и набор пересоздавались каждую минуту.
  set=dxk_udp_vpn$1; lst=$DIR/v$1.lst; smark=/tmp/dxk-udp.set$1
  fam=inet; [ "$1" = 6 ] && fam=inet6
  [ -f "$lst" ] || : >"$lst"
  sum=$(md5sum "$lst" | cut -d' ' -f1)
  if ipset list -n "$set" >/dev/null 2>&1 && [ "$(cat "$smark" 2>/dev/null)" = "$sum" ]; then
    return 0
  fi
  ipset create "$set" hash:net family "$fam" maxelem 262144 -exist || return 1
  ipset destroy "${set}_new" 2>/dev/null
  ipset create "${set}_new" hash:net family "$fam" maxelem 262144 || return 1
  if [ -s "$lst" ] && ! sed "s/^/add ${set}_new /" "$lst" | ipset restore -exist; then
    ipset destroy "${set}_new"
    return 1
  fi
  ipset swap "${set}_new" "$set" && ipset destroy "${set}_new"
  echo "$sum" >"$smark"
}

# Аргументы правила: UDP не на адреса из набора и не на порты из списка — RETURN.
# В одном multiport не больше 15 портов (диапазон считается за два).
rule_args() {
  a="-p udp -m set ! --match-set dxk_udp_vpn$1 dst"
  chunk=""; w=0
  if [ -f "$DIR/ports" ]; then
    while read -r p; do
      [ -n "$p" ] || continue
      pw=1; case "$p" in *:*) pw=2 ;; esac
      if [ $((w + pw)) -gt 15 ]; then a="$a -m multiport ! --dports $chunk"; chunk=""; w=0; fi
      chunk=${chunk:+$chunk,}$p; w=$((w + pw))
    done <"$DIR/ports"
  fi
  [ -z "$chunk" ] || a="$a -m multiport ! --dports $chunk"
  printf '%s -m comment --comment %s -j RETURN' "$a" "$TAG"
}

apply_fam() {
  ipt=$(ipt_of "$1"); rmark=/tmp/dxk-udp.rule$1
  command -v "$ipt" >/dev/null 2>&1 || return 0
  # Цепочки нет: VPN выключен или XKeen ещё не поднялся — потом вызовет хук.
  "$ipt" -w -t mangle -S xkeen 2>/dev/null | grep -q -- '-j TPROXY' || return 0
  if ! want_on; then
    if "$ipt" -w -t mangle -S xkeen 2>/dev/null | grep -q -- "$TAG"; then
      drop_rules "$ipt"; log "$ipt: обход UDP снят, весь UDP через mihomo"
    fi
    rm -f "$rmark"
    return 0
  fi
  if ! load_set "$1"; then
    log "$ipt: набор dxk_udp_vpn$1 не загрузился — весь UDP через mihomo"
    drop_rules "$ipt"; rm -f "$rmark"
    return 1
  fi
  args=$(rule_args "$1")
  if "$ipt" -w -t mangle -S xkeen 2>/dev/null | grep -q -- "$TAG" && [ "$(cat "$rmark" 2>/dev/null)" = "$args" ]; then
    return 0
  fi
  drop_rules "$ipt"
  pos=$(rule_pos "$ipt")
  if [ -z "$pos" ]; then
    log "$ipt: в цепочке xkeen нет правила TPROXY — обход UDP не ставлю"
    return 1
  fi
  # shellcheck disable=SC2086 # args — список аргументов iptables
  if "$ipt" -w -t mangle -I xkeen "$pos" $args; then
    printf '%s' "$args" >"$rmark"
    flush_udp "$ipt"
    log "$ipt: обход UDP на месте (перед правилом $pos)"
  else
    log "$ipt: не смог вставить правило обхода UDP"
    return 1
  fi
}

apply_all() {
  rc=0
  apply_fam 4 || rc=1
  apply_fam 6 || rc=1
  return "$rc"
}

need_build() {
  [ -f "$STATE" ] || return 0
  [ -n "$(find "$CONF" "$MDIR/rule-sets" "$MDIR/rules" -newer "$STATE" 2>/dev/null | head -n1)" ]
}

write_off() {
  : >"$DIR/v4.lst"; : >"$DIR/v6.lst"; : >"$DIR/ports"
  r=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
  printf "UDPB_ON='0'\nUDPB_REASON='%s'\nUDPB_AT='%s'\n" "$r" "$(date +%s)" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  log "обход UDP выключен: $1"
}

build() {
  if ! command -v python3 >/dev/null 2>&1; then write_off "нет python3"; return 0; fi
  if [ ! -f "$CONF" ]; then write_off "нет $CONF"; return 0; fi
  if ! python3 - "$CONF" "$MDIR" "$DIR" >>"$LOG" 2>&1 <<'EOF_PY'
import hashlib, ipaddress, json, os, subprocess, sys, time

CONF, HOME, OUT = sys.argv[1:4]
DOMAIN_TYPES = {"DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD", "GEOSITE"}
PROCESS_TYPES = {"PROCESS-NAME", "PROCESS-NAME-REGEX", "PROCESS-NAME-WILDCARD", "PROCESS-PATH",
                 "PROCESS-PATH-REGEX", "PROCESS-PATH-WILDCARD", "UID"}


class Cond:
    """Где условие правила может сработать для UDP из домашней сети.

    all — причина, по которой границ нет (сработает где угодно);
    иначе только на адресах nets или портах ports. Пустое = никогда.
    """

    __slots__ = ("all", "nets", "ports")

    def __init__(self, all_=None, nets=(), ports=()):
        self.all = all_
        self.nets = set(nets)
        self.ports = set(ports)

    def never(self):
        return self.all is None and not self.nets and not self.ports


def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=120)


def yq_json(path, expr="."):
    r = run(["yq", "-o=json", expr, path])
    if r.returncode:
        raise RuntimeError("yq: " + (r.stderr.strip() or path)[:150])
    return json.loads(r.stdout or "null")


def split(s):
    out, depth, cur = [], 0, []
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur).strip())
    return out


def unwrap(s):
    s = s.strip()
    return s[1:-1].strip() if s.startswith("(") and s.endswith(")") else s


def ports_of(spec):
    res = set()
    for part in str(spec).replace(",", "/").split("/"):
        part = part.strip()
        if not part:
            continue
        a, _, b = part.partition("-")
        lo, hi = int(a), int(b or a)
        if not 0 < lo <= hi <= 65535:
            raise ValueError("порт " + part)
        res.add((lo, hi))
    return res


def net(s):
    return ipaddress.ip_network(str(s).strip().strip("'\""), strict=False)


def nets_cond(items, what):
    out = Cond()
    for it in items:
        n = net(it)
        if n.prefixlen == 0:
            return Cond(all_=what + ": " + str(n))
        out.nets.add(n)
    return out


def any_of(kids):
    out = Cond()
    for k in kids:
        if k.all is not None:
            return Cond(all_=k.all)
        out.nets |= k.nets
        out.ports |= k.ports
    return out


def all_of(kids):
    # Любое из условий AND — надмножество всего AND: берём самое узкое.
    if any(k.never() for k in kids):
        return Cond()
    bounded = [k for k in kids if k.all is None]
    if not bounded:
        return Cond(all_=kids[0].all)

    def cost(k):
        if not k.nets and k.ports <= BASE_PORTS:
            return 0  # эти порты и так идут в mihomo
        if not k.ports:
            return 1
        return 3 if not k.nets else 2

    return min(bounded, key=cost)


def clean(items):
    out = []
    for it in items:
        s = str(it).strip()
        if s and not s.startswith("#"):
            out.append(s.strip("'\""))
    return out


def domain():
    # Домен у UDP с адресом вместо имени mihomo узнаёт только sniffer-ом QUIC
    # или из своего DNS. Fake-ip DNS закрыт набором fake-ip-range, а redir-host,
    # раздающий адреса в сеть, сопоставит домен с любым портом.
    if DNS_LEAKS_DOMAINS:
        return Cond(all_="DNS mihomo в режиме " + DNS_MODE + " слушает сеть")
    return Cond(ports=BASE_PORTS) if BASE_PORTS else Cond()


PROV_CACHE = {}


def provider(name):
    if name not in PROV_CACHE:
        PROV_CACHE[name] = Cond(all_="rule-provider " + name + " ссылается сам на себя")
        p = PROVIDERS.get(name)
        PROV_CACHE[name] = provider_eval(name, p) if isinstance(p, dict) else Cond(all_="нет rule-provider " + name)
    return PROV_CACHE[name]


def provider_items(name, p, beh):
    if str(p.get("type", "")).lower() == "inline":
        return clean(p.get("payload") or [])
    path = p.get("path") or os.path.join("rules", hashlib.md5(str(p.get("url", "")).encode()).hexdigest())
    full = path if os.path.isabs(path) else os.path.normpath(os.path.join(HOME, path))
    if not os.path.isfile(full):
        return Cond(all_="список " + name + " ещё не скачан")
    fmt = str(p.get("format") or "yaml").lower()
    if fmt == "mrs":
        tmp = os.path.join(OUT, ".mrs.txt")
        r = run(["mihomo", "convert-ruleset", beh, "mrs", full, tmp])
        if r.returncode or not os.path.isfile(tmp):
            return Cond(all_="не прочитал список " + name)
        with open(tmp, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        os.remove(tmp)
        return clean(lines)
    if fmt == "text":
        with open(full, encoding="utf-8", errors="replace") as f:
            return clean(f.read().splitlines())
    return clean(yq_json(full, ".payload // []") or [])


def provider_eval(name, p):
    beh = str(p.get("behavior") or "classical").lower()
    if beh == "domain":
        return domain()
    items = provider_items(name, p, beh)
    if isinstance(items, Cond):
        return items
    if beh == "ipcidr":
        return nets_cond(items, name)
    return any_of([cond(it) for it in items])


def cond(text):
    parts = split(text)
    t = parts[0].upper()
    arg = parts[1] if len(parts) > 1 else ""
    if t in ("AND", "OR", "NOT"):
        kids = [cond(unwrap(k)) for k in split(unwrap(arg)) if unwrap(k)]
        if t == "NOT" or not kids:
            return Cond(all_=t)
        return any_of(kids) if t == "OR" else all_of(kids)
    if t in DOMAIN_TYPES:
        return domain()
    if t in PROCESS_TYPES:
        # Процесс находится только у программ самого роутера, не у устройств сети.
        return Cond() if PROCESS_OFF else Cond(all_=t)
    if t in ("IP-CIDR", "IP-CIDR6"):
        return nets_cond([arg], t)
    if t == "DST-PORT":
        return Cond(ports=ports_of(arg))
    if t == "NETWORK":
        return Cond() if arg.lower() == "tcp" else Cond(all_="NETWORK," + arg)
    if t == "RULE-SET":
        return provider(arg)
    return Cond(all_=t)


def direct(target, seen=()):
    if target in ("DIRECT", "PASS", "COMPATIBLE"):
        return True
    g = GROUPS.get(target)
    if not g or target in seen:
        return False
    if any(g.get(k) for k in ("use", "include-all", "include-all-proxies", "include-all-providers")):
        return False
    ps = g.get("proxies") or []
    return bool(ps) and all(direct(p, seen + (target,)) for p in ps)


def q(v):
    return "'" + str(v).replace("'", "'\\''") + "'"


def write(name, text):
    tmp = os.path.join(OUT, "." + name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, os.path.join(OUT, name))


def save(on, reason="", v4=(), v6=(), ports=()):
    write("v4.lst", "".join(x + "\n" for x in v4))
    write("v6.lst", "".join(x + "\n" for x in v6))
    write("ports", "".join(x + "\n" for x in ports))
    write("state.env", "".join(k + "=" + q(v) + "\n" for k, v in (
        ("UDPB_ON", 1 if on else 0), ("UDPB_REASON", reason), ("UDPB_V4", len(v4)),
        ("UDPB_V6", len(v6)), ("UDPB_PORTS", ",".join(ports)), ("UDPB_AT", int(time.time())))))
    if on:
        print("обход UDP: в mihomo только порты", ",".join(ports) or "—", "и", len(v4), "+", len(v6), "сетей")
    else:
        print("обход UDP выключен:", reason)


def short(rule):
    rule = str(rule)
    return rule if len(rule) <= 90 else rule[:87] + "…"


def main():
    global BASE_PORTS, PROCESS_OFF, PROVIDERS, GROUPS, DNS_LEAKS_DOMAINS, DNS_MODE
    cfg = yq_json(CONF) or {}
    sn = cfg.get("sniffer") or {}
    BASE_PORTS = set()
    quic = (sn.get("sniff") or {}).get("QUIC") if sn.get("enable") else None
    if isinstance(quic, dict):
        for x in quic.get("ports") or []:
            BASE_PORTS |= ports_of(x)
    PROCESS_OFF = str(cfg.get("find-process-mode", "")).lower() == "off"
    PROVIDERS = cfg.get("rule-providers") or {}
    GROUPS = {g.get("name"): g for g in cfg.get("proxy-groups") or [] if isinstance(g, dict)}
    dns = cfg.get("dns") or {}
    DNS_MODE = str(dns.get("enhanced-mode") or "redir-host").lower()
    listen = str(dns.get("listen") or "")
    local = listen == "" or listen.startswith(("127.", "localhost", "[::1]", "::1"))
    DNS_LEAKS_DOMAINS = bool(dns.get("enable")) and DNS_MODE != "fake-ip" and not local

    nets, ports = set(), set(BASE_PORTS)
    if dns.get("enable") and DNS_MODE == "fake-ip":
        nets.add(net(dns.get("fake-ip-range") or "198.18.0.1/16"))
        if dns.get("fake-ip-range6"):
            nets.add(net(dns["fake-ip-range6"]))
    for rule in cfg.get("rules") or []:
        parts = split(str(rule))
        t = parts[0].upper()
        if t == "MATCH":
            target, c = (parts[1] if len(parts) > 1 else ""), Cond(all_="MATCH")
        elif len(parts) >= 3:
            target, c = parts[2], None
        else:
            continue
        if direct(target):
            continue
        if c is None:
            c = cond(",".join(parts[:2]))
        if c.all is not None:
            return save(False, "правило «" + short(rule) + "» (" + c.all + ") может отправить в VPN любой UDP")
        nets |= c.nets
        ports |= c.ports

    v4 = [str(n) for n in ipaddress.collapse_addresses(sorted(n for n in nets if n.version == 4))]
    v6 = [str(n) for n in ipaddress.collapse_addresses(sorted(n for n in nets if n.version == 6))]
    merged = []
    for lo, hi in sorted(ports):
        if merged and lo <= merged[-1][1] + 1:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return save(True, "", v4, v6, [str(lo) if lo == hi else "%d:%d" % (lo, hi) for lo, hi in merged])


try:
    main()
except Exception as e:  # любой сбой разбора — весь UDP через mihomo, как раньше
    save(False, "не разобрал конфиг: %s: %s" % (type(e).__name__, str(e)[:150]))
EOF_PY
  then
    write_off "python3 завершился с ошибкой"
  fi
}

case "${1:-}" in
  build)
    take_lock 60 || exit 0
    build
    apply_all
    ;;
  apply)
    # Хук ndm не держим: идущий build сам применит правило в конце.
    take_lock 5 || exit 0
    apply_all
    ;;
  check)
    take_lock 0 || exit 0
    if need_build; then build; fi
    apply_all
    ;;
  remove)
    take_lock 30 || true
    for f in 4 6; do
      ipt=$(ipt_of "$f")
      command -v "$ipt" >/dev/null 2>&1 && drop_rules "$ipt"
      ipset destroy "dxk_udp_vpn$f" 2>/dev/null
      ipset destroy "dxk_udp_vpn${f}_new" 2>/dev/null
    done
    rm -f /tmp/dxk-udp.set4 /tmp/dxk-udp.set6 /tmp/dxk-udp.rule4 /tmp/dxk-udp.rule6
    ;;
  status)
    if [ -f "$STATE" ]; then cat "$STATE"; else echo "списки ещё не собраны"; fi
    [ "$UDP_BYPASS" != 0 ] || echo "UDP_BYPASS=0 в $SETTINGS: весь UDP через mihomo"
    for f in 4 6; do
      ipt=$(ipt_of "$f")
      command -v "$ipt" >/dev/null 2>&1 || continue
      "$ipt" -w -t mangle -S xkeen 2>/dev/null | grep -- "$TAG" || echo "$ipt: правила обхода нет"
    done
    ;;
  *)
    echo "Использование: dropweb-udp-bypass.sh build|apply|check|remove|status" >&2
    exit 2
    ;;
esac
exit 0
EOF_UDPBYPASS
}

write_udp_hook() {
mkdir -p "$(dirname "$UDP_HOOK")"
cat >"$UDP_HOOK" <<'EOF_UDPHOOK'
#!/bin/sh
# dropweb-xkeen: XKeen (proxy.sh) пересобирает цепочку xkeen при каждом
# обновлении netfilter и стирает правило обхода UDP — возвращаем его сразу.
[ "${table:-}" = mangle ] || exit 0
[ -x /opt/sbin/dropweb-udp-bypass.sh ] || exit 0
exec /opt/sbin/dropweb-udp-bypass.sh apply >/dev/null 2>&1
EOF_UDPHOOK
}

write_uninstall() {
cat >/opt/sbin/mihomo-vpn-uninstall.sh <<'EOF_UNINSTALL'
#!/opt/bin/sh
# dropweb-xkeen: удаление. XKeen и mihomo остаются (автозапуск выключен).
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
export XKEEN_FOREGROUND=1
CRONTAB=/opt/var/spool/cron/crontabs/root

echo "Выключаю VPN и удаляю dropweb-xkeen..."
if [ -x /opt/sbin/dropweb-udp-bypass.sh ]; then /opt/sbin/dropweb-udp-bypass.sh remove; fi
if [ -x /opt/sbin/mihomo-panic.sh ]; then /opt/sbin/mihomo-panic.sh; fi
if [ -x /opt/etc/init.d/S96mihomo-panel ]; then /opt/etc/init.d/S96mihomo-panel stop; fi

if [ -f "$CRONTAB" ]; then
  tmp="$CRONTAB.tmp.$$"
  grep -vE '/opt/sbin/(update-mihomo-sub\.sh|update-dropweb-mihomo\.sh|mihomo-watchdog\.sh|dropweb-xkeen-update\.sh)' "$CRONTAB" >"$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$CRONTAB"
fi
for c in /opt/etc/init.d/S05crond /opt/etc/init.d/S10cron; do
  if [ -x "$c" ]; then "$c" restart >/dev/null 2>&1; break; fi
done

rm -f /opt/etc/init.d/S96mihomo-panel /opt/etc/init.d/S97mihomo \
  /opt/sbin/update-mihomo-sub.sh /opt/sbin/mihomo-start.sh /opt/sbin/mihomo-resume.sh /opt/sbin/mihomo-panic.sh \
  /opt/sbin/mihomo-panel.py /opt/sbin/mihomo-watchdog.sh /opt/sbin/dropweb-xkeen-update.sh \
  /opt/sbin/dropweb-udp-bypass.sh /opt/etc/ndm/netfilter.d/zz-dropweb-udp.sh \
  /opt/etc/mihomo/config.yaml /opt/etc/mihomo/.sub.raw.yaml /opt/etc/mihomo/.config.new.yaml \
  /opt/etc/mihomo/.sub.headers \
  /opt/var/run/mihomo-panel.pid
rm -rf /opt/etc/mihomo/zash /opt/backups/mihomo /opt/backups/dropweb-xkeen /opt/etc/dropweb-xkeen /opt/share/dropweb-xkeen
rm -f /opt/var/log/mihomo-*.log /opt/var/log/dropweb-xkeen-update.log /opt/var/log/dropweb-udp-bypass.log

echo "Готово. XKeen и mihomo оставлены (автозапуск XKeen выключен). Удалить их полностью: xkeen -remove"
rm -f "$0"
EOF_UNINSTALL
}

inf "Пишу скрипты..."
write_updater
write_watchdog
write_panic
write_resume
write_self_updater
write_panel_init
write_udp_bypass
write_udp_hook
write_uninstall
chmod +x /opt/sbin/update-mihomo-sub.sh /opt/sbin/mihomo-watchdog.sh /opt/sbin/mihomo-panic.sh \
  /opt/sbin/mihomo-resume.sh /opt/etc/init.d/S96mihomo-panel \
  /opt/sbin/mihomo-vpn-uninstall.sh "$SELF_UPDATER" "$UDP_BYPASS_SH" "$UDP_HOOK"
ok "Скрипты в /opt/sbin и /opt/etc/init.d/S96mihomo-panel"

PANEL_FROM=""
if install_panel; then
  rm -f "$LEGACY_PANEL"
  ok "Веб-панель в $PANEL_DIR (из $PANEL_FROM)"
elif [ -f "$PANEL_DIR/mihomo-panel.py" ]; then
  warn "Не скачались файлы веб-панели ($UPDATE_URL/panel) — оставляю прежнюю версию"
else
  warn "Не скачались файлы веб-панели ($UPDATE_URL/panel) — VPN работает и без неё; повтори установку позже"
fi

# =============================================================================
# Первый конфиг
# =============================================================================
inf "Собираю конфиг mihomo из подписки..."
/opt/sbin/update-mihomo-sub.sh || warn "Скрипт обновления вернул код $? — смотри /opt/var/log/mihomo-sub-update.log"
if [ ! -f "$CONF" ]; then
  say "--- /opt/var/log/mihomo-sub-update.log ---" >&2
  tail -n 20 /opt/var/log/mihomo-sub-update.log >&2 2>/dev/null || true
  die "Конфиг mihomo не собрался."
fi
ok "Конфиг: $CONF"

# =============================================================================
# Zashboard (необязательно)
# =============================================================================
install_zash() {
  [ -x /opt/bin/unzip ] || return 1
  rm -rf "$ZASH_TMP"
  mkdir -p "$ZASH_TMP"
  curl -fsSL --connect-timeout 15 --max-time 120 -o "$ZASH_TMP/zash.zip" \
    "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip" 2>>"$INSTALL_LOG" || return 1
  /opt/bin/unzip -q "$ZASH_TMP/zash.zip" -d "$ZASH_TMP/x" >>"$INSTALL_LOG" 2>&1 || return 1
  rm -rf /opt/etc/mihomo/zash
  mkdir -p /opt/etc/mihomo/zash
  if [ -d "$ZASH_TMP/x/dist" ]; then
    cp -a "$ZASH_TMP/x/dist/." /opt/etc/mihomo/zash/ || return 1
  else
    cp -a "$ZASH_TMP/x/." /opt/etc/mihomo/zash/ || return 1
  fi
  rm -rf "$ZASH_TMP"
  [ -f /opt/etc/mihomo/zash/index.html ]
}
inf "Скачиваю дашборд zashboard..."
if install_zash; then
  ok "zashboard установлен"
else
  warn "Не смог установить zashboard (не критично — VPN работает и без него)."
fi

# =============================================================================
# cron: обновление подписки раз в час, watchdog раз в минуту, проверка
# обновлений dropweb-xkeen раз в сутки ночью
# =============================================================================
inf "Настраиваю cron..."
CRON_DIR=/opt/var/spool/cron/crontabs
CRONTAB=$CRON_DIR/root
mkdir -p "$CRON_DIR"
[ -f "$CRONTAB" ] || : >"$CRONTAB"
# Минута из HWID: роутеры не ломятся в шлюз подписки одновременно.
cron_min=$(printf '%s' "$HWID" | cksum 2>/dev/null | awk '{print $1 % 60}')
case "$cron_min" in ''|*[!0-9]*) cron_min=13 ;; esac
# Обновление — со сдвигом на полчаса от подписки (install.sh сам её обновляет)
# и в 3 или 4 часа: GitHub не получает все роутеры разом, а дома все спят.
upd_min=$(( (cron_min + 30) % 60 ))
upd_hour=$(( 3 + cron_min % 2 ))
cron_tmp="$CRON_DIR/.root.tmp.$$"
grep -vE '/opt/sbin/(update-mihomo-sub\.sh|update-dropweb-mihomo\.sh|mihomo-watchdog\.sh|dropweb-xkeen-update\.sh)' "$CRONTAB" >"$cron_tmp" || true
{
  printf '%s * * * * /opt/sbin/update-mihomo-sub.sh\n' "$cron_min"
  printf '* * * * * /opt/sbin/mihomo-watchdog.sh\n'
  printf '%s %s * * * %s auto\n' "$upd_min" "$upd_hour" "$SELF_UPDATER"
} >>"$cron_tmp"
chmod 600 "$cron_tmp"
mv "$cron_tmp" "$CRONTAB"

cron_init=""
for c in /opt/etc/init.d/S05crond /opt/etc/init.d/S10cron; do
  if [ -x "$c" ]; then cron_init=$c; break; fi
done
if [ -n "$cron_init" ]; then
  "$cron_init" restart >>"$INSTALL_LOG" 2>&1 || true
  sleep 1
fi
if [ -z "$cron_init" ]; then
  warn "Не нашёл init-скрипт cron (S05crond/S10cron) — обновление подписки и watchdog не будут запускаться."
elif [ -z "$(pidof crond 2>/dev/null || true)" ]; then
  warn "crond не запущен после $cron_init restart — проверь: $cron_init start"
else
  ok "cron: подписка в $cron_min-ю минуту каждого часа, watchdog раз в минуту"
  if [ "$AUTO_UPDATE" = 1 ]; then
    ok "cron: обновления dropweb-xkeen каждую ночь в $upd_hour:$(printf '%02d' "$upd_min")"
  else
    ok "cron: проверка обновлений в $upd_hour:$(printf '%02d' "$upd_min"), ставить — кнопкой в панели"
  fi
fi

# =============================================================================
# Кнопка FN: короткое нажатие не должно отключать флешку
# =============================================================================
# На Keenetic/Netcraze FN по умолчанию «извлекает все накопители». Вместе
# с флешкой останавливаются Entware, mihomo и панель — VPN пропадает целиком,
# а объяснить это некому: панель тоже на флешке. 2026-10-19 так и случилось
# на Hopper NC-3811. Снимаем UnmountAll с нажатий и оставляем его на удержании.
protect_usb_buttons() {
  command -v ndmc >/dev/null 2>&1 || return 1
  binds=$(ndmc -c 'show button bindings' 2>/dev/null | tr -d '\033' | awk -F': *' '
    /^[[:space:]]*button:/ { b = $2 }
    /^[[:space:]]*action:/ { a = $2 }
    /^[[:space:]]*active_handler:/ {
      h = $2; gsub(/[[:space:]]/, "", b); gsub(/[[:space:]]/, "", a); gsub(/[[:space:]]/, "", h)
      print b, a, (h == "" ? "-" : h)
    }')
  [ -n "$binds" ] || return 1
  BUTTONS_FIXED=""
  for b in $(printf '%s\n' "$binds" | awk '$3 == "UnmountAll" && ($2 == "click" || $2 == "double-click") { print $1 }' | sort -u); do
    for a in $(printf '%s\n' "$binds" | awk -v b="$b" '$1 == b && $3 == "UnmountAll" && ($2 == "click" || $2 == "double-click") { print $2 }'); do
      ndmc -c "no system button $b on $a" >>"$INSTALL_LOG" 2>&1 || return 1
    done
    # Удержание занято чем-то своим — не трогаем, флешку тогда извлекают из веб-интерфейса.
    if printf '%s\n' "$binds" | awk -v b="$b" '$1 == b && $2 == "hold" && $3 == "-" { f = 1 } END { exit !f }'; then
      ndmc -c "system button $b on hold do UnmountAll" >>"$INSTALL_LOG" 2>&1 || return 1
    fi
    BUTTONS_FIXED="$BUTTONS_FIXED $b"
  done
  [ -n "$BUTTONS_FIXED" ] || return 0
  ndmc -c 'system configuration save' >>"$INSTALL_LOG" 2>&1
}
BUTTONS_FIXED=""
if protect_usb_buttons; then
  if [ -n "$BUTTONS_FIXED" ]; then
    ok "Кнопка${BUTTONS_FIXED}: нажатие больше не отключает флешку (с ней пропал бы VPN), отключить — удержать 3 секунды"
  fi
else
  warn "Не смог проверить кнопки роутера. Не нажимай FN: она может отключить флешку, и VPN пропадёт"
fi

# =============================================================================
# Запуск
# =============================================================================
# Ручной повторный запуск включает VPN, а обновление (DXK_UPDATE=1 от
# dropweb-xkeen-update.sh) оставляет его таким, каким его выключил человек.
VPN_OFF=0
if [ "$FROM_UPDATER" = 1 ] && [ -f /opt/etc/mihomo/.disabled ]; then
  VPN_OFF=1
  inf "VPN выключен в панели — после обновления оставляю выключенным"
  # xkeen -um/-mihomo выше могли поднять mihomo заново.
  if pidof mihomo >/dev/null 2>&1; then /opt/sbin/mihomo-panic.sh >>"$INSTALL_LOG" 2>&1 || true; fi
else
  inf "Запускаю XKeen + mihomo..."
  rm -f /opt/etc/mihomo/.disabled
  /opt/sbin/xkeen -auto on </dev/null >>"$INSTALL_LOG" 2>&1 || true
  /opt/sbin/xkeen -restart </dev/null >>"$INSTALL_LOG" 2>&1 || warn "xkeen -restart вернул ошибку — подробности в $INSTALL_LOG"
fi

inf "Запускаю веб-панель..."
/opt/etc/init.d/S96mihomo-panel restart || warn "Веб-панель не запустилась — смотри /opt/var/log/mihomo-panel.log"

# =============================================================================
# Проверки
# =============================================================================
mihomo_pid=""
api_ver=""
if [ "$VPN_OFF" = 0 ]; then
  inf "Жду mihomo и его API (до 30 с)..."
  i=0
  while [ "$i" -lt 15 ]; do
    mihomo_pid=$(pidof mihomo 2>/dev/null || true)
    if [ -n "$mihomo_pid" ]; then
      api_ver=$(curl -s --max-time 3 -H "Authorization: Bearer $API_SECRET" "http://127.0.0.1:$API_PORT/version" 2>/dev/null || true)
      case "$api_ver" in *version*) break ;; esac
    fi
    sleep 2
    i=$((i + 1))
  done
fi

# Обход UDP. Списки rule-provider mihomo качает после старта: на новой
# установке ждём их до 30 с.
UDPB_STATE=$SETTINGS_DIR/udp-bypass/state.env
UDPB_REASON=""; UDPB_V4=0; UDPB_V6=0; UDPB_PORTS=""
i=0
while :; do
  "$UDP_BYPASS_SH" build >>"$INSTALL_LOG" 2>&1 || true
  if [ -f "$UDPB_STATE" ]; then
    # shellcheck source=/dev/null
    . "$UDPB_STATE"
  fi
  case "$UDPB_REASON" in
    *"ещё не скачан"*) [ "$VPN_OFF" = 0 ] && [ "$i" -lt 6 ] || break ;;
    *) break ;;
  esac
  i=$((i + 1))
  sleep 5
done

say ""
hdr "========== ИТОГ =========="
if [ "$VPN_OFF" = 1 ]; then
  warn "VPN выключен в панели: интернет идёт напрямую, включить можно там же"
else
  [ -n "$mihomo_pid" ] || die "mihomo не поднялся — смотри /opt/var/log/dropweb-xkeen-install.log и \`xkeen -diag\`"
  ok "mihomo: pid $mihomo_pid"
  case "$api_ver" in
    *version*) ok "API mihomo: $api_ver" ;;
    *) warn "API mihomo на порту $API_PORT не ответил${api_ver:+: $api_ver}" ;;
  esac

  if iptables -w -t mangle -S 2>/dev/null | grep -q -- '-j xkeen' || iptables -w -t nat -S 2>/dev/null | grep -q -- '-j xkeen'; then
    ok "Перехват трафика XKeen (iptables) активен"
  else
    warn "Правила XKeen в iptables не видны — проверь xkeen -diag"
  fi

  mixed_port=$(/opt/sbin/yq '."mixed-port" // ""' "$CONF" 2>/dev/null || true)
  if [ -n "$mixed_port" ]; then
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "http://127.0.0.1:$mixed_port" https://www.gstatic.com/generate_204 2>/dev/null || true)
    if [ "$http_code" = "204" ]; then
      ok "Выход в интернет через mihomo работает"
    else
      warn "Проверка выхода через mihomo не прошла (http=${http_code:-нет ответа}) — возможно, сервер ещё подключается"
    fi
  fi

  if [ "$UDP_BYPASS" = 0 ]; then
    ok "UDP: весь через mihomo (UDP_BYPASS=0)"
  elif iptables -w -t mangle -S xkeen 2>/dev/null | grep -q dropweb_udp_bypass; then
    ok "Игры и прочий UDP идут напрямую; в VPN — QUIC (порты $UDPB_PORTS) и звонки ($UDPB_V4 + $UDPB_V6 сетей)"
  else
    warn "Обход UDP не включился${UDPB_REASON:+: $UDPB_REASON} — весь UDP идёт через mihomo, как раньше"
  fi
fi

policy_json=$(curl -s --max-time 3 http://127.0.0.1:79/rci/show/ip/policy 2>/dev/null || true)
if [ -z "$policy_json" ]; then
  warn "не смог проверить политики"
elif printf '%s' "$policy_json" | grep -Eiq '"description"[[:space:]]*:[[:space:]]*"xkeen"'; then
  ok "Политика «xkeen» есть: через VPN идут только устройства, назначенные в неё."
else
  warn "Политики «xkeen» нет — сейчас через mihomo идут ВСЕ устройства сети (российские сайты всё равно напрямую по правилам dropweb)."
  say "     Чтобы пускать через VPN только выбранные устройства: веб-интерфейс роутера →"
  say "     «Приоритеты подключений» → добавить политику с именем xkeen → в «Список клиентов»"
  say "     назначить её нужным устройствам → затем \`xkeen -restart\`."
fi

say ""
printf '%b=========================================================%b\n' "$C_GRN" "$C_RST"
printf '%b  Готово. dropweb-xkeen %s работает.%b\n' "$C_GRN" "$SCRIPT_VERSION" "$C_RST"
printf '%b=========================================================%b\n' "$C_GRN" "$C_RST"
say ""
say "  HWID роутера:        $HWID"
say "                       так роутер виден в боте dropweb как устройство «$DEVICE_MODEL»"
say ""
say "  Веб-панель:          http://$LAN_IP:$PANEL_PORT/"
say "                       VPN вкл/выкл, проверка связи, срок подписки,"
say "                       «Обновить подписку», смена ссылки, лимит устройств,"
say "                       «Обновление» — версия, автообновление, «Обновить сейчас»"
if [ "$AUTO_UPDATE" = 1 ]; then
  say "  Обновления:          сами, ночью с GitHub; если новая версия не заработает,"
  say "                       роутер вернёт прежнюю (лог: /opt/var/log/dropweb-xkeen-update.log)"
else
  say "  Обновления:          только кнопкой в панели (AUTO_UPDATE=0)"
fi
say "  Дашборд mihomo:      http://$LAN_IP:$API_PORT/ui/"
say "                       адрес API http://$LAN_IP:$API_PORT, секрет: $API_SECRET"
say "  Вход в дашборд сразу:"
say "    http://$LAN_IP:$API_PORT/ui/#/setup?hostname=$LAN_IP&port=$API_PORT&secret=$API_SECRET"
say ""
say "  Аварийно выключить:  ssh root@$LAN_IP /opt/sbin/mihomo-panic.sh"
say "  Удалить:             /opt/sbin/mihomo-vpn-uninstall.sh"
say "  Настройки:           $SETTINGS_FILE (повторный запуск install.sh их сохранит)"
say "  Лог установки:       $INSTALL_LOG"
say ""
