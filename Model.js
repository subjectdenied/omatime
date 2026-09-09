.pragma library

// Data layer for the Time Tracker bar widget. The on-disk format is the CSV
// written by the GNOME "Time Tracker" flatpak (com.lynnmichaelmartin.TimeTracker);
// every write has to stay byte-compatible so both apps can keep sharing the file.

var DAY_EN = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTH_EN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var DAY_DE = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]

var HEADER = "Project,Start Time,End Time,Description,ID,Billed,%l%H:%M:%S,%l%s"

function pad2(n) { return (n < 10 ? "0" : "") + n }

// ---------------------------------------------------------------- dates ----

// The GTK app stores GJS Date.toString() output, e.g.
//   "Mon Sep 01 2025 09:00:00 GMT+0200 (Mitteleuropäische Sommerzeit)"
// Reproduce it exactly (incl. the German zone name for CET/CEST) so rows we
// write are indistinguishable from the app's own.
function formatDate(d) {
  var offMin = -d.getTimezoneOffset()
  var sign = offMin >= 0 ? "+" : "-"
  var abs = Math.abs(offMin)
  var off = sign + pad2(Math.floor(abs / 60)) + pad2(abs % 60)
  var tzName = offMin === 120 ? "Mitteleuropäische Sommerzeit"
             : offMin === 60 ? "Mitteleuropäische Normalzeit"
             : "GMT" + off
  return DAY_EN[d.getDay()] + " " + MONTH_EN[d.getMonth()] + " " + pad2(d.getDate()) + " "
    + d.getFullYear() + " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes()) + ":" + pad2(d.getSeconds())
    + " GMT" + off + " (" + tzName + ")"
}

function parseDate(s) {
  if (!s) return null
  var m = /^\w{3} (\w{3}) (\d{1,2}) (\d{4}) (\d{1,2}):(\d{2}):(\d{2}) GMT([+-])(\d{2})(\d{2})/.exec(String(s).trim())
  if (m) {
    var mon = MONTH_EN.indexOf(m[1])
    if (mon < 0) return null
    var offMin = (m[7] === "-" ? -1 : 1) * (parseInt(m[8], 10) * 60 + parseInt(m[9], 10))
    return new Date(Date.UTC(parseInt(m[3], 10), mon, parseInt(m[2], 10),
      parseInt(m[4], 10), parseInt(m[5], 10), parseInt(m[6], 10)) - offMin * 60000)
  }
  var d = new Date(s)
  return isNaN(d.getTime()) ? null : d
}

function fmtTime(d) { return d ? pad2(d.getHours()) + ":" + pad2(d.getMinutes()) : "—" }

function fmtDayDate(d) {
  return d ? DAY_DE[d.getDay()] + " " + pad2(d.getDate()) + "." + pad2(d.getMonth() + 1) + "." : ""
}

function sameDay(a, b) {
  return a && b && a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

function startOfDay(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()) }

function startOfWeek(d) {
  var s = startOfDay(d)
  var dow = (s.getDay() + 6) % 7 // Monday = 0
  return new Date(s.getTime() - dow * 86400000)
}

function startOfMonth(d) { return new Date(d.getFullYear(), d.getMonth(), 1) }
function startOfYear(d) { return new Date(d.getFullYear(), 0, 1) }

function isWeekday(d) { var w = d.getDay(); return w >= 1 && w <= 5 }

// Anzahl Mo–Fr-Tage von `from` bis `to` (beide inklusive, Tagesgrenzen).
function weekdaysBetween(from, to) {
  var n = 0
  var d = startOfDay(from)
  var end = startOfDay(to).getTime()
  while (d.getTime() <= end) {
    if (isWeekday(d)) n++
    d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)
  }
  return n
}

// Vorzeichenbehaftete Stundenangabe für Überstunden: "+1:30" / "−2:15".
function fmtSigned(secs) {
  var s = Math.round(secs)
  return (s < 0 ? "−" : "+") + fmtDurHM(Math.abs(s))
}

// "6:45" for stats, "2:34:56" for the live timer.
function fmtDurHM(secs) {
  secs = Math.max(0, Math.floor(secs))
  return Math.floor(secs / 3600) + ":" + pad2(Math.floor((secs % 3600) / 60))
}

function fmtDurHMS(secs) {
  secs = Math.max(0, Math.floor(secs))
  return Math.floor(secs / 3600) + ":" + pad2(Math.floor((secs % 3600) / 60)) + ":" + pad2(secs % 60)
}

function roundDate(d, minutes) {
  if (!d || !minutes) return d
  var step = minutes * 60000
  return new Date(Math.round(d.getTime() / step) * step)
}

// WLAN-Übernahme: Login abrunden, Logout aufrunden (volle Viertelstunden).
function floorDate(d, minutes) {
  var step = minutes * 60000
  return new Date(Math.floor(d.getTime() / step) * step)
}

function ceilDate(d, minutes) {
  var step = minutes * 60000
  return new Date(Math.ceil(d.getTime() / step) * step)
}

// Date -> {day: Date(Mitternacht), time: "HH:MM"} für die Formular-Picker;
// Mitternacht des Folgetags wird als "24:00" am Vortag ausgedrückt.
function toFormTime(d, prevDay) {
  if (prevDay && d.getHours() === 0 && d.getMinutes() === 0 && !sameDay(d, prevDay)) {
    return { day: startOfDay(prevDay), time: "24:00" }
  }
  return { day: startOfDay(d), time: fmtTime(d) }
}

// ------------------------------------------------------------------ csv ----

function parseCsv(text) {
  var rows = [], row = [], field = "", q = false
  var s = String(text || "")
  for (var i = 0; i < s.length; i++) {
    var c = s[i]
    if (q) {
      if (c === '"') {
        if (s[i + 1] === '"') { field += '"'; i++ } else q = false
      } else field += c
    } else if (c === '"') {
      q = true
    } else if (c === ',') {
      row.push(field); field = ""
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && s[i + 1] === '\n') i++
      row.push(field); field = ""
      rows.push(row); row = []
    } else field += c
  }
  if (field !== "" || row.length) { row.push(field); rows.push(row) }
  return rows
}

function csvField(v) {
  var s = String(v == null ? "" : v)
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s
}

// -> [{project, start:Date, end:Date|null, desc, id, billed}]
function parseLog(text) {
  var rows = parseCsv(text)
  var entries = []
  for (var i = 1; i < rows.length; i++) {
    var r = rows[i]
    if (r.length < 5 || r[0] === "") continue
    entries.push({
      project: r[0],
      start: parseDate(r[1]),
      end: parseDate(r[2]),
      desc: r[3] || "",
      id: r[4],
      billed: r[5] === "true"
    })
  }
  return entries
}

function serializeLog(entries) {
  var out = [HEADER]
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var secs = (e.start && e.end) ? Math.max(0, Math.round((e.end.getTime() - e.start.getTime()) / 1000)) : 0
    var durStr = pad2(Math.floor(secs / 3600)) + ":" + pad2(Math.floor((secs % 3600) / 60)) + ":" + pad2(secs % 60)
    out.push([
      csvField(e.project),
      e.start ? formatDate(e.start) : "",
      e.end ? formatDate(e.end) : "",
      csvField(e.desc),
      String(e.id),
      e.billed ? "true" : "false",
      durStr,
      String(secs)
    ].join(","))
  }
  // The GTK app writes the file without a trailing newline — stay identical.
  return out.join("\n")
}

// The projects list lives in the flatpak's gsettings keyfile as
//   projects='tafel österreich`urlaub`überhang'
function parseProjectsKeyfile(text) {
  var m = /^projects='(.*)'$/m.exec(String(text || ""))
  if (!m || m[1] === "") return []
  return m[1].split("`")
}

// ------------------------------------------------------- manual entry ----

// "8.9.", "08.09.2026", "" (= heute) -> Date um Mitternacht, sonst null.
function parseDayInput(s) {
  s = String(s || "").trim()
  if (s === "") return startOfDay(new Date())
  var m = /^(\d{1,2})\.(\d{1,2})\.?\s*(\d{4})?$/.exec(s)
  if (!m) return null
  var now = new Date()
  var y = m[3] ? parseInt(m[3], 10) : now.getFullYear()
  var d = new Date(y, parseInt(m[2], 10) - 1, parseInt(m[1], 10))
  if (d.getMonth() !== parseInt(m[2], 10) - 1) return null // z.B. 31.02.
  // Ohne Jahr: Zeiteinträge liegen nie in der Zukunft — "31.12." im September
  // meint den letzten Dezember, nicht den kommenden.
  if (!m[3] && d.getTime() > now.getTime()) d.setFullYear(y - 1)
  return d
}

// "7", "7:30", "07:30", "24:00" (= Mitternacht Folgetag) -> {h, min}, sonst null.
function parseTimeInput(s) {
  s = String(s || "").trim()
  var m = /^(\d{1,2})(?:[:.](\d{2}))?$/.exec(s)
  if (!m) return null
  var h = parseInt(m[1], 10), min = m[2] ? parseInt(m[2], 10) : 0
  if (h > 24 || min > 59 || (h === 24 && min !== 0)) return null
  return { h: h, min: min }
}

// 15-Minuten-Raster 06:00–24:00 für die Zeit-Dropdowns.
function timeOptions() {
  var opts = []
  for (var m = 6 * 60; m <= 24 * 60; m += 15)
    opts.push(pad2(Math.floor(m / 60)) + ":" + pad2(m % 60))
  return opts
}

// Datums-Dropdown: heute und die letzten `days` Tage, DST-sicher über den
// Date-Konstruktor statt Millisekunden-Arithmetik.
function dayOptions(days) {
  var opts = []
  var now = new Date()
  for (var i = 0; i < days; i++) {
    var d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i)
    opts.push({
      label: i === 0 ? "Heute" : i === 1 ? "Gestern" : fmtDayDate(d),
      value: String(i)
    })
  }
  return opts
}

function dayFromOffset(offset) {
  var now = new Date()
  return new Date(now.getFullYear(), now.getMonth(), now.getDate() - (parseInt(offset, 10) || 0))
}

function combine(day, t) {
  return new Date(day.getFullYear(), day.getMonth(), day.getDate(), t.h, t.min, 0)
}

// `nmcli -t -f ACTIVE,SSID dev wifi` -> SSID der aktiven Verbindung
// (terse-Mode escaped Doppelpunkte als \:).
function parseActiveSsid(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^yes:(.*)$/.exec(lines[i])
    if (m) return m[1].replace(/\\:/g, ":")
  }
  return ""
}

// -------------------------------------------------------------- journal ----

// Input: `journalctl -u NetworkManager -o short-unix` output. A session opens
// on "Connected to wireless network \"<ssid>\"" and closes when the wifi
// device leaves the activated state (covers disconnect, suspend, shutdown —
// NetworkManager logs "activated -> deactivating" on all of them) or when a
// different network takes over.
function parseSessions(text, ssid) {
  var sessions = [], cur = null
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var mTime = /^(\d+)\.\d+\s/.exec(line)
    if (!mTime) continue
    var ts = new Date(parseInt(mTime[1], 10) * 1000)
    var mConn = /Connected to wireless network "(.*)"/.exec(line)
    if (mConn) {
      if (mConn[1] === ssid) {
        if (!cur) cur = { start: ts, end: null }
      } else if (cur) {
        cur.end = ts; sessions.push(cur); cur = null
      }
      continue
    }
    if (cur && /device \(wl[^)]*\): state change: activated -> /.test(line)) {
      cur.end = ts; sessions.push(cur); cur = null
    }
  }
  if (cur) sessions.push(cur)
  return sessions
}

// Short reconnects (AP roaming, a reboot over lunch at the desk) shouldn't
// split the workday into confetti.
function mergeSessions(sessions, gapMinutes) {
  var out = []
  for (var i = 0; i < sessions.length; i++) {
    var s = sessions[i]
    var last = out.length ? out[out.length - 1] : null
    if (last && last.end && (s.start.getTime() - last.end.getTime()) <= gapMinutes * 60000) {
      last.end = s.end
    } else {
      out.push({ start: s.start, end: s.end })
    }
  }
  return out
}
