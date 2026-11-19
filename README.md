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

## 💬 Chat / „Ask"-Tab (lokale KI)

Die lokale KI (Gemma-4-26B-GGUF, ~17 GB Download, ~19 GB RAM zur Laufzeit) ist in diesem LXC **bewusst nicht installiert** – Suche, Lesen, Videos und Karten funktionieren vollständig ohne sie. Der „Ask"-Tab antwortet erst, wenn ein Modellserver vorhanden ist:

- externer Modellserver: `SURVIVAL_MODEL_BASE` auf `http://<loopback-IP>:19443` zeigen (upstream verlangt Loopback-Adresse), oder
- das AI-Pack später über die Setup-API (`ai: true`) installieren – dafür braucht der CT ~40 GB RAM, **das ist ein VM-Kandidat**, nicht dieses LXC.

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
