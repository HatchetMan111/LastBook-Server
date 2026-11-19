#!/usr/bin/env bash
# =============================================================================
#  📚 LastBook – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/LastBook-Server
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  Lastbook (https://github.com/Immortal-Protocols/lastbook): eine lokale
#  Offline-Survival-Bibliothek – Handbücher, Enzyklopädien, Videos,
#  Offline-Karten und ein Chat mit Quellenverweisen. MIT-Lizenz.
#
#  Deployt wird der BIBLIOTHEKSSERVER-Modus (server.py --lan, Port 8890):
#  die Weboberfläche ist im Heimnetz über http://<CT-IP>:8890/?key=<KEY>
#  erreichbar (Schutz-Zugangslink, einmal öffnen genügt – Cookie für 1 Jahr).
#  Die Bibliothek (Packs von downloads.lastbook.org, SHA-256-geprüft) wird
#  vom Installer headless über die offizielle Setup-API installiert
#  (Default: "small", ~7,7 GB). Lokale KI (16,9 GB GGUF) ist bewusst AUS
#  – Suche/Lesen/Karten brauchen sie nicht.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LastBook-Server/main/install/lastbook.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --pack medium --rootfs 160
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.6"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="lastbook"
UPSTREAM_OWNER="Immortal-Protocols"
UPSTREAM_REPO="lastbook"
UPSTREAM_REF_PIN="9e57ba27920ea4ef25ba93d3f8280edd41ab4a3c"  # getesteter Stand (2026-11-18)
UPSTREAM_BRANCH="main"      # Update-Quelle (--update holt main; Install ist auf REF_PIN gepinnt)
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="lastbook"
CT_STORAGE="local-lvm"
CT_ROOTFS=32                # GB – small-Pack braucht ~18 GB; medium ~140 GB, all ~790 GB!
CT_CORES=2
CT_MEMORY=2048              # MB – Keyword-Suche/Server reicht das; KI-Modus bewusst aus
CT_SWAP=512
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
PORT=8890                   # Lastbook-Server-Port (Original-Default)
PACK="${PACK:-small}"       # Bibliothekspack: small (~7,7 GB) | medium (~67 GB) | all (~388 GB)
MAP="${MAP:-}"              # optional: US-Bundesstaat-Karte dazuladen, z. B. TX (4–9 GB je Staat)
MODEL_BASE="${MODEL_BASE:-}"  # optional: OpenAI-kompatibler Modellserver (nur loopback!) für den
                              # Ask-Tab, z. B. http://127.0.0.1:11434 (Ollama) – sonst leer
MODEL_BASE_SET=false
ASSISTANT=false              # true (--assistant): Ollama IM CT installieren + Modell + verkabeln
ASSISTANT_REMOVE=false       # true (--assistant-remove): Assistant-Verkabelung lösen
ASSISTANT_MODEL=""           # leer = automatisch (RAM-abhängig: <3,5 GB → qwen3:0.6b, sonst qwen3:1.7b)
SKIP_LIBRARY=false          # true = nur Server, Bibliothek später (siehe README)
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LastBook-Server/main/install/lastbook.sh)"'

# Pfade IM CONTAINER (auch vom Host-Script referenziert, z. B. Key/Verify)
C_APP_DIR="/opt/lastbook/app"
C_DATA_STUB="/opt/lastbook/data"
C_DATA_LIB="/opt/lastbook/LastbookData"
C_OLLAMA_DIR="/opt/lastbook/ollama"

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Service + Setup-Job), falls
# schon ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup, Service, Setup-Job):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/lastbook-setup.log 2>/dev/null
            echo "--- setup-library.log ---"
            tail -n 40 /var/log/lastbook-setup-library.log 2>/dev/null
            echo "--- setup-assistant.log ---"
            tail -n 20 /var/log/lastbook-assistant.log 2>/dev/null
            echo "--- journalctl -u ollama ---"
            journalctl -u ollama --no-pager 2>/dev/null | tail -n 10
            echo "--- journalctl -u lastbook ---"
            journalctl -u lastbook --no-pager 2>/dev/null | tail -n 25
            echo "--- Setup-Job (job.json) ---"
            cat /root/.config/Lastbook/setup/job.json 2>/dev/null | tail -c 2000
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    # $NF-Suche ist nicht immer portabel (Live-Fall ProxSmartHome) – Fallback:
    # jede VMID einzeln via `pct config | grep '^hostname: X$'` prüfen.
    local id=""
    id=$(pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}' || true)
    if [[ -z "$id" ]]; then
        while read -r vid; do
            if pct config "$vid" 2>/dev/null | grep -q "^hostname: ${CT_HOSTNAME}$"; then
                id="$vid"
                break
            fi
        done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
    fi
    echo "$id"
}

resolve_ct_id() {
    # Explizite --id gewinnt; sonst per Hostname suchen.
    if [[ -n "$CT_ID" ]]; then
        if ! pct status "$CT_ID" &>/dev/null; then
            die "Container mit --id $CT_ID nicht gefunden (pct status scheiterte)."
        fi
        echo "$CT_ID"
        return 0
    fi
    find_ct_id_by_hostname
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – Tarball + PyPI brauchen Namensauflösung.
    # Live-Fall (2026-11-10, CT 200): DNS ist FLAKY – ein einzelner getent-Erfolg
    # reichte, Stunden später war wieder alles tot. Deshalb: 3 Erfolge in Folge
    # verlangen; eine einzige Störung in diesem Fenster → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts pypi.org >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts pypi.org >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

get_active_lan_key() {
    # LAN-Zugangskey aus dem AKTIVEN Datenordner lesen (LastbookData wenn echte
    # Bibliothek, sonst Stub-Datenordner) – || true INNERHALB von $() (Grube 3).
    pct exec "$1" -- sh -c "
        if [ -s ${C_DATA_LIB}/derived/lan-key ]; then
            cat ${C_DATA_LIB}/derived/lan-key
        else
            cat ${C_DATA_STUB}/derived/lan-key 2>/dev/null
        fi" 2>/dev/null | tail -n 1 || true
    return 0
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --pack)          PACK="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --model-base)    MODEL_BASE="${args[$((i+1))]:-}"; MODEL_BASE_SET=true; i=$((i+2)) ;;
            --assistant)     ASSISTANT=true; i=$((i+1)) ;;
            --assistant-model) ASSISTANT_MODEL="${args[$((i+1))]:-}"; ASSISTANT=true; i=$((i+2)) ;;
            --assistant-remove) ASSISTANT_REMOVE=true; i=$((i+1)) ;;
            --map)           MAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --skip-library)  SKIP_LIBRARY=true; i=$((i+1)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Port hart validieren – er landet direkt in der Service-Config im Container.
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
        die "Ungültiger Port: '$PORT' (1–65535 erwartet, z. B. --port 8890)"
    fi
    case "$PACK" in
        small|medium|all) ;;
        *) die "Ungültiges Pack: '$PACK' (small, medium oder all – z. B. --pack medium)" ;;
    esac
    if [[ -n "$MODEL_BASE" ]] && ! [[ "$MODEL_BASE" =~ ^http://(127\.0\.0\.1|localhost|\[::1\]|::1)(:[0-9]{1,5})?/?$ ]]; then
        die "Ungültige --model-base: '$MODEL_BASE' (nur loopback erlaubt, z. B. http://127.0.0.1:11434 –
  der upstream-Assistant verweigert Nicht-Loopback-Adressen selbst, siehe assistant.py)"
    fi
    if $ASSISTANT && $ASSISTANT_REMOVE; then
        die "--assistant und --assistant-remove widersprechen sich."
    fi
    if [[ -n "$MAP" ]] && ! [[ "$MAP" =~ ^[A-Z]{2}$ ]]; then
        die "Ungültige Karte: '$MAP' (zweibuchstabiger US-Bundesstaat, z. B. --map TX)"
    fi
    if ! [[ "$CT_ROOTFS" =~ ^[0-9]+$ ]] || [[ "$CT_ROOTFS" -lt 8 ]]; then
        die "Ungültige rootfs-Größe: '$CT_ROOTFS' (GB, mindestens 8)"
    fi
}

print_help() {
    cat <<'EOF'
📚 LastBook – Proxmox-Installer (Offline-Survival-Bibliothek als LXC-Server)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LastBook-Server/main/install/lastbook.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --pack medium):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: lastbook)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 32 – reicht für pack "small";
                   medium: --rootfs 160, all: --rootfs 840)
  --cores N        vCPUs (Default: 2)
  --memory MB      RAM (Default: 2048 – Suche/Lesen/Karten brauchen mehr nicht)
  --swap MB        Swap (Default: 512)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT      Server-Port im Container (Default: 8890)
  --pack NAME      Bibliothekspack: small (7,7 GB, Default) | medium (67 GB) | all (388 GB)
  --assistant      💬 Assistant nativ aktivieren: installiert Ollama IM CT, startet den
                   Service auf 127.0.0.1:11434, lädt qwen3 (Modell nach RAM: <3,5 GB →
                   0.6b, sonst 1.7b) und verkabelt SURVIVAL_MODEL_BASE
  --assistant-model NAME   Modell selbst wählen (impliziert --assistant), z. B.
                   --assistant-model qwen3:1.7b
  --assistant-remove       Assistant-Verkabelung lösen (Ollama bleibt installiert)
  --model-base URL Assistant an EIGENEN Modellserver binden (NUR loopback, z. B.
                   http://127.0.0.1:11434) – ohne Ollama-Installation
  --map ST         US-Bundesstaat-Karte dazuladen, z. B. --map TX (2–9 GB je Staat)
  --skip-library   Nur Server installieren; Bibliothek später nachziehen
                   (Befehl steht am Ende der Installation)
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         App im bestehenden Container aktualisieren (Upstream main; Bibliothek bleibt)
  --uninstall      Container stoppen und löschen (Bibliothek wird neu heruntergeladen beim
                   nächsten Install – kein anderer Weg, sie liegt nur im CT)
  --status         Status anzeigen (inkl. Zugangslink mit Key)
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (PORT, LAN_KEY, TAR_URL …) kommen als Umgebungsvariablen via
# `pct exec -- env …` in den Container (keine Escaping-Gruben).
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# LastBook In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: APP_DIR, DATA_STUB, DATA_LIB, PORT, LAN_KEY, TAR_URL
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
die(){ err "$1"; exit 1; }

: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${DATA_STUB:?DATA_STUB fehlt (env)}"
: "${DATA_LIB:?DATA_LIB fehlt (env)}"
: "${PORT:?PORT fehlt (env)}"
: "${LAN_KEY:?LAN_KEY fehlt (env)}"
: "${TAR_URL:?TAR_URL fehlt (env)}"
: "${REF:?REF fehlt (env)}"
MODEL_BASE="${MODEL_BASE:-}"

echo ">>> Resolver-Dateien lesbar für apt-Sandbox stellen (getent-ok/apt-tot-Grube) ..."
chmod 0644 /etc/resolv.conf /etc/hosts /etc/hostname 2>/dev/null || true
mkdir -p /etc/apt/apt.conf.d
echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99lastbook-sandbox

echo ">>> Basis-Pakete installieren (curl, ca-certificates, python3, venv) ..."
apt-get update -qq
apt-get install -y -qq curl ca-certificates python3 python3-venv >/dev/null

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# LastBook: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns

echo ">>> Lastbook-Quellcode laden (${TAR_URL}) ..."
curl -fSL --retry 3 "${TAR_URL}" -o /tmp/lastbook.tar.gz
rm -rf /tmp/lastbook-src && mkdir -p /tmp/lastbook-src
tar -xzf /tmp/lastbook.tar.gz -C /tmp/lastbook-src --strip-components=1

echo ">>> Code nach ${APP_DIR} übernehmen (expliziter Swap, kein mv-INTO) ..."
mkdir -p "$(dirname "${APP_DIR}")"   # Elternordner existiert im frischen CT noch nicht
rm -rf "${APP_DIR}.new" "${APP_DIR}.old"
cp -a /tmp/lastbook-src "${APP_DIR}.new"
if [ -d "$APP_DIR" ]; then
    mv "$APP_DIR" "${APP_DIR}.old"
fi
mv "${APP_DIR}.new" "$APP_DIR"
rm -rf "${APP_DIR}.old" /tmp/lastbook-src /tmp/lastbook.tar.gz

echo ">>> Python-Abhängigkeiten (venv + upstream-requirements) ..."
python3 -m venv "${APP_DIR}/venv"
REQ="${APP_DIR}/packaging/linux/requirements_linux.txt"
if [ -s "$REQ" ]; then
    "${APP_DIR}/venv/bin/pip" install --no-cache-dir -q -r "$REQ"
else
    # Fallback-Pins, falls upstream die Datei mal verschiebt (Stand 2026-11-19)
    "${APP_DIR}/venv/bin/pip" install --no-cache-dir -q \
        "libzim==3.13.1" "numpy==2.4.6" "beautifulsoup4==4.15.0" "pypdfium2==5.14.0"
fi
"${APP_DIR}/venv/bin/python" -c "import libzim, numpy, pypdfium2, bs4; print('    Imports OK (libzim/numpy/pypdfium2/bs4)')"

echo ">>> Stub-Datenordner anlegen (Startbrücke bis zur echten Bibliothek) ..."
mkdir -p "${DATA_STUB}/library-data" "${DATA_STUB}/derived"
if [ ! -s "${DATA_STUB}/library-data/catalog.json" ]; then
    printf '[]' > "${DATA_STUB}/library-data/catalog.json"
fi

echo ">>> LAN-Zugangskey schreiben (bleibt über alle Phasen stabil) ..."
printf '%s' "${LAN_KEY}" > "${DATA_STUB}/derived/lan-key"
chmod 600 "${DATA_STUB}/derived/lan-key"

echo ">>> serve.sh (wählt aktiven Datenordner) ..."
cat > "${APP_DIR}/serve.sh" <<'SERVEEOF'
#!/usr/bin/env bash
# Lastbook-Server-Starter: wählt den aktiven Datenordner.
# LastbookData = echte Bibliothek (nach dem Headless-Setup), sonst Stub.
set -euo pipefail
PORT="${PORT:-8890}"
if [ -f /opt/lastbook/app/lastbook.env ]; then
    # shellcheck disable=SC1091
    . /opt/lastbook/app/lastbook.env
fi
if [ -n "${SURVIVAL_MODEL_BASE:-}" ]; then
    export SURVIVAL_MODEL_BASE
fi
DATA="/opt/lastbook/data"
LIB="/opt/lastbook/LastbookData"
CAT="${LIB}/library-data/catalog.json"
if [ -s "$CAT" ] && [ "$(wc -c < "$CAT")" -gt 10 ]; then
    DATA="$LIB"
fi
exec /opt/lastbook/app/venv/bin/python /opt/lastbook/app/server.py --lan --port "$PORT" --data "$DATA"
SERVEEOF
chmod +x "${APP_DIR}/serve.sh"
{
    printf 'PORT=%s\n' "${PORT}"
    if [ -n "${MODEL_BASE}" ]; then
        printf 'SURVIVAL_MODEL_BASE=%s\n' "${MODEL_BASE}"
    fi
} > "${APP_DIR}/lastbook.env"

echo ">>> systemd-Unit (Restart=always, onboot macht den Rest) ..."
cat > /etc/systemd/system/lastbook.service <<'UNITEOF'
[Unit]
Description=Lastbook Bibliotheksserver (Offline-Survival-Guide)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lastbook/app
ExecStart=/opt/lastbook/app/serve.sh
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
# RESTART statt enable --now: der Service kann von einem früheren Lauf mit
# anderem Config-Stand laufen (Debian startet Services teils schon bei apt).
systemctl enable lastbook >/dev/null 2>&1
systemctl restart lastbook

echo ">>> Warte auf Lastbook-Server (Port ${PORT}) ..."
PORT_OK=""
for _ in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/"; then
        PORT_OK=1
        break
    fi
    sleep 1
done
if [ -z "$PORT_OK" ]; then
    err "Lastbook lauscht nicht auf Port ${PORT}."
    echo "--- journalctl -u lastbook ---"
    journalctl -u lastbook --no-pager 2>/dev/null | tail -n 30 || true
    die "Server nach 30 s nicht erreichbar (Trace oben).\n  Debug: pct enter && journalctl -u lastbook -e"
fi

printf 'ref=%s\nport=%s\n' "${REF}" "${PORT}" > "${APP_DIR}/INSTALL-INFO"
echo ">>> Setup abgeschlossen."
INNEREOF
}

# ── Headless-Bibliotheks-Setup (läuft im CT, nutzt die offizielle Setup-API) ─
# ACHTUNG: QUOTETER Heredoc ('LIBEOF'). Setup-API ist Loopback-only (api.py:
# client_address-Check) – deshalb alle Calls per curl auf 127.0.0.1.
write_setup_library_script() {
    cat > "$TMP_DIR/setup-library.sh" <<'LIBEOF'
#!/usr/bin/env bash
# =============================================================================
# LastBook Headless-Bibliotheks-Setup (im CT ausführen)
# Fährt die offizielle /api/setup/-Kette: state → start → job-Poll → finish →
# apply_pending (Switch) → Service-Restart. Idempotent: vorhandene Bibliothek
# mit gleichem Pack = No-op; anderes Pack = in-place-Upgrade von upstream.
# Variablen via env: PACK, MAP, APP_DIR, DATA_STUB, DATA_LIB, PORT
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Bibliotheks-Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export LC_ALL=C
PY="${APP_DIR}/venv/bin/python"

err(){ echo "✘ $1" >&2; }
die(){ err "$1"; exit 1; }

: "${PACK:?PACK fehlt (env)}"
: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${DATA_STUB:?DATA_STUB fehlt (env)}"
: "${DATA_LIB:?DATA_LIB fehlt (env)}"
: "${PORT:?PORT fehlt (env)}"
MAP="${MAP:-}"
SETCONF="${XDG_CONFIG_HOME:-${HOME}/.config}/Lastbook"
API="http://127.0.0.1:${PORT}/api/setup"
# Venv-Python, Fallback System-Python (beide reichen: nur stdlib nötig);
# LB_PY erlaubt Tests, einen anderen Interpreter zu setzen.
if [ -x "${APP_DIR}/venv/bin/python" ]; then
    PY="${APP_DIR}/venv/bin/python"
else
    PY=$(command -v python3)
fi
PY="${LB_PY:-$PY}"

real_lib() { [ -s "${DATA_LIB}/library-data/catalog.json" ] && [ "$(wc -c < "${DATA_LIB}/library-data/catalog.json")" -gt 10 ]; }

api_get()  { curl -s -m 30 "${API}/$1"; }
api_post() { curl -s -m 30 -X POST -H 'Content-Type: application/json' -d "$2" "${API}/$1"; }

ensure_server() {
    if ! curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/"; then
        echo ">>> Server läuft nicht – starte Service ..."
        systemctl restart lastbook
        local i
        for i in $(seq 1 30); do
            curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/" && return 0
            sleep 1
        done
        err "Server nicht erreichbar (Port ${PORT})."
        journalctl -u lastbook --no-pager 2>/dev/null | tail -n 30 || true
        die "Lastbook-Server reagiert nicht – Trace oben."
    fi
}

jget() { "$PY" -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2" 2>/dev/null || echo ""; }

# ─────────────────────────────────────────────── Schritt 1: Server + Manifest
echo ">>> [1/6] Server prüfen ..."
ensure_server

echo ">>> [2/6] Pack-Manifest laden (downloads.lastbook.org, async – warte) ..."
# upstream fetch_once() startet den Manifest-Fetch EINMAL pro Server-Process und
# retryt nie – ein transienter DNS-Blip würde ihn dauerhaft leer hinterlassen.
# Gegenmaßnahme: nach Timeout den Service neu starten (frischer Fetch-Thread)
# und EINMAL wiederholen.
state_poll() {
    "$PY" -I -c "
import json, sys, time, urllib.request
url = 'http://127.0.0.1:${PORT}/api/setup/state'
deadline = time.time() + 90
last = {}
while time.time() < deadline:
    try:
        last = json.load(urllib.request.urlopen(url, timeout=30))
    except Exception as e:
        print('state-fetch:', e, file=sys.stderr)
    packs = last.get('manifest', {}).get('packs', [])
    if packs:
        with open('/tmp/lastbook-state.json', 'w') as f:
            json.dump(last, f)
        sys.exit(0)
    time.sleep(2)
with open('/tmp/lastbook-state.json', 'w') as f:
    json.dump(last, f)
sys.exit(3)
"
}
if ! state_poll; then
    warn "Manifest blieb leer – Starte Service neu (fetch_once retryt nie) und versuche es EINMAL wieder ..."
    systemctl restart lastbook
    for _ in $(seq 1 30); do
        curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/" && break
        sleep 1
    done
    if ! state_poll; then
        err "Manifest blieb leer (2 Versuche) – Setup-API-Kontext:"
        curl -s -m 10 "${API}/state" | head -c 600 || true
        echo
        die "Keine Packs im Manifest.\n  Prüfe Internet im CT (vom Proxmox-Host): pct exec <CT-ID> -- curl -sI https://downloads.lastbook.org/manifest-v1.json"
    fi
fi
STATE_FILE=/tmp/lastbook-state.json

read -r CUR_PACK CUR_MAP NEED_GB FREE_GB <<< "$("$PY" -I - "$STATE_FILE" "$PACK" <<'PYIN'
import json, sys
d = json.load(open(sys.argv[1]))
cur = d.get('current', {}) or {}
rec = (d.get('recommend', {}) or {}).get('need_bytes', {}) or {}
disks = (d.get('hardware', {}) or {}).get('disks', []) or []
free = disks[0].get('free_bytes', 0) if disks else 0
need = rec.get(sys.argv[2]) or 0
print(cur.get('pack') or '-', cur.get('map') or '-', '{:.1f}'.format(need / 1e9), '{:.1f}'.format(free / 1e9))
PYIN
)"
echo "    Aktuelles Pack: ${CUR_PACK} | Ziel: ${PACK} ${MAP:+(+ Karte ${MAP})} | Bedarf: ~${NEED_GB} GB | Frei: ${FREE_GB} GB"

# ─────────────────────────────────────────────── Schritt 2: Entscheiden
if real_lib && [[ "$CUR_PACK" == "$PACK" ]] && [[ -z "$MAP" || "$CUR_MAP" == "$MAP" ]]; then
    echo ">>> Bibliothek bereits vorhanden (Pack ${PACK}) – nichts zu tun."
    echo ">>> FERTIG (skip)"
    exit 0
fi

MAP_JSON=""
if [[ -n "$MAP" ]]; then
    MAP_JSON=$(printf ', "map": "%s"' "$MAP")
fi
if real_lib; then
    # Upgrade/Änderung IN PLACE: ohne folder-Parameter (upstream verschiebt die
    # alte Bibliothek selbst zu LastbookData.old-<Datum> und behält Karten/Modelle).
    if [[ "$CUR_PACK" != "$PACK" ]]; then
        BODY=$(printf '{"ai": false, "pack": "%s"%s}' "$PACK" "$MAP_JSON")
    else
        BODY=$(printf '{"ai": false%s}' "$MAP_JSON")
    fi
else
    BODY=$(printf '{"ai": false, "pack": "%s", "folder": "/opt/lastbook"%s}' "$PACK" "$MAP_JSON")
fi

# ─────────────────────────────────────────────── Schritt 3: Start
echo ">>> [3/6] Download starten: ${BODY}"
START="$(api_post start "$BODY")"
echo "$START" > /tmp/lastbook-start.json
START_ERR="$(jget /tmp/lastbook-start.json "d.get('error')")"
if [[ -n "$START_ERR" && "$START_ERR" != "None" ]]; then
    err "Start abgelehnt: $START_ERR"
    cat /tmp/lastbook-start.json
    die "Setup-API lehnte start ab (JSON oben – 'no_space' heißt Disk zu klein, 'unavailable' heißt Pack nicht verfügbar)."
fi

# ─────────────────────────────────────────────── Schritt 4: Job-Poll
echo ">>> [4/6] Download/Entpacken läuft (Fortschritt unten, Abbruch mit Strg-C lässtResume zu) ..."
STALL_S=720          # 12 min ohne Fortschritt (ohne retry-Fenster) → Abbruch mit Diagnose
LAST_DONE=-1
LAST_CHANGE=$(date +%s)
while true; do
    sleep 5
    api_get job > /tmp/lastbook-job.json || true
    JSTATE="$(jget /tmp/lastbook-job.json "d.get('state')")"
    if [[ "$JSTATE" == "None" || -z "$JSTATE" ]]; then
        continue
    fi
    if [[ "$JSTATE" == "paused" ]]; then
        echo ""
        echo "    Job pausiert (Service-Restart?) – resume ..."
        api_post resume '{}' > /dev/null
        continue
    fi
    "$PY" -I -c "
import json, sys
j = json.load(open('/tmp/lastbook-job.json'))
parts = []
for it in j.get('items', []):
    done, total = it.get('bytes_done') or 0, it.get('bytes_total') or 0
    pct = '{:.0f}%'.format(100 * done / total) if total else '?'
    rate = it.get('rate_bps')
    mb = '{:.1f} MB/s'.format(rate / 1e6) if rate else ''
    eta = it.get('eta_s')
    eta_s = 'ETA {}:{:02d}'.format(eta // 60, eta % 60) if eta else ''
    retry = '(Retry in {}s)'.format(it.get('retry_in_s')) if it.get('retry_in_s') else ''
    parts.append('{}: {} {} {} {} {}'.format(it.get('title'), it.get('state'), pct, mb, eta_s, retry).rstrip())
print('    ' + (' | '.join(parts) if parts else '(keine Items)'))
" || true
    DONE_SUM="$(jget /tmp/lastbook-job.json "sum(i.get('bytes_done') or 0 for i in d.get('items',[]))")"
    NOW=$(date +%s)
    if [[ "$DONE_SUM" != "$LAST_DONE" ]]; then
        LAST_DONE="$DONE_SUM"
        LAST_CHANGE=$NOW
    fi
    HAS_RETRY="$(jget /tmp/lastbook-job.json "any(i.get('retry_in_s') for i in d.get('items',[]))")"
    if [[ "$HAS_RETRY" != "True" ]] && [[ $((NOW - LAST_CHANGE)) -gt $STALL_S ]]; then
        err "Kein Fortschritt seit ${STALL_S} s – Job-Zustand:"
        cat /tmp/lastbook-job.json | head -c 2000
        die "Download hängt (Stall-Detektion).\n  Resume später: pct exec \$(pct list | awk '/lastbook/{print \$1}') -- env PACK=${PACK} bash /opt/lastbook/setup-library.sh"
    fi
    case "$JSTATE" in
        done) echo ""; echo "    Job fertig."; break ;;
        failed|cancelled)
            echo ""
            err "Job endete mit: $JSTATE"
            cat /tmp/lastbook-job.json | head -c 3000
            echo
            err "--- Letzte Server-Logzeilen ---"
            journalctl -u lastbook --no-pager 2>/dev/null | tail -n 15 || true
            die "Bibliotheks-Download fehlgeschlagen (Job-JSON oben: 'error' pro Item nennt die Ursache – network/checksum/no_space/unpack).\n  Resume später: pct exec \$(pct list | awk '/lastbook/{print \$1}') -- env PACK=${PACK} bash /opt/lastbook/setup-library.sh"
            ;;
    esac
done

# ─────────────────────────────────────────────── Schritt 5: finish + Switch
echo ">>> [5/6] finish + Switch (upstream apply_pending mit Rollback) ..."
FINISH="$(api_post finish '{}')"
echo "$FINISH" > /tmp/lastbook-finish.json
FIN_OK="$(jget /tmp/lastbook-finish.json "d.get('ok')")"
if [[ "$FIN_OK" != "True" ]]; then
    err "finish abgelehnt:"; cat /tmp/lastbook-finish.json
    die "Setup-Job war nicht 'done' bei finish."
fi
# server.py wendet pending.json NICHT selbst an (macht normalerweise die
# Desktop-App) – hier upstream apply_pending direkt aufrufen, inkl. Rollback.
"$PY" -I <<PYEOF
import sys
sys.path.insert(0, '${APP_DIR}')
from pathlib import Path
from engine.setup import install
pend = Path('${SETCONF}') / 'setup' / 'pending.json'
work = Path('${DATA_LIB}.setup')
if pend.exists():
    lib, note = install.apply_pending(pend, work)
    if lib:
        install.confirm(pend)
        print(f'    Switch OK: {lib}')
        if note and note.get('old'):
            print(f'    (alte Bibliothek bleibt bei {note["old"]})')
    else:
        print('    Switch-Fehler:', (note or {}).get('error'), file=sys.stderr)
        sys.exit(1)
else:
    print('    (kein pending – Switch war schon angewendet)')
PYEOF

echo ">>> LAN-Key in die neue Bibliothek übernehmen (gleicher Key wie Stub-Phase) ..."
mkdir -p "${DATA_LIB}/derived"
if [ -s "${DATA_STUB}/derived/lan-key" ]; then
    cp "${DATA_STUB}/derived/lan-key" "${DATA_LIB}/derived/lan-key"
    chmod 600 "${DATA_LIB}/derived/lan-key"
fi

# ─────────────────────────────────────────────── Schritt 6: Restart + Verify
echo ">>> [6/6] Service neu starten (serve.sh wählt jetzt LastbookData) ..."
systemctl restart lastbook
for _ in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/" && break
    sleep 1
done
curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${PORT}/" || die "Server nach Switch nicht erreichbar – journalctl -u lastbook -e"
if ! real_lib; then
    die "Switch hat keine echte Bibliothek hinterlassen (catalog.json fehlt/leer)."
fi
RECORDS="$("$PY" -I -c "import json; print(len(json.load(open('${DATA_LIB}/library-data/catalog.json'))))" 2>/dev/null || echo "?")"
rm -rf "${DATA_LIB}.setup" /tmp/lastbook-state.json /tmp/lastbook-start.json /tmp/lastbook-finish.json /tmp/lastbook-job.json
echo ">>> Bibliothek aktiv: ${RECORDS} Einträge im Katalog."
echo ">>> FERTIG"
LIBEOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere App im Container $ct_id"
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    pct exec "$ct_id" -- env APP_DIR="$C_APP_DIR" DATA_STUB="$C_DATA_STUB" \
        DATA_LIB="$C_DATA_LIB" PORT="$PORT" LAN_KEY="$LAN_KEY" TAR_URL="$TAR_URL" REF="$INNER_REF" \
        MODEL_BASE="$MODEL_BASE" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/lastbook-setup.log'
}

run_setup_library() {
    local ct_id="$1"
    header "📚 Installiere Bibliothek (Pack: ${PACK}${MAP:+ + Karte ${MAP}})"
    write_setup_library_script
    pct push "$ct_id" "$TMP_DIR/setup-library.sh" /opt/lastbook/setup-library.sh
    pct exec "$ct_id" -- chmod +x /opt/lastbook/setup-library.sh
    pct exec "$ct_id" -- env PACK="$PACK" MAP="$MAP" APP_DIR="$C_APP_DIR" \
        DATA_STUB="$C_DATA_STUB" DATA_LIB="$C_DATA_LIB" PORT="$PORT" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/root/.config}" \
        bash -c 'set -o pipefail; bash /opt/lastbook/setup-library.sh 2>&1 | tee /var/log/lastbook-setup-library.log'
}

# ── Assistant (--assistant): Ollama im CT installieren + Modell + verkabeln ──
# ACHTUNG: QUOTETER Heredoc ('ASSEOF'). Alle Werte kommen via env (ASSIST_MODEL,
# APP_DIR, ASSIST_REMOVE). Ollama lauscht per Default auf 127.0.0.1:11434 —
# loopback, wie der upstream-Assistant es verlangt.
write_setup_assistant_script() {
    cat > "$TMP_DIR/setup-assistant.sh" <<'ASSEOF'
#!/usr/bin/env bash
# =============================================================================
# LastBook Assistant-Setup (im CT ausführen, idempotent)
# Installiert Ollama (wenn fehlend), Startet den Service auf 127.0.0.1:11434,
# lädt das Modell (skip, wenn vorhanden) und verkabelt SURVIVAL_MODEL_BASE.
# Variablen via env: ASSIST_MODEL, APP_DIR, ASSIST_REMOVE (0/1)
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Assistant-Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export LC_ALL=C

err(){ echo "✘ $1" >&2; }
die(){ err "$1"; exit 1; }

: "${ASSIST_MODEL:?ASSIST_MODEL fehlt (env)}"
: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${OLLAMA_DIR:?OLLAMA_DIR fehlt (env)}"
ASSIST_REMOVE="${ASSIST_REMOVE:-0}"
ENV_FILE="${APP_DIR}/lastbook.env"

env_set_model() {   # SURVIVAL_MODEL_BASE-Zeile setzen (idempotent)
    local line="$1"
    if [ -f "$ENV_FILE" ]; then
        grep -v '^SURVIVAL_MODEL_BASE=' "$ENV_FILE" > "${ENV_FILE}.new" || true
    else
        : > "${ENV_FILE}.new"
    fi
    printf '%s\n' "$line" >> "${ENV_FILE}.new"
    mv "${ENV_FILE}.new" "$ENV_FILE"
}
env_clear_model() {
    if [ -f "$ENV_FILE" ]; then
        grep -v '^SURVIVAL_MODEL_BASE=' "$ENV_FILE" > "${ENV_FILE}.new" || true
        mv "${ENV_FILE}.new" "$ENV_FILE"
    fi
}

if [ "$ASSIST_REMOVE" = "1" ]; then
    echo ">>> Assistant-Verkabelung lösen (SURVIVAL_MODEL_BASE entfernen) ..."
    env_clear_model
    systemctl restart lastbook
    for _ in $(seq 1 30); do
        curl -s -o /dev/null --max-time 2 http://127.0.0.1:8890/ && break
        sleep 1
    done
    echo ">>> Assistant deaktiviert. Ollama bleibt installiert (ausschalten: systemctl disable --now ollama)."
    echo ">>> FERTIG"
    exit 0
fi

echo ">>> [1/5] Ollama prüfen/installieren ..."
if ! command -v zstd >/dev/null 2>&1; then
    echo "    zstd fehlt (Live-Fund: install.sh braucht es zum Entpacken) – installiere ..."
    apt-get update -qq
    apt-get install -y -qq zstd >/dev/null
fi
if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL --retry 3 https://ollama.com/install.sh | sh
else
    echo "    Ollama vorhanden: $(ollama --version 2>/dev/null | head -1)"
fi

echo ">>> [2/5] Ollama-Service (Modelle unter /opt/lastbook/ollama) ..."
mkdir -p "${OLLAMA_DIR}"
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/lastbook.conf <<'DROPIN'
[Service]
Environment="OLLAMA_MODELS=/opt/lastbook/ollama"
DROPIN
if id ollama >/dev/null 2>&1; then
    chown -R ollama:ollama "${OLLAMA_DIR}" || true
fi
systemctl daemon-reload
systemctl enable --now ollama >/dev/null 2>&1 || systemctl restart ollama

echo ">>> [3/5] Warte auf Ollama-API (127.0.0.1:11434) ..."
API_OK=""
for _ in $(seq 1 90); do
    if curl -s -o /dev/null --max-time 2 http://127.0.0.1:11434/api/version; then
        API_OK=1
        break
    fi
    sleep 1
done
if [ -z "$API_OK" ]; then
    err "Ollama-API nicht erreichbar."
    journalctl -u ollama --no-pager 2>/dev/null | tail -n 15 || true
    die "Ollama lauscht nicht auf 11434 (Trace oben).\n  Debug: pct exec \$(pct list | awk '/lastbook/{print \$1}') -- journalctl -u ollama -e"
fi

echo ">>> [4/5] Modell ${ASSIST_MODEL} laden (skip, wenn schon da) ..."
if ollama list 2>/dev/null | grep -q "^${ASSIST_MODEL}[[:space:]]"; then
    echo "    Modell bereits vorhanden."
else
    if ! ollama pull "${ASSIST_MODEL}"; then
        echo "    pull fehlgeschlagen – ein Retry ..."
        ollama pull "${ASSIST_MODEL}"
    fi
fi

echo ">>> [5/5] Lastbook verbinden (SURVIVAL_MODEL_BASE) + Neustart ..."
env_set_model "SURVIVAL_MODEL_BASE=http://127.0.0.1:11434"
systemctl restart lastbook
for _ in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 http://127.0.0.1:8890/ && break
    sleep 1
done
curl -s -o /dev/null --max-time 5 http://127.0.0.1:8890/ || die "Lastbook nach Neustart nicht erreichbar – journalctl -u lastbook -e"
MODELS_JSON="$(curl -s --max-time 10 http://127.0.0.1:11434/v1/models || true)"
echo "$MODELS_JSON" | grep -q '"id"' || die "Ollama /v1/models antwortet ohne Modelle (JSON oben).\n  Debug: pct exec \$(pct list | awk '/lastbook/{print \$1}') -- ollama list"
echo "    /v1/models: $(echo "$MODELS_JSON" | head -c 120) ..."
echo ">>> Assistant aktiv: ${ASSIST_MODEL} auf http://127.0.0.1:11434"
echo ">>> FERTIG"
ASSEOF
}

run_setup_assistant() {
    local ct_id="$1"
    local model="${ASSISTANT_MODEL:-}"
    if [[ -z "$model" ]]; then
        # RAM-abhängige Modellwahl: 0.6b (~0,7 GB) passt zu 2 GB, 1.7b braucht mehr
        if [[ "$CT_MEMORY" -ge 3500 ]]; then
            model="qwen3:1.7b"
        else
            model="qwen3:0.6b"
        fi
    fi
    header "💬 Aktiviere Assistant (Ollama im CT, Modell: ${model})"
    if [[ "$CT_MEMORY" -lt 2048 ]]; then
        warn "Nur ${CT_MEMORY} MB RAM – qwen3:0.6b läuft, aber knapp (--memory 4096 empfohlen)."
    fi
    write_setup_assistant_script
    pct push "$ct_id" "$TMP_DIR/setup-assistant.sh" /opt/lastbook/setup-assistant.sh
    pct exec "$ct_id" -- chmod +x /opt/lastbook/setup-assistant.sh
    pct exec "$ct_id" -- env ASSIST_MODEL="$model" APP_DIR="$C_APP_DIR" \
        OLLAMA_DIR="$C_OLLAMA_DIR" ASSIST_REMOVE="0" \
        bash -c 'set -o pipefail; bash /opt/lastbook/setup-assistant.sh 2>&1 | tee /var/log/lastbook-assistant.log'
    MODEL_BASE="http://127.0.0.1:11434"
}

run_assistant_remove() {
    local ct_id="$1"
    header "💬 Deaktiviere Assistant (Verkabelung lösen)"
    write_setup_assistant_script
    pct push "$ct_id" "$TMP_DIR/setup-assistant.sh" /opt/lastbook/setup-assistant.sh
    pct exec "$ct_id" -- env ASSIST_MODEL="x" APP_DIR="$C_APP_DIR" \
        OLLAMA_DIR="$C_OLLAMA_DIR" ASSIST_REMOVE="1" \
        bash -c 'set -o pipefail; bash /opt/lastbook/setup-assistant.sh 2>&1 | tee /var/log/lastbook-assistant.log'
    MODEL_BASE=""
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet lastbook 2>/dev/null; then
            ok "Service lastbook läuft (Port $PORT)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service lastbook läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u lastbook -e"
        fi
        sleep 1
    done

    # Code vorhanden?
    if pct exec "$ct_id" -- test -f "${C_APP_DIR}/server.py" 2>/dev/null; then
        ok "App-Code vorhanden (${C_APP_DIR}/server.py)"
    else
        die "server.py fehlt im Container.\n  Debug: pct exec $ct_id -- tail -n 50 /var/log/lastbook-setup.log"
    fi

    # Web-UI im Loopback antwortet? (GET / ist direkt 200 – kein Redirect)
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI antwortet im Container (HTTP 200 auf http://127.0.0.1:${PORT}/)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            local diag
            # shellcheck disable=SC2016  # Absicht: PORT kommt via env in den CT
            diag=$(pct exec "$ct_id" -- env PORT="$PORT" sh -c '
                echo "--- Listener (ss -tlnp) ---"
                ss -tlnp 2>/dev/null | grep -- "${PORT}" || echo "  (KEIN Listener – Service läuft mit falschem Port?)"
                echo "--- journalctl -u lastbook (letzte Zeilen) ---"
                journalctl -u lastbook --no-pager 2>/dev/null | tail -n 12 || true
            ' 2>/dev/null || true)
            die "Web-UI antwortet nicht im Container (letzter HTTP-Code: ${code:-unbekannt}).

${diag}"
        fi
        sleep 1
    done

    # Bibliotheksstatus melden
    local has_lib=""
    has_lib=$(pct exec "$ct_id" -- sh -c "[ -s ${C_DATA_LIB}/library-data/catalog.json ] && [ \$(wc -c < ${C_DATA_LIB}/library-data/catalog.json) -gt 10 ] && echo ja || echo nein" 2>/dev/null | tail -n 1 || true)
    if [[ "$has_lib" == "ja" ]]; then
        local records=""
        records=$(pct exec "$ct_id" -- ${C_APP_DIR}/venv/bin/python -I -c \
            "import json; print(len(json.load(open('${C_DATA_LIB}/library-data/catalog.json'))))" 2>/dev/null | tail -n 1 || true)
        ok "Bibliothek installiert (${records:-?} Einträge im Katalog)"
    else
        warn "Bibliothek NOCH NICHT installiert (Stub-Modus) – Setup-Befehl steht in der Zusammenfassung."
    fi

    # Vom PROXMOX-HOST aus (Nutzer-URL): mit Key – ohne Key antwortet der
    # Server absichtlich 403. ?key= → 302 auf / + Cookie → -L folgt → 200.
    local ct_ip="" host_code="" lan_key=""
    ct_ip=$(get_ct_ip "$ct_id")
    lan_key=$(get_active_lan_key "$ct_id")
    if [[ -n "$ct_ip" && -n "$lan_key" ]]; then
        host_code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 8 \
                    "http://${ct_ip}:${PORT}/?key=${lan_key}" || true)
        if [[ "$host_code" == "200" ]]; then
            ok "Vom Host erreichbar MIT Key: http://${ct_ip}:${PORT}/?key=…  (HTTP 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "📚  LastBook ist bereit!"

    local ct_ip lan_key has_lib=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi
    lan_key=$(get_active_lan_key "$CT_ID")
    has_lib=$(pct exec "$CT_ID" -- sh -c "[ -s ${C_DATA_LIB}/library-data/catalog.json ] && [ \$(wc -c < ${C_DATA_LIB}/library-data/catalog.json) -gt 10 ] && echo ja || echo nein" 2>/dev/null | tail -n 1 || true)

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  📚 LastBook:  http://${ct_ip}:${PORT}/?key=${lan_key}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Zugang:${NC} Link EINMAL öffnen (der ?key=-Teil ist der Zugangs-Schlüssel;"
    echo "  danach setzt der Browser einen Cookie für 1 Jahr – Geräte im Heimnetz genügt"
    echo "  der Link ohne Key nie, Absicht des Upstream-Schutzes). Key ändern:"
    echo "  pct exec ${CT_ID} -- rm ${C_DATA_LIB}/derived/lan-key ${C_DATA_STUB}/derived/lan-key && pct exec ${CT_ID} -- systemctl restart lastbook"
    echo ""
    if [[ "$has_lib" == "ja" ]]; then
        if [[ -n "$MODEL_BASE" ]]; then
            echo -e "  ${GREEN}  💬 Assistant: aktiv (SURVIVAL_MODEL_BASE=${MODEL_BASE})${NC}"
        fi
        echo -e "  ${CYAN}Inhalt:${NC} Handbücher/Enzyklopädien/Videos/Offline-Karten (Pack: ${PACK}${MAP:+ + Karte ${MAP}})."
    else
        echo -e "  ${YELLOW}Bibliothek später nachziehen (SKIP_LIBRARY war gesetzt):${NC}"
        echo "    pct exec ${CT_ID} -- env PACK=${PACK}${MAP:+ MAP=${MAP}} APP_DIR=${C_APP_DIR} DATA_STUB=${C_DATA_STUB} DATA_LIB=${C_DATA_LIB} PORT=${PORT} bash /opt/lastbook/setup-library.sh"
        echo ""
    fi
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Logs:      pct exec ${CT_ID} -- journalctl -u lastbook -e"
    echo ""
    if [[ -z "$MODEL_BASE" ]]; then
        warn "Der „Ask“-Tab (Assistant) ist AUS – nativ aktivieren mit:"
        warn "  ${ONE_LINER} --update --assistant"
        warn "  (installiert Ollama im CT + kleines Modell; Suche/Lesen/Videos/Karten laufen ohne ihn voll.)"
    fi
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "📚 Installiere LastBook (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"
    info "Pack: ${PACK}${MAP:+ + Karte ${MAP}} | Ziel-Port: ${PORT}"
    INNER_REF="$UPSTREAM_REF_PIN"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Pack/Disk-Sanity: Warnung (kein Abbruch) bei klar zu kleiner Disk
    local min_gb=0
    case "$PACK" in
        small)  min_gb=24 ;;
        medium) min_gb=150 ;;
        all)    min_gb=820 ;;
    esac
    if [[ "$CT_ROOTFS" -lt "$min_gb" ]]; then
        warn "rootfs ${CT_ROOTFS} GB ist knapp für Pack '${PACK}' (empfohlen ≥ ${min_gb} GB)."
        warn "Bei 'no_space' im Setup: ${ONE_LINER} --force --rootfs ${min_gb} --pack ${PACK}"
    fi
    if $ASSISTANT && [[ "$CT_ROOTFS" -lt "$((min_gb + 4))" ]]; then
        warn "--assistant braucht ~2-4 GB zusätzlich (Ollama + Modell) – rootfs ${CT_ROOTFS} GB ist knapp."
        warn "Empfehlung: ${ONE_LINER} --force --rootfs $((min_gb + 8)) --pack ${PACK} --assistant"
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen:  ${ONE_LINER} --force\n  Status:  ${ONE_LINER} --status"
        fi
    fi

    # Debian-Template sicherstellen (Debian 13 bevorzugt – libzim-Wheel braucht
    # frisches Python; grep debian-1[23] + sort -rV wählt 13 vor 12).
    # ARCH-BEWUSST (Live-Fund CT 207): im Cache können amd64 UND arm64 liegen –
    # sort -rV würde _arm64 vor _amd64 wählen und ein arm64-Rootfs startet auf
    # amd64-Hosts nicht (sync_wait: Failed to spawn). Filter auf die Host-Arch.
    header "🧱 Container-Template"
    local host_arch=""
    host_arch=$(dpkg --print-architecture 2>/dev/null || uname -m || true)
    case "$host_arch" in
        x86_64|amd64)   host_arch="amd64" ;;
        aarch64|arm64)  host_arch="arm64" ;;
        *) die "Nicht unterstützte Host-Architektur: '${host_arch}' (amd64/arm64 erwartet)" ;;
    esac
    info "Host-Architektur: ${host_arch}"
    local template=""
    template=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -o "debian-1[23]-standard[^ ]*_${host_arch}\.tar\.zst" | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein Debian-12/13-${host_arch}-Template vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null | grep -o "debian-1[23]-standard[^ ]*_${host_arch}\.tar\.zst" | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-12/13-standard_${host_arch}-Template gefunden (pveam available leer oder ohne diese Architektur?)."
        fi
        pveam download local "$template"
    fi
    ok "Template: $template (arch ${host_arch})"

    # ID & Passwort & LAN-Key
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="lb-$(date +%s)"
        fi
    fi
    # LAN-Key wie upstream secrets.token_urlsafe(18): 24 Zeichen URL-safe.
    LAN_KEY=$(openssl rand -base64 18 2>/dev/null | tr '+/' '-_' | tr -d '=\n' || true)
    if [[ -z "$LAN_KEY" ]]; then
        LAN_KEY="lb$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 24)"
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            curl -fsSL --retry 3 -o "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    ok "Container $CT_ID erstellt"
    # pct create --start 1 meldet gescheiterten Spawn NICHT über den Exit-Code
    # (sync_wait-Fehler nur auf stderr) – Status aktiv verifizieren.
    local start_ok="" i
    for i in $(seq 1 15); do
        if [[ "$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
            start_ok=1
            break
        fi
        sleep 1
    done
    if [[ -z "$start_ok" ]]; then
        die "Container $CT_ID startet nicht (pct create --start lief trotzdem Exit 0).

  Häufigste Ursache: Template-Architektur passt nicht zum Host.
  Prüfe: pct config $CT_ID | grep arch && dpkg --print-architecture
  Aufräumen: pct destroy $CT_ID --purge
  Neu:  ${ONE_LINER} --force"
    fi
    ok "Container läuft"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    # App + Server (Stub-Phase)
    run_inner_setup "$CT_ID"

    # Bibliothek (headless über offizielle Setup-API)
    if $SKIP_LIBRARY; then
        write_setup_library_script
        pct push "$CT_ID" "$TMP_DIR/setup-library.sh" /opt/lastbook/setup-library.sh
        pct exec "$CT_ID" -- chmod +x /opt/lastbook/setup-library.sh
        warn "SKIP_LIBRARY gesetzt – Bibliothek wird NICHT geladen (Befehl in der Zusammenfassung)."
    else
        run_setup_library "$CT_ID"
    fi

    # Assistant nativ (--assistant: Ollama im CT installieren + verkabeln)
    if $ASSISTANT; then
        run_setup_assistant "$CT_ID"
    fi

    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update LastBook (neuer Upstream-Stand, Bibliothek bleibt)"

    local ct_id
    ct_id=$(resolve_ct_id || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME'${CT_ID:+ (oder --id $CT_ID)} gefunden.\n  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    # --update holt UPSTREAM_BRANCH (main); Installation selbst bleibt gepinnt.
    TAR_URL="https://codeload.github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/tar.gz/refs/heads/${UPSTREAM_BRANCH}"
    INNER_REF="main@$(date +%Y%m%d)"
    # --model-base: explizit gewinnt, sonst bestehenden Wert aus dem CT behalten
    if ! $MODEL_BASE_SET; then
        MODEL_BASE=$(pct exec "$ct_id" -- sh -c "grep -s '^SURVIVAL_MODEL_BASE=' ${C_APP_DIR}/lastbook.env" 2>/dev/null | cut -d= -f2- | tail -n 1 || true)
        MODEL_BASE="${MODEL_BASE%$'\r'}"
    fi
    # LAN-Key vom CT ÜBERNEHMEN (stabil über Updates), sonst neu generieren
    LAN_KEY=$(get_active_lan_key "$ct_id")
    if [[ -z "$LAN_KEY" ]]; then
        warn "Kein LAN-Key im CT gefunden – generiere neuen."
        LAN_KEY=$(openssl rand -base64 18 2>/dev/null | tr '+/' '-_' | tr -d '=\n' || true)
    fi

    run_inner_setup "$ct_id"

    # Bibliothek mitziehen: idempotent (gleiches Pack = Skip). Mit --pack medium/all
    # wird hier das Pack-In-Place-Upgrade von upstream gefahren.
    if $SKIP_LIBRARY; then
        warn "SKIP_LIBRARY gesetzt – Bibliotheks-Update übersprungen."
    else
        run_setup_library "$ct_id"
    fi

    # Assistant nativ mitziehen (--assistant installiert Ollama, --assistant-remove löst)
    if $ASSISTANT_REMOVE; then
        run_assistant_remove "$ct_id"
    elif $ASSISTANT; then
        run_setup_assistant "$ct_id"
    fi

    verify_installation "$ct_id"

    ok "Update abgeschlossen – Bibliothek/Datenordner blieben unberührt."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere LastBook"

    local ct_id
    ct_id=$(resolve_ct_id || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME'${CT_ID:+ (oder --id $CT_ID)} gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "Die heruntergeladene Bibliothek (bis zu ${PACK}-Größe) lebt nur im CT und wird"
    warn "beim nächsten Install neu geladen. Es gibt keine externe Kopie."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status LastBook"
    info "Installer-Version: v${INSTALLER_VERSION}"

    local ct_id
    ct_id=$(resolve_ct_id || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME'${CT_ID:+ (oder --id $CT_ID)} gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ")"}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet lastbook 2>/dev/null; then
        ok "Service:   lastbook läuft (Port $PORT)"
    else
        err "Service:   lastbook läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u lastbook -e"
    fi

    # Assistant-Status aus der Service-Umgebung (lastbook.env)
    local mb=""
    mb=$(pct exec "$ct_id" -- sh -c "grep -s '^SURVIVAL_MODEL_BASE=' ${C_APP_DIR}/lastbook.env" 2>/dev/null | cut -d= -f2- | tail -n 1 || true)
    if [[ -n "$mb" ]]; then
        ok "Assistant: aktiv (SURVIVAL_MODEL_BASE=${mb})"
    else
        info "Assistant: aus  →  ${ONE_LINER} --update --assistant"
    fi

    # Upstream-Stand (ref aus INSTALL-INFO)
    local ref=""
    ref=$(pct exec "$ct_id" -- cat ${C_APP_DIR}/INSTALL-INFO 2>/dev/null | grep '^ref=' | cut -d= -f2 || true)
    if [[ -n "$ref" ]]; then
        info "Upstream:  ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${ref:0:8}"
    fi

    local has_lib="" records=""
    has_lib=$(pct exec "$ct_id" -- sh -c "[ -s ${C_DATA_LIB}/library-data/catalog.json ] && [ \$(wc -c < ${C_DATA_LIB}/library-data/catalog.json) -gt 10 ] && echo ja || echo nein" 2>/dev/null | tail -n 1 || true)
    if [[ "$has_lib" == "ja" ]]; then
        records=$(pct exec "$ct_id" -- ${C_APP_DIR}/venv/bin/python -I -c \
            "import json; print(len(json.load(open('${C_DATA_LIB}/library-data/catalog.json'))))" 2>/dev/null | tail -n 1 || true)
        ok "Bibliothek: installiert (${records:-?} Einträge)"
    else
        warn "Bibliothek: NICHT installiert (Stub-Modus)"
    fi

    local ip code="" lan_key=""
    ip=$(get_ct_ip "$ct_id")
    lan_key=$(get_active_lan_key "$ct_id")
    if [[ -n "$ip" ]]; then
        if [[ -n "$lan_key" ]]; then
            code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${PORT}/?key=${lan_key}" || true)
            if [[ "$code" == "200" ]]; then
                ok "Web-UI:    http://${ip}:${PORT}/?key=${lan_key}  (HTTP 200)"
            else
                warn "Web-UI:    HTTP-Code ${code:-unbekannt} von http://${ip}:${PORT}/?key=…"
            fi
        else
            warn "Web-UI:    kein LAN-Key gefunden (${lan_key:-leer})"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TAR_URL="https://codeload.github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/tar.gz/${UPSTREAM_REF_PIN}"
LAN_KEY=""

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi
