#!/opt/bin/sh
# =============================================================================
#  Keenetic + Mihomo + XKeen + панель + автообновление подписки
#  Установщик для пользователей VPN
#
#  Что делает скрипт:
#    1. Проверяет, что Entware/OPKG установлены
#    2. Ставит XKeen (если ещё не стоит) и через него — Mihomo + yq
#    3. Тянет YAML-подписку с нужными HWID-заголовками
#    4. Делает безопасный конфиг: только Mixed SOCKS5/HTTP на :1080,
#       без TUN, без перехвата LAN — если mihomo упадёт, инет не отвалится
#    5. Ставит веб-панель «Включить / Выключить VPN» на :8181
#    6. Ставит cron каждый час для обновления подписки (горячая перезагрузка)
#    7. Ставит автозапуск через Entware init.d (с уважением kill switch)
#
#  Использование (на роутере по SSH под root):
#     wget -O install.sh <URL> && chmod +x install.sh && ./install.sh
#  или скопировать содержимое и запустить:
#     ./install.sh
#
#  Деинсталляция:
#     /opt/sbin/mihomo-vpn-uninstall.sh
# =============================================================================

set -eu

# --- defaults (можно переопределить через env-переменные перед запуском) ---
SUB_URL="${SUB_URL:-}"
HWID="${HWID:-}"
DEVICE_OS="${DEVICE_OS:-KeeneticOS}"
DEVICE_MODEL="${DEVICE_MODEL:-Keenetic Router}"
USER_AGENT_HDR="${USER_AGENT_HDR:-clash.meta}"
PANEL_PORT="${PANEL_PORT:-8181}"
LAN_IP="${LAN_IP:-192.168.1.1}"

# --- цветной вывод ---
if [ -t 1 ]; then
  C_RED="\033[1;31m"; C_GRN="\033[1;32m"; C_YEL="\033[1;33m"; C_CYN="\033[1;36m"; C_RST="\033[0m"
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_RST=""
fi
say() { printf "%b\n" "$*"; }
ok()  { say "${C_GRN}[OK]${C_RST} $*"; }
inf() { say "${C_CYN}[..]${C_RST} $*"; }
warn(){ say "${C_YEL}[!!]${C_RST} $*"; }
die() { say "${C_RED}[XX]${C_RST} $*"; exit 1; }

ask() {
  prompt="$1"; default="${2:-}"; var=""
  if [ -n "$default" ]; then printf "%s [%s]: " "$prompt" "$default"
  else printf "%s: " "$prompt"; fi
  read -r var || true
  [ -z "$var" ] && var="$default"
  printf "%s" "$var"
}

# --- preflight ---
inf "Проверяю окружение..."
[ "$(id -u)" = "0" ] || die "Запускай от root (Entware): ssh root@${LAN_IP}"
[ -x /opt/bin/opkg ] || die "OPKG/Entware не найден. Сначала включи Entware на USB через веб-морду Keenetic (Приложения → OPKG)."
[ -x /opt/bin/curl ] || /opt/bin/opkg update >/dev/null && /opt/bin/opkg install curl >/dev/null 2>&1 || true
[ -x /opt/bin/curl ] || die "Не смог поставить curl через opkg."
[ -x /opt/bin/python3 ] || /opt/bin/opkg install python3 >/dev/null 2>&1 || true
[ -x /opt/bin/python3 ] || die "Нужен python3 (для веб-панели). opkg install python3 не сработал."
ok "Entware, curl, python3 на месте."

# --- интерактивный сбор параметров ---
say ""
say "${C_CYN}===========================================================${C_RST}"
say "${C_CYN} Установка Mihomo VPN на Keenetic (для пользователя)${C_RST}"
say "${C_CYN}===========================================================${C_RST}"
say ""

if [ -z "$SUB_URL" ]; then
  while [ -z "$SUB_URL" ]; do
    SUB_URL=$(ask "URL подписки (https://...)")
    [ -z "$SUB_URL" ] && warn "Пустой URL. Попробуй ещё раз."
  done
fi

if [ -z "$HWID" ]; then
  random_id=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' || /opt/bin/python3 -c 'import secrets;print(secrets.token_hex(8))')
  HWID=$(ask "HWID (уникальный идентификатор устройства)" "keenetic-${random_id}")
fi

DEVICE_OS=$(ask    "x-device-os" "$DEVICE_OS")
DEVICE_MODEL=$(ask "x-device-model" "$DEVICE_MODEL")
USER_AGENT_HDR=$(ask "User-Agent" "$USER_AGENT_HDR")
PANEL_PORT=$(ask     "Порт веб-панели" "$PANEL_PORT")

say ""
inf "Параметры:"
say "  URL          : $SUB_URL"
say "  HWID         : $HWID"
say "  device-os    : $DEVICE_OS"
say "  device-model : $DEVICE_MODEL"
say "  user-agent   : $USER_AGENT_HDR"
say "  panel-port   : $PANEL_PORT"
say ""
printf "Продолжить установку? [y/N]: "
read -r _ans || true
case "${_ans:-}" in y|Y|yes|YES) : ;; *) die "Отменено."; esac

# --- проверка/установка XKeen (нужен для удобной установки mihomo+yq) ---
if [ ! -x /opt/sbin/xkeen ]; then
  inf "XKeen не найден. Ставлю (потребует доступ к GitHub)..."
  /opt/bin/opkg update >/dev/null
  /opt/bin/opkg install curl tar >/dev/null 2>&1 || true
  ( cd /tmp && sh -c "$(curl -fsSL https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh)" )
  [ -x /opt/sbin/xkeen ] || die "Установка XKeen сорвалась. Поставь руками с https://github.com/jameszeroX/XKeen и запусти меня снова."
  ok "XKeen установлен."
else
  ok "XKeen уже стоит ($(/opt/sbin/xkeen -v 2>/dev/null | head -1 || echo "версия неизвестна"))."
fi

# --- mihomo + yq ---
if [ ! -x /opt/sbin/mihomo ] || [ ! -x /opt/sbin/yq ]; then
  inf "Ставлю Mihomo + yq через XKeen (выбираю последнюю стабильную)..."
  printf "1\n" | /opt/sbin/xkeen -um >/tmp/xkeen-um.log 2>&1 || die "xkeen -um провалился: $(tail -n 5 /tmp/xkeen-um.log)"
  ok "Mihomo установлен: $(/opt/sbin/mihomo -v 2>&1 | head -1)"
fi
[ -x /opt/sbin/mihomo ] || die "/opt/sbin/mihomo отсутствует."
[ -x /opt/sbin/yq ]     || die "/opt/sbin/yq отсутствует."

# --- глушим автозапуск XKeen (чтобы его iptables/policy не вмешивались) ---
if [ -f /opt/etc/init.d/S99xkeen ]; then
  sed -i 's/start_auto="on"/start_auto="off"/' /opt/etc/init.d/S99xkeen 2>/dev/null || true
  /opt/sbin/xkeen -stop >/dev/null 2>&1 || true
fi

# --- директории/логи ---
mkdir -p /opt/etc/mihomo /opt/var/log /opt/backups/mihomo /opt/var/spool/cron/crontabs

# =============================================================================
# Файл: /opt/sbin/update-mihomo-sub.sh
# =============================================================================
inf "Создаю update-скрипт..."
cat > /opt/sbin/update-mihomo-sub.sh <<UPDATE_EOF
#!/opt/bin/sh
# Hourly subscription updater. Tянет YAML с HWID-заголовками,
# валидирует, hot-reload через Mihomo API без рестарта процесса.
set -eu

SUB_URL="${SUB_URL}"
HWID="${HWID}"
DEVICE_OS="${DEVICE_OS}"
DEVICE_MODEL="${DEVICE_MODEL}"
USER_AGENT_HDR="${USER_AGENT_HDR}"

CONF_DIR="/opt/etc/mihomo"
CONF="\$CONF_DIR/config.yaml"
TMP="\$CONF_DIR/config.yaml.new"
BACKUP_DIR="/opt/backups/mihomo"
LOG="/opt/var/log/mihomo-sub-update.log"
LOCK="/tmp/mihomo-sub-update.lock"
KEEP=5

mkdir -p "\$CONF_DIR" "\$BACKUP_DIR" "\$(dirname "\$LOG")"
log(){ echo "[\$(date '+%F %T')] \$*" >> "\$LOG"; }

if [ -f "\$LOCK" ]; then
  oldpid="\$(cat "\$LOCK" 2>/dev/null || true)"
  [ -n "\$oldpid" ] && kill -0 "\$oldpid" 2>/dev/null && { log "skip: another run pid=\$oldpid"; exit 0; }
fi
echo \$\$ > "\$LOCK"
trap 'rm -f "\$LOCK" "\$TMP"' EXIT INT TERM

log "fetch begin"
if ! /opt/bin/curl -fsSL --connect-timeout 15 --max-time 90 \\
  -H "x-hwid: \$HWID" \\
  -H "x-device-os: \$DEVICE_OS" \\
  -H "x-device-model: \$DEVICE_MODEL" \\
  -H "user-agent: \$USER_AGENT_HDR" \\
  "\$SUB_URL" -o "\$TMP"; then
  log "ERR: curl failed; keep current"; exit 1
fi

if grep -q "Приложение не поддерживается\\|00000000-0000-0000-0000-000000000000\\|0\\.0\\.0\\.0:1" "\$TMP"; then
  log "ERR: placeholder returned (HWID rejected); keep current"; exit 2
fi

# harden: kill TUN/auto-route and force ports/UI
/opt/sbin/yq -i '
  ."mixed-port" = 1080 |
  ."tproxy-port" = 1181 |
  ."redir-port" = 1182 |
  ."external-controller" = "0.0.0.0:9090" |
  ."external-ui" = "./zash" |
  ."external-ui-url" = "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip" |
  .tun.enable = false |
  .tun."auto-route" = false |
  .tun."auto-redirect" = false |
  .tun."auto-detect-interface" = false
' "\$TMP"

if ! /opt/sbin/mihomo -t -f "\$TMP" -d "\$CONF_DIR" >> "\$LOG" 2>&1; then
  log "ERR: mihomo -t failed; keep current"; exit 3
fi

NEW_KEY=\$(/opt/sbin/yq e '.proxies[] | (.name + "|" + .server + ":" + (.port|tostring))' "\$TMP" 2>/dev/null | sort | sha256sum | awk '{print \$1}')
OLD_KEY=""
[ -f "\$CONF" ] && OLD_KEY=\$(/opt/sbin/yq e '.proxies[] | (.name + "|" + .server + ":" + (.port|tostring))' "\$CONF" 2>/dev/null | sort | sha256sum | awk '{print \$1}')

if [ "\$NEW_KEY" = "\$OLD_KEY" ] && [ -f "\$CONF" ]; then
  log "no node changes; skip reload"; rm -f "\$TMP"; exit 0
fi

if [ -f "\$CONF" ]; then
  cp "\$CONF" "\$BACKUP_DIR/config.yaml.\$(date '+%Y%m%d-%H%M%S').bak"
  ls -t "\$BACKUP_DIR"/config.yaml.*.bak 2>/dev/null | sed -n "\$((KEEP+1)),9999p" | xargs rm -f 2>/dev/null || true
fi
mv "\$TMP" "\$CONF"
chmod 644 "\$CONF"
log "config replaced (nodes=\$NEW_KEY)"

if pidof mihomo >/dev/null 2>&1; then
  CODE=\$(/opt/bin/curl -s -o /tmp/mihomo-reload.out -w "%{http_code}" --max-time 10 \\
    -X PUT -H "Content-Type: application/json" \\
    --data "{\"path\":\"\$CONF\"}" \\
    http://127.0.0.1:9090/configs?force=true || echo "000")
  case "\$CODE" in 200|204) log "hot-reload OK (\$CODE)" ;; *) log "WARN: hot-reload http=\$CODE: \$(cat /tmp/mihomo-reload.out 2>/dev/null)" ;; esac
fi
log "done"
UPDATE_EOF
chmod +x /opt/sbin/update-mihomo-sub.sh
ok "/opt/sbin/update-mihomo-sub.sh"

# =============================================================================
# Файл: /opt/sbin/mihomo-start.sh
# =============================================================================
cat > /opt/sbin/mihomo-start.sh <<'STARTEOF'
#!/opt/bin/sh
set -eu
CONF_DIR="/opt/etc/mihomo"; DISABLED="$CONF_DIR/.disabled"; LOG="/opt/var/log/mihomo.log"
mkdir -p "$(dirname "$LOG")"
[ -f "$DISABLED" ] && { echo "skip: kill switch ($DISABLED)"; exit 0; }
pidof mihomo >/dev/null 2>&1 && { echo "already running pid=$(pidof mihomo)"; exit 0; }
/opt/sbin/mihomo -t -d "$CONF_DIR" >/dev/null 2>>"$LOG" || { echo "ERR: mihomo -t failed" >&2; exit 3; }
nohup /opt/sbin/mihomo -d "$CONF_DIR" >> "$LOG" 2>&1 &
disown 2>/dev/null || true
sleep 2
pidof mihomo >/dev/null 2>&1 && { echo "started pid=$(pidof mihomo)"; exit 0; }
echo "ERR: failed to start" >&2; tail -n 5 "$LOG" >&2 || true; exit 1
STARTEOF
chmod +x /opt/sbin/mihomo-start.sh
ok "/opt/sbin/mihomo-start.sh"

# =============================================================================
# Файл: /opt/sbin/mihomo-resume.sh
# =============================================================================
cat > /opt/sbin/mihomo-resume.sh <<'RESUMEEOF'
#!/opt/bin/sh
set -eu
CRON="/opt/var/spool/cron/crontabs/root"
LINE="13 * * * * /opt/sbin/update-mihomo-sub.sh"
rm -f /opt/etc/mihomo/.disabled
mkdir -p "$(dirname "$CRON")"; touch "$CRON"
grep -qF "/opt/sbin/update-mihomo-sub.sh" "$CRON" || { printf "%s\n" "$LINE" >> "$CRON"; chmod 600 "$CRON"; /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true; }
exec /opt/sbin/mihomo-start.sh
RESUMEEOF
chmod +x /opt/sbin/mihomo-resume.sh
ok "/opt/sbin/mihomo-resume.sh"

# =============================================================================
# Файл: /opt/sbin/mihomo-panic.sh
# =============================================================================
cat > /opt/sbin/mihomo-panic.sh <<'PANICEOF'
#!/opt/bin/sh
set +e
DISABLED="/opt/etc/mihomo/.disabled"
mkdir -p "$(dirname "$DISABLED")"
echo "[$(date '+%F %T')] PANIC: stopping VPN"
date "+disabled at %F %T" > "$DISABLED"
[ -x /opt/etc/init.d/S97mihomo ] && /opt/etc/init.d/S97mihomo stop 2>/dev/null
/opt/sbin/xkeen -stop 2>/dev/null
for i in 1 2 3; do
  pidof mihomo >/dev/null 2>&1 || break
  killall mihomo 2>/dev/null
  sleep 1
done
killall -9 mihomo 2>/dev/null
[ -f /opt/etc/init.d/S99xkeen ] && sed -i 's/start_auto="on"/start_auto="off"/' /opt/etc/init.d/S99xkeen
if [ -f /opt/var/spool/cron/crontabs/root ]; then
  grep -vE "/opt/sbin/(xkeen -ug|update-mihomo-sub\.sh|update-dropweb-mihomo\.sh)" \
    /opt/var/spool/cron/crontabs/root > /tmp/root.cron 2>/dev/null
  mv /tmp/root.cron /opt/var/spool/cron/crontabs/root 2>/dev/null
  chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null
fi
/opt/etc/init.d/S10cron restart >/dev/null 2>&1
ip rule | awk -F: '/fwmark/ && $0 !~ /0xffffaaa/ {print $1}' | while read p; do
  [ -n "$p" ] && ip rule del prio "$p" 2>/dev/null
done
echo "[$(date '+%F %T')] PANIC done"
echo "mihomo: $(pidof mihomo || echo not running)"
echo "kill switch: $DISABLED"
PANICEOF
chmod +x /opt/sbin/mihomo-panic.sh
ok "/opt/sbin/mihomo-panic.sh"

# =============================================================================
# Файл: /opt/sbin/mihomo-panel.py (веб-панель)
# =============================================================================
inf "Ставлю веб-панель..."
cat > /opt/sbin/mihomo-panel.py <<PANELEOF
#!/opt/bin/python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess, os, json, datetime
PORT = ${PANEL_PORT}
PANIC = "/opt/sbin/mihomo-panic.sh"
START = "/opt/sbin/mihomo-resume.sh"
LOG_PATH = "/opt/var/log/mihomo-panel.log"

def log(msg):
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {msg}\n")
    except OSError: pass

def running(): return subprocess.run(["pidof","mihomo"], stdout=subprocess.DEVNULL).returncode == 0
def pid():
    out = subprocess.run(["pidof","mihomo"], capture_output=True, text=True)
    return out.stdout.strip() or "-"

PAGE = """<!DOCTYPE html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPN на роутере</title>
<style>
:root{color-scheme:dark;--bg:#0f1115;--card:#181b22;--mut:#8b8f99;--ok:#22c55e;--bad:#ef4444;--btn-bad:#dc2626;--btn-ok:#16a34a;--fg:#e7e9ee}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,system-ui,sans-serif;display:grid;place-items:center;min-height:100dvh;padding:24px}
.card{background:var(--card);border-radius:24px;padding:32px;max-width:520px;width:100%;box-shadow:0 20px 60px rgba(0,0,0,.4)}
h1{margin:0 0 8px;font-size:22px;font-weight:600}p.sub{margin:0 0 24px;color:var(--mut);font-size:14px}
.status{display:flex;align-items:center;gap:12px;padding:16px 20px;background:#222732;border-radius:16px;margin-bottom:24px}
.dot{width:14px;height:14px;border-radius:50%;flex:0 0 auto;box-shadow:0 0 0 4px rgba(255,255,255,.04)}
.ok .dot{background:var(--ok);box-shadow:0 0 0 4px rgba(34,197,94,.15)}
.bad .dot{background:var(--bad);box-shadow:0 0 0 4px rgba(239,68,68,.15)}
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
<p class="hint"><b>Если ничего не работает</b> — выдерни питание роутера на 10 секунд и воткни обратно. VPN сам не поднимется, обычный интернет вернётся.<br><br>
Эта страница: <code id="addr"></code></p>
</main>
<div id="toast" class="toast"></div>
<script>
document.getElementById('addr').textContent=location.origin+'/';
const byId=id=>document.getElementById(id);
function toast(t){const e=byId('toast');e.textContent=t;e.classList.add('show');setTimeout(()=>e.classList.remove('show'),2500)}
async function refresh(){
 try{const r=await fetch('/status',{cache:'no-store'});const j=await r.json();
  const s=byId('status'),txt=byId('s-text'),sub=byId('s-sub'),off=byId('btn-off'),on=byId('btn-on');
  if(j.running){s.className='status ok';txt.textContent='VPN работает';sub.textContent='Процесс mihomo запущен (pid '+j.pid+')';off.disabled=false;on.disabled=true}
  else{s.className='status bad';txt.textContent='VPN выключен';sub.textContent='Интернет идёт напрямую, без VPN';off.disabled=true;on.disabled=false}
 }catch(e){byId('s-text').textContent='Не могу связаться с роутером';byId('s-sub').textContent=String(e)}
}
async function action(p,l){if(!confirm(l+'? Подтверди.'))return;toast('Работаю…');
 try{const r=await fetch(p,{method:'POST'});const j=await r.json();toast(j.ok?'Готово':'Ошибка: '+(j.error||'?'))}
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
    def do_GET(self):
        if self.path in ("/","/index.html") or self.path.startswith("/?"): return self._send(200, PAGE)
        if self.path == "/status":
            r=running(); return self._send(200, json.dumps({"running":r,"pid":pid() if r else None}), "application/json")
        return self._send(404,"not found","text/plain; charset=utf-8")
    def do_POST(self):
        if self.path == "/panic":
            r=subprocess.run([PANIC],capture_output=True,text=True,timeout=30)
            return self._send(200, json.dumps({"ok":r.returncode==0,"rc":r.returncode,"stdout":r.stdout[-2000:],"stderr":r.stderr[-2000:]}), "application/json")
        if self.path == "/resume":
            if not os.path.exists(START): return self._send(500, json.dumps({"ok":False,"error":"start script missing"}), "application/json")
            r=subprocess.run([START],capture_output=True,text=True,timeout=30)
            return self._send(200, json.dumps({"ok":r.returncode==0,"rc":r.returncode,"stdout":r.stdout[-2000:],"stderr":r.stderr[-2000:]}), "application/json")
        return self._send(404,"not found","text/plain; charset=utf-8")

if __name__ == "__main__":
    log(f"start on :{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
PANELEOF
chmod +x /opt/sbin/mihomo-panel.py
ok "/opt/sbin/mihomo-panel.py"

# =============================================================================
# Файл: /opt/etc/init.d/S97mihomo
# =============================================================================
cat > /opt/etc/init.d/S97mihomo <<'INITMIHEOF'
#!/opt/bin/sh
ENABLED=yes
PROCS=mihomo
ARGS="-d /opt/etc/mihomo"
DESC="Mihomo VPN (no-TUN clean SOCKS5)"
PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
case "${1:-}" in
  start)   /opt/sbin/mihomo-start.sh ;;
  stop)    killall mihomo 2>/dev/null; sleep 1; killall -9 mihomo 2>/dev/null || true ;;
  restart) "$0" stop; "$0" start ;;
  status)  pidof mihomo >/dev/null && echo "running pid=$(pidof mihomo)" || echo "stopped" ;;
  *) echo "usage: $0 {start|stop|restart|status}"; exit 2 ;;
esac
INITMIHEOF
chmod +x /opt/etc/init.d/S97mihomo
ok "/opt/etc/init.d/S97mihomo"

# =============================================================================
# Файл: /opt/etc/init.d/S96mihomo-panel
# =============================================================================
cat > /opt/etc/init.d/S96mihomo-panel <<'INITPANELEOF'
#!/opt/bin/sh
ENABLED=yes
PROCS=python3
ARGS="/opt/sbin/mihomo-panel.py"
DESC="Mihomo VPN web panel"
PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
. /opt/etc/init.d/rc.func
INITPANELEOF
chmod +x /opt/etc/init.d/S96mihomo-panel
ok "/opt/etc/init.d/S96mihomo-panel"

# =============================================================================
# Uninstall script
# =============================================================================
cat > /opt/sbin/mihomo-vpn-uninstall.sh <<'UNINEOF'
#!/opt/bin/sh
echo "Останавливаю и удаляю Mihomo VPN установку..."
/opt/sbin/mihomo-panic.sh 2>/dev/null
/opt/etc/init.d/S96mihomo-panel stop 2>/dev/null
killall -9 python3 2>/dev/null
rm -f /opt/etc/init.d/S96mihomo-panel /opt/etc/init.d/S97mihomo
rm -f /opt/sbin/update-mihomo-sub.sh /opt/sbin/mihomo-start.sh /opt/sbin/mihomo-resume.sh /opt/sbin/mihomo-panic.sh /opt/sbin/mihomo-panel.py
rm -rf /opt/etc/mihomo /opt/backups/mihomo /opt/var/log/mihomo*.log
if [ -f /opt/var/spool/cron/crontabs/root ]; then
  grep -vE "/opt/sbin/(update-mihomo-sub\.sh|update-dropweb-mihomo\.sh)" /opt/var/spool/cron/crontabs/root > /tmp/c.cron 2>/dev/null
  mv /tmp/c.cron /opt/var/spool/cron/crontabs/root 2>/dev/null
fi
/opt/etc/init.d/S10cron restart 2>/dev/null
echo "Готово. XKeen и mihomo-бинарь не трогал — если нужны, удали через xkeen -remove или opkg."
UNINEOF
chmod +x /opt/sbin/mihomo-vpn-uninstall.sh
ok "/opt/sbin/mihomo-vpn-uninstall.sh"

# =============================================================================
# Финальная установка: тянем подписку, ставим конфиг, поднимаем
# =============================================================================
inf "Тяну подписку..."
/opt/sbin/update-mihomo-sub.sh
[ -f /opt/etc/mihomo/config.yaml ] || die "Не получилось скачать подписку. Смотри /opt/var/log/mihomo-sub-update.log"
ok "Конфиг получен и валиден."

inf "Скачиваю web-UI zashboard..."
/opt/bin/opkg list-installed | grep -q "^unzip " || /opt/bin/opkg install unzip >/dev/null 2>&1 || true
( cd /tmp && rm -rf zash zash.zip
  /opt/bin/curl -fsSL -o zash.zip "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip"
  /opt/bin/unzip -q zash.zip -d zash 2>/dev/null || true
  rm -rf /opt/etc/mihomo/zash
  mkdir -p /opt/etc/mihomo/zash
  if [ -d zash/dist ]; then cp -a zash/dist/. /opt/etc/mihomo/zash/
  else cp -a zash/. /opt/etc/mihomo/zash/; fi
) || warn "Не смог установить zashboard (это не критично — VPN будет работать без UI)."
[ -f /opt/etc/mihomo/zash/index.html ] && ok "zashboard установлен" || warn "zashboard пропущен"

# cron
inf "Ставлю cron на час..."
touch /opt/var/spool/cron/crontabs/root
grep -vE "/opt/sbin/update-mihomo-sub.sh" /opt/var/spool/cron/crontabs/root > /tmp/c.cron 2>/dev/null || true
mv /tmp/c.cron /opt/var/spool/cron/crontabs/root
printf "13 * * * * /opt/sbin/update-mihomo-sub.sh\n" >> /opt/var/spool/cron/crontabs/root
chmod 600 /opt/var/spool/cron/crontabs/root
/opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true
ok "cron: 13 * * * * /opt/sbin/update-mihomo-sub.sh"

# kill switch очищаем (на случай повторной установки)
rm -f /opt/etc/mihomo/.disabled

# поднимаем mihomo и панель
inf "Запускаю Mihomo..."
/opt/etc/init.d/S97mihomo start
sleep 3
inf "Запускаю панель..."
/opt/etc/init.d/S96mihomo-panel stop 2>/dev/null
sleep 1
/opt/etc/init.d/S96mihomo-panel start
sleep 2

# финальная проверка
say ""
say "${C_CYN}========== ИТОГ ==========${C_RST}"
mihomo_pid=$(pidof mihomo || echo "")
panel_pid=$(pidof python3 || echo "")
if [ -n "$mihomo_pid" ]; then ok "mihomo: pid=$mihomo_pid"; else die "mihomo не поднялся, смотри /opt/var/log/mihomo.log"; fi
if [ -n "$panel_pid" ]; then ok "panel:  pid=$panel_pid"; else warn "panel не поднялся, смотри /opt/var/log/mihomo-panel.log"; fi

ver=$(/opt/bin/curl -s --max-time 3 http://127.0.0.1:9090/version 2>/dev/null || echo "")
[ -n "$ver" ] && ok "API: $ver"

say ""
say "${C_GRN}=========================================================${C_RST}"
say "${C_GRN}  Готово.${C_RST}"
say "${C_GRN}=========================================================${C_RST}"
say ""
say "  Веб-панель  :  ${C_CYN}http://${LAN_IP}:${PANEL_PORT}/${C_RST}"
say "  Дашборд     :  ${C_CYN}http://${LAN_IP}:9090/ui/${C_RST}"
say "  SOCKS5/HTTP :  ${C_CYN}${LAN_IP}:1080${C_RST}"
say ""
say "  Аварийная остановка одной командой:"
say "     ${C_YEL}ssh root@${LAN_IP} /opt/sbin/mihomo-panic.sh${C_RST}"
say ""
say "  Удалить:"
say "     ${C_YEL}/opt/sbin/mihomo-vpn-uninstall.sh${C_RST}"
say ""
