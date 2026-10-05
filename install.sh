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
#    6. Ставит веб-панель «Выключить / Включить VPN», ежечасное обновление
#       подписки (по содержимому, с горячей перезагрузкой) и watchdog
#
#  Использование (на роутере по SSH под root):
#     curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/enkinvsh/dropweb-xkeen/main/install.sh
#     sh /tmp/install.sh                              # спросит ссылку
#     SUB_URL='https://...' sh /tmp/install.sh -y     # без вопросов
#  Повторный запуск = обновление (HWID и ссылка сохраняются).
#
#  Удаление:
#     /opt/sbin/mihomo-vpn-uninstall.sh
# =============================================================================

set -eu

DROPWEB_XKEEN_VERSION="2.0.0"
SCRIPT_VERSION=$DROPWEB_XKEEN_VERSION

# XKeen иначе уходит в фон и сразу возвращает 0 — нам нужен честный код возврата.
export XKEEN_FOREGROUND=1
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

INSTALL_LOG=/opt/var/log/dropweb-xkeen-install.log
SETTINGS_DIR=/opt/etc/dropweb-xkeen
SETTINGS_FILE=$SETTINGS_DIR/settings.env
LEGACY_UPDATER=/opt/sbin/update-mihomo-sub.sh
LEGACY_PANEL=/opt/sbin/mihomo-panel.py
XKEEN_INIT=/opt/etc/init.d/S05xkeen
CONF=/opt/etc/mihomo/config.yaml
PRECHECK_FILE=/tmp/dropweb-sub-check.$$
ZASH_TMP=/tmp/dropweb-zash.$$

trap 'rm -rf "$PRECHECK_FILE" "$ZASH_TMP" /tmp/xkeen-install.sh' EXIT

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
[ -x /opt/bin/opkg ] || die "OPKG/Entware не найден. Сначала включи Entware на USB через веб-интерфейс Keenetic (Приложения → OPKG)."
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

SUB_URL=""; HWID=""; DEVICE_OS=""; OS_VERSION=""; DEVICE_MODEL=""
USER_AGENT_HDR=""; PANEL_PORT=""; API_PORT=""; API_SECRET=""; LAN_IP=""

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

rand_hex() { dd if=/dev/urandom bs=1 count="$1" 2>/dev/null | od -An -tx1 | tr -d ' \n'; }

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

case "$PANEL_PORT" in ''|*[!0-9]*) die "PANEL_PORT должен быть числом (сейчас: $PANEL_PORT)" ;; esac
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
fetch_sub() {
  set -- -H "x-hwid: $HWID" -H "x-device-os: $DEVICE_OS"
  if [ -n "$OS_VERSION" ]; then set -- "$@" -H "x-ver-os: $OS_VERSION"; fi
  set -- "$@" -H "x-device-model: $DEVICE_MODEL" -A "$USER_AGENT_HDR"
  curl -fsS --connect-timeout 15 --max-time 90 --retry 2 --retry-delay 5 "$@" -o "$PRECHECK_FILE" "$SUB_URL"
}

inf "Проверяю подписку..."
fetch_sub 2>>"$INSTALL_LOG" || die_log "Не скачалась подписка: проверь ссылку/интернет"
if grep -qE 'Приложение не поддерживается|превысили лимит|00000000-0000-0000-0000-000000000000' "$PRECHECK_FILE"; then
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
# dropweb-xkeen: обновление подписки (cron раз в час).
# Коды выхода: 0 ок/без изменений, 1 не скачалось, 2 заглушка/не конфиг mihomo,
# 3 mihomo -t не принял конфиг, 4 нет settings.env.
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
export XKEEN_FOREGROUND=1

SETTINGS=/opt/etc/dropweb-xkeen/settings.env
CONF_DIR=/opt/etc/mihomo
CONF=$CONF_DIR/config.yaml
RAW=$CONF_DIR/.sub.raw.yaml
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

# Блокировка без вечных хвостов: чужой lock снимаем, если его процесс умер.
if ! mkdir "$LOCK" 2>/dev/null; then
  p=$(cat "$LOCK/pid" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && exit 0
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK" "$RAW" "$TMP"' EXIT
trap 'exit 1' INT TERM

# 1. Скачать
set -- -H "x-hwid: $HWID" -H "x-device-os: $DEVICE_OS"
if [ -n "$OS_VERSION" ]; then set -- "$@" -H "x-ver-os: $OS_VERSION"; fi
set -- "$@" -H "x-device-model: $DEVICE_MODEL" -A "$USER_AGENT_HDR"
if ! curl -fsS --connect-timeout 15 --max-time 90 --retry 2 --retry-delay 5 "$@" -o "$RAW" "$SUB_URL" 2>>"$LOG"; then
  log "ERR: подписка не скачалась; текущий конфиг не трогаю"
  exit 1
fi

# 2. Заглушка вместо подписки (лимит устройств / HWID не принят)
if grep -qE 'Приложение не поддерживается|превысили лимит|00000000-0000-0000-0000-000000000000' "$RAW"; then
  log "ERR: заглушка (лимит устройств/HWID)"
  exit 2
fi
if ! yq -e '((.proxies // []) | length) > 0' "$RAW" >/dev/null 2>&1; then
  log "ERR: в подписке нет proxies — это не конфиг mihomo"
  exit 2
fi
if ! yq -e '[(.proxies // [])[] | select(.server == "0.0.0.0")] | length == 0' "$RAW" >/dev/null 2>&1; then
  log "ERR: заглушка (сервер 0.0.0.0)"
  exit 2
fi

# 3. Наши правки поверх шаблона dropweb.
# В шаблоне allow-lan: false, а с ним redir-port/tproxy-port слушают только
# 127.0.0.1 — REDIRECT приходит на LAN-адрес и отбивается. Записи listeners
# слушают 0.0.0.0 независимо от allow-lan, поэтому порты XKeen задаём там.
# mixed-port остаётся только для самого роутера. TUN на роутере ломает маршрутизацию.
export API_PORT API_SECRET
EXPR='
.tun.enable = false |
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
  exit 2
fi

# 4. Проверка mihomo
if ! mihomo -t -d "$CONF_DIR" -f "$TMP" >>"$LOG" 2>&1; then
  log "ERR: mihomo -t не принял конфиг; текущий не трогаю"
  exit 3
fi

# 5. Сравнение всего содержимого (не только имён нод)
if [ -f "$CONF" ] && cmp -s "$TMP" "$CONF"; then
  log "без изменений"
  exit 0
fi

# 6. Бэкап и замена
if [ -f "$CONF" ]; then
  cp "$CONF" "$BACKUP_DIR/config.yaml.$(date '+%Y%m%d-%H%M%S').bak"
fi
# shellcheck disable=SC2012 # имена бэкапов наши, без пробелов; нужна сортировка по времени
ls -t "$BACKUP_DIR"/config.yaml.*.bak 2>/dev/null | sed -n '6,$p' | while read -r f; do rm -f "$f"; done
mv "$TMP" "$CONF"
chmod 600 "$CONF"
log "конфиг обновлён"

# 7. Горячая перезагрузка без обрыва соединений
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

exit 0
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
grep -Eq '^[[:space:]]*start_auto="on"' /opt/etc/init.d/S05xkeen 2>/dev/null || exit 0
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

write_panel() {
cat >/opt/sbin/mihomo-panel.py <<'EOF_PANEL'
#!/opt/bin/python3
# dropweb-xkeen: веб-панель «Выключить / Включить VPN» (python3 stdlib).
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess, os, json, datetime, re, sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8181
PANIC = "/opt/sbin/mihomo-panic.sh"
START = "/opt/sbin/mihomo-resume.sh"
CONF = "/opt/etc/mihomo/config.yaml"
DISABLED = "/opt/etc/mihomo/.disabled"
XKEEN_INIT = "/opt/etc/init.d/S05xkeen"
LOG_PATH = "/opt/var/log/mihomo-panel.log"
RUN_TIMEOUT = 90

def log(msg):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {msg}\n")
    except OSError: pass

def mihomo_pid():
    out = subprocess.run(["pidof","mihomo"], capture_output=True, text=True)
    return out.stdout.strip() or None

def autostart():
    try:
        with open(XKEEN_INIT, encoding="utf-8", errors="replace") as f:
            return any(re.match(r'\s*start_auto="on"', line) for line in f)
    except OSError:
        return False

def updated():
    try:
        return datetime.datetime.fromtimestamp(os.path.getmtime(CONF)).strftime("%Y-%m-%d %H:%M")
    except OSError:
        return None

PAGE = """<!DOCTYPE html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPN на роутере</title>
<style>
:root{color-scheme:dark;--bg:#0f1115;--card:#181b22;--mut:#8b8f99;--ok:#22c55e;--bad:#ef4444;--warn:#eab308;--btn-bad:#dc2626;--btn-ok:#16a34a;--fg:#e7e9ee}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,system-ui,sans-serif;display:grid;place-items:center;min-height:100dvh;padding:24px}
.card{background:var(--card);border-radius:24px;padding:32px;max-width:520px;width:100%;box-shadow:0 20px 60px rgba(0,0,0,.4)}
h1{margin:0 0 8px;font-size:22px;font-weight:600}p.sub{margin:0 0 24px;color:var(--mut);font-size:14px}
.status{display:flex;align-items:center;gap:12px;padding:16px 20px;background:#222732;border-radius:16px;margin-bottom:24px}
.dot{width:14px;height:14px;border-radius:50%;flex:0 0 auto;box-shadow:0 0 0 4px rgba(255,255,255,.04)}
.ok .dot{background:var(--ok);box-shadow:0 0 0 4px rgba(34,197,94,.15)}
.bad .dot{background:var(--bad);box-shadow:0 0 0 4px rgba(239,68,68,.15)}
.warn .dot{background:var(--warn);box-shadow:0 0 0 4px rgba(234,179,8,.15)}
.s-text{font-weight:600;font-size:17px}.s-sub{color:var(--mut);font-size:13px;margin-top:2px}
.btn{display:block;width:100%;border:0;border-radius:18px;padding:22px;font-size:18px;font-weight:600;color:#fff;cursor:pointer;margin-bottom:12px;transition:transform .04s,filter .15s;font-family:inherit}
.btn:active{transform:scale(.98)}.btn:hover{filter:brightness(1.08)}
.btn-bad{background:var(--btn-bad)}.btn-ok{background:var(--btn-ok)}
.btn:disabled{opacity:.45;cursor:not-allowed;filter:none}
.hint{color:var(--mut);font-size:13px;line-height:1.55;margin-top:18px;padding-top:18px;border-top:1px solid #262b36}.hint b{color:var(--fg)}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:#262b36;color:#fff;padding:12px 18px;border-radius:12px;font-size:14px;opacity:0;transition:opacity .2s;pointer-events:none;box-shadow:0 12px 30px rgba(0,0,0,.5)}.toast.show{opacity:1}
</style></head><body>
<main class="card">
<h1>VPN на роутере</h1>
<p class="sub">Если интернет странно работает или сайты не открываются — выключи VPN.</p>
<div id="status" class="status"><div class="dot"></div>
<div><div class="s-text" id="s-text">Проверяю…</div><div class="s-sub" id="s-sub">&nbsp;</div></div></div>
<button id="btn-off" class="btn btn-bad">⛔ Выключить VPN</button>
<button id="btn-on"  class="btn btn-ok" >✅ Включить VPN</button>
<p class="hint"><b>Если интернет пропал</b> — нажми «Выключить VPN»: всё пойдёт напрямую, и VPN не включится сам даже после перезагрузки роутера, пока не нажмёшь «Включить». Если эта страница не открывается: <code>ssh root@<span id="router"></span> /opt/sbin/mihomo-panic.sh</code><br><br>
Эта страница: <code id="addr"></code></p>
</main>
<div id="toast" class="toast"></div>
<script>
document.getElementById('addr').textContent=location.origin+'/';
document.getElementById('router').textContent=location.hostname;
const byId=id=>document.getElementById(id);
function toast(t){const e=byId('toast');e.textContent=t;e.classList.add('show');setTimeout(()=>e.classList.remove('show'),2500)}
async function refresh(){
 try{const r=await fetch('/status',{cache:'no-store'});const j=await r.json();
  const s=byId('status'),txt=byId('s-text'),sub=byId('s-sub'),off=byId('btn-off'),on=byId('btn-on');
  if(j.running){s.className='status ok';txt.textContent='VPN работает';sub.textContent='mihomo pid '+j.pid+' · подписка обновлена '+(j.updated||'—')}
  else if(j.disabled){s.className='status bad';txt.textContent='VPN выключен';sub.textContent='Интернет идёт напрямую. Выключение сохранится и после перезагрузки'}
  else{s.className='status warn';txt.textContent='VPN перезапускается';sub.textContent='Поднимется автоматически в течение минуты'}
  off.disabled=!!j.disabled;on.disabled=!(j.disabled||!j.running);
 }catch(e){byId('s-text').textContent='Не могу связаться с роутером';byId('s-sub').textContent=String(e)}
}
async function action(p,l){if(!confirm(l+'? Подтверди.'))return;toast('Работаю…');
 try{const r=await fetch(p,{method:'POST',headers:{'X-Dropweb-Panel':'1'}});const j=await r.json();toast(j.ok?'Готово':'Ошибка: '+(j.error||'?'))}
 catch(e){toast('Сбой: '+e)}setTimeout(refresh,1500)}
byId('btn-off').onclick=()=>action('/panic','Выключить VPN');
byId('btn-on').onclick =()=>action('/resume','Включить VPN');
refresh();setInterval(refresh,5000);
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def log_message(self,fmt,*a): log("HTTP "+(fmt%a))
    def _send(self,c,b,t="text/html; charset=utf-8"):
        d=b.encode() if isinstance(b,str) else b
        self.send_response(c); self.send_header("Content-Type",t); self.send_header("Content-Length",str(len(d))); self.send_header("Cache-Control","no-store"); self.end_headers(); self.wfile.write(d)
    def _json(self,c,obj): return self._send(c, json.dumps(obj), "application/json")
    def _run(self,cmd):
        if not os.path.exists(cmd): return self._json(500, {"ok":False,"error":"script missing"})
        try:
            r=subprocess.run([cmd],capture_output=True,text=True,timeout=RUN_TIMEOUT)
        except subprocess.TimeoutExpired:
            return self._json(200, {"ok":False,"error":"timeout"})
        except OSError as e:
            return self._json(500, {"ok":False,"error":str(e)})
        return self._json(200, {"ok":r.returncode==0,"rc":r.returncode,"stdout":r.stdout[-2000:],"stderr":r.stderr[-2000:]})
    def do_GET(self):
        path=self.path.split("?",1)[0]
        if path in ("/","/index.html"): return self._send(200, PAGE)
        if path == "/status":
            p=mihomo_pid()
            return self._json(200, {"running":p is not None,"pid":p,"disabled":os.path.exists(DISABLED),"autostart":autostart(),"updated":updated()})
        return self._send(404,"not found","text/plain; charset=utf-8")
    def do_POST(self):
        path=self.path.split("?",1)[0]
        if path not in ("/panic","/resume"): return self._send(404,"not found","text/plain; charset=utf-8")
        # Защита от чужих сайтов: свой заголовок требует CORS preflight, а OPTIONS мы не отвечаем.
        if self.headers.get("X-Dropweb-Panel") != "1":
            return self._json(403, {"ok":False,"error":"forbidden"})
        return self._run(PANIC if path == "/panic" else START)

if __name__ == "__main__":
    log(f"start on :{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
EOF_PANEL
}

write_panel_init() {
cat >/opt/etc/init.d/S96mihomo-panel <<'EOF_PANEL_INIT'
#!/opt/bin/sh
# dropweb-xkeen: автозапуск веб-панели. Без rc.func: его stop делает killall python3.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
PIDFILE=/opt/var/run/mihomo-panel.pid
PANEL=/opt/sbin/mihomo-panel.py
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

write_uninstall() {
cat >/opt/sbin/mihomo-vpn-uninstall.sh <<'EOF_UNINSTALL'
#!/opt/bin/sh
# dropweb-xkeen: удаление. XKeen и mihomo остаются (автозапуск выключен).
set -u
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
export XKEEN_FOREGROUND=1
CRONTAB=/opt/var/spool/cron/crontabs/root

echo "Выключаю VPN и удаляю dropweb-xkeen..."
if [ -x /opt/sbin/mihomo-panic.sh ]; then /opt/sbin/mihomo-panic.sh; fi
if [ -x /opt/etc/init.d/S96mihomo-panel ]; then /opt/etc/init.d/S96mihomo-panel stop; fi

if [ -f "$CRONTAB" ]; then
  tmp="$CRONTAB.tmp.$$"
  grep -vE '/opt/sbin/(update-mihomo-sub\.sh|update-dropweb-mihomo\.sh|mihomo-watchdog\.sh)' "$CRONTAB" >"$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$CRONTAB"
fi
for c in /opt/etc/init.d/S05crond /opt/etc/init.d/S10cron; do
  if [ -x "$c" ]; then "$c" restart >/dev/null 2>&1; break; fi
done

rm -f /opt/etc/init.d/S96mihomo-panel /opt/etc/init.d/S97mihomo \
  /opt/sbin/update-mihomo-sub.sh /opt/sbin/mihomo-start.sh /opt/sbin/mihomo-resume.sh /opt/sbin/mihomo-panic.sh \
  /opt/sbin/mihomo-panel.py /opt/sbin/mihomo-watchdog.sh \
  /opt/etc/mihomo/config.yaml /opt/etc/mihomo/.sub.raw.yaml /opt/etc/mihomo/.config.new.yaml \
  /opt/var/run/mihomo-panel.pid
rm -rf /opt/etc/mihomo/zash /opt/backups/mihomo /opt/etc/dropweb-xkeen
rm -f /opt/var/log/mihomo-*.log

echo "Готово. XKeen и mihomo оставлены (автозапуск XKeen выключен). Удалить их полностью: xkeen -remove"
rm -f "$0"
EOF_UNINSTALL
}

inf "Пишу скрипты..."
write_updater
write_watchdog
write_panic
write_resume
write_panel
write_panel_init
write_uninstall
chmod +x /opt/sbin/update-mihomo-sub.sh /opt/sbin/mihomo-watchdog.sh /opt/sbin/mihomo-panic.sh \
  /opt/sbin/mihomo-resume.sh /opt/sbin/mihomo-panel.py /opt/etc/init.d/S96mihomo-panel \
  /opt/sbin/mihomo-vpn-uninstall.sh
ok "Скрипты в /opt/sbin и /opt/etc/init.d/S96mihomo-panel"

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
# cron: обновление подписки раз в час + watchdog раз в минуту
# =============================================================================
inf "Настраиваю cron..."
CRON_DIR=/opt/var/spool/cron/crontabs
CRONTAB=$CRON_DIR/root
mkdir -p "$CRON_DIR"
[ -f "$CRONTAB" ] || : >"$CRONTAB"
# Минута из HWID: роутеры не ломятся в шлюз подписки одновременно.
cron_min=$(printf '%s' "$HWID" | cksum 2>/dev/null | awk '{print $1 % 60}')
case "$cron_min" in ''|*[!0-9]*) cron_min=13 ;; esac
cron_tmp="$CRON_DIR/.root.tmp.$$"
grep -vE '/opt/sbin/(update-mihomo-sub\.sh|update-dropweb-mihomo\.sh|mihomo-watchdog\.sh)' "$CRONTAB" >"$cron_tmp" || true
printf '%s * * * * /opt/sbin/update-mihomo-sub.sh\n' "$cron_min" >>"$cron_tmp"
printf '* * * * * /opt/sbin/mihomo-watchdog.sh\n' >>"$cron_tmp"
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
fi

# =============================================================================
# Запуск
# =============================================================================
inf "Запускаю XKeen + mihomo..."
rm -f /opt/etc/mihomo/.disabled
/opt/sbin/xkeen -auto on </dev/null >>"$INSTALL_LOG" 2>&1 || true
/opt/sbin/xkeen -restart </dev/null >>"$INSTALL_LOG" 2>&1 || warn "xkeen -restart вернул ошибку — подробности в $INSTALL_LOG"

inf "Запускаю веб-панель..."
/opt/etc/init.d/S96mihomo-panel restart || warn "Веб-панель не запустилась — смотри /opt/var/log/mihomo-panel.log"

# =============================================================================
# Проверки
# =============================================================================
inf "Жду mihomo и его API (до 30 с)..."
mihomo_pid=""
api_ver=""
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

say ""
hdr "========== ИТОГ =========="
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
say "  Веб-панель Вкл/Выкл: http://$LAN_IP:$PANEL_PORT/"
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
