.pragma library

// Pure logic for the pomodoro plugin. No Qt objects in here so
// it can be unit-tested with plain `qml` / node if ever needed.

var DEFAULTS = {
  focus: 25,            // minutes
  shortBreak: 5,
  longBreak: 15,
  longEvery: 4,         // long break after every Nth focus block
  dnd: true,            // silence notifications while focusing
  overlay: true,        // full-screen break screen
  overlayDim: 0.93,     // scrim alpha of the break screen
  sound: true,
  notify: true,
  autoStartBreak: true, // focus done -> break starts by itself
  autoStartFocus: false,// break done -> wait for the user ("ready") instead of counting straight away
  presets: [15, 25, 50, 90],
  soundFocusEnd: "/usr/share/sounds/freedesktop/stereo/complete.oga",
  soundBreakEnd: "/usr/share/sounds/freedesktop/stereo/message.oga",
  staleAfter: 30,       // minutes past the end after which a restored timer is dropped
  music: true,          // pause what's playing on a break, resume it when focus starts again
  showSubject: true,    // show the subject next to the countdown in the bar
  todoistFilter: "today | overdue", // Todoist filter for the subject picker
  studyLog: ""          // markdown file each focus block is appended to; empty = off
}

var SUBJECT_MAX = 120
var RECENT_MAX = 8

var BREAK_TIPS = [
  "Stand up. Roll your shoulders.",
  "Look at something twenty metres away.",
  "Water. Then more water.",
  "Breathe out longer than you breathe in.",
  "Step away from the keyboard — it will wait.",
  "Ta en paus. Skärmen springer inte iväg.",
  "Stretch the hands that just did the work.",
  "Walk to a window."
]

function num(value, fallback, min, max) {
  var n = Number(value)
  if (value === undefined || value === null || value === "" || isNaN(n)) n = fallback
  if (min !== undefined) n = Math.max(min, n)
  if (max !== undefined) n = Math.min(max, n)
  return n
}

function bool(value, fallback) {
  if (value === undefined || value === null) return fallback
  if (typeof value === "string") return value !== "false" && value !== "0" && value !== "off"
  return !!value
}

function config(entry) {
  var e = entry || {}
  var presets = Array.isArray(e.presets) ? e.presets.map(function(p) { return num(p, 0, 1, 180) }).filter(function(p) { return p > 0 }) : []
  return {
    focus: num(e.focus, DEFAULTS.focus, 1, 180),
    shortBreak: num(e.shortBreak, DEFAULTS.shortBreak, 1, 60),
    longBreak: num(e.longBreak, DEFAULTS.longBreak, 1, 120),
    longEvery: num(e.longEvery, DEFAULTS.longEvery, 0, 12),
    dnd: bool(e.dnd, DEFAULTS.dnd),
    overlay: bool(e.overlay, DEFAULTS.overlay),
    overlayDim: num(e.overlayDim, DEFAULTS.overlayDim, 0.3, 1),
    sound: bool(e.sound, DEFAULTS.sound),
    notify: bool(e.notify, DEFAULTS.notify),
    autoStartBreak: bool(e.autoStartBreak, DEFAULTS.autoStartBreak),
    autoStartFocus: bool(e.autoStartFocus, DEFAULTS.autoStartFocus),
    presets: presets.length ? presets : DEFAULTS.presets.slice(),
    soundFocusEnd: e.soundFocusEnd ? String(e.soundFocusEnd) : DEFAULTS.soundFocusEnd,
    soundBreakEnd: e.soundBreakEnd ? String(e.soundBreakEnd) : DEFAULTS.soundBreakEnd,
    staleAfter: num(e.staleAfter, DEFAULTS.staleAfter, 1, 24 * 60),
    music: bool(e.music, DEFAULTS.music),
    showSubject: bool(e.showSubject, DEFAULTS.showSubject),
    todoistFilter: e.todoistFilter ? String(e.todoistFilter) : DEFAULTS.todoistFilter,
    studyLog: e.studyLog ? String(e.studyLog) : DEFAULTS.studyLog
  }
}

// "mm:ss"; minutes are not capped at 59 so a 90-minute block reads 90:00.
function mmss(ms) {
  var total = Math.max(0, Math.ceil(ms / 1000))
  var m = Math.floor(total / 60)
  var s = total % 60
  return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
}

function minutesLabel(ms) {
  var m = Math.round(ms / 60000)
  return m + " min"
}

function phaseLabel(phase, readyNext) {
  switch (phase) {
  case "focus": return "Focus"
  case "short": return "Short break"
  case "long": return "Long break"
  case "ready": return readyNext === "break" ? "Focus complete" : "Break over"
  default: return "Pomodoro"
  }
}

function phaseIcon(phase, running) {
  switch (phase) {
  case "focus": return running ? "󰧐" : "󰏤"
  case "short":
  case "long": return running ? "󰅶" : "󰏤"
  case "ready": return "󰔛"
  default: return "󰔛"
  }
}

function isBreak(phase) {
  return phase === "short" || phase === "long"
}

function nextBreakKind(cyclesDone, longEvery) {
  return longEvery > 0 && cyclesDone > 0 && cyclesDone % longEvery === 0 ? "long" : "short"
}

function todayKey(date) {
  var d = date || new Date()
  var m = d.getMonth() + 1
  var day = d.getDate()
  return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day
}

function tipFor(index) {
  var i = Math.abs(Math.round(index)) % BREAK_TIPS.length
  return BREAK_TIPS[i]
}

function parseState(raw) {
  if (!raw) return null
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object") return null
    return parsed
  } catch (e) {
    return null
  }
}

// Dots for the current set: filled for finished focus blocks, one half for
// the block in progress, empty for the rest. longEvery 0 -> no dots.
function sessionDots(cyclesDone, longEvery, phase) {
  if (!longEvery) return []
  var dots = []
  for (var i = 0; i < longEvery; i++) {
    var state = "empty"
    if (i < cyclesDone) state = "done"
    else if (i === cyclesDone && phase === "focus") state = "current"
    dots.push(state)
  }
  return dots
}

// ---- subject

// One line, no control characters, capped. Anything that would break the
// bar, the log line or the state file is flattened to a space.
function cleanSubject(text) {
  var s = String(text === undefined || text === null ? "" : text)
  s = s.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim()
  return s.length > SUBJECT_MAX ? s.slice(0, SUBJECT_MAX).trim() : s
}

function cleanTaskId(id) {
  var s = String(id === undefined || id === null ? "" : id)
  return /^[A-Za-z0-9_-]{1,64}$/.test(s) ? s : ""
}

// Most recent first, no duplicates (case-insensitive), at most RECENT_MAX.
function addRecent(list, subject) {
  var s = cleanSubject(subject)
  var out = s ? [s] : []
  var src = Array.isArray(list) ? list : []
  for (var i = 0; i < src.length && out.length < RECENT_MAX; i++) {
    var r = cleanSubject(src[i])
    if (!r) continue
    var dup = false
    for (var j = 0; j < out.length; j++) if (out[j].toLowerCase() === r.toLowerCase()) dup = true
    if (!dup) out.push(r)
  }
  return out
}

function shorten(text, max) {
  var s = String(text || "")
  return s.length > max ? s.slice(0, Math.max(1, max - 1)).trim() + "…" : s
}

// ---- history

// One focus block as it goes to history.jsonl and the study log.
// focusedMs excludes paused time; outcome is done | skipped | stopped.
function focusEntry(startedAt, endedAt, focusedMs, plannedMs, outcome, subject, taskId, track) {
  return {
    start: Math.round(startedAt),
    end: Math.round(endedAt),
    minutes: Math.round(Math.max(0, focusedMs) / 60000),
    planned: Math.round(Math.max(0, plannedMs) / 60000),
    outcome: outcome === "skipped" || outcome === "stopped" ? outcome : "done",
    subject: cleanSubject(subject),
    taskId: cleanTaskId(taskId),
    track: shorten(cleanSubject(track), 200)
  }
}

// ---- music (MPRIS)

function isProxyPlayer(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
}

// Players that are playing right now and can be paused. playerctld is a
// proxy for the others, so pausing it too would act twice.
function playersToPause(players) {
  var out = []
  var src = players || []
  for (var i = 0; i < src.length; i++) {
    var p = src[i]
    if (!p || isProxyPlayer(p) || !p.isPlaying || !p.dbusName) continue
    if (p.canPause || p.canTogglePlaying) out.push(p)
  }
  return out
}

function firstPlaying(players) {
  var src = players || []
  for (var i = 0; i < src.length; i++) {
    var p = src[i]
    if (p && !isProxyPlayer(p) && p.isPlaying) return p
  }
  return null
}

// "Title — Artist", falling back to the app name (a browser tab, Spotify, ...).
function trackLabel(player) {
  if (!player) return ""
  var title = cleanSubject(player.trackTitle)
  var artist = cleanSubject(player.trackArtist)
  var label = title && artist ? title + " — " + artist : title || cleanSubject(player.identity || player.desktopEntry)
  return shorten(label, 200)
}
