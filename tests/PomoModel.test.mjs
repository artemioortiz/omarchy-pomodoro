// node --test tests/*.test.mjs
// PomoModel.js is a QML `.pragma library` script, not a module: load it by
// dropping the pragma and returning its top-level functions.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../PomoModel.js", import.meta.url), "utf8").replace(/^\.pragma library$/m, "")
const names = [...src.matchAll(/^function (\w+)/gm)].map((m) => m[1])
const Pomo = new Function(`${src}\nreturn { DEFAULTS, ${names.join(", ")} }`)()

test("config fills in the new settings", () => {
  const c = Pomo.config({})
  assert.equal(c.music, true)
  assert.equal(c.showSubject, true)
  assert.equal(c.todoistFilter, "today | overdue")
  assert.equal(c.studyLog, "")
  const d = Pomo.config({ music: "false", todoistFilter: "##WGU | @study", studyLog: "~/Obsidian/Journal/Study log.md" })
  assert.equal(d.music, false)
  assert.equal(d.todoistFilter, "##WGU | @study")
  assert.equal(d.studyLog, "~/Obsidian/Journal/Study log.md")
})

test("cleanSubject flattens control characters and caps length", () => {
  assert.equal(Pomo.cleanSubject("  D340\tch.4\nreading  "), "D340 ch.4 reading")
  assert.equal(Pomo.cleanSubject(null), "")
  assert.equal(Pomo.cleanSubject("x".repeat(300)).length, 120)
})

test("cleanTaskId only accepts plain ids", () => {
  assert.equal(Pomo.cleanTaskId("6X7rM8997g3RQmvh"), "6X7rM8997g3RQmvh")
  assert.equal(Pomo.cleanTaskId("../close"), "")
  assert.equal(Pomo.cleanTaskId(""), "")
})

test("addRecent puts the newest first, dedupes and caps", () => {
  assert.deepEqual(Pomo.addRecent(["A", "B"], "b"), ["b", "A"])
  assert.deepEqual(Pomo.addRecent(["A"], ""), ["A"])
  const many = Array.from({ length: 20 }, (_, i) => "s" + i)
  assert.equal(Pomo.addRecent(many, "new").length, 8)
})

test("shorten adds an ellipsis only when needed", () => {
  assert.equal(Pomo.shorten("short", 10), "short")
  assert.equal(Pomo.shorten("a longer subject", 8), "a longe…")
})

test("focusEntry rounds minutes and normalizes fields", () => {
  const e = Pomo.focusEntry(1000, 2000, 12.6 * 60000, 25 * 60000, "skipped", " D340 ", "bad id!", "Song — Artist")
  assert.deepEqual(e, {
    start: 1000, end: 2000, minutes: 13, planned: 25, outcome: "skipped",
    subject: "D340", taskId: "", track: "Song — Artist"
  })
  assert.equal(Pomo.focusEntry(0, 0, 0, 0, "weird", "", "", "").outcome, "done")
})

test("playersToPause skips proxies, idle and uncontrollable players", () => {
  const players = [
    { dbusName: "org.mpris.MediaPlayer2.playerctld", isPlaying: true, canPause: true },
    { dbusName: "org.mpris.MediaPlayer2.chromium.instance42", isPlaying: true, canPause: true },
    { dbusName: "org.mpris.MediaPlayer2.spotify", isPlaying: false, canPause: true },
    { dbusName: "org.mpris.MediaPlayer2.mpv", isPlaying: true, canPause: false, canTogglePlaying: false },
    { dbusName: "org.mpris.MediaPlayer2.pandora", isPlaying: true, canPause: false, canTogglePlaying: true }
  ]
  assert.deepEqual(Pomo.playersToPause(players).map((p) => p.dbusName), [
    "org.mpris.MediaPlayer2.chromium.instance42",
    "org.mpris.MediaPlayer2.pandora"
  ])
})

test("trackLabel prefers title and artist, then the app", () => {
  assert.equal(Pomo.trackLabel({ trackTitle: "Lofi", trackArtist: "Girl" }), "Lofi — Girl")
  assert.equal(Pomo.trackLabel({ trackTitle: "Audio Overview" }), "Audio Overview")
  assert.equal(Pomo.trackLabel({ identity: "Brave" }), "Brave")
  assert.equal(Pomo.trackLabel(null), "")
  // pomo-state-read accepts at most 200 characters
  assert.equal(Pomo.trackLabel({ trackTitle: "t".repeat(120), trackArtist: "a".repeat(120) }).length, 200)
})

test("firstPlaying ignores the playerctld proxy", () => {
  const p = Pomo.firstPlaying([
    { dbusName: "org.mpris.MediaPlayer2.playerctld", isPlaying: true },
    { dbusName: "org.mpris.MediaPlayer2.spotify", isPlaying: true }
  ])
  assert.equal(p.dbusName, "org.mpris.MediaPlayer2.spotify")
})
