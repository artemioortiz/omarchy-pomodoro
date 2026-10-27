import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "PomoModel.js" as Pomo

// Pomodoro engine. One instance lives in the shell for the whole
// session; the bar widget (one per monitor) reads its state and calls into it.
//
// Time is kept as an absolute wall-clock end (`endsAt`) so the countdown
// survives suspend, shell restarts and theme switches: state is persisted to
// ~/.local/state/uni-pomo/state.json on every transition and rehydrated on
// load through the bundled `pomo-state-read` helper (bounded, O_NOFOLLOW,
// fstat-validated, whitelisted). Configuration is this plugin's inline entry
// in shell.json, handed over by the bar widget: third-party services get a
// scoped shell API with no access to shellConfig.
//
// Each focus block that ends (done, skipped or stopped, at least a minute) is
// appended by `pomo-history` to ~/.local/state/uni-pomo/history.jsonl and,
// when `studyLog` is set, to that markdown file, as is each Todoist task
// marked done from here. Music playing over MPRIS is paused when a break
// starts and only what we paused is resumed on focus.
//
// IPC: `omarchy-shell pomodoro <status|start|pause|resume|toggle|stop|skip|
//        focus <min>|shortBreak <min>|longBreak <min>|extend <min>|hideBreak|showBreak|
//        setSubject <text> <todoist id>|clearSubject|todoistDone>`
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: "techywilbur.pomodoro"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/uni-pomo"
  readonly property string statePath: stateDir + "/state.json"

  // The shell stamps the plugin folder into manifest.__sourceDir; the state
  // reader ships next to this file.
  readonly property string sourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir).replace(/^file:\/\//, "").replace(/\/$/, "") : ""
  readonly property string stateReaderPath: sourceDir ? sourceDir + "/pomo-state-read" : ""
  readonly property string historyPath: sourceDir ? sourceDir + "/pomo-history" : ""
  readonly property string todoistPath: sourceDir ? sourceDir + "/pomo-todoist" : ""
  readonly property string cliPath: sourceDir ? sourceDir + "/uni-pomo" : ""

  // ---- configuration (inline on the widget's bar entry; set by BarWidget.qml)
  property var entry: null
  readonly property var config: Pomo.config(entry)

  // ---- state
  property string phase: "idle"        // idle | focus | short | long | ready
  property string readyNext: "focus"   // what a "ready" pause is waiting to start: focus | break
  property bool running: false
  property real endsAt: 0              // epoch ms, valid while running
  property real remainingMs: 0
  property real plannedMs: 0
  property int cyclesDone: 0           // focus blocks finished in the current set
  property string day: Pomo.todayKey()
  property int todayCount: 0
  property int todayMinutes: 0
  property bool dndBefore: false
  property bool dndApplied: false
  property bool overlayDismissed: false
  property int tipIndex: 0
  property bool hydrated: false

  property string subject: ""          // what this focus is for: free text or a Todoist task
  property string subjectTaskId: ""    // Todoist task id when the subject came from Todoist
  property bool subjectDone: false     // that task was marked done from here
  property var recentSubjects: []
  property real focusStartedAt: 0      // epoch ms; non-zero while a focus block is open
  property var pausedPlayers: []       // MPRIS bus names we paused for a break

  readonly property bool active: phase === "focus" || Pomo.isBreak(phase)
  readonly property bool isBreak: Pomo.isBreak(phase)
  readonly property bool paused: active && !running
  readonly property real progress: plannedMs > 0 ? Math.min(1, Math.max(0, 1 - remainingMs / plannedMs)) : 0
  readonly property string clock: Pomo.mmss(remainingMs)
  readonly property string phaseLabel: Pomo.phaseLabel(phase, readyNext)
  readonly property string icon: Pomo.phaseIcon(phase, running)
  readonly property var dots: Pomo.sessionDots(cyclesDone, config.longEvery, phase)
  readonly property string tip: Pomo.tipFor(tipIndex)

  readonly property bool dndWanted: config.dnd && phase === "focus" && running
  readonly property bool overlayVisible: hydrated && config.overlay && !overlayDismissed && (isBreak || phase === "ready")
  readonly property var players: Mpris.players ? Mpris.players.values : []

  // ------------------------------------------------------------------ engine

  function now() { return Date.now() }

  function tick() {
    if (!running) return
    var left = endsAt - now()
    if (left <= 0) {
      remainingMs = 0
      complete()
      return
    }
    remainingMs = left
  }

  function begin(nextPhase, minutes) {
    if (nextPhase === "focus") {
      endFocus("stopped")             // a preset clicked mid-focus restarts the block
      focusStartedAt = now()
      resumeMusic()
    } else {
      endFocus("skipped")
      if (phase === "focus") pauseMusic()
    }
    phase = nextPhase
    plannedMs = Math.max(1, minutes) * 60000
    remainingMs = plannedMs
    endsAt = now() + plannedMs
    running = true
    overlayDismissed = false
    tipIndex += 1
    persist()
  }

  function startFocus(minutes) {
    var m = Number(minutes) > 0 ? Number(minutes) : config.focus
    begin("focus", m)
  }

  function startBreak(kind, minutes) {
    var k = kind === "long" || kind === "short" ? kind : Pomo.nextBreakKind(cyclesDone, config.longEvery)
    var m = Number(minutes) > 0 ? Number(minutes) : (k === "long" ? config.longBreak : config.shortBreak)
    begin(k, m)
  }

  function enterReady(next) {
    if (phase === "focus") {
      endFocus("skipped")             // no-op after complete(), which already logged "done"
      pauseMusic()
    }
    phase = "ready"
    readyNext = next === "break" ? "break" : "focus"
    running = false
    remainingMs = 0
    plannedMs = 0
    endsAt = 0
    overlayDismissed = false
    persist()
  }

  function complete() {
    running = false
    if (phase === "focus") {
      endFocus("done")
      cyclesDone += 1
      chime(config.soundFocusEnd)
      var kind = Pomo.nextBreakKind(cyclesDone, config.longEvery)
      var mins = kind === "long" ? config.longBreak : config.shortBreak
      notify("Focus complete", (kind === "long" ? "Long break — " : "Break — ") + mins + " min", "󰅶")
      if (config.autoStartBreak) startBreak(kind, 0)
      else enterReady("break")
    } else if (isBreak) {
      if (phase === "long") cyclesDone = 0
      chime(config.soundBreakEnd)
      notify("Break over", "Next: " + config.focus + " min focus", "󰧐")
      if (config.autoStartFocus) startFocus(0)
      else enterReady("focus")
    } else {
      stop()
    }
  }

  function pause() {
    if (!active || !running) return
    remainingMs = Math.max(0, endsAt - now())
    running = false
    persist()
  }

  function resume() {
    if (!active || running) return
    endsAt = now() + remainingMs
    running = true
    persist()
  }

  function toggle() {
    if (phase === "idle") startFocus(0)
    else if (phase === "ready") { if (readyNext === "break") startBreak("", 0); else startFocus(0) }
    else if (running) pause()
    else resume()
  }

  function start() {
    if (active && running) return
    toggle()
  }

  function skip() {
    if (phase === "focus") {
      running = false
      cyclesDone += 1
      var kind = Pomo.nextBreakKind(cyclesDone, config.longEvery)
      if (config.autoStartBreak) startBreak(kind, 0)
      else enterReady("break")
    } else if (isBreak) {
      if (phase === "long") cyclesDone = 0
      startFocus(0)
    } else if (phase === "ready") {
      toggle()
    }
  }

  function stop() {
    endFocus("stopped")
    resumeMusic()
    phase = "idle"
    readyNext = "focus"
    running = false
    remainingMs = 0
    plannedMs = 0
    endsAt = 0
    cyclesDone = 0
    overlayDismissed = false
    persist()
  }

  function extend(minutes) {
    var ms = Number(minutes) * 60000
    if (!ms || !active) return
    if (running) {
      endsAt += ms
      remainingMs = Math.max(0, endsAt - now())
    } else {
      remainingMs = Math.max(0, remainingMs + ms)
    }
    plannedMs = Math.max(plannedMs + ms, remainingMs, 60000)
    if (running && remainingMs <= 0) { complete(); return }
    persist()
  }

  function dismissOverlay() { overlayDismissed = true }
  function showOverlay() { overlayDismissed = false }

  function rollDay() {
    var today = Pomo.todayKey()
    if (day === today) return false
    day = today
    todayCount = 0
    todayMinutes = 0
    return true
  }

  // Close the open focus block: count the minutes actually focused (paused
  // time excluded) and log it. Blocks under a minute are dropped as misclicks.
  function endFocus(outcome) {
    if (!focusStartedAt) return
    var left = running ? Math.max(0, endsAt - now()) : remainingMs
    var focusedMs = outcome === "done" ? plannedMs : Math.max(0, plannedMs - left)
    var entry = Pomo.focusEntry(focusStartedAt, now(), focusedMs, plannedMs, outcome,
                                subject, subjectDone ? "" : subjectTaskId)
    focusStartedAt = 0
    if (entry.minutes < 1) return
    rollDay()
    if (outcome === "done") todayCount += 1
    todayMinutes += entry.minutes
    recordFocus(entry)
  }

  // ------------------------------------------------------------------ subject

  function setSubject(text, taskId) {
    var s = Pomo.cleanSubject(text)
    subject = s
    subjectTaskId = s ? Pomo.cleanTaskId(taskId) : ""
    subjectDone = false
    if (s) recentSubjects = Pomo.addRecent(recentSubjects, s)
    persist()
  }

  function pickSubject() {
    if (cliPath) Quickshell.execDetached(["bash", cliPath, "subject"])
  }

  function todoistDone() {
    if (!subjectTaskId || subjectDone || todoistCloser.running || !todoistPath) return
    todoistCloser.taskId = subjectTaskId
    todoistCloser.label = subject
    todoistCloser.command = ["python3", todoistPath, "close", subjectTaskId]
    todoistCloser.running = true
  }

  Process {
    id: todoistCloser
    property string taskId: ""
    property string label: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = Pomo.parseState(text) || { ok: false, error: "no answer from pomo-todoist" }
        if (r.ok) {
          // The subject may have changed while the request was in flight.
          if (root.subjectTaskId === todoistCloser.taskId) {
            root.subjectDone = true
            root.persist()
          }
          root.recordDone(Pomo.doneEntry(root.now(), todoistCloser.label, todoistCloser.taskId))
          root.notify("Done in Todoist", todoistCloser.label, "󰄬")
        } else {
          root.notify("Todoist", String(r.error || "could not close the task"), "󰀦")
        }
      }
    }
  }

  // ------------------------------------------------------------------ history

  function recordFocus(entry) { writeHistory("append", entry) }
  function recordDone(entry) { if (entry.taskId) writeHistory("done", entry) }

  function writeHistory(verb, entry) {
    if (!historyPath) return
    var cmd = ["python3", historyPath, verb, JSON.stringify(entry)]
    if (config.studyLog) cmd.push("--log", config.studyLog)
    historyWriter.queue.push(cmd)
    historyWriter.next()
  }

  // One write at a time so two blocks ending together can't interleave lines.
  Process {
    id: historyWriter
    property var queue: []
    function next() {
      if (running || !queue.length) return
      command = queue.shift()
      running = true
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) root.notify("Study log", text.trim().replace(/^pomo-history: /, ""), "󰀦")
    }
    onExited: Qt.callLater(next)
  }

  // ------------------------------------------------------------------ music

  function pauseMusic() {
    if (!config.music) return
    var list = Pomo.playersToPause(players)
    var keys = pausedPlayers.slice()
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (p.canPause) p.pause()
      else p.togglePlaying()
      if (keys.indexOf(p.dbusName) === -1) keys.push(p.dbusName)
    }
    pausedPlayers = keys
  }

  // Resume only what pauseMusic stopped, and only if it's still paused:
  // something you paused or switched yourself during the break stays put.
  function resumeMusic() {
    var keys = pausedPlayers
    pausedPlayers = []
    if (!config.music || !keys.length) return
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || p.isPlaying || keys.indexOf(p.dbusName) === -1) continue
      if (p.canPlay) p.play()
      else if (p.canTogglePlaying) p.togglePlaying()
    }
  }

  // ------------------------------------------------------------------ effects

  onDndWantedChanged: { dndTries = 0; syncDnd() }

  // DND goes through the notifications plugin's IPC: the scoped plugin API
  // doesn't hand third-party plugins the notifications service.
  property int dndTries: 0

  function syncDnd() {
    if (dndWanted && !dndApplied) {
      if (dndReader.running || dndTries >= 5) return
      dndTries += 1
      dndReader.running = true          // continues in onStreamFinished
    } else if (!dndWanted && dndApplied) {
      Quickshell.execDetached([omarchyPath + "/bin/omarchy-shell", "notifications", "setDnd", dndBefore ? "on" : "off"])
      dndApplied = false
      persist()
    }
  }

  Process {
    id: dndReader
    command: [root.omarchyPath + "/bin/omarchy-shell", "notifications", "dndState"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = text.trim()
        if (!root.dndWanted || root.dndApplied || (state !== "on" && state !== "off")) return
        root.dndBefore = state === "on"
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-shell", "notifications", "setDnd", "on"])
        root.dndApplied = true
        root.persist()
      }
    }
  }

  // The notifications plugin may come up after us; keep trying while the
  // wanted and applied DND states disagree.
  Timer {
    interval: 2000
    repeat: true
    running: root.hydrated && root.dndWanted !== root.dndApplied && root.dndTries < 5
    onTriggered: root.syncDnd()
  }

  function chime(path) {
    if (!config.sound || !path) return
    Quickshell.execDetached(["bash", "-c", 'pw-play --volume=0.9 "$1" 2>/dev/null || paplay "$1"', "_", path])
  }

  function notify(title, body, glyph) {
    if (!config.notify) return
    Quickshell.execDetached([omarchyPath + "/bin/omarchy-notification-send", "--app-name", "uni-pomo", "-g", glyph, "-u", "normal", title, body])
  }

  // ------------------------------------------------------------------ persistence

  function statusJson() {
    return JSON.stringify({
      phase: phase, label: phaseLabel, readyNext: readyNext,
      running: running, paused: paused,
      remaining: clock, remainingMs: Math.round(remainingMs), plannedMs: Math.round(plannedMs),
      progress: Math.round(progress * 1000) / 1000,
      cyclesDone: cyclesDone, longEvery: config.longEvery,
      todayCount: todayCount, todayMinutes: todayMinutes,
      dnd: dndApplied, breakScreen: overlayVisible,
      subject: subject, subjectTaskId: subjectTaskId, subjectDone: subjectDone,
      recentSubjects: recentSubjects, musicPaused: pausedPlayers.length,
      config: config
    })
  }

  function persist() {
    if (!hydrated) return
    stateFile.setText(JSON.stringify({
      version: 1, phase: phase, readyNext: readyNext, running: running,
      endsAt: endsAt, remainingMs: remainingMs, plannedMs: plannedMs,
      cyclesDone: cyclesDone, day: day, todayCount: todayCount, todayMinutes: todayMinutes,
      dndBefore: dndBefore, dndApplied: dndApplied, tipIndex: tipIndex,
      subject: subject, subjectTaskId: subjectTaskId, subjectDone: subjectDone,
      recentSubjects: recentSubjects, focusStartedAt: focusStartedAt,
      pausedPlayers: pausedPlayers
    }, null, 2) + "\n")
  }

  // Settings come from the bar widget a moment after load; restoring needs
  // them (staleAfter, dnd), so hold the state until they arrive or the
  // fallback fires.
  property var pendingState: null
  property bool hydrateTimedOut: false
  onEntryChanged: if (!hydrated && pendingState !== null) hydrate(pendingState)

  function hydrate(raw) {
    if (hydrated) return
    if (entry === null && !hydrateTimedOut) { pendingState = String(raw || ""); return }
    var s = Pomo.parseState(raw)
    hydrated = true
    if (!s) { rollDay(); return }

    day = String(s.day || day)
    todayCount = Number(s.todayCount || 0)
    todayMinutes = Number(s.todayMinutes || 0)
    rollDay()
    cyclesDone = Number(s.cyclesDone || 0)
    tipIndex = Number(s.tipIndex || 0)
    dndBefore = !!s.dndBefore
    dndApplied = !!s.dndApplied
    subject = Pomo.cleanSubject(s.subject)
    subjectTaskId = subject ? Pomo.cleanTaskId(s.subjectTaskId) : ""
    subjectDone = !!s.subjectDone
    recentSubjects = Pomo.addRecent(s.recentSubjects, "")
    pausedPlayers = Array.isArray(s.pausedPlayers) ? s.pausedPlayers.map(String) : []

    var p = String(s.phase || "idle")
    if (p === "focus" || p === "short" || p === "long") {
      plannedMs = Number(s.plannedMs || 0)
      if (s.running) {
        endsAt = Number(s.endsAt || 0)
        var left = endsAt - now()
        if (left < -config.staleAfter * 60000) {
          // Came back long after the block ended (reboot, overnight): drop it.
          phase = "idle"
          cyclesDone = 0
        } else {
          phase = p
          remainingMs = Math.max(0, left)
          running = true // an overdue block completes on the first tick
        }
      } else {
        phase = p
        remainingMs = Number(s.remainingMs || 0)
        running = false
      }
      if (phase === "focus") {
        focusStartedAt = Number(s.focusStartedAt || 0) || now() - Math.max(0, plannedMs - remainingMs)
      }
    } else if (p === "ready") {
      phase = "ready"
      readyNext = s.readyNext === "break" ? "break" : "focus"
    } else {
      phase = "idle"
    }
    syncDnd()
    persist()
  }

  // Write-only. The shell never reads the raw state path itself: `preload`
  // is off so this FileView only ever writes, and it writes atomically
  // (temp file + rename), so a symlink planted at the path is replaced, not
  // followed.
  FileView {
    id: stateFile
    path: root.statePath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // Reading goes through the bundled `pomo-state-read` helper instead of a
  // FileView on the predictable path: it opens the directory and the file
  // with O_NOFOLLOW (the file also O_NONBLOCK), fstat()s the already-open
  // descriptor (must be a regular file owned by us, at most 16 KiB), caps the
  // read, and prints only a whitelisted, range-checked object. A planted FIFO,
  // symlink or oversized file therefore cannot block or bloat the shell at
  // startup; the engine just starts fresh.
  Process {
    id: stateReader
    command: ["python3", root.stateReaderPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.hydrate(text)
    }
  }

  // If the helper could not run at all (no python, missing file), still
  // start the engine rather than sitting unhydrated forever.
  Timer {
    id: hydrateFallback
    interval: 5000
    onTriggered: {
      root.hydrateTimedOut = true
      root.hydrate(root.pendingState !== null ? root.pendingState : "")
    }
  }

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", root.stateDir])
    hydrateFallback.start()
    Qt.callLater(function() {
      if (root.stateReaderPath) stateReader.running = true
      else root.hydrate("")
    })
  }

  Timer {
    interval: 500
    repeat: true
    running: root.running
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  Timer {
    interval: 20000
    repeat: true
    running: root.overlayVisible
    onTriggered: root.tipIndex += 1
  }

  // Reset "today" at midnight even when no block finishes after it.
  Timer {
    interval: 60000
    repeat: true
    running: root.hydrated
    onTriggered: if (root.rollDay()) root.persist()
  }

  IpcHandler {
    target: "pomodoro"

    function status(): string { return root.statusJson() }
    function start(): string { root.start(); return root.statusJson() }
    function pause(): string { root.pause(); return root.statusJson() }
    function resume(): string { root.resume(); return root.statusJson() }
    function toggle(): string { root.toggle(); return root.statusJson() }
    function stop(): string { root.stop(); return root.statusJson() }
    function skip(): string { root.skip(); return root.statusJson() }
    function focus(minutes: string): string { root.startFocus(Number(minutes)); return root.statusJson() }
    function shortBreak(minutes: string): string { root.startBreak("short", Number(minutes)); return root.statusJson() }
    function longBreak(minutes: string): string { root.startBreak("long", Number(minutes)); return root.statusJson() }
    function extend(minutes: string): string { root.extend(Number(minutes)); return root.statusJson() }
    function hideBreak(): string { root.dismissOverlay(); return root.statusJson() }
    function showBreak(): string { root.showOverlay(); return root.statusJson() }
    function setSubject(text: string, taskId: string): string { root.setSubject(text, taskId); return root.statusJson() }
    function clearSubject(): string { root.setSubject("", ""); return root.statusJson() }
    function todoistDone(): string { root.todoistDone(); return root.statusJson() }
  }

  // ------------------------------------------------------------------ break screen

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      visible: root.overlayVisible
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "uni-pomodoro"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      readonly property color fg: Color.foreground
      readonly property color accent: Color.accent
      readonly property string fontFamily: Style.font.family
      readonly property int ringSize: Math.round(Math.min(win.width, win.height) * 0.36)
      readonly property int ringStroke: Math.max(4, Math.round(ringSize * 0.02))

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, root.config.overlayDim)
      }

      Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.dismissOverlay(); event.accepted = true }
          else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.phase === "ready") root.toggle(); else root.skip()
            event.accepted = true
          }
        }
      }

      Item {
        id: content
        anchors.fill: parent
        opacity: win.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

        Column {
          anchors.centerIn: parent
          spacing: Math.round(win.ringSize * 0.09)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.phaseLabel.toUpperCase()
            color: win.accent
            font.family: win.fontFamily
            font.pixelSize: Math.round(win.ringSize * 0.075)
            font.letterSpacing: Math.round(win.ringSize * 0.02)
            font.bold: true
          }

          Item {
            width: win.ringSize
            height: win.ringSize
            anchors.horizontalCenter: parent.horizontalCenter

            Shape {
              anchors.fill: parent
              preferredRendererType: Shape.CurveRenderer

              ShapePath {
                strokeColor: Util.alpha(win.fg, 0.12)
                strokeWidth: win.ringStroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: win.ringSize / 2; centerY: win.ringSize / 2
                  radiusX: win.ringSize / 2 - win.ringStroke; radiusY: radiusX
                  startAngle: -90; sweepAngle: 360
                }
              }

              ShapePath {
                strokeColor: win.accent
                strokeWidth: win.ringStroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: win.ringSize / 2; centerY: win.ringSize / 2
                  radiusX: win.ringSize / 2 - win.ringStroke; radiusY: radiusX
                  startAngle: -90
                  sweepAngle: root.phase === "ready" ? 360 : Math.max(0.01, 360 * (1 - root.progress))
                  Behavior on sweepAngle { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
                }
              }
            }

            Text {
              anchors.centerIn: parent
              text: root.phase === "ready" ? (root.readyNext === "break" ? "󰅶" : "󰧐") : root.clock
              color: root.paused ? Util.alpha(win.fg, 0.5) : win.fg
              font.family: win.fontFamily
              font.pixelSize: Math.round(win.ringSize * (root.phase === "ready" ? 0.34 : 0.24))
              font.bold: true
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(win.width * 0.7, win.ringSize * 2.2)
            horizontalAlignment: Text.AlignHCenter
            visible: root.subject !== ""
            elide: Text.ElideRight
            text: (root.subjectDone ? "󰄬  " : "") + root.subject
            textFormat: Text.PlainText // subjects can be Todoist titles: never render markup
            color: win.fg
            font.family: win.fontFamily
            font.pixelSize: Math.round(win.ringSize * 0.07)
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(win.width * 0.7, win.ringSize * 2.2)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.phase === "ready"
              ? (root.readyNext === "break" ? "Nice work. Take the break." : "Ready when you are.")
              : (root.paused ? "Paused." : root.tip)
            color: Util.alpha(win.fg, 0.72)
            font.family: win.fontFamily
            font.pixelSize: Math.round(win.ringSize * 0.06)
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Math.round(win.ringSize * 0.04)
            visible: root.dots.length > 0
            Repeater {
              model: root.dots
              Rectangle {
                required property string modelData
                width: Math.round(win.ringSize * 0.04)
                height: width
                radius: width / 2
                color: modelData === "done" ? win.accent
                     : modelData === "current" ? Util.alpha(win.accent, 0.35)
                     : Util.alpha(win.fg, 0.14)
                border.width: modelData === "current" ? 1 : 0
                border.color: win.accent
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(10)

            Button {
              visible: root.phase === "ready"
              iconText: root.readyNext === "break" ? "󰅶" : "󰐊"
              text: root.readyNext === "break"
                ? "Start break"
                : "Start " + root.config.focus + " min focus"
              foreground: win.fg
              accent: win.accent
              bordered: true
              selected: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.toggle()
            }
            Button {
              visible: root.isBreak
              iconText: root.running ? "󰏤" : "󰐊"
              text: root.running ? "Pause" : "Resume"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.toggle()
            }
            Button {
              visible: root.isBreak
              text: "+5 min"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.extend(5)
            }
            Button {
              visible: root.isBreak
              iconText: "󰒭"
              text: "Skip break"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.skip()
            }
            Button {
              visible: root.subjectTaskId !== "" && !root.subjectDone
              iconText: "󰄬"
              text: "Done in Todoist"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.todoistDone()
            }
            Button {
              iconText: "󰓛"
              text: "Stop"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.stop()
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.phase === "ready" ? "Enter starts · Esc hides" : "Space skips · Esc hides this screen"
            color: Util.alpha(win.fg, 0.35)
            font.family: win.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
