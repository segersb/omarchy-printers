import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root
  required property string requestId
  required property string pluginDir
  signal finished()
  property var state: ({ stage: "loading", busy: true })
  property var settings: ({})
  property bool initialized: false
  property bool dirty: false
  property int revision: 0
  property bool terminal: false
  readonly property bool previewing: state.stage === "preview"
  readonly property bool hasDocument: !!state.metadata
  readonly property bool busy: dirty || !!state.busy
  readonly property var queues: state.caps ? state.caps.queues : []
  readonly property var queue: queues.find(function(q) { return q.value === settings.queue }) || null
  readonly property var media: queue ? queue.media : []
  readonly property var paper: state.metadata ? state.metadata.paper : null
  readonly property var pages: state.metadata ? state.metadata.pages : []
  readonly property int pageIndex: state.page || 0
  readonly property var currentPage: pages.length ? pages[pageIndex] : null
  readonly property int sourcePage: currentPage ? currentPage.source : 1
  readonly property var pageAdjustment: (settings.adjustments || {})[String(sourcePage)] || settings.defaultAdjustment || {zoom: 100, x: 0, y: 0}
  property real dragX: 0
  property real dragY: 0

  function setPageAdjustment(value) {
    var edits = Object.assign({}, settings.adjustments || {})
    edits[String(sourcePage)] = {zoom: Math.max(10, Math.min(400, value.zoom)),
      x: Math.max(-14400, Math.min(14400, value.x)), y: Math.max(-14400, Math.min(14400, value.y))}
    change("adjustments", edits)
  }
  function setZoom(value) {
    setPageAdjustment({zoom: value, x: pageAdjustment.x, y: pageAdjustment.y})
  }
  function zoomAt(value, x, y) {
    var zoom = Math.max(10, Math.min(400, value))
    if (!paper || zoom === pageAdjustment.zoom) return
    var ratio = zoom / pageAdjustment.zoom
    var anchorX = x - paper.width / 2
    var anchorY = y - paper.height / 2
    setPageAdjustment({zoom: zoom,
      x: anchorX - (anchorX - pageAdjustment.x - dragX) * ratio - dragX,
      y: anchorY - (anchorY - pageAdjustment.y - dragY) * ratio - dragY})
  }
  function applyToAll() {
    var value = Object.assign({}, pageAdjustment)
    settings = Object.assign({}, settings, {adjustments: {}})
    change("defaultAdjustment", value)
  }


  function send(message) {
    if (bridge.running) bridge.write(JSON.stringify(message) + "\n")
  }
  function change(key, value) {
    var next = Object.assign({}, settings)
    next[key] = value
    settings = next
    if (previewing || state.direct) {
      revision++
      dirty = true
      renderDelay.restart()
    }
  }
  function chooseQueue(value) {
    var q = queues.find(function(item) { return item.value === value })
    if (!q) return
    var m = q.media.find(function(item) { return item.value === q.defaultMedia }) || q.media[0]
    settings = Object.assign({}, settings, {queue: value, media: m ? m.value : "",
      color: q.colors.indexOf(q.defaultColor) >= 0 ? q.defaultColor : q.colors[0],
      sides: q.sides.indexOf(q.defaultSides) >= 0 ? q.defaultSides : q.sides[0]})
    if (previewing || state.direct) { revision++; dirty = true; renderDelay.restart() }
  }
  function cancel() {
    if (state.stage === "submitting") return
    if (!terminal) send({action: "cancel"})
    terminal = true
    window.visible = false
    root.finished()
  }
  function applyState(line) {
    if (root.terminal) return
    try {
      var incoming = JSON.parse(line)
      root.state = incoming
      if (!root.initialized && incoming.settings && incoming.caps) {
        root.settings = incoming.settings
        root.initialized = true
      }
      if (!incoming.busy && (incoming.revision || 0) === root.revision) root.dirty = false
      if (incoming.stage === "done") {
        root.terminal = true
        if (!incoming.message) { window.visible = false; root.finished() }
      }
    } catch (e) {
      root.state = Object.assign({}, root.state, { stage: "error", error: "Could not read print status.", busy: false })
    }
  }
  Component.onCompleted: bridge.running = true
  Component.onDestruction: bridge.running = false
  Timer {
    id: renderDelay
    interval: 300
    onTriggered: root.send({action: "render", settings: root.settings, revision: root.revision, viewSource: root.sourcePage})
  }
  Process {
    id: bridge
    command: ["python3", root.pluginDir + "/backend/print_portal.py", "bridge", root.requestId]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.applyState(line) }
    }
    onExited: {
      if (!root.terminal) {
        root.state = Object.assign({}, root.state, { stage: "error", error: "The print service disconnected. Close this window and try again.", busy: false })
        root.terminal = true
      }
    }
  }

  FloatingWindow {
    id: window
    title: "Print"
    visible: true
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
    implicitWidth: Style.space(980)
    implicitHeight: Style.space(720)
    minimumSize: Qt.size(Style.space(980), Style.space(720))
    maximumSize: minimumSize
    onVisibleChanged: if (!visible && !root.terminal) root.cancel()

    Item {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.cancel()
      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(24)
        spacing: Style.space(18)
        RowLayout {
          Layout.fillWidth: true
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(4)
            Text {
              textFormat: Text.PlainText
              text: "Print"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.state.title || "Preparing your document…"
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideMiddle
              Layout.fillWidth: true
            }
          }
          Text {
            textFormat: Text.PlainText
            text: root.terminal ? "FINISHED" : (root.hasDocument ? "PREVIEW" : "PREPARING")
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 2
          }
        }
        PanelSeparator { Layout.fillWidth: true }
        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(26)
          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              color: Qt.darker(Color.background, 1.18)
              radius: Style.cornerRadius
              clip: true
              Item {
                id: previewArea
                anchors.fill: parent
                anchors.margins: Style.space(22)
                readonly property real unit: root.paper ? Math.min(width / root.paper.width, height / root.paper.height) : 1
                Rectangle {
                  id: sheet
                  anchors.centerIn: parent
                  width: root.paper ? root.paper.width * previewArea.unit : 0
                  height: root.paper ? root.paper.height * previewArea.unit : 0
                  color: "white"
                  visible: root.hasDocument
                  Rectangle {
                    id: printable
                    x: root.paper ? root.paper.margins[0] * previewArea.unit : 0
                    y: root.paper ? root.paper.margins[1] * previewArea.unit : 0
                    width: root.paper ? (root.paper.width - root.paper.margins[0] - root.paper.margins[2]) * previewArea.unit : 0
                    height: root.paper ? (root.paper.height - root.paper.margins[1] - root.paper.margins[3]) * previewArea.unit : 0
                    color: "white"
                    clip: true
                    Image {
                      id: documentImage
                      source: root.state.sourceImage || ""
                      asynchronous: true
                      cache: false
                      layer.enabled: root.settings.color === "monochrome"
                      layer.effect: MultiEffect { saturation: -1 }
                      width: root.currentPage ? root.currentPage.width * root.pageAdjustment.zoom / 100 * previewArea.unit : 0
                      height: root.currentPage ? root.currentPage.height * root.pageAdjustment.zoom / 100 * previewArea.unit : 0
                      x: (sheet.width - width) / 2 + (root.pageAdjustment.x + root.dragX) * previewArea.unit - printable.x
                      y: (sheet.height - height) / 2 + (root.pageAdjustment.y + root.dragY) * previewArea.unit - printable.y
                      fillMode: Image.Stretch
                    }
                  }
                  Rectangle {
                    x: printable.x; y: printable.y
                    width: printable.width; height: printable.height
                    color: "transparent"
                    border.width: 1
                    border.color: Color.accent
                    opacity: .5
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: root.previewing && !root.terminal
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    property real startX: 0
                    property real startY: 0
                    property real wheelRemainder: 0
                    onWheel: function(wheel) {
                      if (!(wheel.modifiers & Qt.ControlModifier)) {
                        wheelRemainder = 0
                        wheel.accepted = false
                        return
                      }
                      wheel.accepted = true
                      var delta = wheel.angleDelta.y ? wheel.angleDelta.y / 120 : wheel.pixelDelta.y / 40
                      if (wheelRemainder * delta < 0) wheelRemainder = 0
                      wheelRemainder += delta
                      var steps = Math.trunc(wheelRemainder)
                      if (!steps) return
                      wheelRemainder -= steps
                      root.zoomAt(root.pageAdjustment.zoom + steps * 5,
                        wheel.x / previewArea.unit, wheel.y / previewArea.unit)
                    }
                    onPressed: function(mouse) { startX = mouse.x; startY = mouse.y }
                    onPositionChanged: function(mouse) {
                      if (pressed) {
                        root.dragX = (mouse.x - startX) / previewArea.unit
                        root.dragY = (mouse.y - startY) / previewArea.unit
                      }
                    }
                    onReleased: {
                      root.setPageAdjustment({zoom: root.pageAdjustment.zoom,
                        x: root.pageAdjustment.x + root.dragX, y: root.pageAdjustment.y + root.dragY})
                      root.dragX = 0; root.dragY = 0
                    }
                    onCanceled: { root.dragX = 0; root.dragY = 0 }
                  }
                }
              }
              Column {
                anchors.centerIn: parent
                width: parent.width - Style.space(60)
                visible: !root.hasDocument
                spacing: Style.space(12)
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.busy ? "Preparing preview…" : "Your page, before you print"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                  text: "Waiting for the document. You can change print settings in the preview."
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
            RowLayout {
              Layout.alignment: Qt.AlignHCenter
              Button {
                opacity: enabled ? 1 : 0.4
                text: "‹"
                focusable: true
                enabled: !root.busy && root.pageIndex > 0
                onClicked: root.send({action: "page", page: root.pageIndex - 1})
              }
              Text {
                textFormat: Text.PlainText
                text: root.pages.length ? "Page " + (root.pageIndex + 1) + " of " + root.pages.length : "Preview appears here"
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                opacity: enabled ? 1 : 0.4
                text: "›"
                focusable: true
                enabled: !root.busy && root.pageIndex + 1 < root.pages.length
                onClicked: root.send({action: "page", page: root.pageIndex + 1})
              }
            }
          }
          ColumnLayout {
            Layout.preferredWidth: Style.space(290)
            Layout.maximumWidth: Style.space(290)
            Layout.fillHeight: true
            spacing: Style.space(8)
            enabled: root.initialized && !root.terminal && root.previewing
            Dropdown {
              opacity: enabled ? 1 : 0.4
              Layout.fillWidth: true
              label: "PRINTER"
              options: root.queues
              value: root.settings.queue || ""
              onChanged: function(value) { root.chooseQueue(value) }
            }
            RowLayout {
              Layout.fillWidth: true
              Dropdown {
                opacity: enabled ? 1 : 0.4
                Layout.fillWidth: true
                label: "PAPER"
                options: root.media
                value: root.settings.media || ""
                onChanged: function(value) { root.change("media", value) }
              }
              Dropdown {
                opacity: enabled ? 1 : 0.4
                Layout.fillWidth: true
                label: "ORIENTATION"
                options: [{value: "portrait", label: "Portrait"}, {value: "landscape", label: "Landscape"}]
                value: root.settings.orientation || "portrait"
                onChanged: function(value) { root.change("orientation", value) }
              }
            }
            RowLayout {
              Layout.fillWidth: true
              Dropdown {
                opacity: enabled ? 1 : 0.4
                Layout.fillWidth: true
                label: "COLOR"
                options: root.queue ? root.queue.colors.map(function(v) { return {value: v, label: v === "monochrome" ? "Black & white" : (v === "color" ? "Color" : "Auto")} }) : []
                value: root.settings.color || "monochrome"
                onChanged: function(value) { root.change("color", value) }
              }
              ColumnLayout {
                Layout.preferredWidth: Style.space(66)
                Text {
                  textFormat: Text.PlainText
                  text: "COPIES"
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                TextField {
                  opacity: enabled ? 1 : 0.4
                  id: copiesInput
                  Layout.fillWidth: true
                  text: String(root.settings.copies || 1)
                  validator: IntValidator { bottom: 1; top: 999 }
                  onTextEdited: if (acceptableInput) root.change("copies", Number(text))
                }
              }
            }
            Dropdown {
              opacity: enabled ? 1 : 0.4
              Layout.fillWidth: true
              label: "SIDES"
              value: root.settings.sides || "one-sided"
              options: root.queue ? root.queue.sides.map(function(v) { return {value: v, label: v === "one-sided" ? "One-sided" : (v === "two-sided-long-edge" ? "Two-sided · Long edge" : "Two-sided · Short edge")} }) : []
              onChanged: function(value) { root.change("sides", value) }
            }
            PanelSeparator { Layout.fillWidth: true; visible: root.hasDocument }
            Text {
              textFormat: Text.PlainText
              visible: root.hasDocument
              text: "PRINT ZOOM · PAGE " + root.sourcePage
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            RowLayout {
              visible: root.hasDocument
              Layout.fillWidth: true
              Button { opacity: enabled ? 1 : 0.4; text: "−"; focusable: true; enabled: root.pageAdjustment.zoom > 10; onClicked: root.setZoom(root.pageAdjustment.zoom - 5) }
              TextField {
                opacity: enabled ? 1 : 0.4
                Layout.fillWidth: true
                text: String(Math.round(root.pageAdjustment.zoom))
                validator: IntValidator { bottom: 10; top: 400 }
                onEditingFinished: {
                  if (acceptableInput) root.setZoom(Number(text))
                  text = Qt.binding(function() { return String(Math.round(root.pageAdjustment.zoom)) })
                }
              }
              Text {
                textFormat: Text.PlainText
                text: "%"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Button { opacity: enabled ? 1 : 0.4; text: "+"; focusable: true; enabled: root.pageAdjustment.zoom < 400; onClicked: root.setZoom(root.pageAdjustment.zoom + 5) }
            }
            PanelSlider {
              opacity: enabled ? 1 : 0.4
              Layout.fillWidth: true
              visible: root.hasDocument
              minimum: 10; maximum: 400; step: 1; integer: true
              value: root.pageAdjustment.zoom
              fillColor: Color.accent
              knobColor: Color.accent
              onMoved: function(value) { root.setZoom(value) }
            }
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: root.hasDocument
              wrapMode: Text.WordWrap
              text: "Ctrl + scroll to zoom. Drag to position. Anything outside the outline will not print."
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            RowLayout {
              Layout.fillWidth: true
              visible: root.hasDocument
              Button {
                opacity: enabled ? 1 : 0.4
                text: "Reset page"
                focusable: true
                onClicked: root.setPageAdjustment({zoom: 100, x: 0, y: 0})
              }
              Button {
                opacity: enabled ? 1 : 0.4
                text: "Apply to all pages"
                focusable: true
                enabled: !!root.state.metadata && root.state.metadata.count > 1
                onClicked: root.applyToAll()
              }
            }
            TextField {
              opacity: enabled ? 1 : 0.4
              Layout.fillWidth: true
              visible: root.hasDocument
              placeholderText: "All pages · or 1-3, 5"
              text: root.settings.pages || ""
              onTextEdited: root.change("pages", text)
            }
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: root.hasDocument ? (root.busy ? "Updating print output…" : "Adjustments saved for printing") : ""
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Item { Layout.fillHeight: true }
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: "100% uses the received document’s original physical size."
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
        PanelSeparator { Layout.fillWidth: true }
        RowLayout {
          Layout.fillWidth: true
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.state.error || root.state.message || (root.initialized && !root.media.length ? "No supported paper sizes. Check the printer setup." : "")
            color: root.state.error ? Color.urgent : Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            opacity: enabled ? 1 : 0.4
            text: root.terminal ? "Close" : "Cancel"
            focusable: true
            enabled: root.state.stage !== "submitting"
            onClicked: root.cancel()
          }
          Button {
            opacity: enabled ? 1 : 0.4
            text: "Print"
            selected: enabled
            bordered: true
            focusable: true
            enabled: !root.terminal && root.initialized && !root.busy && root.media.length > 0 &&
              !root.state.error && copiesInput.acceptableInput && root.previewing
            onClicked: root.send({action: "print", generation: root.state.generation})
          }
        }
      }
    }
  }
}
