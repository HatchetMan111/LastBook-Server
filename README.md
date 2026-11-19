# 📚 LastBook-Server

**Lastbook als One-Click-LXC für Proxmox VE** – im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

Lastbook ([Immortal-Protocols/lastbook](https://github.com/Immortal-Protocols/lastbook), MIT, 2,3 k ★) ist eine **lokale Offline-Survival-Bibliothek**: Handbücher, Enzyklopädien, Videos, Offline-Karten (gesamte US-Staaten) und ein Chat, der Antworten **mit Quellenverweisen** aus der Bibliothek gibt. Nach dem Setup läuft alles vollständig offline.

Deployt wird der **Bibliotheksserver-Modus** (`server.py --lan`, Port **8890**): eine Weboberfläche für alle Geräte im Heimnetz – PC, Handy, Tablet.

---

## ⚡ Installation (Einzeiler auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LastBook-Server/main/install/lastbook.sh)"
```

Am Ende der Installation erscheint der **Zugangs-Link mit Key**:

```
════════════════════════════════════════════════════════════════════
  📚 LastBook:  http://<CT-IP>:8890/?key=<KEY>
════════════════════════════════════════════════════════════════════
```

**Der `?key=`-Teil ist der Zugangsschlüssel** (upstream-Schutz: ohne Key antwortet der Server im LAN mit 403). Link einmal öffnen genügt – der Browser setzt einen Cookie für 1 Jahr. Jede Zeile im Terminal/Log wird mitgeschrieben (`/tmp/lastbook-installer-*.log`).

### Optionen (hinter dem schließenden Anführungszeichen anhängen)

```bash
... " --pack medium --rootfs 160          # größere Bibliothek
... " --map TX                            # Karte Texas dazuladen
... " --id 210 --port 8890 --ip 192.168.1.50/24 --gateway 192.168.1.1
... " --skip-library                      # erstmal nur den Server
```

| Option | Default | Bedeutung |
|---|---|---|
| `--pack NAME` | `small` | Bibliothekspack: **small** (~7,7 GB, 315 Einträge), **medium** (~67 GB, 9 696), **all** (~388 GB, 12 864) |
| `--model-base URL` | – | Assistant an eigenen Modellserver binden (nur loopback) |
| `--assistant` | aus | 💬 Assistant **nativ** aktivieren: Ollama im CT installieren + Modell (nach RAM 0.6b/1.7b) + verkabeln |
| `--assistant-model NAME` | – | Modell wählen (impliziert `--assistant`) |
| `--assistant-remove` | – | Assistant-Verkabelung lösen (Ollama bleibt) |
| `--map ST` | – | US-Bundesstaat-Karte dazuladen, z. B. `TX` (2–9 GB je Staat) |
| `--rootfs GB` | `32` | Disk. Empfehlung: small ≥ 32, medium ≥ 160, all ≥ 840 |
| `--memory MB` | `2048` | RAM – Suche/Lesen/Karten brauchen mehr nicht |
| `--port PORT` | `8890` | Server-Port |
| `--skip-library` | aus | Nur Server installieren, Bibliothek später laden (Befehl erscheint am Ende) |
| `--id / --hostname / --storage / --cores / --bridge / --ip / --gateway / --password / --sshkey` | – | wie bei jedem Community-Script |
| `--force / --yes` | – | vorhandenen CT neu aufsetzen / Rückfragen überspringen |

## 🔄 Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LastBook-Server/main/install/lastbook.sh)" --update
```

Aktualisiert die App auf den aktuellen upstream-`main`-Stand; **Bibliothek und Daten bleiben unberührt**. Mit `--update --pack medium` wird zugleich das Pack-In-Place-Upgrade gefahren (upstream behält die alte Bibliothek als `LastbookData.old-<Datum>`, Karten/Einstellungen wandern mit).

## 📊 Status / 🗑️ Deinstall

```bash
... " --status        # inkl. aktuellem Zugangslink mit Key
... " --uninstall     # CT stoppen + löschen (Bibliothek lebt nur im CT!)
```

## 🏗️ Was der Installer macht

1. Unprivilegierter LXC (Debian 13, `nesting=1`, `onboot=1`, nächste freie ID ab 200), Hostname `lastbook`
2. Python 3.13 + venv mit den offiziellen Linux-Abhängigkeiten aus `packaging/linux/requirements_linux.txt` (libzim, numpy, beautifulsoup4, pypdfium2) – **kein** poppler/ffmpeg/Node/Docker nötig
3. Upstream-Code (gepinnter Commit `9e57ba2`, Updates via `main`) nach `/opt/lastbook/app`
4. **Headless-Bibliotheks-Setup über die offizielle Setup-API** (`/api/setup/state → start → job → finish`): Download von `downloads.lastbook.org` mit SHA-256-Prüfung, Fortschrittsanzeige im Terminal, Stall-Detektion (12 min), Resume nach Abbruch (`setup-library.sh` ist wiederaufrufbar), Switch per upstream `apply_pending` inkl. Rollback
5. systemd-Service `lastbook` (`Restart=always`, `After=network-online.target`), CT `onboot=1` → **reboot-sicher**

## 🔑 Access-Key

- Key liegt im CT: `/opt/lastbook/LastbookData/derived/lan-key` (bleibt über Updates/Reboots stabil)
- **Key ändern:** `pct exec <CT-ID> -- rm /opt/lastbook/LastbookData/derived/lan-key /opt/lastbook/data/derived/lan-key && pct exec <CT-ID> -- systemctl restart lastbook` (neuer Key erscheint beim nächsten `--status` und im Service-Log)
- Loopback-Zugriffe im CT brauchen keinen Key; die Setup-API akzeptiert ohnehin nur Loopback (upstream-Sicherheitsdesign)

## 🎬 Videos: „this video is saved in the av1 format"

Diese Meldung kommt vom **Browser des Clients**, nicht vom Server: die App prüft per
`canPlayType('video/mp4; codecs="av01.0.05M.08")`, ob dein Browser AV1 dekodieren kann
(`web/app.js`). Die Pack-Videos liegen in gemischten Codecs (h264/av1/vp9).

**Fix:** aktuellen Chrome/Chromium oder Firefox (>= 60, enthält dav1d-Softwaredecoder)
verwenden – Zorin/Firefox-ESR aktualisieren genügt in der Regel. Der Server muss dafür
nichts ändern. (Ein serverseitiges Transkodieren wäre ein Eingriff in die SHA-256-geprüfte
Bibliothek und würde den upstream-Repair-Pfad stören – bewusst nicht gebaut.)

## 🗺️ Karte: Deutschland/Europa

Die Detailkarten von Lastbook sind **nur für die USA** verfügbar: die State-Maps basieren
auf US-ZCTA-Zentroiden und USGS/NAIP-Quellen (`derived/packs/pack-spec.json`, alle
`address_indexes` sind US-Staaten). Die **Base-Map** (im small-Pack enthalten) ist eine
Welt-Übersicht ohne Straßendetail. Deutschland-/Europa-Daten gibt es upstream nicht –
weder zum Nachladen noch als Pack. Optionen: upstream-Issue/Contribution (die
`build_packs.py`-Pipeline auf OSM-Extract für DE erweitern) oder Base-Map akzeptieren.

## 💬 Chat / „Ask"-Tab (lokale KI)

Der Assistant ist **standardmäßig aus** – er braucht einen OpenAI-kompatiblen Modellserver
`IM CONTAINER` und **nur Loopback-Adressen** (`assistant.py`: `/v1/chat/completions`,
`/v1/models`, Host muss 127.0.0.1/localhost/[::1] sein).

### Assistant nativ aktivieren (Einzeiler)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LastBook-Server/main/install/lastbook.sh)" --update --assistant
```

Das installiert **im CT** den kompletten Stack (idempotent, wiederholbar):
1. Ollama (offizielles Install-Script, falls fehlend), Modelle unter `/opt/lastbook/ollama`
2. Service `ollama` auf **127.0.0.1:11434** (loopback – upstream-Pflicht, `assistant.py`)
3. Modell nach RAM: `< 3,5 GB → qwen3:0.6b` (~700 MB), sonst `qwen3:1.7b` – Skip, wenn schon da
4. `SURVIVAL_MODEL_BASE` in die Lastbook-Service-Umgebung + Neustart + Verifikation über `/v1/models`

Danach antwortet der „Ask"-Tab mit Quellenverweisen aus der Bibliothek. Varianten:

```bash
... " --update --assistant --assistant-model qwen3:1.7b   # Modell explizit (impliziert --assistant)
... " --update --assistant-remove                          # Verkabelung lösen (Ollama bleibt installiert)
... " --update --model-base http://127.0.0.1:1234          # eigener OpenAI-kompatibler Server (nur loopback)
```

Status zeigt den Assistant-Zustand: `... " --status` → `Assistant: aktiv (SURVIVAL_MODEL_BASE=…)`.

RAM-Hinweis: mit 2 GB läuft `qwen3:0.6b` knapp aber stabil; für `1.7b` das CT mit
`--memory 4096` (neu) aufsetzen. Das offizielle upstream-AI-Pack (Gemma-4-26B, ~17 GB,
~19 GB RAM) ist für dieses LXC zu groß – dafür wäre eine VM der richtige Ort.
Manuelles Setup ohne Installer-Flag: README-Historie bzw. `pct exec` mit
`curl -fsSL https://ollama.com/install.sh | sh` + `ollama pull` + `--model-base`.

## 🛠️ Troubleshooting

| Symptom | Ursache / Fix |
|---|---|
| `HTTP 403` beim Öffnen ohne Key | Absicht – Link mit `?key=` nutzen (steht in `--status`) |
| `no_space` im Setup-Job | Disk zu klein fürs Pack → `--force --rootfs 160 --pack medium` (Bedarf steht in der Fehlermeldung: ~`need_bytes`) |
| `That library is not available yet` | Pack-ID falsch (nur `small`/`medium`/`all`) oder Downloads-Server nicht erreichbar |
| `Keine Packs im Manifest` | DNS/Internet im CT tot → Installer schreibt automatisch Fallback-Resolver; danach `setup-library.sh` erneut laufen lassen (siehe unten) |
| Download abgebrochen (Netz, Strg-C) | **Resume:** Befehl aus der Zusammenfassung erneut ausführen – der Job setzt mit HTTP-Range fort |
| Service tot | `pct exec <CT-ID> -- journalctl -u lastbook -e` |
| Kompletter Re-Run mit Trace | Einzeiler + ` --debug` |

**Bibliothek manuell (nach)laden** – im Proxmox-Host:

```bash
pct exec <CT-ID> -- env PACK=small APP_DIR=/opt/lastbook/app DATA_STUB=/opt/lastbook/data \
  DATA_LIB=/opt/lastbook/LastbookData PORT=8890 bash /opt/lastbook/setup-library.sh
```

## 📁 Layout im CT

```
/opt/lastbook/app            Upstream-Code (server.py, engine/, web/)
/opt/lastbook/app/venv      Python-Umgebung (libzim/numpy/bs4/pypdfium2)
/opt/lastbook/data           Stub-Datenordner (Startbrücke, danach ungenutzt)
/opt/lastbook/LastbookData   ECHTE Bibliothek (library-data/ + derived/) – die Daten
/opt/lastbook/app/serve.sh  Starter: wählt aktiven Datenordner
/opt/lastbook/setup-library.sh Headless-Setup (idempotent, resume-fähig)
/etc/systemd/system/lastbook.service
/var/log/lastbook-setup.log, /var/log/lastbook-setup-library.log
```

## ⚖️ Lizenz / Quellen

- Installer & Doku: wie das Repo (MIT-Politik des Betreibers)
- Lastbook: [MIT](https://github.com/Immortal-Protocols/lastbook) – Bibliotheksinhalte und Drittkomponenten (u. a. GPL-Komponente libzim) unter eigenen Bedingungen, siehe [THIRD_PARTY_NOTICES](https://github.com/Immortal-Protocols/lastbook/blob/main/THIRD_PARTY_NOTICES.md)
