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
  // Leeres ssid-Setting = automatisch das aktuell verbundene WLAN verwenden.
  readonly property string configuredSsid: setting("ssid", "")
  property string detectedSsid: ""
  readonly property string ssid: configuredSsid !== "" ? configuredSsid : detectedSsid
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
      if (!e.end) continue
      var k = e.start.toDateString()
      totals[k] = (totals[k] || 0) + (e.end.getTime() - e.start.getTime()) / 1000
    }
    dayTotals = totals
    listed.reverse() // neueste oben; ein laufender Eintrag steht damit ganz oben
    recentEntries = listed
  }

  readonly property real targetSecs: (parseInt(setting("targetHours", 7), 10) || 7) * 3600
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

  function totalSince(since) {
    var sum = 0
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (!e.start || e.start.getTime() < since.getTime()) continue
      sum += e.end ? (e.end.getTime() - e.start.getTime()) / 1000 : runningSecs
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
    if (configuredSsid === "" && !ssidProc.running) ssidProc.running = true
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

  function startTimer(startDate) {
    if (runningEntry) return
    entries.push({
      project: activeProject,
      start: startDate || new Date(),
      end: null,
      desc: "",
      id: String(Date.now()),
      billed: false
    })
    save()
  }

  function stopTimer() {
    if (!runningEntry) return
    runningEntry.end = new Date()
    save()
  }

  function addEntry(start, end) {
    var e = {
      project: activeProject,
      start: start,
      end: end,
      desc: "",
      id: String(Date.now()),
      billed: false
    }
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
  // Leeres Bis ist gültig, wenn der bearbeitete Eintrag läuft (läuft weiter)
  // oder ein NEUER Eintrag als laufender gestartet werden kann.
  readonly property bool manualValid: newFrom !== "" && (
    (newTo === "" && (editingRunning || (editingEntry === null && runningEntry === null)))
    || (newTo !== ""
        && Model.combine(newToDate, Model.parseTimeInput(newTo)).getTime()
           > Model.combine(newFromDate, Model.parseTimeInput(newFrom)).getTime()))

  function addManualEntry() {
    if (!manualValid) return
    var start = Model.combine(newFromDate, Model.parseTimeInput(newFrom))
    if (newTo === "") startTimer(start)
    else addEntry(start, Model.combine(newToDate, Model.parseTimeInput(newTo)))
    resetForm()
  }

  function resetForm() {
    editingEntry = null
    selectedProject = ""
    newFromDate = Model.startOfDay(new Date())
    newToDate = Model.startOfDay(new Date())
    newFrom = ""
    newTo = ""
  }

  // WLAN-Session ins Formular übernehmen: Login auf volle 15 min abrunden,
  // Logout (oder jetzt, falls noch verbunden) aufrunden.
  function takeoverSession(session) {
    editingEntry = null
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
  onSsidChanged: recomputeSessions()

  function recomputeSessions() {
    wifiSessions = ssid !== ""
      ? Model.mergeSessions(Model.parseSessions(journalText, ssid), 10)
      : []
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
    contentWidth: panel.fittedContentWidth(Style.space(533))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight + Style.space(28))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: fromDatePick.popupOpen || toDatePick.popupOpen || fromTimePick.popupOpen || toTimePick.popupOpen || projectPopup.opened
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
                      + " · "
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
            text: root.ssid !== "" ? "WLAN " + root.ssid + " heute" : "WLAN heute"
            foreground: root.barForeground
          }

          Text {
            visible: root.wifiSessions.length === 0
            textFormat: Text.PlainText
            text: root.ssid !== "" ? "Heute keine Anmeldung im " + root.ssid : "Kein WLAN verbunden"
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
                  onClicked: root.startTimer(sessionRow.sStart)
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
                tooltipText: "Löschen"
                onClicked: root.deleteEdit()
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
            text: root.newTo === "" ? "⚠ Es läuft bereits ein Eintrag – Ende angeben"
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

          // ---- Recent entries ----
          PanelSectionHeader {
            text: "Einträge"
            foreground: root.barForeground
            visible: root.recentEntries.length > 0
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
              readonly property bool isEditing: root.editingEntry !== null && root.editingEntry.id === modelData.id
              readonly property bool hot: rowHover.hovered
              readonly property bool running: !modelData.end
              readonly property double liveSecs: { root.nowTick; return running ? root.runningSecs : (modelData.end.getTime() - modelData.start.getTime()) / 1000 }

              width: entryList.width
              height: rowText.implicitHeight + Style.space(6)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: parent.isEditing ? Style.selectionFillFor(root.barForeground, Color.accent)
                  : parent.hot ? Style.hoverFillFor(root.barForeground, Color.accent)
                  : "transparent"
              }

              // Soll/Ist-Balken: Spur = Soll-Stunden, Füllung = Ist des Tages.
              Item {
                id: dayBar
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(54)
                height: Style.space(7)

                readonly property real isSecs: (root.dayTotals[modelData.start.toDateString()] || 0)
                  + (root.runningEntry && Model.sameDay(root.runningEntry.start, modelData.start) ? root.runningSecs : 0)
                readonly property real frac: root.targetSecs > 0 ? Math.min(1, isSecs / root.targetSecs) : 0
                readonly property bool met: isSecs >= root.targetSecs

                Rectangle {
                  anchors.fill: parent
                  radius: height / 2
                  color: Style.hoverFillFor(root.barForeground, Color.accent)
                }
                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(height, parent.width * parent.frac)
                  height: parent.height
                  radius: height / 2
                  color: dayBar.met ? Color.accent : Qt.darker(Color.accent, 1.5)
                }
              }

              Text {
                id: rowText
                anchors.left: parent.left
                anchors.right: dayBar.left
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: Model.fmtDayDate(modelData.start) + "  "
                  + Model.fmtTime(modelData.start) + "–" + (parent.running ? "     " : Model.fmtTime(modelData.end))
                  + "  (" + Model.fmtDurHM(parent.liveSecs) + " h)  "
                  + modelData.project
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
