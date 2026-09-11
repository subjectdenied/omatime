import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "chris.timetracker"
  ipcTarget: "chris.timetracker"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // Same contract as the weather panel: the bar identifies this popup by the
  // widget mounted in its slot, not by this nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- settings ----
  readonly property string csvPath: {
    var p = setting("csvPath", "")
    return p !== "" ? p : Quickshell.env("HOME") + "/.local/share/time-tracker/log.csv"
  }
  // Netz-Listen: Büro-WLANs (Vorschläge) und Homeoffice-WLANs (Vorschläge
  // plus Homeoffice-Thema als Beschreibung). Das ältere Einzel-Setting
  // `ssid` zählt als weiteres Büro-Netz. Ist nichts konfiguriert, gilt das
  // gerade verbundene WLAN als Büro-Netz (nur Vorschläge, kein Thema).
  readonly property string configuredSsid: setting("ssid", "")
  property string detectedSsid: ""
  readonly property var officeNetworks: Model.parseNetworkList(setting("officeNetworks", ""))
    .concat(configuredSsid !== "" ? [configuredSsid] : [])
  readonly property var homeofficeNetworks: Model.parseNetworkList(setting("homeofficeNetworks", ""))
  readonly property var knownNetworks: officeNetworks.concat(homeofficeNetworks)
  readonly property var suggestionNetworks: knownNetworks.length > 0 ? knownNetworks
    : (detectedSsid !== "" ? [detectedSsid] : [])
  // "homeoffice" | "office" | "" für das aktuell verbundene WLAN.
  readonly property string currentKind: Model.networkKind(detectedSsid, officeNetworks, homeofficeNetworks)
  readonly property string defaultProject: setting("defaultProject", "tafel österreich")
  readonly property int roundMinutes: parseInt(setting("roundMinutes", 5), 10) || 0

  // Diagnose: Instanz-Tag (eine Panel-Instanz pro Monitor-Bar)
  readonly property string inst: Math.random().toString(36).slice(2, 6)

  // ---- state ----
  property var entries: []
  property var projects: []
  property string selectedProject: ""
  property var wifiSessions: []
  property bool logLoaded: false
  property bool backupDone: false
  property double nowTick: Date.now()

  readonly property var runningEntry: findRunning(entries)

  // Explizit statt als Binding gepflegt: nach jedem save()/reload wird die
  // Liste garantiert neu aufgebaut (Einträge sind plain JS-Objekte ohne
  // Change-Notification — Mutationen sieht ein Binding sonst nicht).
  property var recentEntries: []
  // Tagessummen (Sekunden) für die Soll/Ist-Balken in der Liste.
  property var dayTotals: ({})
  onEntriesChanged: {
    var listed = entries.filter(function(e) { return e.start })
    var totals = {}
    for (var i = 0; i < listed.length; i++) {
      var e = listed[i]
      if (!e.end || isVacation(e)) continue
      var k = e.start.toDateString()
      totals[k] = (totals[k] || 0) + (e.end.getTime() - e.start.getTime()) / 1000
    }
    dayTotals = totals
    listed.reverse() // neueste oben; ein laufender Eintrag steht damit ganz oben
    recentEntries = listed
  }

  // ---- Soll-Konfiguration ----
  readonly property real weeklyHours: parseFloat(setting("weeklyHours", 35)) || 35
  readonly property int workDays: Math.max(1, parseInt(setting("workDays", 5), 10) || 5)
  readonly property int vacationDays: parseInt(setting("vacationDays", 25), 10) || 0
  // ---- Stichtag mit Startwerten (Tracking-Start mitten im Jahr): ab
  // baseDate (inklusive) laufen Rest-Urlaub und Überstundenkonto von den
  // konfigurierten Werten weiter.
  readonly property var baseDate: {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(setting("baseDate", "")))
    return m ? new Date(parseInt(m[1], 10), parseInt(m[2], 10) - 1, parseInt(m[3], 10)) : null
  }
  readonly property int baseVacationLeft: parseInt(setting("baseVacationLeft", -1), 10)
  readonly property var baseSurplusSecs: Model.parseHours(setting("baseSurplusHours", ""))
  readonly property bool vacationOverride: baseDate !== null && baseVacationLeft >= 0
  readonly property bool surplusOverride: baseDate !== null && baseSurplusSecs !== null
  // Alles seit dem Stichtag: Ist, Soll, Urlaubstage (nur diese sind in den
  // Startwerten noch nicht enthalten).
  readonly property var baseStats: { nowTick; return baseDate ? periodStats(baseDate) : null }
  readonly property int vacationRemaining: vacationOverride
    ? Math.max(0, baseVacationLeft - baseStats.vacation)
    : Math.max(0, vacationDays - yearStats.vacation)
  readonly property real accountSurplus: surplusOverride ? baseSurplusSecs + baseStats.surplus : yearStats.surplus
  readonly property string vacationProject: String(setting("vacationProject", "urlaub")).toLowerCase()
  // Tages-Soll für die Balken und die Überstundenrechnung.
  readonly property real targetSecs: weeklyHours * 3600 / workDays

  function isVacation(e) { return String(e.project || "").toLowerCase() === vacationProject }

  // ---- Homeoffice: Einträge bekommen das Homeoffice-Thema als Beschreibung
  // (Beschreibungsspalte, wie in der GTK-App gepflegt — das Projekt bleibt
  // das Arbeitsprojekt), wenn sie in einem Homeoffice-WLAN entstehen. Ist
  // das Netz unbekannt (kein WLAN, Alt-Eintrag), entscheiden die
  // konfigurierten Homeoffice-Wochentage.
  readonly property var homeofficeDays: Model.parseWeekdays(setting("homeofficeDays", ""))
  readonly property string homeofficeTopic: String(setting("homeofficeTopic", "homeoffice"))
  function isHomeofficeDay(d) { return homeofficeDays.indexOf(d.getDay()) >= 0 }
  // kind: "homeoffice" | "office" | "" (dann: heute = aktuelles WLAN, sonst Wochentag)
  function wantsHomeoffice(start, kind) {
    var k = kind || ""
    if (k === "" && start && Model.sameDay(start, new Date())) k = currentKind
    if (k === "homeoffice") return true
    if (k === "office") return false
    return !!start && isHomeofficeDay(start)
  }
  function presetTopic(e, kind) {
    if (e.start && (!e.desc || e.desc === "") && wantsHomeoffice(e.start, kind)) e.desc = homeofficeTopic
    return e
  }
  // Ein bereits laufender Eintrag wird nachgezogen, sobald das WLAN bekannt
  // ist (nmcli antwortet asynchron) — einmal je Eintrag und Netz-Zustand.
  property string hoPresetFor: ""
  function presetRunningTopic() {
    if (!logLoaded || !runningEntry) return
    var key = runningEntry.id + ":" + currentKind
    if (hoPresetFor === key) return
    hoPresetFor = key
    if ((!runningEntry.desc || runningEntry.desc === "") && wantsHomeoffice(runningEntry.start, "")) {
      runningEntry.desc = homeofficeTopic
      save()
    }
  }
  onCurrentKindChanged: presetRunningTopic()

  // Ist-Arbeitszeit, Urlaubstage und Soll (Werktage bis heute minus
  // Urlaubs-Werktage, mal Tages-Soll) seit `since`.
  function periodStats(since) {
    var actual = totalSince(since), vacDays = {}
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (!e.start || e.start.getTime() < since.getTime()) continue
      if (isVacation(e)) vacDays[e.start.toDateString()] = e.start
    }
    var vacCount = 0, vacWeekdays = 0
    for (var k in vacDays) { vacCount++; if (Model.isWeekday(vacDays[k])) vacWeekdays++ }
    var workdays = Math.max(0, Model.weekdaysBetween(since, new Date()) - vacWeekdays)
    var target = workdays * targetSecs
    return { actual: actual, target: target, surplus: actual - target, vacation: vacCount }
  }

  readonly property var weekStats: { nowTick; return periodStats(Model.startOfWeek(new Date())) }
  readonly property var monthStats: { nowTick; return periodStats(Model.startOfMonth(new Date())) }
  readonly property var yearStats: { nowTick; return periodStats(Model.startOfYear(new Date())) }
  readonly property string activeProject: selectedProject !== "" ? selectedProject
    : (runningEntry ? runningEntry.project : defaultProject)
  readonly property double runningSecs: runningEntry && runningEntry.start
    ? (nowTick - runningEntry.start.getTime()) / 1000 : 0

  // Bar label: icon plus live h:mm while the timer runs.
  readonly property string label: runningEntry ? "󱎫 " + Model.fmtDurHM(runningSecs) : "󱎫"

  function findRunning(list) {
    for (var i = list.length - 1; i >= 0; i--)
      if (list[i].start && !list[i].end) return list[i]
    return null
  }

  // ---- Pausenregel: über breakAfterHours Brutto am Tag werden breakMinutes
  // abgezogen (Einträge bleiben unverändert; nur die Auswertung ist netto).
  readonly property real breakAfterSecs: (parseFloat(setting("breakAfterHours", 6)) || 0) * 3600
  readonly property real breakSecs: (parseInt(setting("breakMinutes", 30), 10) || 0) * 60
  function netSecs(gross) {
    return (breakAfterSecs > 0 && breakSecs > 0 && gross > breakAfterSecs) ? Math.max(0, gross - breakSecs) : gross
  }

  // Brutto-Arbeitszeit je Tag (ohne Urlaub, laufender Eintrag live):
  // { "Tue Sep 08 2026": { day: Date, secs: n }, … }
  readonly property var grossByDay: {
    nowTick
    var map = {}
    var now = new Date()
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (!e.start || isVacation(e)) continue
      var k = e.start.toDateString()
      if (!map[k]) map[k] = { day: Model.startOfDay(e.start), secs: 0, segs: [], target: null }
      map[k].secs += e.end ? (e.end.getTime() - e.start.getTime()) / 1000 : runningSecs
      map[k].segs.push({ s: e.start, e: e.end || now })
    }
    // Soll-Zeitpunkt je Tag: wann das Netto-Soll (brutto inkl. Pause) erreicht
    // ist — exakt über die Segmente; sonst ab dem letzten Ende projiziert.
    var required = targetSecs + (targetSecs > breakAfterSecs ? breakSecs : 0)
    for (var key in map) {
      var segs = map[key].segs.sort(function(a, b) { return a.s.getTime() - b.s.getTime() })
      var acc = 0, target = null
      for (var j = 0; j < segs.length; j++) {
        var len = (segs[j].e.getTime() - segs[j].s.getTime()) / 1000
        if (acc + len >= required) { target = new Date(segs[j].s.getTime() + (required - acc) * 1000); break }
        acc += len
      }
      if (!target && segs.length) target = new Date(segs[segs.length - 1].e.getTime() + (required - acc) * 1000)
      map[key].target = target
    }
    return map
  }

  // Gemeinsame Achse der Mini-Raster in der Liste: 06:00–20:00.
  readonly property int rasterStartHour: 6
  readonly property int rasterEndHour: 20
  readonly property real rasterWidth: Style.space(176)
  function rasterX(d, dayStart, width) {
    var t = (d.getTime() - dayStart.getTime()) / 3600000
    var f = (t - rasterStartHour) / (rasterEndHour - rasterStartHour)
    return Math.max(0, Math.min(1, f)) * width
  }

  // ---- Tages-Timeline: Stundenraster ab Arbeitsbeginn, gearbeitete
  // Segmente, Soll-Marke (Soll netto + Pause, falls fällig), Jetzt-Marke.
  readonly property var todayTimeline: {
    nowTick
    var today = Model.startOfDay(new Date())
    var segs = []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (!e.start || isVacation(e) || !Model.sameDay(e.start, today)) continue
      segs.push({ s: e.start, e: e.end || new Date(), running: !e.end })
    }
    if (segs.length === 0) return null
    segs.sort(function(a, b) { return a.s.getTime() - b.s.getTime() })
    var now = new Date()
    var first = segs[0].s
    var last = segs[segs.length - 1].e
    // Brutto, das für das Netto-Soll nötig ist (Pause kommt oben drauf).
    var required = targetSecs + (targetSecs > breakAfterSecs ? breakSecs : 0)
    var acc = 0, target = null
    for (var j = 0; j < segs.length; j++) {
      var len = (segs[j].e.getTime() - segs[j].s.getTime()) / 1000
      if (acc + len >= required) { target = new Date(segs[j].s.getTime() + (required - acc) * 1000); break }
      acc += len
    }
    var reached = target !== null
    if (!reached) target = new Date(now.getTime() + (required - acc) * 1000) // Projektion: ab jetzt durchgehend
    var gross = grossByDay[today.toDateString()] ? grossByDay[today.toDateString()].secs : 0
    var net = netSecs(gross)
    var hour = 3600000
    var axisStart = new Date(Math.floor(first.getTime() / hour) * hour)
    var axisEndRaw = Math.max(target.getTime(), last.getTime(), now.getTime()) + 15 * 60000
    var axisEnd = new Date(Math.ceil(axisEndRaw / hour) * hour)
    var hours = []
    for (var t = axisStart.getTime(); t <= axisEnd.getTime(); t += hour) hours.push(new Date(t))
    return {
      axisStart: axisStart, axisEnd: axisEnd, hours: hours, segments: segs,
      first: first, now: now, target: target, reached: reached,
      net: net, remaining: Math.max(0, targetSecs - net), over: Math.max(0, net - targetSecs),
      running: segs[segs.length - 1].running
    }
  }

  function dayNetSecs(d) {
    var rec = grossByDay[d.toDateString()]
    return rec ? netSecs(rec.secs) : 0
  }

  function totalSince(since) {
    var sum = 0
    for (var k in grossByDay) {
      var rec = grossByDay[k]
      if (rec.day.getTime() >= Model.startOfDay(since).getTime()) sum += netSecs(rec.secs)
    }
    return sum
  }

  readonly property double todaySecs: { nowTick; return totalSince(Model.startOfDay(new Date())) }
  readonly property double weekSecs: { nowTick; return totalSince(Model.startOfWeek(new Date())) }
  readonly property double monthSecs: { nowTick; return totalSince(Model.startOfMonth(new Date())) }

  // ---- lifecycle (weather-panel contract) ----
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Omarchy ≥ 4.0.3 stellt die Bar-Property nur noch readonly bereit und
  // bietet dafür eine Setter-Funktion. Nie werfen lassen: ein Fehler hier
  // würde close() vor controller.hide() abbrechen — das Panel bliebe offen
  // und hielte den exklusiven Fokus-Prime fest.
  function setCenterHoverRevealSuppressed(value) {
    if (!root.bar) return
    try {
      if (typeof root.bar.setCenterHoverRevealSuppressed === "function")
        root.bar.setCenterHoverRevealSuppressed(value)
      else if ("centerHoverRevealSuppressed" in root.bar)
        root.bar.centerHoverRevealSuppressed = value
    } catch (e) {
      console.log("setCenterHoverRevealSuppressed nicht möglich: " + e)
    }
  }

  function refresh() {
    logFile.reload()
    keyFile.reload()
    journalProc.running = true
    if (!ssidProc.running) ssidProc.running = true
    nowTick = Date.now()
  }

  // ---- data: Time Tracker CSV ----
  FileView {
    id: logFile
    path: root.csvPath
    watchChanges: true
    atomicWrites: true
    printErrors: true
    onSaveFailed: function(error) { console.log("timetracker[" + root.inst + "] SAVE FAILED: " + error) }
    onFileChanged: reload()
    onLoaded: {
      root.entries = Model.parseLog(text())
      root.logLoaded = true
      // Nach einem Reload (auch durch die GTK-App) zeigt editingEntry sonst
      // auf ein verwaistes Objekt — über die ID wieder anbinden.
      if (root.editingEntry) {
        var id = root.editingEntry.id
        root.editingEntry = root.entries.find(function(e) { return e.id === id }) || null
      }
      // One safety copy per shell session before we ever touch the file.
      if (!root.backupDone) {
        root.backupDone = true
        Quickshell.execDetached(["cp", "-n", root.csvPath, root.csvPath + ".omarchy-shell.bak"])
      }
      Qt.callLater(root.presetRunningTopic)
      // Netz nachschlagen, damit ein laufender Eintrag auch ohne geöffnetes
      // Panel sein Homeoffice-Thema bekommt.
      if (!ssidProc.running) ssidProc.running = true
    }
    onLoadFailed: function(error) { root.logLoaded = false; console.log("timetracker[" + root.inst + "] LOAD FAILED: " + error) }
  }

  function save() {
    // Only overwrite a file we actually parsed — never clobber the log with
    // an empty list because the initial read failed.
    if (!logLoaded) { console.log("timetracker[" + root.inst + "] save skipped: not loaded"); return }
    console.log("timetracker[" + root.inst + "] save " + entries.length + " entries")
    logFile.setText(Model.serializeLog(entries))
    // setText schreibt asynchron, und ein dazwischenkommendes reload()
    // (Datei-Watcher einer der Panel-Instanzen) CANCELT den Schreibjob still.
    // waitForJob erzwingt den Abschluss, bevor irgendwer neu lädt.
    logFile.waitForJob()
    root.entries = entries.slice()
  }

  function startTimer(startDate, kind) {
    if (runningEntry) return
    entries.push(presetTopic({
      project: activeProject,
      start: startDate || new Date(),
      end: null,
      desc: "",
      id: String(Date.now()),
      billed: false
    }, kind))
    save()
    // Falls das WLAN noch nicht bekannt war: nachschlagen, presetRunningTopic
    // trägt das Thema dann nach.
    if (!ssidProc.running) ssidProc.running = true
  }

  function stopTimer() {
    if (!runningEntry) return
    runningEntry.end = new Date()
    save()
  }

  function addEntry(start, end, kind) {
    var e = presetTopic({
      project: activeProject,
      start: start,
      end: end,
      desc: "",
      id: String(Date.now()),
      billed: false
    }, kind)
    // Chronologisch einsortieren — die Bestandsdatei ist nach Startzeit
    // sortiert, nachgetragene Alt-Einträge sollen das nicht brechen.
    var i = entries.length
    while (i > 0 && entries[i - 1].start && entries[i - 1].start.getTime() > start.getTime()) i--
    entries.splice(i, 0, e)
    save()
  }

  // Manual entry state: Von/Bis mit eigenem Datum (Über-Nacht-Einträge) und
  // "HH:MM"-Zeiten aus dem 15-min-Raster der TimePicker.
  property var newFromDate: Model.startOfDay(new Date())
  property var newToDate: Model.startOfDay(new Date())
  property string newFrom: ""
  property string newTo: ""

  readonly property bool editingRunning: editingEntry !== null && !editingEntry.end
  // Leeres Bis ist gültig, solange kein ANDERER Eintrag läuft: der bearbeitete
  // läuft dann (weiter), ein neuer wird als laufender gestartet.
  readonly property bool otherRunning: runningEntry !== null
    && (editingEntry === null || runningEntry.id !== editingEntry.id)
  readonly property bool manualValid: newFrom !== "" && (
    (newTo === "" && !otherRunning)
    || (newTo !== ""
        && Model.combine(newToDate, Model.parseTimeInput(newTo)).getTime()
           > Model.combine(newFromDate, Model.parseTimeInput(newFrom)).getTime()))

  function addManualEntry() {
    if (!manualValid) return
    var start = Model.combine(newFromDate, Model.parseTimeInput(newFrom))
    if (newTo === "") startTimer(start, newKind)
    else addEntry(start, Model.combine(newToDate, Model.parseTimeInput(newTo)), newKind)
    resetForm()
  }

  // Netz-Art der übernommenen WLAN-Session ("homeoffice"/"office"/""), damit
  // "Anlegen" das Thema passend setzt.
  property string newKind: ""

  function resetForm() {
    editingEntry = null
    selectedProject = ""
    newFromDate = Model.startOfDay(new Date())
    newToDate = Model.startOfDay(new Date())
    newFrom = ""
    newTo = ""
    newKind = ""
  }

  // WLAN-Session ins Formular übernehmen: Login auf volle 15 min abrunden,
  // Logout (oder jetzt, falls noch verbunden) aufrunden.
  // Ein gerade bearbeiteter Eintrag bleibt in Bearbeitung — die Werte
  // landen im Formular, 󰆓 aktualisiert dann diesen Eintrag.
  function takeoverSession(session) {
    newKind = session.kind || ""
    var from = Model.toFormTime(Model.floorDate(session.start, 15), null)
    newFromDate = from.day
    newFrom = from.time
    if (session.end) {
      var to = Model.toFormTime(Model.ceilDate(session.end, 15), session.start)
      newToDate = to.day
      newTo = to.time
    } else {
      // Noch verbunden: kein Logout, also kein Ende — Anlegen startet dann
      // einen laufenden Eintrag ab der Login-Zeit.
      newToDate = from.day
      newTo = ""
    }
  }

  // ---- edit existing entries ----
  property var editingEntry: null

  function startEdit(e) {
    // Delegates liefern modelData als KOPIE (QVariantMap-Konvertierung des
    // JS-Array-Modells) — immer das Original aus `entries` per ID auflösen,
    // sonst mutiert saveEdit ins Leere und die CSV bleibt unverändert.
    editingEntry = entries.find(function(x) { return x.id === e.id }) || e
    selectedProject = e.project
    newFromDate = Model.startOfDay(e.start)
    newFrom = Model.fmtTime(e.start)
    if (!e.end) {
      // Läuft noch: Bis bleibt leer; Speichern mit leerem Bis lässt ihn laufen.
      newToDate = Model.startOfDay(e.start)
      newTo = ""
    } else if (!Model.sameDay(e.end, e.start) && Model.fmtTime(e.end) === "00:00") {
      // Ende um Mitternacht des Folgetags entspricht "24:00" am Starttag.
      newToDate = Model.startOfDay(e.start)
      newTo = "24:00"
    } else {
      newToDate = Model.startOfDay(e.end)
      newTo = Model.fmtTime(e.end)
    }
  }

  function saveEdit() {
    if (!editingEntry || !manualValid) {
      console.log("timetracker[" + root.inst + "] saveEdit skipped: editing=" + (editingEntry ? editingEntry.id : "null") + " valid=" + manualValid)
      return
    }
    var id = editingEntry.id
    var idx = entries.findIndex(function(x) { return x.id === id })
    if (idx < 0) { console.log("timetracker[" + root.inst + "] saveEdit: id " + id + " nicht in entries"); resetForm(); return }
    var target = entries[idx]
    target.project = activeProject
    target.start = Model.combine(newFromDate, Model.parseTimeInput(newFrom))
    target.end = newTo === "" ? null : Model.combine(newToDate, Model.parseTimeInput(newTo))
    // Neu einsortieren, falls sich der Tag geändert hat.
    entries.splice(idx, 1)
    var i = entries.length
    while (i > 0 && entries[i - 1].start && entries[i - 1].start.getTime() > target.start.getTime()) i--
    entries.splice(i, 0, target)
    save()
    resetForm()
  }

  // Löschen nur nach Rückfrage (Kit-ConfirmDialog über dem Panelinhalt).
  property bool deleteConfirmOpen: false
  readonly property string deleteConfirmMessage: editingEntry
    ? "Eintrag " + Model.fmtDayDate(editingEntry.start) + " " + Model.fmtTime(editingEntry.start)
      + (editingEntry.end ? "–" + Model.fmtTime(editingEntry.end) : " (läuft)")
      + " · " + editingEntry.project + " wirklich löschen?"
    : ""
  function requestDelete() {
    if (!editingEntry) return
    deleteConfirm.selectedIndex = 1
    deleteConfirmOpen = true
    Qt.callLater(function() { deleteConfirm.forceActiveFocus() })
  }
  function cancelDelete() {
    deleteConfirmOpen = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }
  function confirmDelete() {
    deleteConfirmOpen = false
    deleteEdit()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function deleteEdit() {
    if (!editingEntry) return
    var id = editingEntry.id
    var idx = entries.findIndex(function(x) { return x.id === id })
    if (idx >= 0) {
      entries.splice(idx, 1)
      save()
    }
    resetForm()
  }

  // Suggestion already covered by an existing entry on the same day with
  // roughly the same start (±20 min)? Then don't offer it again.
  function suggestionCovered(session) {
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (!e.start || !Model.sameDay(e.start, session.start)) continue
      if (Math.abs(e.start.getTime() - session.start.getTime()) <= 20 * 60000) return true
    }
    return false
  }

  // ---- data: projects from the flatpak's gsettings keyfile ----
  FileView {
    id: keyFile
    path: Quickshell.env("HOME") + "/.var/app/com.lynnmichaelmartin.TimeTracker/config/glib-2.0/settings/keyfile"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var p = Model.parseProjectsKeyfile(text())
      root.projects = p.length ? p : [root.defaultProject]
    }
    onLoadFailed: root.projects = [root.defaultProject]
  }

  // ---- data: wifi sessions from the journal ----
  // Journal-Text und SSID treffen asynchron ein — Sessions werden neu
  // berechnet, sobald sich eines von beiden ändert.
  property string journalText: ""
  onJournalTextChanged: recomputeSessions()
  onSuggestionNetworksChanged: recomputeSessions()

  function recomputeSessions() {
    var nets = suggestionNetworks
    var sessions = nets.length > 0 ? Model.mergeSessions(Model.parseSessions(journalText, nets), 10) : []
    wifiSessions = sessions.map(function(s) {
      return { start: s.start, end: s.end, ssid: s.ssid,
               kind: Model.networkKind(s.ssid, root.officeNetworks, root.homeofficeNetworks) }
    })
  }

  Process {
    id: journalProc
    command: ["journalctl", "-u", "NetworkManager", "-o", "short-unix", "--no-pager", "--since", "today"]
    stdout: StdioCollector {
      id: journalStdout
      waitForEnd: true
      onStreamFinished: root.journalText = text
    }
  }

  Process {
    id: ssidProc
    command: ["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.detectedSsid = Model.parseActiveSsid(text)
    }
  }

  Timer {
    interval: root.opened ? 1000 : 30000
    running: root.opened || root.runningEntry !== null
    repeat: true
    onTriggered: root.nowTick = Date.now()
  }

  // Refresh wifi sessions occasionally while the panel sits open.
  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    onTriggered: journalProc.running = true
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function start(): void { root.startTimer(null) }
    function stop(): void { root.stopTimer() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(711))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight + Style.space(28))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        z: 10
        opened: root.deleteConfirmOpen
        message: root.deleteConfirmMessage
        confirmText: "Löschen"
        cancelText: "Abbrechen"
        background: Color.popups.background
        foreground: Color.popups.text
        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
        // Pfeile/Enter/Escape gehen an den Dialog, solange er offen ist.
        Keys.onPressed: function(event) {
          if (root.deleteConfirmOpen && deleteConfirm.handleKey(event)) event.accepted = true
        }
      }
      blocked: root.deleteConfirmOpen || fromDatePick.popupOpen || toDatePick.popupOpen || fromTimePick.popupOpen || toTimePick.popupOpen || projectPopup.opened
      onCloseRequested: root.close()
      onReturnRequested: root.runningEntry ? root.stopTimer() : root.startTimer(null)
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          // ---- Hero: live timer + project label + square start/stop ----
          Item {
            width: parent.width
            height: Math.max(heroTimer.implicitHeight, startStopBtn.height)

            Column {
              id: heroTimer
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: root.runningEntry ? Model.fmtDurHMS(root.runningSecs) : "–:––"
                color: root.runningEntry ? Color.accent : root.barForeground
                font.family: Style.font.family
                font.pixelSize: 34
                font.bold: true
              }

              Row {
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  visible: root.runningEntry !== null
                  text: root.runningEntry
                    ? "seit " + (Model.sameDay(root.runningEntry.start, new Date())
                        ? Model.fmtTime(root.runningEntry.start)
                        : Model.fmtDayDate(root.runningEntry.start) + " " + Model.fmtTime(root.runningEntry.start))
                      + (root.runningEntry.desc ? " · " + root.runningEntry.desc : "") + " · "
                    : ""
                  color: root.runningSecs > 12 * 3600 ? Color.urgent : Qt.darker(root.barForeground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                // Klickbares Projekt-Label — ersetzt das Dropdown.
                Text {
                  id: projectLabel
                  textFormat: Text.PlainText
                  text: root.activeProject
                  color: projectHover.hovered ? Color.accent : Qt.darker(root.barForeground, 1.15)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.underline: projectHover.hovered

                  HoverHandler {
                    id: projectHover
                    cursorShape: Qt.PointingHandCursor
                  }
                  TapHandler {
                    onTapped: projectPopup.open()
                  }

                  Popup {
                    id: projectPopup
                    y: projectLabel.height + Style.spacing.xxs
                    padding: Style.space(6)

                    background: Rectangle {
                      color: Color.popups.background
                      border.color: Color.popups.border
                      border.width: 1
                      radius: Style.cornerRadius
                    }

                    contentItem: Column {
                      spacing: Style.space(2)

                      Repeater {
                        model: root.projects

                        Button {
                          required property string modelData
                          width: Style.space(170)
                          leftAlign: true
                          text: modelData
                          selected: modelData === root.activeProject
                          onClicked: {
                            root.selectedProject = modelData
                            // Läuft ein Timer (und wird gerade kein alter
                            // Eintrag bearbeitet), wechselt der laufende
                            // Eintrag sofort das Projekt.
                            if (!root.editingEntry && root.runningEntry) {
                              root.runningEntry.project = modelData
                              root.save()
                            }
                            projectPopup.close()
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            Button {
              id: startStopBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(46)
              height: Style.space(46)
              bordered: true
              text: root.runningEntry ? "󰓛" : "󰐊"
              fontSize: 22
              foreground: root.runningEntry ? Color.urgent : Color.accent
              tooltipText: root.runningEntry ? "Stopp" : "Start jetzt"
              onClicked: root.runningEntry ? root.stopTimer() : root.startTimer(null)
            }
          }

          PanelSeparator { width: parent.width }

          // ---- Wifi suggestions ----
          PanelSectionHeader {
            text: "WLAN heute"
            foreground: root.barForeground
          }

          Text {
            visible: root.wifiSessions.length === 0
            textFormat: Text.PlainText
            text: root.suggestionNetworks.length > 0
              ? "Heute keine Anmeldung in " + root.suggestionNetworks.join(", ")
              : "Kein WLAN verbunden"
            color: Qt.darker(root.barForeground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.wifiSessions

            Item {
              id: sessionRow
              required property var modelData
              readonly property var sStart: Model.roundDate(modelData.start, root.roundMinutes)
              readonly property bool covered: root.suggestionCovered(modelData)

              width: contentColumn.width
              height: Style.spacing.controlHeight + Style.space(4)

              // Echte Login-/Logout-Zeiten (ungerundet); die Übernahme rundet.
              Text {
                anchors.left: parent.left
                anchors.right: sessionActions.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: "Login " + Model.fmtTime(sessionRow.modelData.start)
                  + " → Logout " + (sessionRow.modelData.end ? Model.fmtTime(sessionRow.modelData.end) : "–")
                  + " · " + sessionRow.modelData.ssid
                  + (sessionRow.modelData.kind === "homeoffice" ? " (Homeoffice)" : "")
                  + (sessionRow.covered ? "  ✓ erfasst" : "")
                color: sessionRow.covered ? Qt.darker(root.barForeground, 1.4) : root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Row {
                id: sessionActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Button {
                  visible: !sessionRow.covered && !sessionRow.modelData.end && root.runningEntry === null
                  width: Style.spacing.controlHeight
                  height: Style.spacing.controlHeight
                  bordered: true
                  text: "󰐊"
                  fontSize: Style.font.icon
                  foreground: Color.accent
                  tooltipText: "Timer ab " + Model.fmtTime(sessionRow.sStart) + " starten"
                  onClicked: root.startTimer(sessionRow.sStart, sessionRow.modelData.kind)
                }
                Button {
                  width: Style.spacing.controlHeight
                  height: Style.spacing.controlHeight
                  bordered: true
                  text: "󰇚"
                  fontSize: Style.font.icon
                  tooltipText: "Ins Formular übernehmen (Login ab-, Logout aufgerundet auf 15 min)"
                  onClicked: root.takeoverSession(sessionRow.modelData)
                }
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---- Manual entry / edit ----
          PanelSectionHeader {
            text: root.editingEntry ? "Eintrag bearbeiten" : "Neuer Eintrag"
            foreground: root.barForeground
          }

          // Zwei Spalten: links die Von/Bis-Picker, rechts die Aktionen als
          // quadratische Icon-Buttons — spart die separate Button-Zeile.
          Item {
            width: parent.width
            height: pickerCol.implicitHeight

            Column {
              id: pickerCol
              spacing: Style.space(6)

              Row {
                spacing: Style.space(6)

                Text {
                  width: Style.space(30)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "Von"
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                DatePicker {
                  id: fromDatePick
                  selectedDate: root.newFromDate
                  onPicked: function(d) {
                    root.newFromDate = d
                    // Bis-Datum folgt dem Von-Datum, solange es nicht dahinter liegt.
                    if (root.newToDate.getTime() < d.getTime()) root.newToDate = d
                  }
                }
                TimePicker {
                  id: fromTimePick
                  value: root.newFrom
                  onChanged: function(v) { root.newFrom = v }
                }
              }

              Row {
                spacing: Style.space(6)

                Text {
                  width: Style.space(30)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "Bis"
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                DatePicker {
                  id: toDatePick
                  selectedDate: root.newToDate
                  onPicked: function(d) { root.newToDate = d }
                }
                TimePicker {
                  id: toTimePick
                  value: root.newTo
                  onChanged: function(v) { root.newTo = v }
                }
              }
            }

            Row {
              anchors.right: parent.right
              anchors.top: pickerCol.top
              spacing: Style.space(6)

              Button {
                visible: root.editingEntry === null
                width: Style.spacing.controlHeight
                height: Style.spacing.controlHeight
                bordered: true
                text: "󰐕"
                fontSize: Style.font.icon
                foreground: Color.accent
                enabled: root.manualValid
                opacity: root.manualValid ? 1 : 0.4
                tooltipText: root.newTo === "" ? "Als laufenden Eintrag starten" : "Anlegen"
                onClicked: root.addManualEntry()
              }

              Button {
                visible: root.editingEntry !== null
                width: Style.spacing.controlHeight
                height: Style.spacing.controlHeight
                bordered: true
                text: "󰆓"
                fontSize: Style.font.icon
                foreground: Color.accent
                enabled: root.manualValid
                opacity: root.manualValid ? 1 : 0.4
                tooltipText: "Speichern"
                onClicked: root.saveEdit()
              }
              Button {
                visible: root.editingEntry !== null
                width: Style.spacing.controlHeight
                height: Style.spacing.controlHeight
                bordered: true
                text: "󰩺"
                fontSize: Style.font.icon
                foreground: Color.urgent
                tooltipText: "Löschen …"
                onClicked: root.requestDelete()
              }
              Button {
                visible: root.editingEntry !== null
                width: Style.spacing.controlHeight
                height: Style.spacing.controlHeight
                bordered: true
                text: "󰅖"
                fontSize: Style.font.icon
                tooltipText: "Abbrechen"
                onClicked: root.resetForm()
              }
            }
          }

          // Sichtbarer Grund, warum 󰐕/󰆓 gedimmt sind — sonst wirkt das
          // Formular einfach "kaputt", wenn Bis vor Von liegt.
          Text {
            visible: root.newFrom !== "" && !root.manualValid
            textFormat: Text.PlainText
            text: root.newTo === "" ? "⚠ Es läuft bereits ein anderer Eintrag – Ende angeben"
                                    : "⚠ Ende liegt nicht nach dem Beginn"
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // ---- Totals ----
          Text {
            textFormat: Text.PlainText
            text: "Heute " + Model.fmtDurHM(root.todaySecs) + " h · Woche " + Model.fmtDurHM(root.weekSecs) + " h · Monat " + Model.fmtDurHM(root.monthSecs) + " h"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          // Überstunden = Ist − Soll bis heute (Werktage × Tages-Soll, Urlaub
          // senkt das Soll); Urlaub = verbrauchte Tage im Kalenderjahr.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: "Überstunden: Woche " + Model.fmtSigned(root.weekStats.surplus)
              + " · Monat " + Model.fmtSigned(root.monthStats.surplus)
              + (root.surplusOverride
                  ? " · Konto aktuell " + Model.fmtSigned(root.accountSurplus) + " h"
                  : " · Jahr " + Model.fmtSigned(root.yearStats.surplus) + " h")
            color: Qt.darker(root.barForeground, 1.2)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: "Urlaub: " + root.yearStats.vacation + " Tage genommen · " + root.vacationRemaining + " übrig"
              + (root.vacationOverride ? " (Stand " + Model.fmtDayDate(root.baseDate) + ": " + root.baseVacationLeft + ")" : " von " + root.vacationDays)
              + " · Soll " + root.weeklyHours + " h/Woche (" + Model.fmtDurHM(root.targetSecs) + " h/Tag)"
              + (root.breakAfterSecs > 0 && root.breakSecs > 0
                  ? " · Pause " + Math.round(root.breakSecs / 60) + " min ab " + Model.fmtDurHM(root.breakAfterSecs) + " h" : "")
            color: Qt.darker(root.barForeground, 1.2)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // ---- Tages-Timeline ----
          PanelSectionHeader {
            visible: root.todayTimeline !== null
            text: "Heute"
            foreground: root.barForeground
          }

          Item {
            id: timeline
            visible: root.todayTimeline !== null
            width: parent.width
            height: Style.space(46)
            readonly property var tl: root.todayTimeline
            readonly property real x0: tl ? tl.axisStart.getTime() : 0
            readonly property real x1: tl ? tl.axisEnd.getTime() : 1
            function xOf(d) { return (d.getTime() - x0) / Math.max(1, x1 - x0) * width }

            // Stundenlinien + Beschriftung
            Repeater {
              model: timeline.tl ? timeline.tl.hours : []
              Item {
                required property var modelData
                x: timeline.xOf(modelData)
                y: 0
                width: 1
                height: timeline.height
                Rectangle { x: 0; y: Style.space(12); width: 1; height: timeline.height - Style.space(12); color: Qt.alpha(root.barForeground, 0.18) }
                Text {
                  x: 2; y: 0
                  textFormat: Text.PlainText
                  text: Model.pad2(modelData.getHours())
                  color: Qt.darker(root.barForeground, 1.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Spur
            Rectangle {
              x: 0; y: Style.space(20); width: parent.width; height: Style.space(10)
              radius: height / 2
              color: Style.hoverFillFor(root.barForeground, Color.accent)
            }

            // Gearbeitete Segmente: bis zur Soll-Marke Akzent, darüber Warnfarbe.
            Repeater {
              model: timeline.tl ? timeline.tl.segments : []
              Item {
                required property var modelData
                readonly property real sx: timeline.xOf(modelData.s)
                readonly property real ex: timeline.xOf(modelData.e)
                readonly property real tx: timeline.xOf(timeline.tl.target)
                Rectangle {
                  x: sx; y: Style.space(20); height: Style.space(10)
                  width: Math.max(0, Math.min(ex, tx) - sx)
                  radius: height / 2
                  color: Color.accent
                }
                Rectangle {
                  x: Math.max(sx, tx); y: Style.space(20); height: Style.space(10)
                  width: Math.max(0, ex - Math.max(sx, tx))
                  radius: height / 2
                  color: Color.urgent
                }
              }
            }

            // Soll-Marke
            Rectangle {
              visible: timeline.tl !== null
              x: timeline.tl ? timeline.xOf(timeline.tl.target) - 1 : 0
              y: Style.space(14); width: 2; height: Style.space(22)
              color: root.barForeground
            }
            Text {
              visible: timeline.tl !== null
              x: timeline.tl ? Math.min(timeline.xOf(timeline.tl.target) + 4, timeline.width - implicitWidth) : 0
              y: Style.space(34)
              textFormat: Text.PlainText
              text: timeline.tl ? "Soll " + Model.fmtTime(timeline.tl.target) : ""
              color: Qt.darker(root.barForeground, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            // Jetzt-Marke (nur bei laufendem Eintrag)
            Rectangle {
              visible: timeline.tl !== null && timeline.tl.running
              x: timeline.tl ? timeline.xOf(timeline.tl.now) : 0
              y: Style.space(16); width: 1; height: Style.space(18)
              color: Color.accent
            }
          }

          Text {
            visible: root.todayTimeline !== null
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: root.todayTimeline
              ? "Start " + Model.fmtTime(root.todayTimeline.first)
                + " · gearbeitet " + Model.fmtDurHM(root.todayTimeline.net) + " h netto"
                + " · Soll " + Model.fmtDurHM(root.targetSecs) + " h"
                + (root.todayTimeline.over > 0
                    ? " · über Soll +" + Model.fmtDurHM(root.todayTimeline.over) + " h"
                    : " · noch " + Model.fmtDurHM(root.todayTimeline.remaining) + " h bis " + Model.fmtTime(root.todayTimeline.target))
              : ""
            color: Qt.darker(root.barForeground, 1.2)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // ---- Recent entries ----
          Item {
            width: parent.width
            height: axisHeader.implicitHeight
            visible: root.recentEntries.length > 0

            PanelSectionHeader {
              id: axisHeader
              anchors.left: parent.left
              text: "Einträge"
              foreground: root.barForeground
            }

            // Achse der Mini-Raster (alle 2 h beschriftet), bündig mit der Spalte.
            Item {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.bottom: parent.bottom
              width: root.rasterWidth
              height: Style.font.caption + 2
              Repeater {
                model: Math.floor((root.rasterEndHour - root.rasterStartHour) / 2) + 1
                Text {
                  required property int index
                  readonly property int hour: root.rasterStartHour + index * 2
                  x: (hour - root.rasterStartHour) / (root.rasterEndHour - root.rasterStartHour) * root.rasterWidth - implicitWidth / 2
                  textFormat: Text.PlainText
                  text: Model.pad2(hour)
                  color: Qt.darker(root.barForeground, 1.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption - 2
                }
              }
            }
          }

          // Virtualisiert: die ListView instanziiert nur sichtbare Zeilen,
          // die komplette Historie bleibt scrollbar.
          ListView {
            id: entryList
            width: parent.width
            height: Math.min(contentHeight, Style.space(230))
            clip: true
            model: root.recentEntries
            boundsBehavior: Flickable.StopAtBounds
            reuseItems: true

            ScrollBar.vertical: ScrollBar {}

            delegate: Item {
              required property var modelData
              required property int index
              // Trennlinie, wenn der vorherige (neuere) Eintrag in einer anderen
              // Woche bzw. einem anderen Monat liegt.
              readonly property var prevEntry: index > 0 ? root.recentEntries[index - 1] : null
              readonly property bool newMonth: prevEntry !== null && prevEntry.start && Model.monthKey(prevEntry.start) !== Model.monthKey(modelData.start)
              readonly property bool newWeek: !newMonth && prevEntry !== null && prevEntry.start && Model.weekKey(prevEntry.start) !== Model.weekKey(modelData.start)
              readonly property real sepGap: (newWeek || newMonth) ? Style.space(7) : 0
              readonly property bool isEditing: root.editingEntry !== null && root.editingEntry.id === modelData.id
              readonly property bool hot: rowHover.hovered
              readonly property bool running: !modelData.end
              readonly property double liveSecs: { root.nowTick; return running ? root.runningSecs : (modelData.end.getTime() - modelData.start.getTime()) / 1000 }

              width: entryList.width
              height: rowText.implicitHeight + Style.space(6) + sepGap

              // Schmale, dezente Linie: Wochenwechsel leicht, Monatswechsel etwas kräftiger.
              Rectangle {
                visible: parent.newWeek || parent.newMonth
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                y: Math.round(parent.sepGap / 2) - 1
                height: 1
                color: parent.newMonth ? Qt.alpha(root.barForeground, 0.35) : Qt.alpha(root.barForeground, 0.15)
              }

              Rectangle {
                anchors.fill: parent
                anchors.topMargin: parent.sepGap
                radius: Style.cornerRadius
                color: parent.isEditing ? Style.selectionFillFor(root.barForeground, Color.accent)
                  : parent.hot ? Style.hoverFillFor(root.barForeground, Color.accent)
                  : "transparent"
              }

              // Mini-Raster (gemeinsame Achse 06–20 Uhr): Stundenlinien, Segment
              // des Eintrags, Anteil über Soll in Warnfarbe, Soll-Marke des Tages.
              Item {
                id: dayBar
                visible: !root.isVacation(modelData)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: parent.sepGap / 2
                width: root.rasterWidth
                height: Style.space(12)

                readonly property var dayStart: Model.startOfDay(modelData.start)
                readonly property var info: { root.nowTick; return root.grossByDay[modelData.start.toDateString()] || null }
                readonly property var segEnd: modelData.end || new Date(root.nowTick)
                readonly property real sx: root.rasterX(modelData.start, dayStart, width)
                readonly property real ex: root.rasterX(segEnd, dayStart, width)
                readonly property real tx: info && info.target ? root.rasterX(info.target, dayStart, width) : width

                Repeater {
                  model: root.rasterEndHour - root.rasterStartHour + 1
                  Rectangle {
                    required property int index
                    x: index / (root.rasterEndHour - root.rasterStartHour) * dayBar.width
                    y: 0; width: 1; height: dayBar.height
                    color: Qt.alpha(root.barForeground, index % 2 === 0 ? 0.22 : 0.10)
                  }
                }
                Rectangle {
                  x: dayBar.sx; y: Style.space(3); height: Style.space(6)
                  width: Math.max(0, Math.min(dayBar.ex, dayBar.tx) - dayBar.sx)
                  radius: height / 2
                  color: Color.accent
                }
                Rectangle {
                  x: Math.max(dayBar.sx, dayBar.tx); y: Style.space(3); height: Style.space(6)
                  width: Math.max(0, dayBar.ex - Math.max(dayBar.sx, dayBar.tx))
                  radius: height / 2
                  color: Color.urgent
                }
                Rectangle {
                  visible: dayBar.info !== null && dayBar.info.target !== null
                  x: dayBar.tx - 1; y: 0; width: 2; height: dayBar.height
                  color: Qt.alpha(root.barForeground, 0.7)
                }
              }

              Text {
                id: rowText
                anchors.left: parent.left
                anchors.right: dayBar.left
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: parent.sepGap / 2
                textFormat: Text.PlainText
                text: Model.fmtDayDate(modelData.start) + "  "
                  + Model.fmtTime(modelData.start) + "–" + (parent.running ? "     " : Model.fmtTime(modelData.end))
                  + "  (" + Model.fmtDurHM(parent.liveSecs) + " h)  "
                  + modelData.project
                  + (modelData.desc ? " · " + modelData.desc : "")
                  + (parent.running ? "  󰐊 läuft" : "")
                color: parent.running ? Color.accent
                  : parent.isEditing || parent.hot ? root.barForeground : Qt.darker(root.barForeground, 1.2)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              HoverHandler {
                id: rowHover
                cursorShape: Qt.PointingHandCursor
              }
              TapHandler {
                onTapped: parent.isEditing ? root.resetForm() : root.startEdit(parent.modelData)
              }
            }
          }

          Text {
            visible: !root.logLoaded
            textFormat: Text.PlainText
            text: "⚠ " + root.csvPath + " nicht lesbar"
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
