.pragma library

// Pure logic for rams.teams. No QML types in here on purpose: everything in
// this file is a plain function over plain values, so it can be reasoned about
// (and unit-tested with node) without a running shell.


// ---------------------------------------------------------------- constants

// Presence values as teams-for-linux publishes them (mqtt/index.js statusMap).
var TEAMS_GLYPH = "󰊻"

var PRESENCE = {
  available:      { label: "Available",     glyph: TEAMS_GLYPH, tone: "ok" },
  busy:           { label: "Busy",          glyph: TEAMS_GLYPH, tone: "busy" },
  do_not_disturb: { label: "Do not disturb", glyph: TEAMS_GLYPH, tone: "busy" },
  away:           { label: "Away",          glyph: TEAMS_GLYPH, tone: "idle" },
  be_right_back:  { label: "Be right back", glyph: TEAMS_GLYPH, tone: "idle" },
  offline:        { label: "Offline",       glyph: TEAMS_GLYPH, tone: "off" },
  unknown:        { label: "Unknown",       glyph: TEAMS_GLYPH, tone: "off" }
}

var MIC = {
  speaking: { label: "Speaking",  glyph: "󰍬", tone: "ok" },
  silent:   { label: "Unmuted",   glyph: "󰍬", tone: "normal" },
  muted:    { label: "Muted",     glyph: "󰍭", tone: "busy" },
  off:      { label: "Mic off",   glyph: "󰍭", tone: "off" }
}

// Actions teams-for-linux accepts on the command topic. Anything not in this
// list is rejected by the app anyway (it whitelists), so we mirror the list
// rather than letting a typo travel all the way to the broker.
var ACTIONS = ["toggle-mute", "mute", "unmute", "toggle-video", "toggle-hand-raise", "get-calendar"]

// ---------------------------------------------------------------- parsing

function parseLine(line) {
  var text = String(line || "").trim()
  if (!text) return null
  try {
    var obj = JSON.parse(text)
    return (obj && typeof obj === "object") ? obj : null
  } catch (e) {
    return null
  }
}

function boolOf(payload) {
  var v = String(payload === undefined || payload === null ? "" : payload).trim().toLowerCase()
  return v === "true" || v === "1" || v === "on" || v === "yes"
}

// teams/status carries JSON ({status, statusCode, ...}); everything else on
// that topic is treated as a bare string so a simpler publisher still works.
function presenceFrom(payload) {
  var raw = String(payload || "").trim()
  if (!raw) return "unknown"
  if (raw.charAt(0) === "{") {
    try {
      var obj = JSON.parse(raw)
      if (obj && obj.status) return normalizePresence(obj.status)
    } catch (e) { /* fall through to the bare-string reading */ }
  }
  return normalizePresence(raw)
}

function normalizePresence(value) {
  var key = String(value || "").trim().toLowerCase().replace(/[\s-]+/g, "_")
  if (key === "dnd") key = "do_not_disturb"
  if (key === "brb") key = "be_right_back"
  return PRESENCE[key] ? key : "unknown"
}

function presenceInfo(key) {
  return PRESENCE[normalizePresence(key)] || PRESENCE.unknown
}

function micInfo(state) {
  var key = String(state || "off").trim().toLowerCase()
  return MIC[key] || MIC.off
}

// Strip the configured prefix so the service switches on "in-call" rather than
// "teams/in-call", and a custom topicPrefix costs nothing.
function subtopic(topic, prefix) {
  var t = String(topic || "")
  var p = String(prefix || "teams") + "/"
  return t.indexOf(p) === 0 ? t.slice(p.length) : t
}

// ---------------------------------------------------------------- bar state
//
// One place decides what the widget shows, so the QML stays declarative and
// this stays testable. Order matters: the most urgent thing wins the icon.

function barState(s) {
  if (!s.bridgeReady) return { glyph: TEAMS_GLYPH, label: "Teams bridge starting", tone: "off", show: false }
  if (!s.teamsConnected) return { glyph: TEAMS_GLYPH, label: "Teams not running", tone: "off", show: !!s.showWhenClosed }

  if (s.incomingCall)
    return { glyph: "󰕿", label: "Incoming call", tone: "urgent", show: true, pulse: true }
  if (s.screenSharing)
    return { glyph: "󰍹", label: "Sharing your screen", tone: "urgent", show: true, pulse: true }
  if (s.inCall) {
    var mic = micInfo(s.microphone)
    return {
      glyph: mic.glyph,
      label: "In a call · " + mic.label,
      tone: s.microphone === "muted" ? "busy" : "ok",
      show: true,
      pulse: false
    }
  }
  if (s.meetingStarted)
    return { glyph: "󰐌", label: "Meeting starting", tone: "urgent", show: true, pulse: true }

  var p = presenceInfo(s.presence)
  return { glyph: p.glyph, label: p.label, tone: p.tone, show: true, pulse: false }
}

// A compact secondary line for the popup header.
function statusSummary(s) {
  if (!s.bridgeReady) return "Bridge starting…"
  if (!s.teamsConnected) return "Teams for Linux is not running"
  var bits = []
  if (s.inCall) bits.push("In a call")
  if (s.screenSharing) bits.push("sharing screen")
  if (s.camera) bits.push("camera on")
  if (s.inCall) bits.push(micInfo(s.microphone).label.toLowerCase())
  if (!bits.length) return presenceInfo(s.presence).label
  return bits.join(" · ")
}

// ---------------------------------------------------------------- colors

function clamp255(n) { return Math.max(0, Math.min(255, Math.round(n))) }

function hexToRgb(hex) {
  var h = String(hex || "").replace("#", "").trim()
  if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
  if (h.length === 8) h = h.slice(0, 6)          // drop alpha
  if (h.length !== 6) return { r: 0, g: 0, b: 0 }
  return {
    r: parseInt(h.slice(0, 2), 16),
    g: parseInt(h.slice(2, 4), 16),
    b: parseInt(h.slice(4, 6), 16)
  }
}

function rgbToHex(c) {
  function two(n) { var s = clamp255(n).toString(16); return s.length === 1 ? "0" + s : s }
  return "#" + two(c.r) + two(c.g) + two(c.b)
}

function mix(a, b, t) {
  var x = hexToRgb(a), y = hexToRgb(b)
  return rgbToHex({
    r: x.r + (y.r - x.r) * t,
    g: x.g + (y.g - x.g) * t,
    b: x.b + (y.b - x.b) * t
  })
}

function rgba(hex, alpha) {
  var c = hexToRgb(hex)
  return "rgba(" + c.r + ", " + c.g + ", " + c.b + ", " + alpha + ")"
}

function luminance(hex) {
  var c = hexToRgb(hex)
  return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255
}

function isDark(hex) { return luminance(hex) < 0.5 }

// ---------------------------------------------------------------- theme css
//
// Teams V2 is a Fluent UI v9 app that draws almost everything from CSS custom
// properties — but NOT from :root. Fluent mounts a .fui-FluentProvider element
// and defines the whole token set there, and custom properties inherit from
// the nearest definition, so anything set only on :root is silently shadowed
// for every element inside the app. The overrides therefore target the
// provider itself, and carry !important so they beat Fluent's own
// declarations on the same element. Verified against the live DOM over the
// DevTools protocol. Anything Teams hardcodes outside the token system stays
// as Microsoft shipped it.

function themeCss(theme) {
  var bg = theme.background || "#101315"
  var fg = theme.foreground || "#cacccc"
  var accent = theme.accent || fg
  var dark = isDark(bg)

  // Build a small ramp around the base background so surfaces stay distinct.
  var step = dark ? "#ffffff" : "#000000"
  var s1 = bg
  var s2 = mix(bg, step, 0.04)
  var s3 = mix(bg, step, 0.08)
  var s4 = mix(bg, step, 0.12)
  var s5 = mix(bg, step, 0.16)
  var stroke = mix(bg, step, 0.20)
  var strokeSoft = mix(bg, step, 0.12)

  var fg2 = mix(fg, bg, 0.25)
  var fg3 = mix(fg, bg, 0.45)
  var fg4 = mix(fg, bg, 0.60)

  var onAccent = isDark(accent) ? "#ffffff" : "#101315"
  var accentHover = mix(accent, step, 0.12)
  var accentPressed = mix(accent, dark ? "#000000" : "#ffffff", 0.12)

  var radius = Math.max(0, Number(theme.cornerRadius || 0))

  var lines = []
  lines.push("/* Generated by the rams.teams Omarchy plugin. Do not edit by hand:")
  lines.push("   it is rewritten whenever the Omarchy theme changes. */")
  lines.push(":root, body, .fui-FluentProvider, [class*=\"fui-FluentProvider\"] {")
  lines.push("  --colorNeutralBackground1: " + s1 + " !important;")
  lines.push("  --colorNeutralBackground1Hover: " + s2 + " !important;")
  lines.push("  --colorNeutralBackground1Pressed: " + s3 + " !important;")
  lines.push("  --colorNeutralBackground1Selected: " + s3 + " !important;")
  lines.push("  --colorNeutralBackground2: " + s2 + " !important;")
  lines.push("  --colorNeutralBackground3: " + s3 + " !important;")
  lines.push("  --colorNeutralBackground4: " + s4 + " !important;")
  lines.push("  --colorNeutralBackground5: " + s5 + " !important;")
  lines.push("  --colorNeutralBackground6: " + s4 + " !important;")
  lines.push("  --colorNeutralBackgroundInverted: " + fg + " !important;")
  lines.push("  --colorNeutralBackgroundStatic: " + s3 + " !important;")
  lines.push("  --colorSubtleBackground: transparent !important;")
  lines.push("  --colorSubtleBackgroundHover: " + rgba(fg, 0.08) + " !important;")
  lines.push("  --colorSubtleBackgroundPressed: " + rgba(fg, 0.12) + " !important;")
  lines.push("  --colorSubtleBackgroundSelected: " + rgba(accent, 0.16) + " !important;")
  lines.push("")
  lines.push("  --colorNeutralForeground1: " + fg + " !important;")
  lines.push("  --colorNeutralForeground1Hover: " + fg + " !important;")
  lines.push("  --colorNeutralForeground1Static: " + fg + " !important;")
  lines.push("  --colorNeutralForeground2: " + fg2 + " !important;")
  lines.push("  --colorNeutralForeground2Hover: " + fg + " !important;")
  lines.push("  --colorNeutralForeground3: " + fg3 + " !important;")
  lines.push("  --colorNeutralForeground4: " + fg4 + " !important;")
  lines.push("  --colorNeutralForegroundDisabled: " + fg4 + " !important;")
  lines.push("  --colorNeutralForegroundInverted: " + bg + " !important;")
  lines.push("  --colorNeutralForegroundOnBrand: " + onAccent + " !important;")
  lines.push("")
  lines.push("  --colorNeutralStroke1: " + stroke + " !important;")
  lines.push("  --colorNeutralStroke2: " + strokeSoft + " !important;")
  lines.push("  --colorNeutralStroke3: " + strokeSoft + " !important;")
  lines.push("  --colorNeutralStrokeAccessible: " + fg3 + " !important;")
  lines.push("  --colorTransparentStroke: transparent !important;")
  lines.push("")
  lines.push("  --colorBrandBackground: " + accent + " !important;")
  lines.push("  --colorBrandBackgroundHover: " + accentHover + " !important;")
  lines.push("  --colorBrandBackgroundPressed: " + accentPressed + " !important;")
  lines.push("  --colorBrandBackgroundSelected: " + accentHover + " !important;")
  lines.push("  --colorBrandBackground2: " + rgba(accent, 0.16) + " !important;")
  lines.push("  --colorBrandBackgroundStatic: " + accent + " !important;")
  lines.push("  --colorBrandForeground1: " + accent + " !important;")
  lines.push("  --colorBrandForeground2: " + accentHover + " !important;")
  lines.push("  --colorBrandForegroundLink: " + accent + " !important;")
  lines.push("  --colorBrandForegroundLinkHover: " + accentHover + " !important;")
  lines.push("  --colorBrandStroke1: " + accent + " !important;")
  lines.push("  --colorBrandStroke2: " + rgba(accent, 0.4) + " !important;")
  lines.push("  --colorCompoundBrandBackground: " + accent + " !important;")
  lines.push("  --colorCompoundBrandBackgroundHover: " + accentHover + " !important;")
  lines.push("  --colorCompoundBrandForeground1: " + accent + " !important;")
  lines.push("  --colorCompoundBrandStroke: " + accent + " !important;")
  lines.push("")
  lines.push("  --colorNeutralShadowAmbient: " + rgba("#000000", dark ? 0.5 : 0.12) + " !important;")
  lines.push("  --colorNeutralShadowKey: " + rgba("#000000", dark ? 0.6 : 0.16) + " !important;")
  if (radius > 0) {
    lines.push("  --borderRadiusMedium: " + Math.min(radius, 8) + "px !important;")
    lines.push("  --borderRadiusLarge: " + Math.min(radius, 12) + "px !important;")
    lines.push("  --borderRadiusXLarge: " + radius + "px !important;")
  }
  lines.push("}")
  lines.push("")
  lines.push("/* The title bar and app chrome sit outside the token set. */")
  lines.push("html, body { background: " + bg + " !important; }")
  lines.push(".app-layout, #app { background: " + bg + " !important; }")

  if (theme.fontFamily) {
    lines.push("")
    lines.push("/* Match the Omarchy UI font. */")
    lines.push(":root, .fui-FluentProvider, [class*=\"fui-FluentProvider\"] { --fontFamilyBase: "
               + JSON.stringify(String(theme.fontFamily))
               + ", 'Segoe UI', system-ui, sans-serif !important; }")
  }

  if (theme.hideAvatars) {
    lines.push("")
    lines.push(".ui-avatar, [data-tid='avatar'] { filter: grayscale(1); }")
  }

  return lines.join("\n") + "\n"
}

// ---------------------------------------------------------------- tfl config
//
// The set of teams-for-linux settings this plugin needs in order to work. It is
// merged into the user's existing config.json rather than replacing it, so
// anything else they have configured survives untouched.

function teamsConfigPatch(opts) {
  var patch = {
    mqtt: {
      enabled: true,
      brokerUrl: "mqtt://" + (opts.host || "127.0.0.1") + ":" + (opts.port || 1883),
      clientId: opts.clientId || "teams-for-linux",
      topicPrefix: opts.prefix || "teams",
      statusTopic: "status",
      // Without a command topic the app never subscribes, and the mute/video
      // keybinds have nowhere to land.
      commandTopic: opts.commandTopic || "command",
      meetingStartDetection: {
        enabled: opts.meetingStartDetection !== false,
        resetSeconds: 10
      }
    }
  }
  if (opts.cssPath) patch.customCSSLocation = opts.cssPath
  return patch
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v)
}

// Recursive merge that leaves keys the patch does not mention alone.
function deepMerge(base, patch) {
  var out = isPlainObject(base) ? JSON.parse(JSON.stringify(base)) : {}
  for (var k in patch) {
    if (!patch.hasOwnProperty(k)) continue
    if (isPlainObject(patch[k])) out[k] = deepMerge(out[k], patch[k])
    else out[k] = patch[k]
  }
  return out
}

// True when `config` already satisfies everything in `patch`, so the service can
// skip rewriting (and restarting) when there is nothing to change.
function configSatisfies(config, patch) {
  for (var k in patch) {
    if (!patch.hasOwnProperty(k)) continue
    if (isPlainObject(patch[k])) {
      if (!isPlainObject(config ? config[k] : null)) return false
      if (!configSatisfies(config[k], patch[k])) return false
    } else if (!config || config[k] !== patch[k]) {
      return false
    }
  }
  return true
}

function commandPayload(action, extra) {
  var obj = { action: String(action) }
  if (isPlainObject(extra)) {
    for (var k in extra) if (extra.hasOwnProperty(k)) obj[k] = extra[k]
  }
  return JSON.stringify(obj)
}

function isAllowedAction(action) {
  return ACTIONS.indexOf(String(action)) !== -1
}

// ---------------------------------------------------------------- calendar

// Shape the get-calendar reply into the few fields the popup renders.
function parseCalendar(payload) {
  var raw = String(payload || "").trim()
  if (!raw) return []
  var data
  try { data = JSON.parse(raw) } catch (e) { return [] }
  var items = []
  var list = Array.isArray(data) ? data
    : (data && Array.isArray(data.events) ? data.events
      : (data && Array.isArray(data.value) ? data.value : []))
  for (var i = 0; i < list.length; i++) {
    var ev = list[i]
    if (!ev) continue
    var start = ev.start && ev.start.dateTime ? ev.start.dateTime : ev.start
    var end = ev.end && ev.end.dateTime ? ev.end.dateTime : ev.end
    items.push({
      subject: String(ev.subject || ev.title || "(no subject)"),
      start: String(start || ""),
      end: String(end || ""),
      joinUrl: String(ev.joinUrl || (ev.onlineMeeting && ev.onlineMeeting.joinUrl) || ""),
      organizer: String(
        (ev.organizer && ev.organizer.emailAddress && ev.organizer.emailAddress.name) || ""
      )
    })
  }
  items.sort(function (a, b) { return String(a.start).localeCompare(String(b.start)) })
  return items
}

// Minutes until an ISO timestamp, or null when it is unparseable.
function minutesUntil(iso, nowMs) {
  var t = Date.parse(String(iso || ""))
  if (!isFinite(t)) return null
  return Math.round((t - nowMs) / 60000)
}

function nextEvent(events, nowMs) {
  for (var i = 0; i < events.length; i++) {
    var m = minutesUntil(events[i].end || events[i].start, nowMs)
    if (m !== null && m > 0) return events[i]
  }
  return null
}

function formatWhen(iso, nowMs) {
  var m = minutesUntil(iso, nowMs)
  if (m === null) return ""
  if (m < 0) return "now"
  if (m === 0) return "now"
  if (m < 60) return "in " + m + " min"
  var h = Math.floor(m / 60)
  var rem = m % 60
  return "in " + h + "h" + (rem ? " " + rem + "m" : "")
}
