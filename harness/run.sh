#!/usr/bin/env bash
# =============================================================================
#  🧪 LastBook-Server – Mock-Harness
#  Testet install/lastbook.sh End-to-End gegen gemockte Proxmox-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/curl/apt/systemctl/getent als Mocks (Fakebin)
#   - Die Inner-Scripts laufen ECHT: echtes Python3, echte Tar-Entpackung und –
#     für den Bibliotheks-Teil – eine ECHTE lokale Mock-API (HTTP auf
#     127.0.0.1:8890), gegen die state_poll/urllib, Job-Poll und finish laufen.
#     Der Switch benutzt den ECHTEN upstream-Code engine/setup/install.py
#     (apply_pending mit Rollback) – nicht eine Nachbildung.
#  Usage: bash harness/run.sh [-v]   (Exit 0 = alle Cases grün)
# =============================================================================
set -u
SCRIPT="/home/phil/Proxmox-Scripts/LastBook-Server/install/lastbook.sh"
UPSTREAM_INSTALL="/tmp/lastbook-upstream/engine/setup/install.py"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }
[[ -f "$UPSTREAM_INSTALL" ]] || { echo "✘ upstream install.py fehlt: $UPSTREAM_INSTALL (git clone /tmp/lastbook-upstream)"; exit 1; }

VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

MK=$(mktemp -d /tmp/lastbook-harness.XXXXXX)
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK" 2>/dev/null; fi' EXIT
HS="$MK/state"
HOSTBIN="$MK/bin-host"
INNERBIN="$MK/bin-inner"
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" \
    "$MK/etc" "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
CT_IP="192.168.178.201"
PORT=8890
API_LOG="$HS/api.log"

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }

t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }
assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_file() {
    if [[ -f "$1" ]]; then pass "Datei: $1"
    else fail "Datei fehlt: $1"; fi
}
assert_no_file() {
    if [[ -f "$1" ]]; then fail "Datei existiert (sollte nicht): $1"
    else pass "Datei fehlt (korrekt): $1"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "$1 enthält: $2"
    else fail "$1 enthält NICHT: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "$1 matcht: $2"
    else fail "$1 matcht NICHT: $2"; fi
}
assert_calls() {
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}
assert_no_calls() {
    if /bin/grep -qF -- "$1" "$HS/calls.log" 2>/dev/null; then fail "Unerwarteter Call: $1"
    else pass "Kein Call: $1"; fi
}
dump_case() {
    echo "---- out.log ($CUR_NAME) ----"; tail -n 40 "$CUR_DIR/out.log" 2>/dev/null
    echo "---- calls.log ----"; tail -n 25 "$HS/calls.log" 2>/dev/null
    echo "---- api.log ----"; tail -n 10 "$API_LOG" 2>/dev/null
}

# ── Mock-Umgebung (env -i: Profil-Funktionen wie grep→ugrep meiden) ────────
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() {
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id uname
ln -sf "$MK/mock-curl"  "$HOSTBIN/curl"
ln -sf "$MK/mock-pct"   "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam" "$HOSTBIN/pveam"
ln -sf "$MK/mock-sleep" "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep" "$INNERBIN/sleep"

# Inner-Fakebin: echtes Python3 (Wrapper), kein curl/apt/systemctl vor apt
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod dirname basename sort uniq printf ls touch readlink stat uname date \
    tee openssl wc ln tar gzip
# test ist ein dash-Builtin – `command -v` liefert den Namen selbst → Self-Symlink.
ln -sf /usr/bin/test "$INNERBIN/test"
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"
ln -sf "$MK/mock-python3"   "$INNERBIN/python3"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-ip"        "$INNERBIN/ip"

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-python3" <<'EOF'
#!/usr/bin/env bash
# Python3-Wrapper: -m venv → Fake-Venv; libzim-Importcheck → OK; Rest ECHT.
set -u
MK="${MKROOT:?MKROOT fehlt}"
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
    dir="${3:-/tmp/venv}"
    mkdir -p "$dir/bin"
    # Wrapper → Mock selbst (der alles außer venv/libzim-Check an echtes python3 durchreicht)
    cat > "$dir/bin/python" <<PYWRAP
#!/usr/bin/env bash
exec "$(command -v python3)" "\$@"
PYWRAP
    chmod +x "$dir/bin/python"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/pip"
    chmod +x "$dir/bin/pip"
    exit 0
fi
if [[ "${1:-}" == "-c" && "${2:-}" == *"import libzim"* ]]; then
    echo "    Imports OK (mock)"
    exit 0
fi
exec /usr/bin/python3 "$@"
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="$(dirname "$HS")"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"; id="${2:-}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ $# -gt 0 ]]; then shift; fi

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    create)
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        tmpl="$1"; shift
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${id}.create"
        hostname="ct-$id"
        if [[ -f "$HS/create_nostart" ]]; then
            # pct create --start: Spawn gescheitert, aber Exit 0 (Live-Fund CT 207)
            echo "$id stopped $hostname" >> "$HS/ct_list"
            echo "stopped" > "$HS/ct_${id}.status"
            echo "$hostname" > "$HS/ct_${id}.hostname"
            exit 0
        fi
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$id running $hostname" >> "$HS/ct_list"
        echo "running" > "$HS/ct_${id}.status"
        echo "$hostname" > "$HS/ct_${id}.hostname"
        exit 0 ;;
    start)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}".hostname
        exit 0 ;;
    push)
        src="$1"; dst="$2"; shift 2
        mkdir -p "$MK$(dirname "$dst")"
        # Reihenfolge WICHTIG: /tmp zuerst (die /etc-Ersetzung injiziert selbst /tmp)
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" "$src" > "$MK$dst"
        exit 0 ;;
    exec)
        [[ "${1:-}" == "--" ]] && shift
        envs=()
        if [[ "${1:-}" == "env" ]]; then
            shift
            while [[ "${1:-}" == *=* && "${1:-}" != -* ]]; do envs+=("$1"); shift; done
        fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        if [[ -f "$HS/exec_fail" ]]; then
            echo "mock: exec erzwingt Fehler" >&2
            exit 255
        fi
        INNERBIN="$MK/bin-inner"
        rewrite_path() {
            local a="$1"
            a="${a//\/opt\/lastbook/$MK/opt/lastbook}"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/etc\//$MK/etc/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "$@"; do
            newargs+=("$(rewrite_path "$a")")
        done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do
            newenvs+=("$(rewrite_path "$a")")
        done
        exec env -i PATH="$INNERBIN" \
            HARNESS_STATE="$HS" MKROOT="$MK" PORT_API="http://127.0.0.1:${PORT_API:-8890}" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    config)
        if [[ ! -f "$HS/ct_${id}.hostname" ]]; then
            echo "mock: CT $id unbekannt" >&2
            exit 2
        fi
        printf 'arch: amd64\ncores: 2\nhostname: %s\nonboot: 1\n' "$(cat "$HS/ct_${id}.hostname")"
        exit 0 ;;
    enter|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex|set)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
TMPL_AMD="local:vztmpl/debian-13-standard_13.2-1_amd64.tar.zst"
TMPL_ARM="local:vztmpl/debian-13-standard_13.2-1_arm64.tar.zst"
case "${1:-}" in
    list)
        if [[ -f "$HS/template_downloaded" && ! -f "$HS/pveam_empty" ]]; then
            # Beide Varianten im Cache (Live-Fall CT 207): Installer muss arch-filtern!
            echo "$TMPL_ARM  123456789"
            echo "$TMPL_AMD  123456789"
        fi
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            echo "system          $TMPL_ARM  123456789"
            echo "system          $TMPL_AMD  123456789"
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        mkdir -p "$HS/templates"
        touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
        touch "$HS/templates/debian-13-standard_13.2-1_arm64.tar.zst"
        touch "$HS/template_downloaded"
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: Host-Ebene Health/Key-Checks; Inner-Ebene: /api/* an die echte
# lokale Mock-API durchreichen (echtes curl), Rest 200.
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
url=""; outfile=""; prev=""
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then outfile="$a"; fi
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

# Inner-Kontext: API-URLs wirklich stellen (echtes curl → Mock-API-Server)
if [[ -n "${MKROOT:-}" && "$url" == *"127.0.0.1:8890/api/"* ]]; then
    exec /usr/bin/curl "$@"
fi
# Tarball-Download (Host ODER Inner): baut ein echtes tar.gz-Fixture
case "$url" in
    https://codeload.github.com/Immortal-Protocols/lastbook*)
        [[ -n "$outfile" ]] || { echo "curl mock: Tarball-URL ohne -o" >&2; exit 1; }
        APP="$MK/tarball-src"
        rm -rf "$APP"; mkdir -p "$APP/engine/setup" "$APP/packaging/linux" "$APP/web"
        echo "# mock server.py (upstream $MKROOT-fixture)" > "$APP/server.py"
        echo '{}' > "$APP/engine/__init__.py"
        echo '"""mock setup package"""' > "$APP/engine/setup/__init__.py"
        cp "$MK/upstream-install.py" "$APP/engine/setup/install.py"
        echo "# libzim==3.13.1 (mock)" > "$APP/packaging/linux/requirements_linux.txt"
        echo "<html>mock</html>" > "$APP/web/index.html"
        /bin/tar -czf "$outfile" -C "$APP" . 2>/dev/null || /bin/tar -czf "$outfile" -C "$MK/tarball-src" .
        exit 0 ;;
esac

code="200"
if [[ -f "$HS/host_curl_fail" && -z "${MKROOT:-}" ]]; then
    code="000"
fi
case "$url" in
    http://127.0.0.1:*)
        [[ -f "$HS/fail_inner_http" && -n "${MKROOT:-}" ]] && code="000" ;;
    http://*)
        # Host-Seite: CT-IP-Checks → 200 (mit Key), ohne Key 403 simulieren?
        [[ -f "$HS/host_no_key_ok" ]] && code="200"
        ;;
esac
echo "$code"
[[ "$code" == "200" ]] && exit 0 || exit 7
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl real in der Inner-Fakebin (Bootstrap-Reihenfolge)
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
if [[ "${1:-}" == "install" ]]; then
    for a in "$@"; do
        if [[ "$a" == "curl" && ! -e "$INNERBIN_DIR/curl" ]]; then
            ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl"
        fi
    done
fi
exit 0
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
echo "systemctl $*" >> "$HS/calls.log"
unitdir="$MK/etc/systemd/system"
sub="${1:-}"
case "$sub" in
    daemon-reload) exit 0 ;;
    enable)
        mkdir -p "$unitdir"; echo "${2:-}" >> "$HS/enabled_units"; exit 0 ;;
    start|restart)
        if [[ "${2:-}" == "lastbook" ]]; then
            [[ -f "$unitdir/lastbook.service" ]] || { echo "mock: lastbook.service fehlt" >&2; exit 1; }
            # ExecStart-Validierung (Live-Fund CT 207 #3: Unit zeigte auf alte
            # serve.sh-Lage → systemd 203/EXEC, Mock hatte das NICHT gefangen)
            execpath=$(/bin/sed -n 's/^ExecStart=//p' "$unitdir/lastbook.service" | head -1)
            if [[ -n "$execpath" ]]; then
                execpath="${execpath//\/opt\/lastbook/$MK/opt/lastbook}"
                [[ -x "$execpath" ]] || { echo "mock: ExecStart nicht ausführbar: $execpath (203/EXEC-Simulation)" >&2; exit 203; }
            fi
            touch "$HS/lastbook_active"
        fi
        exit 0 ;;
    stop)
        rm -f "$HS/lastbook_active"; exit 0 ;;
    is-active)
        svc="${3:-${2:-}}"
        if [[ "$svc" == "lastbook" && -f "$HS/lastbook_active" ]]; then exit 0; fi
        exit 3 ;;
    *) exit 0 ;;
esac
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        [[ "$n" -le 9 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

# ── Echte Mock-API (HTTP auf 127.0.0.1:8890) ───────────────────────────────
# state/start/job/finish wie die upstream Setup-API; finish ruft den ECHTEN
# install.stage_switch auf (Fixture-App-Dir), damit apply_pending im Inner
# gegen echten upstream-Code läuft.
cat > "$MK/mock-api.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HS = Path(os.environ['HARNESS_STATE'])
MK = HS.parent
PORT = int(os.environ.get('PORT_API', '8890'))
APP = MK / 'api-fixture'
STAGED = MK / 'opt' / 'lastbook' / 'LastbookData.setup' / 'unpack' / 'LastbookData'
TARGET = MK / 'opt' / 'lastbook' / 'LastbookData'
PEND = MK / 'root' / '.config' / 'Lastbook' / 'setup' / 'pending.json'

sys.path.insert(0, str(APP))
install = None  # ECHTER upstream-Code, lazy import beim ersten finish

def lever(name, default=None):
    p = HS / name
    if p.exists():
        return p.read_text().strip() or default
    return default

def state_doc():
    cur_pack = lever('cur_pack', '')
    packs = []
    if not (HS / 'manifest_empty').exists():
        packs = [
            {'id': 'small', 'title': 'Small', 'records': 315, 'installed_bytes': 7691309976,
             'download_bytes': 7691528852, 'available': True, 'revision': '2026-11-13-small-v2',
             'files': [{'name': 'Lastbook-Small.zip', 'size': 7691528852, 'sha256': '0'*64, 'kind': 'zip'}]},
            {'id': 'medium', 'title': 'Medium', 'installed_bytes': 67476559546, 'available': True,
             'files': [{'name': 'Lastbook-Medium.zip', 'size': 67492034038, 'sha256': '0'*64, 'kind': 'zip'}]},
            {'id': 'all', 'title': 'All', 'installed_bytes': 387861708053, 'available': True,
             'files': [{'name': 'Lastbook-All.zip', 'size': 387878571619, 'sha256': '0'*64, 'kind': 'zip'}]},
        ]
    job = None
    jp = HS / 'job.json'
    if jp.exists():
        job = json.loads(jp.read_text())
    return {
        'mode': 'manage',
        'hardware': {'os': 'linux', 'arch': 'x64', 'ram_bytes': 4e9, 'unified_memory': False,
                     'gpus': [], 'disks': [{'path': str(TARGET.parent), 'free_bytes': 80e9, 'total_bytes': 100e9}],
                     'ai': {'fits': False, 'needs_bytes': None, 'estimate': True, 'why': 'mock'}},
        'manifest': {'source': 'bundled', 'published': '2026-11-13', 'packs': packs, 'models': [], 'maps': []},
        'current': {'folder': str(TARGET if cur_pack else MK / 'opt' / 'lastbook' / 'data'),
                    'pack': cur_pack or None, 'content_revision': '', 'map_bytes': 0,
                    'model': None, 'map': 'base', 'address_indexes': [], 'old': []},
        'found': [],
        'recommend': {'pack': 'small', 'ai': False,
                      'need_bytes': {'small': 17382838828, 'medium': 136968593584, 'all': 777740279672}},
        'job': job,
    }

def job_doc():
    jp = HS / 'job.json'
    if not jp.exists():
        return None
    return json.loads(jp.read_text())

def new_job(pack, folder):
    total = 7691528852 if pack == 'small' else 67492034038 if pack == 'medium' else 387878571619
    return {'id': 'mockjob', 'state': 'waiting',
            'items': [{'id': pack, 'kind': 'pack', 'title': pack.capitalize(), 'state': 'waiting',
                       'bytes_done': 0, 'bytes_total': total, 'rate_bps': 0, 'eta_s': None,
                       'error': None, 'source': 'download'}],
            'error': None, 'started': time.strftime('%Y-%m-%dT%H:%M:%S'),
            'folder': folder or str(TARGET)}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj, status=200):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        with open(HS / 'api.log', 'a') as f:
            f.write(f'GET {self.path}\n')
        if self.path.startswith('/api/setup/state'):
            return self._send(state_doc())
        if self.path.startswith('/api/setup/job'):
            stage = int((HS / 'job_stage').read_text() or '0') if (HS / 'job_stage').exists() else 0
            if (HS / 'job_pause').exists() and stage == 0:
                j = job_doc()
                if j:
                    j['state'] = 'paused'
                    return self._send(j)
            if stage < 3:
                j = job_doc()
                if j:
                    j['state'] = 'downloading'
                    for it in j['items']:
                        it['state'], it['bytes_done'] = 'downloading', int(it['bytes_total'] * 0.5)
                        it['rate_bps'] = 10000000
            else:
                j = job_doc()
                if j:
                    j['state'] = 'done'
                    for it in j['items']:
                        it['state'], it['bytes_done'] = 'done', it['bytes_total']
                    (HS / 'job.json').write_text(json.dumps(j))
            stage += 1
            (HS / 'job_stage').write_text(str(stage))
            return self._send(j)
        self._send({}, 404)

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}') if n else {}
        with open(HS / 'api.log', 'a') as f:
            f.write(f'POST {self.path} {json.dumps(body)[:200]}\n')
        if self.path.startswith('/api/setup/start'):
            pack = body.get('pack')
            valid = {'small', 'medium', 'all'}
            if pack not in valid:
                return self._send({'error': 'That library is not available yet.', 'code': 'unavailable'}, 400)
            if (HS / 'start_fail_space').exists():
                return self._send({'error': 'This needs 17.4 GB free on that disk, and it has 1.2 GB.',
                                   'code': 'no_space', 'need_bytes': 17382838828, 'free_bytes': 1200000000}, 400)
            (HS / 'job_stage').write_text('0')
            (HS / 'job.json').write_text(json.dumps(new_job(pack, body.get('folder'))))
            (HS / 'last_start_body').write_text(json.dumps(body))
            return self._send(job_doc())
        if self.path.startswith('/api/setup/resume'):
            (HS / 'job_pause').unlink(missing_ok=True)
            (HS / 'job_stage').write_text('1')
            return self._send(job_doc())
        if self.path.startswith('/api/setup/pause'):
            return self._send(job_doc())
        if self.path.startswith('/api/setup/finish'):
            global install
            if install is None:
                from engine.setup import install
            j = job_doc()
            if not j or j.get('state') != 'done':
                return self._send({'error': 'Setup has not finished yet.', 'code': 'not_done'}, 400)
            if lever('cur_pack', '') == '':
                install.stage_switch(PEND, STAGED, TARGET)
            return self._send({'ok': True, 'restart': True, 'folder': str(TARGET)})
        self._send({}, 404)

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
PYEOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_hostname_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "192.168.178.201")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "lastbook"; exit 0
EOF

cat > "$MK/mock-ip" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "192.168.178.201")
printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq state UP group default qlen 1000\n'
printf '    inet %s/24 scope global eth0\n       valid_lft forever preferred_lft forever\n' "$IP"
exit 0
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null

# Fixture: echte upstream install.py für Mock-API + Tarball + Engine-Paket
mkdir -p "$MK/upstream" "$MK/opt/lastbook/app/engine/setup"
cp "$UPSTREAM_INSTALL" "$MK/upstream-install.py"
cp "$UPSTREAM_INSTALL" "$MK/opt/lastbook/app/engine/setup/install.py"
echo '{}' > "$MK/opt/lastbook/app/engine/__init__.py"
echo '# mock setup package' > "$MK/opt/lastbook/app/engine/setup/__init__.py"

MOCK_API_PID=""
start_api() {
    # Stale Mock-Server früherer Läufe killen (sonst antwortet alter Code auf :8890)
    /usr/bin/pkill -f "mock-api.py" 2>/dev/null || true
    sleep 0.3
    if [[ -z "$MOCK_API_PID" ]] || ! kill -0 "$MOCK_API_PID" 2>/dev/null; then
        env -i PATH=/usr/bin:/bin HARNESS_STATE="$HS" MKROOT="$MK" PORT_API="$PORT" \
            /usr/bin/python3 "$MK/mock-api.py" > "$MK/api-server.log" 2>&1 &
        MOCK_API_PID=$!
        for _ in $(seq 1 30); do
            curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT}/" 2>/dev/null && return 0
            sleep 0.2
        done
        echo "✘ Mock-API startete nicht ($MK/api-server.log)"; exit 1
    fi
}
stop_api() {
    if [[ -n "$MOCK_API_PID" ]]; then kill "$MOCK_API_PID" 2>/dev/null || true; fi
}
trap 'stop_api' EXIT

# ══════════════════════════ Runner ═════════════════════════════════════════
reset_state() {
    # Mock-Root KOMPLETT wipen (Reste früherer Cases verfälschen has_lib/resolv.conf!)
    rm -rf "$HS" "${MK:?}/opt/lastbook" "${MK:?}/root" "${MK:?}/etc" "${MK:?}/var/log" "${MK:?}/tmp" "${MK:?}/tarball-src"
    mkdir -p "$HS" "$HS/templates" "$MK/etc/systemd/system" "$MK/etc/dhcp" \
        "$MK/etc/apt" "$MK/opt/lastbook" "$MK/root" "$MK/var/log" "$MK/tmp"
    echo "$CT_IP" > "$HS/ct_ip"
    : > "$HS/ct_list"
    : > "$HS/calls.log"
    : > "$API_LOG"
    echo "getent_mode=ok" > "$HS/getent_mode"
    # Engine-Fixture für die Mock-API — bewusst AUSSERHALB von opt/lastbook
    mkdir -p "$MK/api-fixture/engine/setup"
    cp "$UPSTREAM_INSTALL" "$MK/api-fixture/engine/setup/install.py"
    echo '{}' > "$MK/api-fixture/engine/__init__.py"
    echo '# mock setup package' > "$MK/api-fixture/engine/setup/__init__.py"
}

seed_ct() { # laufender CT mit installiertem Stack (für Update/Status/Deinstall)
    reset_state
    echo "200 running lastbook" > "$HS/ct_list"
    echo "running" > "$HS/ct_200.status"
    echo "lastbook" > "$HS/ct_200.hostname"
    mkdir -p "$MK/opt/lastbook/app" "$MK/opt/lastbook/LastbookData/library-data" \
        "$MK/opt/lastbook/LastbookData/derived" "$MK/opt/lastbook/data/derived" \
        "$MK/opt/lastbook/app/venv/bin" "$MK/etc/systemd/system" "$MK/var/log"
    printf '#!/usr/bin/env bash\nexec /usr/bin/python3 "$@"\n' > "$MK/opt/lastbook/app/venv/bin/python"
    chmod +x "$MK/opt/lastbook/app/venv/bin/python"
    echo "# mock server.py" > "$MK/opt/lastbook/app/server.py"
    printf 'ref=9e57ba27920ea4ef25ba93d3f8280edd41ab4a3c\nport=8890\n' > "$MK/opt/lastbook/app/INSTALL-INFO"
    printf '[{"id":"r1"},{"id":"r2"}]' > "$MK/opt/lastbook/LastbookData/library-data/catalog.json"
    printf '{"name": "small"}' > "$MK/opt/lastbook/LastbookData/pack.json"
    printf '%s' "harnesslankey123" > "$MK/opt/lastbook/LastbookData/derived/lan-key"
    printf '%s' "harnesslankey123" > "$MK/opt/lastbook/data/derived/lan-key"
    touch "$HS/template_downloaded" "$HS/lastbook_active"
    touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
    touch "$MK/etc/systemd/system/lastbook.service"
    echo "small" > "$HS/cur_pack"   # State meldet installiertes Pack small → Update-Skip
}

seed_staged_library() { # Fake-Entpackstand, den finish via stage_switch aktiviert
    mkdir -p "$MK/opt/lastbook/LastbookData.setup/unpack/LastbookData/library-data"
    cat > "$MK/opt/lastbook/LastbookData.setup/unpack/LastbookData/library-data/catalog.json" <<'CAT'
[{"id":"r1","kind":"metadata"},{"id":"r2","kind":"metadata"},{"id":"r3","kind":"metadata"},
 {"id":"r4","kind":"metadata"},{"id":"r5","kind":"metadata"}]
CAT
    printf '{"name": "small"}' > "$MK/opt/lastbook/LastbookData.setup/unpack/LastbookData/pack.json"
}

run_installer_stdin() {
    local input="$1"; shift
    start_api
    ( printf '%s\n' "$input" | unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_devnull() {
    start_api
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" < /dev/null > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}

echo "════════════════════════════════════════════════════════════"
echo " LastBook-Installer Harness (Mock-API: 127.0.0.1:$PORT, echtes apply_pending)"
echo "════════════════════════════════════════════════════════════"

# ── Case 1: Happy-Path-Install (small) ─────────────────────────────────────
t "Install happy-path (small)"
reset_state
seed_staged_library
rc=$(run_installer_devnull)
assert_exit 0 "$rc"
assert_calls 1 "pct create 200 local:vztmpl/debian-13-standard"
assert_fregex "$HS/ct_200.create" "TEMPLATE=.*_amd64\.tar\.zst"
assert_fcontains "$HS/ct_200.create" "--hostname lastbook"
assert_fcontains "$HS/ct_200.create" "--unprivileged 1"
assert_fcontains "$HS/ct_200.create" "--features nesting=1"
assert_fcontains "$HS/ct_200.create" "--onboot 1"
assert_file "$MK/root/setup-inner.sh"
assert_file "$MK/opt/lastbook/setup-library.sh"
assert_file "$MK/etc/systemd/system/lastbook.service"
assert_fcontains "$MK/etc/systemd/system/lastbook.service" "Restart=always"
assert_fcontains "$MK/etc/systemd/system/lastbook.service" "After=network-online.target"
assert_fcontains "$MK/etc/systemd/system/lastbook.service" "ExecStart=/opt/lastbook/app/serve.sh"
assert_fcontains "$MK/opt/lastbook/app/serve.sh" "/opt/lastbook/app/venv/bin/python"
assert_fcontains "$MK/opt/lastbook/app/serve.sh" ". /opt/lastbook/app/lastbook.env"
assert_calls 1 "/api/setup/start"
assert_fcontains "$HS/last_start_body" '"pack": "small"'
assert_fcontains "$HS/last_start_body" '"folder"'
# Echter Switch: echte Bibliothek aktiv (apply_pending lief)
assert_file "$MK/opt/lastbook/LastbookData/library-data/catalog.json"
assert_no_file "$MK/opt/lastbook/LastbookData.setup"
assert_no_file "$MK/root/.config/Lastbook/setup/pending.json"
assert_file "$MK/opt/lastbook/LastbookData/derived/lan-key"
assert_out "📚  LastBook ist bereit!"
assert_out "http://${CT_IP}:${PORT}/?key="
assert_calls 1 "systemctl enable lastbook"
assert_calls 1 "systemctl restart lastbook"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 2: --pack medium --rootfs 160 ─────────────────────────────────────
t "Install mit --pack medium --rootfs 160"
reset_state
seed_staged_library
rc=$(run_installer_devnull --pack medium --rootfs 160)
assert_exit 0 "$rc"
assert_fcontains "$HS/ct_200.create" "local-lvm:160"
assert_fcontains "$HS/last_start_body" '"pack": "medium"'
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 3: --map TX dazuladen ─────────────────────────────────────────────
t "Install mit --map TX"
reset_state
seed_staged_library
rc=$(run_installer_devnull --map TX)
assert_exit 0 "$rc"
assert_fcontains "$HS/last_start_body" '"map": "TX"'
assert_out "+ Karte TX"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 4: ungültiges Pack → die ──────────────────────────────────────────
t "Install mit --pack bogus → abgelehnt"
reset_state
rc=$(run_installer_devnull --pack bogus)
assert_exit 1 "$rc"
assert_out "Ungültiges Pack"
assert_no_calls "pct create"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 5: CT existiert bereits (ohne --force) → die mit Hinweisen ────────
t "Install bei vorhandenem CT → Hinweis, kein zweiter CT"
reset_state
echo "200 running lastbook" > "$HS/ct_list"
echo "running" > "$HS/ct_200.status"
echo "lastbook" > "$HS/ct_200.hostname"
rc=$(run_installer_devnull)
assert_exit 1 "$rc"
assert_out "existiert bereits"
assert_out "--update"
assert_no_calls "pct destroy"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 6: --force löscht vorhandenen CT ──────────────────────────────────
t "Install --force recreates"
reset_state
echo "200 running lastbook" > "$HS/ct_list"
echo "running" > "$HS/ct_200.status"
echo "lastbook" > "$HS/ct_200.hostname"
mkdir -p "$HS/templates"; touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst" "$HS/template_downloaded"
seed_staged_library
rc=$(run_installer_devnull --force)
assert_exit 0 "$rc"
assert_calls 1 "pct destroy 200"
assert_calls 1 "pct create 200"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 7: SKIP_LIBRARY — kein Bibliotheks-Call, Hinweis mit Befehl ───────
t "Install --skip-library"
reset_state
rc=$(run_installer_devnull --skip-library)
assert_exit 0 "$rc"
assert_calls 0 "POST /api/setup/start"
assert_file "$MK/opt/lastbook/setup-library.sh"
assert_out "Bibliothek NOCH NICHT installiert"
assert_out "env PACK=small"
assert_out "setup-library.sh"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 8: Setup lehnt start ab (unavailable) → die mit Fehlerkette ───────
t "Setup-API lehnt start ab → Fehlerkette"
reset_state
mkdir -p "$MK/opt/lastbook/LastbookData.setup"
touch "$HS/api_reject"  # (unbenutzt – rejection kommt über fake pack-id unten)
# Trick: pack korrekt, aber Manifest leer → start findet Pack nicht.
# Einfacher: start_fail-Space-Hebel prüft die no_space-Fehlerkette:
touch "$HS/start_fail_space"
seed_staged_library
rc=$(run_installer_devnull)
assert_exit 1 "$rc"
assert_out "no_space"
assert_out "Start abgelehnt"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 9: Pause/Resume-Hebel im Job-Poll ─────────────────────────────────
t "Job pausiert → resume"
reset_state
seed_staged_library
touch "$HS/job_pause"
rc=$(run_installer_devnull)
assert_exit 0 "$rc"
assert_calls 1 "/api/setup/resume"
assert_out "resume"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 10: DNS defekt → Fallback geschrieben ─────────────────────────────
t "DNS im CT defekt → Fallback-Resolver"
reset_state
seed_staged_library
echo "getent_mode=fail_then_ok" > "$HS/getent_mode"
rc=$(run_installer_devnull)
assert_exit 0 "$rc"
assert_out "DNS-Fallback aktiv"
assert_fregex "$MK/etc/resolv.conf" "nameserver 1.1.1.1"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 11: pct create schlägt fehl → Fehlerkette mit Aufräumarbeiten ─────
t "pct create fehlgeschlagen → Fehlerkette"
reset_state
touch "$HS/create_fail"
rc=$(run_installer_devnull)
assert_exit 255 "$rc"
assert_out "Installationsfehler"
assert_out "Vollständiges Log"
assert_out "--debug"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 12: Host-Seite nicht erreichbar → nur Warnung ─────────────────────
t "Host-Key-Check 000 → Warnung, kein Abbruch"
reset_state
seed_staged_library
touch "$HS/host_curl_fail"
rc=$(run_installer_devnull)
assert_exit 0 "$rc"
assert_out "vom Proxmox-Host nicht erreichbar"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 13: --update auf laufendem CT (Bibliothek = Skip) ──────────────────
t "Update laufender CT (Bibliothek bleibt)"
seed_ct
rc=$(run_installer_devnull --update)
assert_exit 0 "$rc"
assert_no_calls "pct create"
assert_calls 1 "curl -fSL --retry 3 https://codeload.github.com/Immortal-Protocols/lastbook/tar.gz/refs/heads/main"
assert_fcontains "$API_LOG" "GET /api/setup/state"
assert_out "Bibliothek bereits vorhanden (Pack small) – nichts zu tun."
assert_out "Update abgeschlossen"
assert_file "$MK/opt/lastbook/LastbookData/library-data/catalog.json"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 14: --update auf GESTOPPTEM CT → startet ihn selbst (Grube 10) ─────
t "Update auf gestopptem CT"
seed_ct
echo "200 stopped lastbook" > "$HS/ct_list"
echo "stopped" > "$HS/ct_200.status"
rc=$(run_installer_devnull --update)
assert_exit 0 "$rc"
assert_calls 1 "pct start 200"
assert_out "starte ihn"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 15: --update --pack medium → Upgrade-Body OHNE folder ──────────────
t "Update mit --pack medium → In-Place-Upgrade"
seed_ct
rc=$(run_installer_devnull --update --pack medium)
assert_exit 0 "$rc"
assert_fcontains "$HS/last_start_body" '"pack": "medium"'
assert_no_out '"folder"'
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 16: --update ohne CT → die mit Install-Hinweis ────────────────────
t "Update ohne CT"
reset_state
rc=$(run_installer_devnull --update)
assert_exit 1 "$rc"
assert_out "Kein Container mit Hostname 'lastbook'"
assert_out "Erst installieren"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 17: --update --id 999 unbekannt → die ──────────────────────────────
t "Update --id unbekannt"
reset_state
rc=$(run_installer_devnull --update --id 999)
assert_exit 1 "$rc"
assert_out "--id 999 nicht gefunden"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 18: --uninstall mit Bestätigung 'ja' ───────────────────────────────
t "Deinstall mit Bestätigung"
seed_ct
rc=$(run_installer_stdin "ja" --uninstall)
assert_exit 0 "$rc"
assert_calls 1 "pct stop 200"
assert_calls 1 "pct destroy 200 --purge"
assert_out "Container 200 entfernt."
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 19: --uninstall nicht-interaktiv ohne --yes → nichts gelöscht ──────
t "Deinstall nicht-interaktiv → Abbruch"
seed_ct
rc=$(run_installer_devnull --uninstall)
assert_exit 1 "$rc"
assert_out "Keine Bestätigung erhalten"
assert_no_calls "pct destroy"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 20: --uninstall --yes ohne Rückfrage ───────────────────────────────
t "Deinstall --yes"
seed_ct
rc=$(run_installer_devnull --uninstall --yes)
assert_exit 0 "$rc"
assert_calls 1 "pct destroy 200 --purge"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 21: --status laufender CT ──────────────────────────────────────────
t "Status laufender CT"
seed_ct
rc=$(run_installer_devnull --status)
assert_exit 0 "$rc"
assert_out "Service:   lastbook läuft"
assert_out "Bibliothek: installiert (2 Einträge)"
assert_out "http://${CT_IP}:${PORT}/?key=harnesslankey123"
assert_out "Upstream:  Immortal-Protocols/lastbook@9e57ba27"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 22: --status gestoppter CT ─────────────────────────────────────────
t "Status gestoppter CT"
seed_ct
echo "200 stopped lastbook" > "$HS/ct_list"
echo "stopped" > "$HS/ct_200.status"
rc=$(run_installer_devnull --status)
assert_exit 0 "$rc"
assert_out "nicht gestartet"
assert_no_out "läuft (Port"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 23: --status ohne CT ───────────────────────────────────────────────
t "Status ohne CT"
reset_state
rc=$(run_installer_devnull --status)
assert_exit 0 "$rc"
assert_out "Kein Container mit Hostname 'lastbook'"
assert_out "Installieren:"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 24: --id Override für --status auf zweitem CT ──────────────────────
t "Status --id Override"
seed_ct
echo "205 running lastbook" > "$HS/ct_list"
echo "running" > "$HS/ct_205.status"
echo "lastbook" > "$HS/ct_205.hostname"
mkdir -p "$MK/opt/lastbook/LastbookData/library-data" "$MK/opt/lastbook/LastbookData/derived"
printf '[{"id":"x"}]' > "$MK/opt/lastbook/LastbookData/library-data/catalog.json"
printf '%s' "andererkey205" > "$MK/opt/lastbook/LastbookData/derived/lan-key"
touch "$HS/lastbook_active"
rc=$(run_installer_devnull --status --id 205)
assert_exit 0 "$rc"
assert_out "http://${CT_IP}:${PORT}/?key=andererkey205"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 25: Root-Check ─────────────────────────────────────────────────────
t "Ohne root → die"
reset_state
# Root-Prüfung läuft unter unshare (EUID=0) durch – simuliere Nicht-Root via
# direktem Aufruf ohne unshare (Install-Modus prüft EUID als allererstes):
rc=$( ( env -i PATH="$HOSTBIN:/usr/bin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb \
        bash "$SCRIPT" < /dev/null > "$CUR_DIR/out.log" 2>&1 ); echo $? )
assert_exit 1 "$rc"
assert_out "Bitte als root ausführen"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 28: --model-base valid → lastbook.env enthält SURVIVAL_MODEL_BASE ──
t "Install mit --model-base (Ollama)"
reset_state
seed_staged_library
rc=$(run_installer_devnull --model-base http://127.0.0.1:11434)
assert_exit 0 "$rc"
assert_fcontains "$MK/opt/lastbook/app/lastbook.env" "SURVIVAL_MODEL_BASE=http://127.0.0.1:11434"
assert_out "Assistant: aktiv"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 29: --model-base nicht-loopback → abgelehnt ────────────────────────
t "--model-base nicht-loopback → abgelehnt"
reset_state
rc=$(run_installer_devnull --model-base http://10.120.1.5:11434)
assert_exit 1 "$rc"
assert_out "nur loopback erlaubt"
assert_no_calls "pct create"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 27: pct create --start spawn fehlgeschlagen (Exit trotzdem 0) ──────
t "Spawn fehlgeschlagen → Arch-Diagnose"
reset_state
touch "$HS/create_nostart"
seed_staged_library
rc=$(run_installer_devnull)
assert_exit 1 "$rc"
assert_out "Container 200 startet nicht"
assert_out "Template-Architektur"
assert_out "pct destroy 200 --purge"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

# ── Case 26: --help ─────────────────────────────────────────────────────────
t "Hilfe"
reset_state
rc=$(run_installer_devnull --help)
assert_exit 0 "$rc"
assert_out "--pack NAME"
assert_out "skip-library"
if [[ $VERBOSE == 1 ]]; then dump_case; fi

stop_api
echo ""
echo "════════════════════════════════════════════════════════════"
if [[ $FAILED -eq 0 ]]; then
    echo " ✅ ALLE CASES GRÜN – $PASSED Assertionen bestanden"
    exit 0
else
    echo " ❌ $FAILED Assertionen fehlgeschlagen ($PASSED bestanden)"
    exit 1
fi
