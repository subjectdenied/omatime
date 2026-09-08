# omatime

Zeiterfassungs-Widget für die Omarchy-Shell (Quickshell). Repliziert die
GNOME-App „Time Tracker" (com.lynnmichaelmartin.TimeTracker) und arbeitet
auf **derselben CSV** — beide Apps können parallel benutzt werden.

## Features

- Bar-Widget mit Live-Timer (`󱎫 2:34`), Mittelklick = Start/Stopp
- Panel: Live-Timer, klickbares Projekt-Label (Projektliste aus der
  gsettings-Konfiguration der GTK-App), quadratischer Start/Stopp-Button
- **WLAN-Vorschläge:** Anmeldezeiten im Büro-Netz werden aus dem
  NetworkManager-Journal gelesen und als Start/Ende neuer Einträge
  vorgeschlagen; bereits erfasste Zeiten werden markiert. Die SSID wird
  standardmäßig automatisch erkannt (aktuell verbundenes WLAN, via nmcli)
  und kann per Setting auf ein bestimmtes Netz gepinnt werden
- Manuelle Einträge über Kalender-Picker (Qt MonthGrid) und Zeit-Picker
  (15-min-Raster 06:00–24:00), Über-Nacht-Einträge möglich
- Einträge per Klick bearbeiten/löschen (Liste virtualisiert, volle Historie)
- Soll/Ist-Balken pro Tag (Soll-Stunden konfigurierbar), Summen für
  Heute/Woche/Monat

## Installation

```sh
git clone <repo-url> ~/.config/omarchy/plugins/chris.timetracker
omarchy plugin enable chris.timetracker
```

## Konfiguration

Im Widget-Eintrag in `~/.config/omarchy/shell.json`:

| Key | Default | Bedeutung |
|---|---|---|
| `csvPath` | `~/.local/share/time-tracker/log.csv` | Time-Tracker-CSV |
| `ssid` | *(leer)* | Büro-WLAN für Vorschläge; leer = aktuell verbundenes WLAN (Autodetect via nmcli) |
| `defaultProject` | `tafel österreich` | Projekt für neue Einträge |
| `roundMinutes` | `15` | Rundung der WLAN-Vorschläge |
| `targetHours` | `7` | Soll-Stunden pro Tag (Balken) |

## Datenformat

Byte-kompatibel zur GTK-App: GJS-`Date.toString()`-Datumsformat inkl.
deutschem Zonennamen, Datei ohne trailing newline. Vor dem ersten Schreiben
je Shell-Session wird `log.csv.omarchy-shell.bak` angelegt; Writes sind
atomar (temp + rename) und werden synchron abgeschlossen (`waitForJob`),
damit kein Datei-Watcher-Reload den Schreibjob abbricht.

## IPC

```sh
omarchy-shell chris.timetracker toggle|open|close|start|stop
```
