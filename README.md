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
- Tages-Timeline: Stundenraster ab Arbeitsbeginn, gearbeitete Segmente
  (laufender Eintrag live), Soll-Marke (Soll netto + Pause), Jetzt-Marke,
  Anteil über Soll in Warnfarbe; Textzeile mit gearbeitet/Soll/noch bzw. über
- Soll/Ist-Balken pro Tag, Summen für Heute/Woche/Monat
- Wochen-/Monatstrennlinien in der Liste; Homeoffice-Wochentage setzen die
  Beschreibung automatisch
- Überstunden Woche/Monat/Jahr (Ist − Werktage-bis-heute × Tages-Soll,
  Urlaubstage senken das Soll) und Urlaubskonto (genommen/übrig)

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
| `weeklyHours` | `35` | Wochenstunden (Soll); Tages-Soll = weeklyHours / workDays |
| `workDays` | `5` | Arbeitstage pro Woche |
| `vacationDays` | `25` | Urlaubstage pro Jahr |
| `baseDate` | *(leer)* | Stichtag `YYYY-MM-DD`: ab hier (inklusive) laufen Überstundenkonto und Rest-Urlaub von den Startwerten weiter — für Tracking-Start mitten im Jahr |
| `baseVacationLeft` | `-1` | Rest-Urlaub am Stichtag; `-1` = aus |
| `baseSurplusHours` | *(leer)* | Überstunden am Stichtag, `"11:46"` (h:mm) oder `"11.5"` (dezimal), auch negativ; leer = aus |
| `homeofficeDays` | *(leer)* | Wochentage, kommagetrennt (`Fr` oder `Mi,Fr`), an denen neue/laufende Einträge automatisch das Homeoffice-Thema als Beschreibung bekommen |
| `homeofficeTopic` | `homeoffice` | Beschreibungstext für Homeoffice-Tage (Beschreibungsspalte der CSV, Projekt bleibt unverändert) |
| `breakAfterHours` | `6` | Liegt die Brutto-Arbeitszeit eines Tages darüber, wird die Pause automatisch abgezogen (Balken, Summen, Überstunden); `0` = aus |
| `breakMinutes` | `30` | Länge der abgezogenen Pause |
| `vacationProject` | `urlaub` | Einträge dieses Projekts zählen nicht als Arbeitszeit, senken das Tages-Soll auf null und verbrauchen je Tag einen Urlaubstag |

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
