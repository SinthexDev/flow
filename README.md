# Sinthex Flow

Diktat für die Menüleiste auf dem Mac. Die Sprache bleibt auf dem Gerät. Eine Korrektur über OpenAI ist optional und nutzt den eigenen Schlüssel.

**Autor: Sinthex**

Quelltext: <https://github.com/beeXperts-Niko/flow>  
Projektseite: <https://sinthex.de/flow/>

![Startseite von Sinthex Flow](docs/screenshots/main-home.png)

## Was Sinthex Flow tut

- Aufnahme über die Fn-Taste, Doppeltipp für freies Sprechen, Esc bricht ab.
- Erkennung mit Whisper lokal auf Apple Silicon. Audio verlässt den Mac dafür nicht.
- Optional Korrektur mit dem eigenen OpenAI-Schlüssel. Der Schlüssel liegt im Schlüsselbund, nicht in einer Konfigurationsdatei und nicht in diesem Repository. In den Einstellungen kann statt OpenAI eine andere OpenAI-kompatible Adresse stehen, auch ein lokales Modell. Der Schlüssel bleibt optional und im Schlüsselbund.
- Das Korrekturmodell wird über den Schlüssel ermittelt. Sinthex Flow empfiehlt das neueste schnelle Modell, ein anderes lässt sich fest einstellen.
- Der Stil richtet sich nach dem vorderen Programm, zum Beispiel Coding in einer Entwicklungsumgebung und E-Mail in Mail. Pro Programm lässt sich der Stil ändern.
- Der Text wird in das aktive Feld eingesetzt.
- Befehlsmodus: Text markieren, Fn halten, den Auftrag sagen. „Übersetz das ins Englische“, „Fass das in einem Satz zusammen“, „Mach das freundlicher“, „Mach daraus eine Stichpunktliste“. Sinthex Flow ersetzt die Markierung durch das Ergebnis. Der Tab „Befehle“ in der App zeigt neun Beispiele.

Sinthex Flow ist eine Menüleisten-App für macOS 14 oder neuer, auf Apple Silicon.

Die Oberfläche folgt der ersten Systemsprache. Die Amtssprachen Europas liegen als `Languages/<code>.json` bei, dazu regionale Amtssprachen wie Katalanisch, Baskisch, Gälisch und Rätoromanisch. Die Schlüssel stehen in `en.json`. Fehlt eine Sprache, bleibt Deutsch bei Deutsch und jede andere Sprache wird Englisch. Eine Datei im Ordner `~/Library/Application Support/Sinthex Flow/Languages` ergänzt oder überschreibt dieselbe Sprache und wird beim nächsten Start gelesen. Fehlende Schlüssel fallen auf Englisch zurück.

## Lizenz

Sinthex Flow steht unter der [MIT-Lizenz](LICENSE).

Copyright (c) 2026 Sinthex.

Das bedeutet: Du darfst Sinthex Flow nutzen, verändern und weitergeben, auch in eigenen Produkten. Bedingung ist, dass der Copyright-Hinweis und der Lizenztext erhalten bleiben. Es gibt keine Gewährleistung. Der vollständige Text steht in [LICENSE](LICENSE).

Sinthex Flow baut auf anderen Open-Source-Projekten auf, vor allem mlx-whisper, MLX, mlx-vlm und den Whisper-Modellgewichten von OpenAI. Deren Lizenzen gelten zusätzlich und sind in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) abgedruckt.

## Privatsphäre

Es gehören keine API-Schlüssel, Zertifikate, PKCS#12-Dateien oder Diktate in dieses Repository. Der OpenAI-Schlüssel bleibt im macOS-Schlüsselbund (`de.sinthex.flow` / `openai-api-key`). Konfiguration und Verlauf liegen lokal unter `~/Library/Application Support/Sinthex Flow/` und sind von Git ausgeschlossen.

## Bauen

Voraussetzungen: macOS 14, Apple Silicon, Xcode-Kommandozeilenwerkzeuge, [uv](https://docs.astral.sh/uv/) und Python 3.12.

```bash
./scripts/install.sh
```

Das Skript legt eine virtuelle Umgebung unter `~/Library/Application Support/Sinthex Flow/.venv` an, installiert die Engine, lädt die Whisper-Gewichte und baut `Sinthex Flow.app`.

Die lokale Codesign-Identität bleibt über Updates stabil, damit Mikrofon- und Bedienungshilfe-Freigaben nicht jedes Mal neu verlangt werden. Das Passwort für das lokale Zertifikat liegt außerhalb des Repositorys, in `~/Library/Application Support/Sinthex Flow/signing/password` oder in der Umgebungsvariable `FLOW_SIGNING_PASSWORD`.

Die Engine allein:

```bash
uv pip install --python ~/Library/Application\ Support/Sinthex\ Flow/.venv/bin/python ./engine
```

Sie hört auf `127.0.0.1:17321`.
