// rams.teams — bar face and popup.
//
// Reads state off the service and renders it; it never touches the bridge. The
// division matters because the shell can reload this widget (theme switch, bar
// edit) while the service — and therefore the broker and the meeting-mode
// bookkeeping — keeps running underneath.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "rams.teams"
  ipcTarget: "rams.teams"

  readonly property var service: bar && bar.shell && bar.shell.serviceFor
    ? bar.shell.serviceFor("rams.teams") : null

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Presentation settings (bar layout entry in shell.json).
  readonly property bool hideWhenClosed: setting("hideWhenClosed", false) === true
  readonly property bool showLabel: setting("showLabel", false) === true
  readonly property string rightClickAction: setting("rightClick", "Toggle mute")
  readonly property int calendarDays: setting("calendarDays", 1)

  readonly property var state: service ? service.barState
    : ({ glyph: "󰊻", label: "Teams service not loaded", tone: "off", show: true, pulse: false })

  readonly property bool inCall: service ? service.inCall : false
  readonly property bool sharing: service ? service.screenSharing : false
  readonly property bool ringing: service ? service.incomingCall : false
  readonly property bool teamsUp: service ? service.teamsConnected : false

  function toneColor(tone) {
    switch (tone) {
    case "urgent": return urgent
    case "busy":   return urgent
    case "ok":     return accent
    case "idle":   return Qt.darker(foreground, 1.25)
    case "off":    return Qt.darker(foreground, 1.8)
    default:       return foreground
    }
  }

  visible: state.show || !hideWhenClosed
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------- bar face

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontFamily: root.fontFamily
    text: root.showLabel && !root.bar.vertical
      ? root.state.glyph + "  " + root.state.label
      : root.state.glyph
    foreground: root.toneColor(root.state.tone)
    active: root.opened
    tooltipText: root.state.label + (root.service && root.service.lastError
      ? "\n" + root.service.lastError : "")

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.rightClickAction === "Toggle mute") root.act("toggleMute")
        else if (root.rightClickAction === "Focus Teams") root.focusTeams()
        else root.toggle()
      } else if (buttonCode === Qt.MiddleButton) {
        root.focusTeams()
      } else {
        root.toggle()
      }
    }

    // Sharing your screen and a ringing phone are the two states worth
    // interrupting someone's peripheral vision for.
    SequentialAnimation on opacity {
      running: root.state.pulse === true && root.visible
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0;  duration: 700; easing.type: Easing.InOutQuad }
      onRunningChanged: if (!running) button.opacity = 1.0
    }
  }

  function act(name) {
    if (!service) return
    if (name === "toggleMute") service.sendAction("toggle-mute", null)
    else if (name === "toggleVideo") service.sendAction("toggle-video", null)
    else if (name === "raiseHand") service.sendAction("toggle-hand-raise", null)
  }

  function focusTeams() {
    if (service) service.focusTeams()
  }

  // ---------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var k = String(t).toLowerCase()
        if (k === "m") root.act("toggleMute")
        else if (k === "v") root.act("toggleVideo")
        else if (k === "h") root.act("raiseHand")
        else if (k === "f") root.focusTeams()
        else if (k === "c" && root.service) root.service.requestCalendar(root.calendarDays)
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          // ---- hero -------------------------------------------------------

          PanelHero {
            width: parent.width
            title: root.teamsUp ? Model.presenceInfo(root.service ? root.service.presence : "unknown").label
                                : "Teams for Linux"
            meta: root.service ? root.service.summary : "Service not loaded"
            detail: root.service && root.service.lastError ? root.service.lastError : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.teamsUp ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: root.state.glyph
                color: root.toneColor(root.state.tone)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---- in-call controls -------------------------------------------

          PanelSeparator { width: parent.width; visible: root.inCall }

          PanelSectionHeader {
            width: parent.width
            text: "Call"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.inCall
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.inCall

            PanelActionButton {
              iconText: root.service && root.service.microphone === "muted" ? "󰍭" : "󰍬"
              tooltipText: "Toggle mute  (m)"
              foreground: root.service && root.service.microphone === "muted"
                ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.act("toggleMute")
            }
            PanelActionButton {
              iconText: root.service && root.service.camera ? "󰄀" : "󰄁"
              tooltipText: "Toggle camera  (v)"
              foreground: root.service && root.service.camera ? root.accent : root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.act("toggleVideo")
            }
            PanelActionButton {
              iconText: "󰹇"
              tooltipText: "Raise hand  (h)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.act("raiseHand")
            }
            PanelActionButton {
              iconText: "󰍹"
              tooltipText: root.sharing ? "You are sharing your screen" : "Not sharing"
              foreground: root.sharing ? root.urgent : Qt.darker(root.foreground, 1.8)
              fontFamily: root.fontFamily
              bordered: true
              enabled: false
            }
          }

          // ---- meeting mode -----------------------------------------------

          Rectangle {
            width: parent.width
            implicitHeight: mmRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, root.accent, root.urgent)
            border.width: 1
            border.color: Style.normalBorderFor(root.foreground, root.accent, root.urgent)
            visible: root.service ? root.service.meetingModeActive : false

            Row {
              id: mmRow
              anchors.centerIn: parent
              width: parent.width - Style.space(20)
              spacing: Style.space(8)

              Text {
                text: "󰤄"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Column {
                width: parent.width - Style.space(60)
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  text: "Meeting mode"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: {
                    var bits = []
                    if (root.service && root.service.weSetStayAwake) bits.push("idle inhibited")
                    if (root.service && root.service.weSetDnd) bits.push("notifications silenced")
                    return bits.length ? bits.join(" · ") : "active"
                  }
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  elide: Text.ElideRight
                }
              }
            }
          }

          // ---- calendar ----------------------------------------------------

          PanelSeparator { width: parent.width }

          Item {
            width: parent.width
            implicitHeight: calHeader.implicitHeight

            PanelSectionHeader {
              id: calHeader
              text: "Next up"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: calHeader.verticalCenter
              iconText: "󰑐"
              tooltipText: "Refresh calendar  (c)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: if (root.service) root.service.requestCalendar(root.calendarDays)
            }
          }

          Text {
            width: parent.width
            visible: !root.service || !root.service.calendar || root.service.calendar.length === 0
            text: root.service && root.service.calendarFetchedAt > 0
              ? "Nothing scheduled."
              : "Press c or the refresh icon to load your calendar.\nNeeds the Graph API enabled in teams-for-linux."
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.service && root.service.calendar ? root.service.calendar.slice(0, 5) : []

            Rectangle {
              required property var modelData
              width: column.width
              implicitHeight: evRow.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: evMouse.containsMouse
                ? Style.hoverFillFor(root.foreground, root.accent, root.urgent)
                : "transparent"

              MouseArea {
                id: evMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: modelData.joinUrl ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (modelData.joinUrl) Quickshell.execDetached(["xdg-open", modelData.joinUrl])
              }

              Column {
                id: evRow
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(8)
                width: parent.width - Style.space(16)
                spacing: Style.space(2)

                Text {
                  text: modelData.subject
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  width: parent.width
                  elide: Text.ElideRight
                }
                Text {
                  text: {
                    var when = Model.formatWhen(modelData.start, Date.now())
                    return modelData.organizer ? when + "  ·  " + modelData.organizer : when
                  }
                  color: Qt.darker(root.foreground, 1.45)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  elide: Text.ElideRight
                }
              }
            }
          }

          // ---- footer ------------------------------------------------------

          PanelSeparator { width: parent.width }

          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelActionButton {
              iconText: "󰊻"
              tooltipText: root.teamsUp ? "Focus Teams  (f)" : "Start Teams  (f)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: { root.focusTeams(); root.close() }
            }
            PanelActionButton {
              iconText: "󰸉"
              tooltipText: "Apply the Omarchy theme to Teams now"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.service) root.service.applyThemeNow()
            }
            PanelActionButton {
              iconText: "󰑓"
              tooltipText: root.service && root.service.bridgeReady
                ? "Bridge: " + root.service.bridgeMode + " — restart it"
                : "Bridge is down — restart it"
              foreground: root.service && root.service.bridgeReady
                ? root.foreground : root.urgent
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.service) root.service.startBridge()
            }
          }
        }
      }
    }
  }
}
