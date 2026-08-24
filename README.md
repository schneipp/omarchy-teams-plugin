# Teams for Omarchy

Microsoft Teams as a first-class citizen of the [Omarchy](https://omarchy.org) desktop:
presence in the bar, live mic and screen-share state, a meeting mode that silences
notifications and holds off the lock screen, incoming-call toasts you can click to
answer, a mute key that works from any window, and Teams retinted to your current
Omarchy theme.

Built on [`teams-for-linux`](https://github.com/IsmaelMartinez/teams-for-linux).
Almost all of the logic lives inside the Omarchy shell as a Quickshell plugin.

![Omarchy 4](https://img.shields.io/badge/Omarchy-4.x-8b8ff5) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Why this exists

Microsoft retired the native Linux client in 2022. What is left is a web app, and a
web app cannot tell your desktop that you just joined a call. `teams-for-linux` can:
it wraps the web app in Electron and publishes what it sees — presence, call state,
microphone, camera, screen sharing — over MQTT.

This plugin listens to that, and reacts.

## What it does

| | |
|---|---|
| **Presence in the bar** | Available / Busy / DND / Away, straight from your account |
| **Live call state** | Mic glyph flips between muted, unmuted, and speaking as it happens |
| **Screen-share indicator** | A pulsing icon whenever you are live — closes a gap where Wayland gives you no indication at all |
| **Meeting mode** | On call join: notifications silenced, lock screen and screensaver held off. On hang-up: both put back |
| **Incoming call toasts** | Critical-urgency toast with the caller's name; click it to answer. Pops through DND, including the DND meeting mode just switched on |
| **Global mute** | `SUPER + ALT + M` from any window, including a fullscreen one |
| **Meeting-starting nudge** | A toast when a scheduled meeting begins, before anyone calls you |
| **Theme sync** | Teams is retinted from your Omarchy palette and follows every theme switch |
| **Deep links** | `msteams://` and `teams.microsoft.com/l/…` links open in the app, reusing the window |
| **Next up** | Your upcoming meetings in the popup, click to join (needs Graph API enabled) |

## Install

```bash
yay -S teams-for-linux-bin
omarchy plugin add https://github.com/schneipp/omarchy-teams-plugin.git --enable --yes
omarchy bar add rams.teams
```

Then wire up Teams itself:

```bash
~/.config/omarchy/plugins/rams.teams/bin/omarchy-teams install
~/.config/omarchy/plugins/rams.teams/bin/omarchy-teams doctor
```

The plugin writes the `teams-for-linux` settings it needs (MQTT broker, command
topic, theme CSS path) into `~/.config/teams-for-linux/config.json`, **merging**
them into whatever is already there rather than replacing the file. Restart Teams
once afterwards.

### Keybindings

Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + M", "Teams mute", "omarchy-shell teams toggleMute")
o.bind("SUPER + ALT + V", "Teams camera", "omarchy-shell teams toggleVideo")
o.bind("SUPER + ALT + H", "Teams raise hand", "omarchy-shell teams raiseHand")
o.bind("SUPER + ALT + T", "Teams", "omarchy-shell teams focus")
```

### Screen sharing

The AUR package ships a desktop entry that forces `--ozone-platform=x11`, which
is why screen sharing tends to be second-class. Switch it:

```bash
omarchy-teams wayland on    # native Wayland + PipeWire capture
omarchy-teams wayland off   # back to XWayland if anything misbehaves
```

## How it fits together

```
teams-for-linux ──MQTT──> omarchy-teams-bridge ──JSON lines──> Service.qml
   (Electron)              (~400 lines python)                 (the shell)
        ^                                                          │
        └──────────────── commands ────────────────────────────────┘
```

**The bridge is deliberately thin.** Quickshell cannot open TCP sockets and
`teams-for-linux` only speaks MQTT, so something has to be the wire. It is a
loopback-only MQTT 3.1.1 broker with no policy in it at all: no state machine, no
side effects, just newline-delimited JSON in both directions.

**No mosquitto, no root, no system service.** The bridge *is* the broker, running
inside the shell's own process tree. If you already run a broker on 1883 it
detects that and attaches as an ordinary client instead — the plugin cannot tell
the difference.

**Everything that decides what a signal means lives in QML**, so the shell can
reload the widget while the bridge, the broker and the meeting-mode bookkeeping
keep running underneath.

### Things that were fiddlier than they look

- **Meeting mode only restores what it changed.** If you had DND on before the
  call, it is still on afterwards. The plugin tracks ownership rather than
  blindly toggling.
- **It survives being killed.** `omarchy-restart-shell` kills the process
  outright, so `Component.onDestruction` never runs. Without a receipt on disk
  that would strand your desktop with notifications silenced and the lock screen
  disabled, and nothing alive that knew it did that. A fresh instance reads the
  receipt and puts things back.
- **Retained state is persisted for the session.** `teams-for-linux` only
  republishes presence when it *changes*, so a shell restart would otherwise
  leave the bar showing "unknown" until you next changed your status.

## Commands

```
omarchy-teams status         Current state as JSON
omarchy-teams mute           Toggle mute from anywhere
omarchy-teams video / hand   Camera, raised hand
omarchy-teams focus          Focus Teams, or start it
omarchy-teams calendar [n]   Ask Teams for upcoming events
omarchy-teams theme          Rewrite theme CSS  (--reload to restart Teams)
omarchy-teams link <url>     Open an msteams:// or teams.microsoft.com/l/ link
omarchy-teams wayland on|off Native Wayland or XWayland
omarchy-teams unstick        Force meeting mode off if something got stuck
omarchy-teams doctor         Check the whole setup
```

Everything is also on the shell IPC: `omarchy-shell teams <method>`.

## Configuration

`~/.config/omarchy/teams.json` — hot-reloaded, no restart needed.

```json
{
  "broker":        { "host": "127.0.0.1", "port": 1883, "prefix": "teams", "commandTopic": "command" },
  "meetingMode":   { "enabled": true, "stayAwake": true, "doNotDisturb": true },
  "notifications": { "incomingCall": true, "meetingStarting": true, "callEnded": false },
  "theme":         { "sync": true, "autoReload": true, "fontFamily": "", "hideAvatars": false },
  "manageTeamsConfig": true
}
```

Set `manageTeamsConfig` to `false` if you would rather own
`teams-for-linux/config.json` yourself.

Bar appearance (label, right-click action, calendar look-ahead) is configured
where every other widget is: the widget's entry in `~/.config/omarchy/shell.json`,
or through `omarchy bar`.

## Theming, honestly

Teams V2 is a Fluent UI v9 app, and Fluent v9 reads its colors from CSS custom
properties. The plugin generates a stylesheet that overrides that token set from
your Omarchy palette, so surfaces, text, strokes, and brand accents retint.
Anything Teams hardcodes outside the token system stays as Microsoft shipped it —
this is a good retint, not a full reskin.

CSS is read when a page loads, so applying it means restarting Teams. With
`theme.autoReload` on (the default), a theme switch restarts Teams by itself —
unless you are in a call, in which case it waits and retints on hang-up. The
popup's palette button forces it immediately.

## Requirements

- Omarchy 4.x (Quickshell plugin API with `service` + `bar-widget` kinds)
- `teams-for-linux` ≥ 2.17
- `python3` (in the base install; no third-party modules)

`jq` makes `doctor` more informative but is not required.

## Calendar

The "Next up" list uses `teams-for-linux`'s Graph API integration. If you have not
enabled it, the list stays empty and everything else works fine.

## Troubleshooting

```bash
omarchy-teams doctor          # start here
omarchy-teams unstick         # desktop stuck in meeting mode
omarchy-teams bridge          # restart just the bridge
journalctl --user -f | grep rams.teams
```

## Tests

```bash
cd test && npm install mqtt && cd ..
./test/run.sh
```

19 checks against the real `mqtt.js` client — the same library `teams-for-linux`
uses — covering connect, retained publishes, subscribe delivery, commands, last
will on a dropped socket, retained replay, and state persistence across a bridge
restart.

## License

MIT. Not affiliated with Microsoft. `teams-for-linux` is an independent project;
some behavior is bounded by what the Teams web app exposes.
