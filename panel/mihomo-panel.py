#!/opt/bin/python3
# dropweb-xkeen: веб-панель роутера (python3 stdlib). Всё, что раньше требовало
# SSH: вкл/выкл VPN, срок подписки и лимит устройств, обновление подписки сейчас,
# смена ссылки, проверка связи, обновление всего dropweb-xkeen с GitHub, список
# сайтов, которые роутер сам перевёл на VPN.
# Внешний вид — index.html рядом с этим файлом, читается с диска на каждый запрос.
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64, datetime, json, os, re, shlex, subprocess, sys, threading, time
import urllib.error, urllib.parse, urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8181
# Версию продукта панель берёт из settings.env. Эту строку читает только старая
# кнопка «Обновить панель» 2.1.x, чтобы написать «обновлена до версии …»: поднимать не нужно.
PANEL_VERSION = "2.3+"
# Панель 2.1.x перед заменой запускает новую версию на 127.0.0.1 для проверки.
BIND = os.environ.get("DROPWEB_PANEL_BIND", "0.0.0.0")
PANEL_DIR = os.path.dirname(os.path.abspath(__file__))
UI_FILE = os.path.join(PANEL_DIR, "index.html")
SELF_UPDATER = "/opt/sbin/dropweb-xkeen-update.sh"
# На роутерах 2.1.x SELF_UPDATER ещё нет, а эту панель туда уже могла привезти
# старая кнопка «Обновить панель»: берём скрипт обновления из install.sh в репозитории.
BOOT_UPDATER = "/tmp/dxk-bootstrap-update.sh"
BOOT_BEGIN = "<<'EOF_SELFUPDATE'\n"
BOOT_END = "\nEOF_SELFUPDATE\n"
DEFAULT_UPDATE_URL = "https://raw.githubusercontent.com/enkinvsh/dropweb-xkeen/main"
UPD_STATE = "/opt/etc/dropweb-xkeen/update-state.env"
UPD_LOCK_PID = "/tmp/dxk-update.lock/pid"
# Проверка обновлений = GitHub API + скачать install.sh (до ~2 минут при плохой связи).
UPD_CHECK_TIMEOUT = 150
# Сайты, которые провайдер режет напрямую: их находит dropweb-learn.py (cron раз в минуту).
LEARN_PY = "/opt/sbin/dropweb-learn.py"
LEARN_STATE = "/opt/etc/dropweb-xkeen/learn.json"
LEARN_ENV = "/opt/etc/dropweb-xkeen/learn.env"
# /status опрашивается каждые 5 секунд: весь список (до 500 сайтов) туда не кладём.
LEARN_SHOW = 100
HOST_RE = re.compile(r"(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}")
PANIC = "/opt/sbin/mihomo-panic.sh"
START = "/opt/sbin/mihomo-resume.sh"
UPDATER = "/opt/sbin/update-mihomo-sub.sh"
CONF = "/opt/etc/mihomo/config.yaml"
DISABLED = "/opt/etc/mihomo/.disabled"
XKEEN_INIT = "/opt/etc/init.d/S05xkeen"
SETTINGS = "/opt/etc/dropweb-xkeen/settings.env"
STATE = "/opt/etc/dropweb-xkeen/sub-state.env"
LOG_PATH = "/opt/var/log/mihomo-panel.log"
RUN_TIMEOUT = 90
# Если основной домен подписки заблокирован, апдейтер перебирает зеркала — до ~5 минут.
UPDATE_TIMEOUT = 330
PROBE_URL = "https://www.gstatic.com/generate_204"
# Российские сайты по правилам dropweb всегда идут напрямую: ими проверяем сам интернет.
DIRECT_PROBES = ("https://ya.ru/", PROBE_URL)
GROUP_TYPES = {"Selector", "URLTest", "Fallback", "LoadBalance", "Relay"}
# Одна долгая операция за раз: двойной клик не запускает два апдейтера.
BUSY = threading.Lock()
NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))
LINK_RE = re.compile(r"https://[^\s'\"\\<>`]{4,2000}")

def log(msg):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {msg}\n")
    except OSError: pass

def read_env(path):
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return out
    for line in lines:
        m = re.match(r"([A-Z_][A-Z0-9_]*)=(.*)$", line)
        if not m:
            continue
        try:
            parts = shlex.split(m.group(2))
        except ValueError:
            continue
        out[m.group(1)] = parts[0] if parts else ""
    return out

def shq(v):
    return "'" + v.replace("'", "'\\''") + "'"

def write_file(path, data):
    tmp = path + ".panel.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)

def write_setting(key, value):
    with open(SETTINGS, encoding="utf-8") as f:
        lines = f.read().splitlines()
    line = f"{key}={shq(value)}"
    for i, old in enumerate(lines):
        if old.startswith(key + "="):
            lines[i] = line
            break
    else:
        lines.append(line)
    write_file(SETTINGS, ("\n".join(lines) + "\n").encode("utf-8"))

def mihomo_pid():
    out = subprocess.run(["pidof","mihomo"], capture_output=True, text=True)
    return out.stdout.strip() or None

def autostart():
    try:
        with open(XKEEN_INIT, encoding="utf-8", errors="replace") as f:
            return any(re.match(r'\s*start_auto="on"', line) for line in f)
    except OSError:
        return False

def https_or_none(v):
    return v if v and v.startswith("https://") and len(v) < 2048 else None

def announce_text(v):
    if v.startswith("base64:"):
        try:
            return base64.b64decode(v[7:]).decode("utf-8", "replace").strip()
        except ValueError:
            return ""
    return v.strip()

def mask_link(u):
    # Ссылка = доступ к подписке: на странице показываем только домен и хвост.
    m = re.match(r"https://([^/]+)/(.*)$", u or "")
    if not m:
        return ""
    tail = m.group(2)
    return f"{m.group(1)}/…{tail[-4:]}" if len(tail) > 4 else f"{m.group(1)}/{tail}"

def sub_info():
    cur = read_env(SETTINGS).get("SUB_URL", "")
    st = read_env(STATE)
    if st.get("SUB_STATE_URL") != cur:
        st = {}
    def num(k):
        v = st.get(k, "")
        return int(v) if v.isdigit() else None
    used = st.get("SUB_USED_URL", "")
    return {
        "link": mask_link(cur),
        "result": st.get("SUB_RESULT", ""),
        "at": num("SUB_RESULT_AT"),
        "last_ok": num("SUB_LAST_OK"),
        "expire": num("SUB_EXPIRE"),
        "devices_url": https_or_none(st.get("SUB_DEVICES_URL")),
        "cabinet_url": https_or_none(st.get("SUB_CABINET_URL")),
        "announce": announce_text(st.get("SUB_ANNOUNCE", "")),
        "via_mirror": bool(used) and used != cur,
    }

def run_script(cmd):
    if not os.path.exists(cmd): return {"ok":False,"error":"script missing"}
    try:
        r=subprocess.run([cmd],capture_output=True,text=True,timeout=RUN_TIMEOUT)
    except subprocess.TimeoutExpired:
        return {"ok":False,"error":"timeout"}
    except OSError as e:
        return {"ok":False,"error":str(e)}
    return {"ok":r.returncode==0,"rc":r.returncode,"stdout":r.stdout[-2000:],"stderr":r.stderr[-2000:]}

def run_updater():
    try:
        rc = subprocess.run([UPDATER], capture_output=True, text=True, timeout=UPDATE_TIMEOUT).returncode
    except subprocess.TimeoutExpired:
        return "timeout"
    except OSError as e:
        log(f"updater: {e}")
        return "error"
    if rc == 5:
        return "busy"
    if rc == 4:
        return "error"
    return read_env(STATE).get("SUB_RESULT", "") or "error"

def change_link(new):
    new = new.strip() if isinstance(new, str) else ""
    if not LINK_RE.fullmatch(new):
        return {"ok": False, "result": "bad_url"}
    old = read_env(SETTINGS).get("SUB_URL", "")
    try:
        with open(STATE, "rb") as f:
            old_state = f.read()
    except OSError:
        old_state = None
    write_setting("SUB_URL", new)
    res = run_updater()
    if new != old and res in ("fetch_failed", "not_config", "busy", "timeout", "error"):
        # Ссылка не дала подписку — возвращаем прежнюю, чтобы роутер не остался ни с чем.
        write_setting("SUB_URL", old)
        if old_state is None:
            try: os.remove(STATE)
            except OSError: pass
        else:
            write_file(STATE, old_state)
        log(f"новая ссылка не подошла ({res}) — вернул прежнюю")
        return {"ok": False, "result": res, "reverted": True}
    if new != old:
        log(f"ссылка на подписку сменена через панель ({res})")
    return {"ok": res in ("updated", "unchanged"), "result": res}

def probe_direct():
    for url in DIRECT_PROBES:
        try:
            r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code} %{time_total}",
                                "--max-time", "8", url], capture_output=True, text=True, timeout=12)
        except (subprocess.TimeoutExpired, OSError):
            continue
        parts = r.stdout.split()
        if len(parts) == 2 and parts[0] != "000":
            return {"ok": True, "ms": int(float(parts[1]) * 1000)}
    return {"ok": False}

def api(path, timeout):
    s = read_env(SETTINGS)
    req = urllib.request.Request(f"http://127.0.0.1:{s.get('API_PORT') or '9090'}{path}",
                                 headers={"Authorization": "Bearer " + s.get("API_SECRET", "")})
    with NO_PROXY.open(req, timeout=timeout) as r:
        return json.load(r)

def probe_vpn():
    # Основная группа = первая группа в порядке подписки (GLOBAL.all его сохраняет):
    # имена групп в подписке меняются, вшивать их нельзя.
    group = None
    try:
        px = api("/proxies", 5).get("proxies", {})
        for name in px.get("GLOBAL", {}).get("all", []):
            if px.get(name, {}).get("type") in GROUP_TYPES:
                group = name
                break
        if not group:
            return {"ok": False, "error": "no_group"}
        q = urllib.parse.urlencode({"url": PROBE_URL, "timeout": "6000"})
        d = api(f"/proxies/{urllib.parse.quote(group, safe='')}/delay?{q}", 10)
    except urllib.error.HTTPError as e:
        return {"ok": False, "group": group, "error": f"http {e.code}"}
    except (OSError, ValueError) as e:
        return {"ok": False, "group": group, "error": str(e)[:200]}
    delay = d.get("delay")
    return {"ok": isinstance(delay, int) and delay > 0, "ms": delay, "group": group}

def check():
    running = mihomo_pid() is not None
    return {"running": running, "direct": probe_direct(), "vpn": probe_vpn() if running else None}

def page():
    try:
        with open(UI_FILE, "rb") as f:
            return f.read()
    except OSError:
        return ("<!DOCTYPE html><meta charset='utf-8'><title>VPN на роутере</title>"
                f"<p>Нет файла панели {UI_FILE}. Переустанови: <code>sh install.sh -y</code></p>")

def ver_gt(a, b):
    # Как ver_gt в dropweb-xkeen-update.sh: числа через точку, хвост вроде «-test» не важен.
    def parts(v):
        out = []
        for p in (v or "").split("."):
            m = re.match(r"\d+", p)
            out.append(int(m.group()) if m else 0)
        return out
    x, y = parts(a), parts(b)
    n = max(len(x), len(y))
    return x + [0] * (n - len(x)) > y + [0] * (n - len(y))

def updating():
    # Замок держит dropweb-xkeen-update.sh всё время работы, даже когда эту панель
    # перезапускает install.sh посреди обновления.
    try:
        with open(UPD_LOCK_PID, encoding="utf-8") as f:
            os.kill(int(f.read().strip()), 0)
        return True
    except (OSError, ValueError):
        return False

def update_info():
    s = read_env(SETTINGS)
    st = read_env(UPD_STATE)
    cur = s.get("DROPWEB_XKEEN_VERSION", "")
    latest = st.get("UPD_LATEST", "")
    def num(k):
        v = st.get(k, "")
        return int(v) if v.isdigit() else None
    locked = updating()
    result = st.get("UPD_RESULT", "")
    if result == "running" and not locked:
        # Роутер выключили или процесс убили посреди установки.
        result = "interrupted"
    return {
        "version": cur or None,
        "latest": latest or None,
        "available": bool(latest) and ver_gt(latest, cur),
        "checked_at": num("UPD_CHECKED_AT"),
        "check_error": st.get("UPD_CHECK_ERR") or None,
        "result": result or None,
        "at": num("UPD_RESULT_AT"),
        "from": st.get("UPD_FROM") or None,
        "to": st.get("UPD_TO") or None,
        "mode": st.get("UPD_MODE") or None,
        "locked": locked,
        "auto": s.get("AUTO_UPDATE", "1") != "0",
        "installed": os.path.exists(SELF_UPDATER),
    }

def update_url():
    s = read_env(SETTINGS)
    u = s.get("UPDATE_URL", "")
    src = s.get("PANEL_SOURCE", "")
    if not u and src.endswith("/panel"):
        u = src[:-len("/panel")]
    return (u or DEFAULT_UPDATE_URL).rstrip("/")

def updater_script():
    """Путь к скрипту обновления и код ошибки, если его нет и скачать не вышло."""
    if os.path.exists(SELF_UPDATER):
        return SELF_UPDATER, None
    url = update_url() + "/install.sh"
    try:
        r = subprocess.run(["curl", "-fsSL", "--connect-timeout", "15", "--max-time", "90", url],
                           capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"bootstrap: {e}")
        return None, "fetch_failed"
    if r.returncode != 0:
        log(f"bootstrap: curl {url} rc={r.returncode}")
        return None, "fetch_failed"
    text = r.stdout.decode("utf-8", "replace")
    i = text.find(BOOT_BEGIN)
    j = text.find(BOOT_END, i) if i >= 0 else -1
    if j < 0:
        log(f"bootstrap: в {url} нет скрипта обновления")
        return None, "bad_files"
    write_file(BOOT_UPDATER, text[i + len(BOOT_BEGIN):j + 1].encode("utf-8"))
    log(f"bootstrap: скрипт обновления взят из {url}")
    return BOOT_UPDATER, None

def drop_boot(path):
    # Скрипт сразу копирует себя в /tmp и работает из копии: исходник больше не нужен.
    if path == BOOT_UPDATER:
        try: os.remove(BOOT_UPDATER)
        except OSError: pass

def start_upgrade():
    if updating():
        return {"ok": False, "result": "busy"}
    script, err = updater_script()
    if not script:
        return {"ok": False, "result": err}
    # Своя сессия и без наших pipe: install.sh перезапустит панель, а обновление
    # должно дойти до конца и при неудаче откатиться само.
    try:
        subprocess.Popen(["sh", script, "run"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
    except OSError as e:
        log(f"upgrade: {e}")
        return {"ok": False, "result": "error"}
    # Отвечаем, когда скрипт уже взял замок: следующий /status покажет locked.
    deadline = time.time() + 5
    while time.time() < deadline and not updating():
        time.sleep(0.2)
    drop_boot(script)
    log("обновление dropweb-xkeen запущено из панели")
    return {"ok": True, "result": "started"}

def check_upgrade():
    script, err = updater_script()
    if not script:
        return {"ok": False, "result": err, "upd": update_info()}
    try:
        rc = subprocess.run(["sh", script, "check"], capture_output=True,
                            timeout=UPD_CHECK_TIMEOUT).returncode
    except subprocess.TimeoutExpired:
        return {"ok": False, "result": "timeout", "upd": update_info()}
    except OSError as e:
        log(f"upgrade-check: {e}")
        return {"ok": False, "result": "error", "upd": update_info()}
    finally:
        drop_boot(script)
    info = update_info()
    if rc == 3:
        return {"ok": False, "result": "busy", "upd": info}
    if rc != 0:
        return {"ok": False, "result": info["check_error"] or "error", "upd": info}
    return {"ok": True, "result": "available" if info["available"] else "latest", "upd": info}

def set_auto(on):
    if not isinstance(on, bool):
        return {"ok": False, "result": "bad_request"}
    write_setting("AUTO_UPDATE", "1" if on else "0")
    log(f"автообновление {'включено' if on else 'выключено'} через панель")
    return {"ok": True, "auto": on}

def learn_info():
    env = read_env(LEARN_ENV)
    try:
        with open(LEARN_STATE, encoding="utf-8") as f:
            hosts = json.load(f).get("hosts") or {}
    except (OSError, ValueError, AttributeError):
        hosts = {}
    if not isinstance(hosts, dict):
        hosts = {}
    items = []
    for h, v in hosts.items():
        v = v if isinstance(v, dict) else {}
        try:
            at = int(v.get("at") or 0)
        except (TypeError, ValueError):
            at = 0
        items.append({"host": h, "at": at, "why": str(v.get("why") or "")})
    items.sort(key=lambda x: -x["at"])
    return {"installed": os.path.exists(LEARN_PY),
            "enabled": read_env(SETTINGS).get("DPI_LEARN", "1") != "0",
            "on": env.get("LEARN_ON") == "1", "reason": env.get("LEARN_REASON", ""),
            "group": env.get("LEARN_GROUP", ""), "count": len(items), "items": items[:LEARN_SHOW]}

def learn_remove(host):
    if not isinstance(host, str) or not HOST_RE.fullmatch(host.strip().lower()):
        return {"ok": False, "result": "bad_host"}
    if not os.path.exists(LEARN_PY):
        return {"ok": False, "result": "no_learn"}
    try:
        r = subprocess.run([sys.executable, LEARN_PY, "remove", host.strip().lower()],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"learn-remove: {e}")
        return {"ok": False, "result": "error", "learn": learn_info()}
    if r.returncode != 0:
        log(f"learn-remove rc={r.returncode}: {(r.stdout + r.stderr).strip()[-300:]}")
        return {"ok": False, "result": "error", "learn": learn_info()}
    log(f"{host} убран из списка «через VPN» через панель")
    return {"ok": True, "result": "removed", "learn": learn_info()}

def set_learn(on):
    if not isinstance(on, bool):
        return {"ok": False, "result": "bad_request"}
    write_setting("DPI_LEARN", "1" if on else "0")
    log(f"поиск заблокированных сайтов {'включён' if on else 'выключен'} через панель")
    return {"ok": True, "enabled": on, "learn": learn_info()}


class H(BaseHTTPRequestHandler):
    def log_message(self,format,*a): log("HTTP "+(format%a))
    def _send(self,c,b,t="text/html; charset=utf-8"):
        d=b.encode() if isinstance(b,str) else b
        self.send_response(c); self.send_header("Content-Type",t); self.send_header("Content-Length",str(len(d))); self.send_header("Cache-Control","no-store"); self.end_headers(); self.wfile.write(d)
    def _json(self,c,obj): return self._send(c, json.dumps(obj), "application/json")
    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if n <= 0 or n > 8192:
            return {}
        try:
            d = json.loads(self.rfile.read(n))
        except ValueError:
            return {}
        return d if isinstance(d, dict) else {}
    def do_GET(self):
        path=self.path.split("?",1)[0]
        if path in ("/","/index.html"): return self._send(200, page())
        if path == "/status":
            p=mihomo_pid()
            upd=update_info()
            return self._json(200, {"running":p is not None,"pid":p,"disabled":os.path.exists(DISABLED),
                                    "autostart":autostart(),"busy":BUSY.locked() or upd["locked"],
                                    "sub":sub_info(),"upd":upd,"learn":learn_info()})
        return self._send(404,"not found","text/plain; charset=utf-8")
    def do_POST(self):
        path=self.path.split("?",1)[0]
        if path not in ("/panic","/resume","/update","/check","/link","/upgrade","/upgrade-check","/auto-update","/learn-remove","/learn-auto"):
            return self._send(404,"not found","text/plain; charset=utf-8")
        # Защита от чужих сайтов: свой заголовок требует CORS preflight, а OPTIONS мы не отвечаем.
        if self.headers.get("X-Dropweb-Panel") != "1":
            return self._json(403, {"ok":False,"error":"forbidden"})
        if path == "/check":
            return self._json(200, check())
        # Пока идёт обновление, install.sh переписывает настройки и скрипты: любое
        # действие сейчас потерялось бы или помешало откату.
        if updating() or not BUSY.acquire(blocking=False):
            return self._json(200, {"ok": False, "result": "busy"})
        try:
            if path == "/panic": return self._json(200, run_script(PANIC))
            if path == "/resume": return self._json(200, run_script(START))
            if path == "/update":
                res = run_updater()
                return self._json(200, {"ok": res in ("updated", "unchanged"), "result": res})
            if path == "/upgrade": return self._json(200, start_upgrade())
            if path == "/upgrade-check": return self._json(200, check_upgrade())
            if path == "/auto-update": return self._json(200, set_auto(self._body().get("on")))
            if path == "/learn-remove": return self._json(200, learn_remove(self._body().get("host")))
            if path == "/learn-auto": return self._json(200, set_learn(self._body().get("on")))
            return self._json(200, change_link(self._body().get("url")))
        finally:
            BUSY.release()

if __name__ == "__main__":
    log(f"start {read_env(SETTINGS).get('DROPWEB_XKEEN_VERSION', '?')} on {BIND}:{PORT}")
    ThreadingHTTPServer((BIND, PORT), H).serve_forever()
