---
description: Sinthex Flow lokal bauen und die Dist-App starten
---

# startLocal

Baue die lokale Dist-App und starte sie. Nicht nach `/Applications` installieren und nicht deployen.

## Schritte

1. Im Repo-Root `./scripts/build_app.sh` ausführen.
2. Laufende Instanzen beenden, ohne die installierte App in `/Applications` anzufassen. **Nicht** auf `osascript … quit` warten (hängt oft). Stattdessen:
   ```bash
   killall "Sinthex Flow" 2>/dev/null || true
   pkill -f -- "--update-hud" 2>/dev/null || true
   pkill -f "$PWD/dist/Sinthex Flow.app/Contents/MacOS/Sinthex Flow" 2>/dev/null || true
   sleep 0.5
   ```
3. Dist starten mit neuer Instanz:
   ```bash
   open -n "dist/Sinthex Flow.app"
   ```
4. Kurz prüfen, dass ein Prozess `Sinthex Flow` ohne `--update-hud` läuft. Danach in ein bis zwei Sätzen melden: gebaut, gestartet, Version aus `packaging/Info.plist`.

Nicht committen, nicht pushen, kein Paket, keine Website.
