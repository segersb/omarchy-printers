import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root
  required property string pluginDir
  property var status: ({})
  property string message: ""
  property bool failed: false
  readonly property bool opened: window.visible
  readonly property bool busy: process.running
  function open() { window.visible = true; content.forceActiveFocus(); run("status", "") }
  function moveFocus(direction) {
    var controls = []
    for (var i = 0; i < integrations.count; i++) {
      var row = integrations.itemAt(i)
      if (row) controls.push(row.control)
    }
    controls = controls.concat([enableAll, restoreDefaults, closeButton])
    var current = controls.findIndex(function(control) { return control.activeFocus })
    var next = current < 0 ? (direction > 0 ? 0 : controls.length - 1) : current + direction
    for (; next >= 0 && next < controls.length; next += direction) {
      if (controls[next].enabled && controls[next].visible) {
        controls[next].forceActiveFocus(Qt.TabFocusReason)
        return
      }
    }
  }
  function run(action, part) {
    if (process.running) return
    process.command = ["python3", pluginDir + "/backend/print_setup.py", action].concat(part ? [part] : [])
    process.running = true
  }
  Process {
    id: process
    stdout: StdioCollector { id: output; waitForEnd: true }
    onExited: {
      try {
        var result = JSON.parse(output.text)
        root.failed = !result.ok
        if (result.ok) { root.status = result.data; root.message = result.data.notice || "" }
        else root.message = result.error
      } catch (e) { root.failed = true; root.message = "Could not read integration status." }
    }
  }
  FloatingWindow {
    id: window
    visible: false
    onClosed: visible = false
    title: "Printers · System integration"
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
    implicitWidth: Style.space(620)
    implicitHeight: content.implicitHeight + Style.space(48)
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: minimumSize
    ColumnLayout {
      id: content
      focus: true
      Shortcut {
        sequence: "Escape"
        context: Qt.WindowShortcut
        enabled: window.visible
        autoRepeat: false
        onActivated: window.visible = false
      }
      Shortcut {
        sequences: ["Down", "Right"]
        context: Qt.WindowShortcut
        enabled: window.visible
        onActivated: root.moveFocus(1)
      }
      Shortcut {
        sequences: ["Up", "Left"]
        context: Qt.WindowShortcut
        enabled: window.visible
        onActivated: root.moveFocus(-1)
      }
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(24)
      spacing: Style.space(16)
      Text {
        textFormat: Text.PlainText
        text: "Printers · System integration"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "Connect this plugin to your system’s built-in printing actions."
        color: Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Text {
          textFormat: Text.PlainText
          text: "󰀦"
          color: Color.flatColor("warning", Color.urgent)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          Layout.alignment: Qt.AlignTop
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          text: "Restore defaults before removing this plugin."
          color: Qt.darker(Color.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
      Repeater {
        id: integrations
        model: [
          {key: "settings", title: "Printer settings", description: "Replace the default printer settings with an Omarchy-style interface."},
          {key: "portal", title: "System print dialog", description: "Replace the default print dialog with an Omarchy-style interface."},
          {key: "files", title: "Print from Files", description: "Print supported documents and images directly from the right-click menu.\nFiles will restart to apply changes."}
        ]
        delegate: ColumnLayout {
          readonly property alias control: integrationToggle
          required property var modelData
          readonly property var entry: (root.status.integrations || {})[modelData.key] || {}
          Layout.fillWidth: true
          spacing: Style.space(6)
          PanelSeparator { Layout.fillWidth: true }
          RowLayout {
            Layout.fillWidth: true
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: modelData.title
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: entry.label || "Checking…"
              visible: text !== "Enabled" && text !== "Not enabled"
              color: entry.enabled ? Color.accent : Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            ToggleSwitch {
              id: integrationToggle
              checked: !!entry.managed || !!entry.enabled
              enabled: !!root.status.integrations
              busy: process.running
              opacity: enabled ? 1 : 0.4
              activeFocusOnTab: true
              hasCursor: enabled && activeFocus
              Accessible.role: Accessible.CheckBox
              Accessible.name: modelData.title
              Accessible.checked: checked
              onToggled: root.run(checked ? "restore" : "enable", modelData.key)
              Keys.onSpacePressed: if (enabled && !busy) toggled()
              Keys.onReturnPressed: if (enabled && !busy) toggled()
              Keys.onEnterPressed: if (enabled && !busy) toggled()
            }
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: modelData.description
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

        }
      }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: text !== ""
        wrapMode: Text.WordWrap
        text: root.message || (root.status.missing && root.status.missing.length
          ? "Missing print components: " + root.status.missing.join(", ") : "")
        color: root.failed ? Color.urgent : Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        Layout.bottomMargin: Style.space(4)
      }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)
        Button {
          id: enableAll
          text: "Enable all"
          enabled: !process.running && !!root.status.integrations
            && ["settings", "portal", "files"].some(function(key) {
              var entry = root.status.integrations[key]
              return entry && !entry.managed && !entry.enabled
            })
          opacity: enabled ? 1 : 0.4
          bordered: true
          focusable: true
          onClicked: root.run("enable", "all")
        }
        Button {
          id: restoreDefaults
          text: "Restore defaults"
          enabled: !process.running && !!root.status.managed
          opacity: enabled ? 1 : 0.4
          bordered: true
          focusable: true
          onClicked: root.run("restore", "all")
        }
        Item { Layout.fillWidth: true }
        Button {
          id: closeButton
          text: "Close"
          focusable: true
          onClicked: window.visible = false
        }
      }
    }
  }
}
