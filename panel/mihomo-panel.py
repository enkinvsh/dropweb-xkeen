#!/opt/bin/python3
# dropweb-xkeen: веб-панель роутера (python3 stdlib). Всё, что раньше требовало
# SSH: вкл/выкл VPN, срок подписки и лимит устройств, обновление подписки сейчас,
# смена ссылки, проверка связи. Внешний вид — index.html рядом с этим файлом;
# оба файла обновляются кнопкой из репозитория (POST /panel-update).
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64, datetime, json, os, re, shlex, shutil, socket, subprocess, sys, threading, time
import urllib.error, urllib.parse, urllib.request

# Поднимай при каждом изменении panel/: версию видно в панели и в ответе обновления.
PANEL_VERSION = "2.1.0"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8181
# Пробный запуск новой версии слушает только 127.0.0.1.
BIND = os.environ.get("DROPWEB_PANEL_BIND", "0.0.0.0")
PANEL_DIR = os.path.dirname(os.path.abspath(__file__))
PANEL_FILES = ("mihomo-panel.py", "index.html")
UI_FILE = os.path.join(PANEL_DIR, "index.html")
DEFAULT_SOURCE = "https://raw.githubusercontent.com/enkinvsh/dropweb-xkeen/main/panel"
# raw.githubusercontent.com держит файл в кэше до 5 минут и игнорирует ?query,
# поэтому ветку превращаем в SHA коммита: такой адрес всегда свежий.
RAW_RE = re.compile(r"https://raw\.githubusercontent\.com/([\w.-]+)/([\w.-]+)/([^/]+)/(.+)$")
VERSION_RE = re.compile(rb'^PANEL_VERSION = "([^"\n]{1,32})"', re.M)
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

def curl(args, timeout):
    try:
        r = subprocess.run(["curl", "-fsSL", "--connect-timeout", "15"] + args,
                           capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as e:
        return False, str(e)
    return r.returncode == 0, (r.stdout if r.returncode == 0 else r.stderr).strip()

def panel_source():
    src = read_env(SETTINGS).get("PANEL_SOURCE", "").rstrip("/")
    if not re.match(r"https?://\S+$", src):
        src = DEFAULT_SOURCE
    m = RAW_RE.match(src)
    if not m:
        return src, ""
    owner, repo, ref, path = m.groups()
    ok, sha = curl(["--max-time", "20", "-H", "Accept: application/vnd.github.sha",
                    f"https://api.github.com/repos/{owner}/{repo}/commits/{ref}"], 30)
    if ok and re.fullmatch(r"[0-9a-f]{40}", sha):
        return f"https://raw.githubusercontent.com/{owner}/{repo}/{sha}/{path}", sha[:7]
    # API GitHub недоступен или лимит запросов исчерпан — берём ветку, пусть и из кэша.
    log(f"panel-update: SHA ветки {ref} не получен ({sha[-200:]}) — качаю по ветке")
    return src, ""

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def trial_run(stage):
    # Новая версия должна сама подняться и ответить на / и /status — иначе не ставим:
    # сломанная панель отрезала бы человека от кнопки «Выключить VPN».
    port = free_port()
    out = open(os.path.join(stage, "trial.log"), "wb")
    try:
        p = subprocess.Popen([sys.executable, os.path.join(stage, "mihomo-panel.py"), str(port)],
                             env=dict(os.environ, DROPWEB_PANEL_BIND="127.0.0.1"),
                             stdout=out, stderr=subprocess.STDOUT)
    finally:
        out.close()
    try:
        deadline = time.time() + 20
        while time.time() < deadline and p.poll() is None:
            try:
                with NO_PROXY.open(f"http://127.0.0.1:{port}/", timeout=3) as r:
                    r.read()
                with NO_PROXY.open(f"http://127.0.0.1:{port}/status", timeout=10) as r:
                    return isinstance(json.load(r), dict)
            except (OSError, ValueError):
                time.sleep(0.5)
        return False
    finally:
        p.kill()
        p.wait()

def panel_update():
    stage = PANEL_DIR + ".new"
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    try:
        src, commit = panel_source()
        new = {}
        for name in PANEL_FILES:
            dest = os.path.join(stage, name)
            ok, err = curl(["--max-time", "60", "--retry", "2", "-o", dest, f"{src}/{name}"], 200)
            if not ok:
                log(f"panel-update: {src}/{name} не скачался: {err[-300:]}")
                return {"ok": False, "result": "fetch_failed"}
            with open(dest, "rb") as f:
                new[name] = f.read()
        try:
            compile(new["mihomo-panel.py"], "mihomo-panel.py", "exec")
            html = new["index.html"].decode("utf-8")
        except (SyntaxError, ValueError) as e:
            log(f"panel-update: скачанные файлы битые: {e}")
            return {"ok": False, "result": "bad_files"}
        if "<html" not in html.lower():
            log("panel-update: index.html без <html>")
            return {"ok": False, "result": "bad_files"}
        m = VERSION_RE.search(new["mihomo-panel.py"])
        version = m.group(1).decode("utf-8", "replace") if m else "?"
        cur = {}
        for name in PANEL_FILES:
            try:
                with open(os.path.join(PANEL_DIR, name), "rb") as f:
                    cur[name] = f.read()
            except OSError:
                cur[name] = None
        if cur == new:
            return {"ok": True, "result": "same", "version": PANEL_VERSION, "commit": commit}
        if not trial_run(stage):
            try:
                with open(os.path.join(stage, "trial.log"), encoding="utf-8", errors="replace") as f:
                    tail = f.read()[-600:]
            except OSError:
                tail = ""
            log(f"panel-update: новая версия {version} не запустилась: {tail}")
            return {"ok": False, "result": "test_failed"}
        backup = PANEL_DIR + ".bak"
        shutil.rmtree(backup, ignore_errors=True)
        os.makedirs(backup)
        for name in PANEL_FILES:
            if cur[name] is not None:
                shutil.copy2(os.path.join(PANEL_DIR, name), os.path.join(backup, name))
        for name in PANEL_FILES:
            os.replace(os.path.join(stage, name), os.path.join(PANEL_DIR, name))
        os.chmod(os.path.join(PANEL_DIR, "mihomo-panel.py"), 0o755)
        log(f"панель обновлена: {PANEL_VERSION} → {version} {commit} ({src})")
        return {"ok": True, "result": "updated", "version": version, "commit": commit}
    finally:
        shutil.rmtree(stage, ignore_errors=True)

def restart_self():
    # execv сохраняет PID — pidfile init-скрипта остаётся верным; слушающий сокет
    # не наследуется, новая версия занимает тот же порт.
    log("перезапуск в новую версию панели")
    os.execv(sys.executable, [sys.executable, os.path.join(PANEL_DIR, "mihomo-panel.py")] + sys.argv[1:])


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
            return self._json(200, {"running":p is not None,"pid":p,"disabled":os.path.exists(DISABLED),
                                    "autostart":autostart(),"busy":BUSY.locked(),"sub":sub_info(),
                                    "panel":PANEL_VERSION})
        return self._send(404,"not found","text/plain; charset=utf-8")
    def do_POST(self):
        path=self.path.split("?",1)[0]
        if path not in ("/panic","/resume","/update","/check","/link","/panel-update"): return self._send(404,"not found","text/plain; charset=utf-8")
        # Защита от чужих сайтов: свой заголовок требует CORS preflight, а OPTIONS мы не отвечаем.
        if self.headers.get("X-Dropweb-Panel") != "1":
            return self._json(403, {"ok":False,"error":"forbidden"})
        if path == "/check":
            return self._json(200, check())
        if not BUSY.acquire(blocking=False):
            return self._json(200, {"ok": False, "result": "busy"})
        restarting = False
        try:
            if path == "/panic": return self._json(200, run_script(PANIC))
            if path == "/resume": return self._json(200, run_script(START))
            if path == "/update":
                res = run_updater()
                return self._json(200, {"ok": res in ("updated", "unchanged"), "result": res})
            if path == "/panel-update":
                res = panel_update()
                self._json(200, res)
                if res["result"] == "updated":
                    # Замок не отпускаем до execv: ответ уже ушёл, второй клик получит busy.
                    restarting = True
                    threading.Timer(0.5, restart_self).start()
                return None
            return self._json(200, change_link(self._body().get("url")))
        finally:
            if not restarting:
                BUSY.release()

if __name__ == "__main__":
    log(f"start {PANEL_VERSION} on {BIND}:{PORT}")
    ThreadingHTTPServer((BIND, PORT), H).serve_forever()
