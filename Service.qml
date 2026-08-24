// rams.teams — service half.
//
// Owns everything that is not pixels: the bridge process, the live Teams state,
// the meeting-mode side effects, the toasts, the theme file, and the IPC surface
// that Hyprland keybinds talk to. BarWidget.qml reads properties off this object
// and never touches the bridge itself.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: service

  // Injected by the shell's service loader.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/teams.json"
  readonly property string tflConfigDir: home + "/.config/teams-for-linux"
  readonly property string tflConfigPath: tflConfigDir + "/config.json"
  readonly property string cssPath: tflConfigDir + "/omarchy-theme.css"
  // The bridge ships inside the plugin rather than on PATH, so installing it is
  // nothing more than cloning the repo. Resolved from this file's own URL
  // because the directory is named after the manifest id, which the user is
  // free to change.
  readonly property string bridgePath: String(Qt.resolvedUrl("bin/omarchy-teams-bridge")).replace(/^file:\/\//, "")
  readonly property string cliPath: String(Qt.resolvedUrl("bin/omarchy-teams")).replace(/^file:\/\//, "")

  // ------------------------------------------------------------------ config

  readonly property var defaultConfig: ({
    broker: { host: "127.0.0.1", port: 1883, prefix: "teams", commandTopic: "command" },
    meetingMode: { enabled: true, stayAwake: true, doNotDisturb: true },
    notifications: { incomingCall: true, meetingStarting: true, callEnded: false },
    theme: { sync: true, fontFamily: "", hideAvatars: false },
    manageTeamsConfig: true,
    windowClass: "teams-for-linux",
    // Empty means "use the plugin CLI", which resolves the real binary (the
    // AUR package installs to /opt with nothing on PATH) and carries the
    // Wayland/X11 launch flags from the managed desktop entry.
    launchCommand: ""
  })

  property var config: defaultConfig

  function cfg(section, key, fallback) {
    var s = config && config[section] ? config[section] : null
    if (s && s[key] !== undefined && s[key] !== null) return s[key]
    var d = defaultConfig[section]
    if (d && d[key] !== undefined) return d[key]
    return fallback
  }

  function cfgTop(key, fallback) {
    if (config && config[key] !== undefined && config[key] !== null) return config[key]
    return defaultConfig[key] !== undefined ? defaultConfig[key] : fallback
  }

  readonly property string prefix: String(cfg("broker", "prefix", "teams"))
  readonly property string commandTopic: prefix + "/" + String(cfg("broker", "commandTopic", "command"))

  FileView {
    id: configFile
    path: service.configPath
    watchChanges: true
    printErrors: false
    onLoaded: service.applyConfig(text())
    onLoadFailed: service.applyConfig("")
    onFileChanged: reload()
  }

  function applyConfig(text) {
    var parsed = null
    if (text && String(text).trim()) {
      try {
        parsed = JSON.parse(text)
      } catch (e) {
        service.lastError = "teams.json is not valid JSON"
        console.warn("rams.teams: " + service.lastError + ": " + e)
      }
    }
    config = Model.deepMerge(defaultConfig, Model.isPlainObject(parsed) ? parsed : {})
    // A changed broker endpoint has to reach both ends: our bridge and the
    // teams-for-linux config that points at it.
    reconcileTeamsConfig()
    restartBridgeSoon()
  }

  // ------------------------------------------------------------------- state

  property bool bridgeReady: false
  property string bridgeMode: ""
  property bool teamsConnected: false
  property string presence: "unknown"
  property bool inCall: false
  property bool incomingCall: false
  property bool camera: false
  property string microphone: "off"
  property bool screenSharing: false
  property bool meetingStarted: false
  property string lastError: ""
  property var calendar: []
  property double calendarFetchedAt: 0

  // Snapshot the widget binds to, so one property change repaints once.
  readonly property var barState: Model.barState({
    bridgeReady: bridgeReady,
    teamsConnected: teamsConnected,
    presence: presence,
    inCall: inCall,
    incomingCall: incomingCall,
    camera: camera,
    microphone: microphone,
    screenSharing: screenSharing,
    meetingStarted: meetingStarted,
    showWhenClosed: true
  })

  readonly property string summary: Model.statusSummary({
    bridgeReady: bridgeReady,
    teamsConnected: teamsConnected,
    presence: presence,
    inCall: inCall,
    camera: camera,
    microphone: microphone,
    screenSharing: screenSharing
  })

  // ------------------------------------------------------------------ bridge

  Process {
    id: bridge
    running: false
    stdinEnabled: true
    stdout: SplitParser { onRead: function (line) { service.onBridgeLine(line) } }
    stderr: SplitParser {
      onRead: function (line) {
        if (String(line).trim()) console.warn("rams.teams bridge: " + line)
      }
    }
    onExited: function (exitCode) {
      service.bridgeReady = false
      service.teamsConnected = false
      if (exitCode !== 0) service.lastError = "bridge exited (" + exitCode + ")"
      // The bridge dying mid-call would otherwise leave the desktop pinned in
      // meeting mode with no way to learn the call ended.
      service.setInCall(false)
      if (service.enabled) bridgeRestart.start()
    }
  }

  property bool enabled: true

  Timer {
    id: bridgeRestart
    interval: 3000
    repeat: false
    // Guarded: startBridge() kills the old process, whose exited signal lands
    // AFTER the replacement is already running and schedules this timer. An
    // unguarded restart here would then kill the healthy new bridge, whose
    // death schedules the next restart — a permanent 3-second kill loop that
    // drops teams-for-linux's connection (and flickers the bar icon) on every
    // lap. Only a bridge that is actually gone gets restarted.
    onTriggered: if (!bridge.running) service.startBridge()
  }

  Timer {
    id: bridgeDebounce
    interval: 250
    repeat: false
    onTriggered: service.startBridge()
  }

  function restartBridgeSoon() {
    bridgeDebounce.restart()
  }

  function startBridge() {
    if (!bridgePath) {
      lastError = "plugin source directory unknown; cannot locate the bridge"
      return
    }
    bridgeRestart.stop()
    bridge.running = false
    bridge.command = [
      "python3", bridgePath,
      "--host", String(cfg("broker", "host", "127.0.0.1")),
      "--port", String(cfg("broker", "port", 1883)),
      "--prefix", prefix
    ]
    bridge.running = true
  }

  function onBridgeLine(line) {
    var msg = Model.parseLine(line)
    if (!msg) return

    if (msg.t === "ready") {
      bridgeReady = true
      bridgeMode = String(msg.mode || "")
      lastError = ""
      return
    }
    if (msg.t === "error") {
      lastError = String(msg.message || "")
      return
    }
    if (msg.t === "link") {
      // Any client attaching is teams-for-linux in practice, but the retained
      // <prefix>/connected topic is the authority; this only covers the gap
      // before it arrives.
      if (msg.up) teamsConnected = true
      return
    }
    if (msg.t === "msg") {
      applyTopic(String(msg.topic || ""), String(msg.payload === undefined ? "" : msg.payload))
    }
  }

  function applyTopic(topic, payload) {
    switch (Model.subtopic(topic, prefix)) {
    case "connected":
      var up = Model.boolOf(payload)
      teamsConnected = up
      if (!up) {
        // Teams is gone: drop every derived signal rather than leaving stale
        // "in a call" state pinned in the bar forever.
        setInCall(false)
        incomingCall = false
        screenSharing = false
        camera = false
        microphone = "off"
        presence = "offline"
      }
      break
    case "status":
      presence = Model.presenceFrom(payload)
      break
    case "in-call":
      setInCall(Model.boolOf(payload))
      break
    case "incoming-call":
      setIncomingCall(Model.boolOf(payload))
      break
    case "camera":
      camera = Model.boolOf(payload)
      break
    case "microphone":
      microphone = String(payload || "off")
      break
    case "screen-sharing":
      screenSharing = Model.boolOf(payload)
      break
    case "meeting-started":
      setMeetingStarted(Model.boolOf(payload))
      break
    case "calendar":
      calendar = Model.parseCalendar(payload)
      calendarFetchedAt = Date.now()
      break
    default:
      break
    }
  }

  // --------------------------------------------------------------- commands

  function publish(topic, payload) {
    if (!bridge.running || !bridgeReady) {
      lastError = "bridge is not running"
      return false
    }
    bridge.write(JSON.stringify({ cmd: "publish", topic: topic, payload: payload }) + "\n")
    return true
  }

  function sendAction(action, extra) {
    if (!Model.isAllowedAction(action)) {
      lastError = "unknown action: " + action
      return false
    }
    if (!teamsConnected) {
      lastError = "Teams is not running"
      return false
    }
    return publish(commandTopic, Model.commandPayload(action, extra))
  }

  function requestCalendar(days) {
    var span = Math.max(1, Number(days || 1))
    var now = new Date()
    var end = new Date(now.getTime() + span * 86400000)
    return sendAction("get-calendar", {
      startDate: now.toISOString(),
      endDate: end.toISOString()
    })
  }

  // ------------------------------------------------------------ meeting mode
  //
  // Both effects are restore-what-we-changed: we only put idle and DND back if
  // we were the one that moved them. Someone who deliberately switched on DND
  // before a call still has DND on when it ends.

  property bool meetingModeActive: false
  property bool weSetStayAwake: false
  property bool weSetDnd: false

  // Meeting mode changes global desktop state, so it cannot live only in this
  // object's memory: `omarchy-restart-shell` kills the process outright and
  // Component.onDestruction never runs, which would strand the desktop with
  // notifications silenced and the lock screen held off, and no widget left
  // alive that knows it did that. The file is the receipt; a fresh service
  // instance reads it and puts back whatever the dead one had moved.
  readonly property string recoveryPath: home + "/.local/state/omarchy/teams-meeting.json"

  FileView {
    id: recoveryFile
    path: service.recoveryPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.recoverMeetingMode(text())
    onLoadFailed: { /* no receipt: nothing was left switched on */ }
  }

  function writeRecovery() {
    recoveryFile.setText(JSON.stringify({
      stayAwake: weSetStayAwake,
      dnd: weSetDnd
    }) + "\n")
  }

  function clearRecovery() {
    // An empty file is the "nothing owed" marker; deleting it from QML would
    // need a subprocess for no benefit.
    recoveryFile.setText("")
  }

  function recoverMeetingMode(text) {
    var raw = String(text || "").trim()
    if (!raw) return
    var owed = null
    try { owed = JSON.parse(raw) } catch (e) { return }
    if (!owed || (!owed.stayAwake && !owed.dnd)) return

    // Undo the previous instance's work. If the call is in fact still running,
    // the retained in-call topic arrives moments later and meeting mode simply
    // re-applies — the same path a call starting normally takes.
    if (owed.stayAwake) run(["omarchy-toggle-idle", "allow-idle"])
    if (owed.dnd) setDnd(false)
    clearRecovery()
    console.log("rams.teams: recovered meeting mode left behind by a previous shell")
  }

  function notificationsService() {
    return shell && shell.serviceFor ? shell.serviceFor("omarchy.notifications") : null
  }

  function dndOn() {
    var n = notificationsService()
    return n ? !!n.doNotDisturb : false
  }

  function setDnd(on) {
    var n = notificationsService()
    if (!n || typeof n.setDoNotDisturb !== "function") return false
    n.setDoNotDisturb(!!on)
    return true
  }

  function setInCall(value) {
    var next = !!value
    if (next === inCall) return
    inCall = next
    if (next) {
      incomingCall = false
      setMeetingStarted(false)
      enterMeetingMode()
    } else {
      exitMeetingMode()
      screenSharing = false
      camera = false
      microphone = "off"
      if (cfg("notifications", "callEnded", false)) {
        notify("Call ended", "", "󰋕", "low")
      }
      if (pendingThemeReload) {
        pendingThemeReload = false
        if (cfg("theme", "autoReload", true)) reloadTeams()
      }
    }
  }

  function enterMeetingMode() {
    if (!cfg("meetingMode", "enabled", true)) return
    if (meetingModeActive) return
    meetingModeActive = true

    if (cfg("meetingMode", "stayAwake", true)) {
      // omarchy-toggle-idle is explicit about its verbs, so this is safe to
      // call whatever state idle is already in.
      run(["omarchy-toggle-idle", "stay-awake"])
      weSetStayAwake = true
    }
    if (cfg("meetingMode", "doNotDisturb", true) && !dndOn()) {
      if (setDnd(true)) weSetDnd = true
    }
    writeRecovery()
  }

  function exitMeetingMode() {
    if (!meetingModeActive) return
    meetingModeActive = false

    if (weSetStayAwake) {
      run(["omarchy-toggle-idle", "allow-idle"])
      weSetStayAwake = false
    }
    if (weSetDnd) {
      setDnd(false)
      weSetDnd = false
    }
    clearRecovery()
  }

  function setIncomingCall(value) {
    var next = !!value
    if (next === incomingCall) return
    incomingCall = next
    if (next && cfg("notifications", "incomingCall", true)) {
      // Critical urgency plus an app-name the shell recognises as a user action
      // is what lets this through DND — which we may have just switched on.
      notifyAction("Incoming Teams call", "Click to answer", "󰏲", "critical",
                   focusCommand())
    }
  }

  function setMeetingStarted(value) {
    var next = !!value
    if (next === meetingStarted) return
    meetingStarted = next
    if (next && cfg("notifications", "meetingStarting", true)) {
      notifyAction("A meeting is starting", "Click to open Teams", "󰐌", "normal",
                   focusCommand())
    }
  }

  // ----------------------------------------------------------- launch/focus

  function launchCommand() {
    var custom = String(cfgTop("launchCommand", ""))
    return custom || (JSON.stringify(cliPath) + " launch")
  }

  function focusCommand() {
    return "omarchy-launch-or-focus " + JSON.stringify(String(cfgTop("windowClass", "teams-for-linux")))
      + " " + JSON.stringify(launchCommand())
  }

  function focusTeams() {
    run(["bash", "-lc", focusCommand()])
  }

  function run(argv) {
    Quickshell.execDetached(argv)
  }

  function notify(headline, body, glyph, urgency) {
    notifyAction(headline, body, glyph, urgency, "")
  }

  function notifyAction(headline, body, glyph, urgency, execCommand) {
    var argv = ["omarchy-notification-send", "--app-name", "omarchy-action",
                "-g", glyph, "-u", urgency]
    if (execCommand) argv = argv.concat(["--exec", execCommand])
    argv.push(headline)
    if (body) argv.push(body)
    run(argv)
  }

  // ----------------------------------------------------------- theme syncing
  //
  // Teams reads the CSS file when a page loads, so a fresh theme lands on the
  // next Teams start (or on an explicit reload from the popup). We still write
  // it immediately: the file is the durable part, the reload is the courtesy.

  readonly property string themeCss: Model.themeCss({
    background: String(Color.background),
    foreground: String(Color.foreground),
    accent: String(Color.accent),
    cornerRadius: Style.cornerRadius,
    fontFamily: String(cfg("theme", "fontFamily", "")),
    hideAvatars: !!cfg("theme", "hideAvatars", false)
  })

  onThemeCssChanged: if (cfg("theme", "sync", true)) themeWriteDebounce.restart()

  // A theme switch mid-call must not kill the meeting; remember and apply on
  // hang-up instead.
  property bool pendingThemeReload: false

  Timer {
    id: themeWriteDebounce
    interval: 400
    repeat: false
    onTriggered: service.applyTheme()
  }

  // Auto-restarting Teams is only safe once we have actually read what is on
  // disk: before the FileView loads, text() is empty, every comparison says
  // "changed", and a shell restart would take Teams down with it for no reason.
  property bool cssSeen: false

  FileView {
    id: cssFile
    path: service.cssPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.cssSeen = true
    onLoadFailed: { /* no file yet: write, but never auto-restart over it */ }
  }

  function writeThemeCss() {
    if (!cfg("theme", "sync", true)) return false
    // Compare against what is on disk: the binding also "changes" once at
    // startup when it first evaluates, and rewriting (worse, auto-restarting
    // Teams) on every shell start would be absurd.
    var current = ""
    try { current = String(cssFile.text() || "") } catch (e) { current = "" }
    if (current === themeCss) return false
    ensureDir(tflConfigDir)
    cssFile.setText(themeCss)
    cssSeen = true
    return true
  }

  // Teams reads the CSS once per page load, so writing the file is only half
  // the job — an already-running Teams keeps the old palette until restarted.
  function applyTheme() {
    var seen = cssSeen
    var changed = writeThemeCss()
    if (!changed || !seen) return
    if (!teamsConnected) return          // next start picks it up anyway
    if (inCall) {
      // Restarting Teams would hang up the call. Do it after.
      pendingThemeReload = true
      notify("Theme staged", "Teams retints when the call ends.", "\u{f02bb}", "low")
      return
    }
    if (cfg("theme", "autoReload", true)) reloadTeams()
  }

  function ensureDir(dir) {
    run(["mkdir", "-p", dir])
  }

  function reloadTeams() {
    // No IPC into the app, so a restart is the honest way to re-read the CSS.
    //
    // `pkill -x` matches the process comm name, never the command line. That
    // matters: this runs inside a `bash -c` whose own command line contains the
    // pattern, so a `pkill -f` here would match the shell running it and kill
    // itself before ever reaching Teams.
    // Waiting for the process to actually die matters: Electron can take
    // longer than a fixed sleep to shut down, and a relaunch that races the
    // old instance loses to its single-instance lock and simply exits —
    // which reads as "Teams crashed and never came back".
    run(["bash", "-lc",
         "pkill -x teams-for-linux ; "
         + "for i in $(seq 1 20); do pgrep -x teams-for-linux >/dev/null || break ; sleep 0.5 ; done ; "
         + launchCommand() + " >/dev/null 2>&1 &"])
  }

  // ------------------------------------------------- teams-for-linux config
  //
  // The plugin is useless unless teams-for-linux is pointed at our broker, so
  // we merge the handful of keys we need into its config.json and leave every
  // other key the user has set alone.

  FileView {
    id: tflConfig
    path: service.tflConfigPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.mergeTeamsConfig(text())
    onLoadFailed: service.mergeTeamsConfig("")
  }

  property bool teamsConfigChanged: false

  function requiredTeamsPatch() {
    return Model.teamsConfigPatch({
      host: String(cfg("broker", "host", "127.0.0.1")),
      port: Number(cfg("broker", "port", 1883)),
      prefix: prefix,
      commandTopic: String(cfg("broker", "commandTopic", "command")),
      cssPath: cfg("theme", "sync", true) ? cssPath : "",
      meetingStartDetection: !!cfg("notifications", "meetingStarting", true)
    })
  }

  function reconcileTeamsConfig() {
    if (!cfgTop("manageTeamsConfig", true)) return
    tflConfig.reload()
  }

  function mergeTeamsConfig(text) {
    if (!cfgTop("manageTeamsConfig", true)) return

    var existing = {}
    if (text && String(text).trim()) {
      try {
        existing = JSON.parse(text)
      } catch (e) {
        // Refuse to clobber a file we cannot parse — that is the user's data.
        lastError = "teams-for-linux config.json is not valid JSON; leaving it alone"
        console.warn("rams.teams: " + lastError)
        return
      }
    }

    var patch = requiredTeamsPatch()
    if (Model.configSatisfies(existing, patch)) return

    ensureDir(tflConfigDir)
    tflConfig.setText(JSON.stringify(Model.deepMerge(existing, patch), null, 2) + "\n")
    teamsConfigChanged = true
    notify("Teams integration configured",
           "Restart Teams for Linux to pick up the new settings.", "󰊻", "normal")
  }

  // ---------------------------------------------------------------- lifecycle

  Component.onCompleted: {
    ensureDir(tflConfigDir)
    ensureDir(home + "/.local/state/omarchy")
    recoveryFile.reload()
    // configFile.onLoaded/onLoadFailed drives applyConfig, which starts the
    // bridge and reconciles the Teams config, so there is nothing to do here
    // beyond making sure the directory exists for the writes that follow.
  }

  Component.onDestruction: {
    // Leaving the desktop in meeting mode after the shell reloads would be a
    // trap: idle inhibited and notifications silenced with no widget to undo it.
    exitMeetingMode()
    bridge.running = false
  }

  // --------------------------------------------------------------------- IPC

  IpcHandler {
    target: "teams"

    function status(): string {
      return JSON.stringify({
        bridge: { ready: service.bridgeReady, mode: service.bridgeMode },
        teamsConnected: service.teamsConnected,
        presence: service.presence,
        inCall: service.inCall,
        incomingCall: service.incomingCall,
        camera: service.camera,
        microphone: service.microphone,
        screenSharing: service.screenSharing,
        meetingMode: service.meetingModeActive,
        error: service.lastError
      })
    }

    function toggleMute(): string {
      return service.sendAction("toggle-mute", null) ? "ok" : (service.lastError || "unhandled")
    }

    function toggleVideo(): string {
      return service.sendAction("toggle-video", null) ? "ok" : (service.lastError || "unhandled")
    }

    function raiseHand(): string {
      return service.sendAction("toggle-hand-raise", null) ? "ok" : (service.lastError || "unhandled")
    }

    function focus(): string {
      service.focusTeams()
      return "ok"
    }

    function calendar(days: string): string {
      var n = Number(days)
      service.requestCalendar(isFinite(n) && n > 0 ? n : 1)
      return "requested"
    }

    function reloadTheme(): string {
      service.writeThemeCss()
      service.reloadTeams()
      return "ok"
    }

    function writeTheme(): string {
      service.writeThemeCss()
      return service.cssPath
    }

    function restartBridge(): string {
      service.startBridge()
      return "ok"
    }

    // Escape hatch for a desktop stuck in meeting mode after something crashed.
    function endMeetingMode(): string {
      service.exitMeetingMode()
      return "ok"
    }
  }
}
