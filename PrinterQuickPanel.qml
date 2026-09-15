import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PrinterState.js" as PrinterState

Panel {
  id: root

  moduleName: "segersb.omarchy-printers"
  ipcTarget: "segersb.omarchy-printers.quick"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property var snapshot: ({ queues: [], available: [] })
  property int selectedQueueIndex: -1
  property var options: []
  property var optionValues: ({})
  property string activeCommand: ""
  property string statusMessage: ""
  property string statusKind: ""
  property bool backendTimedOut: false
  property bool controlPopupOpen: false
  property bool cursorActive: false
  property int cursorIndex: 0

  readonly property var selectedQueue: selectedQueueIndex >= 0
    && selectedQueueIndex < snapshot.queues.length
      ? snapshot.queues[selectedQueueIndex] : null
  readonly property var commonOptions: PrinterState.quickOptions(options)
  readonly property int targetCount: snapshot.queues.length
    + commonOptions.length
    + (commonOptions.length > 0 ? 1 : 0)
    + 1
  readonly property int optionOffset: snapshot.queues.length
  readonly property int saveIndex: optionOffset + commonOptions.length
  readonly property int settingsIndex: targetCount - 1
  readonly property bool busy: backend.running
  readonly property bool hasProblem: snapshot.queues.some(function(queue) {
    return !queue.enabled || queue.online === false
  })
  readonly property string icon: "󰐪"

  readonly property string pluginDir: {
    var path = Qt.resolvedUrl(".").toString()
    if (path.indexOf("file://") === 0) path = decodeURIComponent(path.substring(7))
    return path.replace(/\/$/, "")
  }
  readonly property string backendPath: pluginDir + "/backend/printers.py"

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      refresh()
    } else {
      closeOptionPopups()
      controlPopupOpen = false
    }
  }

  function refresh() {
    runBackend("snapshot", ["--timeout", "2"])
  }

  function runBackend(command, args) {
    if (backend.running) return
    activeCommand = command
    backendTimedOut = false
    statusMessage = ""
    backend.command = ["python3", backendPath, command].concat(args || [])
    backend.running = true
    backendTimeout.restart()
  }

  function selectQueue(index) {
    if (busy || index < 0 || index >= snapshot.queues.length) return
    selectedQueueIndex = index
    options = []
    optionValues = ({})
    cursorIndex = Math.min(cursorIndex, settingsIndex)
    runBackend("options", ["--queue", snapshot.queues[index].name])
  }

  function closeOptionPopups() {
    for (var i = 0; i < optionRepeater.count; i++) {
      var optionItem = optionRepeater.itemAt(i)
      if (optionItem && optionItem.popupOpen) optionItem.close()
    }
  }

  function saveOptions() {
    if (!selectedQueue || commonOptions.length === 0) return
    var values = {}
    for (var i = 0; i < commonOptions.length; i++) {
      var option = commonOptions[i]
      values[option.name] = optionValues[option.name]
    }
    runBackend("set-options", [
      "--queue", selectedQueue.name,
      "--options", JSON.stringify(values)
    ])
  }

  function openSettings() {
    close()
    if (bar && bar.shell)
      bar.shell.summon("segersb.omarchy-printers", "{}")
  }

  function moveCursor(delta) {
    if (!cursorActive) {
      cursorActive = true
      cursorIndex = Math.max(0, Math.min(targetCount - 1, cursorIndex))
      Qt.callLater(ensureCursorVisible)
      return
    }
    cursorIndex = Math.max(0, Math.min(targetCount - 1, cursorIndex + delta))
    Qt.callLater(ensureCursorVisible)
  }

  function targetItem(index) {
    if (index < snapshot.queues.length) return queueRepeater.itemAt(index)
    if (index < saveIndex) return optionRepeater.itemAt(index - optionOffset)
    if (commonOptions.length > 0 && index === saveIndex) return saveRow
    return settingsRow
  }

  function ensureCursorVisible() {
    var item = targetItem(cursorIndex)
    if (!item || viewport.height <= 0) return
    var point = item.mapToItem(content, 0, 0)
    var top = point.y
    var bottom = top + item.height
    if (top < viewport.contentY)
      viewport.contentY = Math.max(0, top)
    else if (bottom > viewport.contentY + viewport.height)
      viewport.contentY = Math.min(
        Math.max(0, content.implicitHeight - viewport.height),
        bottom - viewport.height
      )
  }

  function activateCursor() {
    if (!cursorActive || targetCount === 0 || busy) return
    var activeIndex = Math.max(0, Math.min(settingsIndex, cursorIndex))
    cursorIndex = activeIndex
    if (activeIndex < snapshot.queues.length) {
      selectQueue(activeIndex)
      return
    }
    if (activeIndex < saveIndex) {
      var optionItem = optionRepeater.itemAt(activeIndex - optionOffset)
      if (optionItem) optionItem.toggle()
      return
    }
    if (commonOptions.length > 0 && activeIndex === saveIndex) {
      saveOptions()
      return
    }
    openSettings()
  }

  function setPointerCursor(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    cursorActive = true
    cursorIndex = index
  }

  function handleSuccess(command, data) {
    if (command === "snapshot") {
      snapshot = {
        queues: data.queues || [],
        available: data.available || []
      }
      if (snapshot.queues.length === 0) {
        selectedQueueIndex = -1
        options = []
        optionValues = ({})
        cursorIndex = settingsIndex
        return
      }
      var defaultIndex = 0
      for (var i = 0; i < snapshot.queues.length; i++) {
        if (snapshot.queues[i].isDefault) {
          defaultIndex = i
          break
        }
      }
      selectQueue(defaultIndex)
      return
    }
    if (command === "options") {
      options = data.options || []
      var values = {}
      for (var i = 0; i < options.length; i++)
        values[options[i].name] = options[i].default
      optionValues = values
      cursorIndex = Math.min(cursorIndex, settingsIndex)
      return
    }
    if (command === "set-options") {
      statusKind = "success"
      statusMessage = "Defaults saved"
    }
  }

  function handleBackendResult() {
    backendTimeout.stop()
    if (backendTimedOut) return
    var response
    try {
      response = JSON.parse(backendOut.text)
    } catch (error) {
      statusKind = "error"
      statusMessage = "Printer service returned an invalid response"
      return
    }
    if (!response.ok) {
      statusKind = "error"
      statusMessage = response.error && response.error.message
        ? String(response.error.message) : "Printer operation failed"
      return
    }
    if (activeCommand !== "set-options") statusKind = ""
    handleSuccess(activeCommand, response.data || ({}))
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.hasProblem
    tooltipText: root.hasProblem ? "Printer needs attention" : "Printers"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.controlPopupOpen
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.moveCursor(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
      }

      Flickable {
        id: viewport
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: viewport.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, refreshButton.implicitHeight)

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.icon
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.selectedQueue ? root.selectedQueue.name : "Printers"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.selectedQueue
                  ? PrinterState.queueStatus(root.selectedQueue).toUpperCase()
                  : (root.busy ? "CHECKING PRINTERS" : "NO PRINTERS ADDED")
                color: root.selectedQueue && root.selectedQueue.online
                  ? Color.flatColor("green", root.bar.foreground)
                  : Color.muted
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              tooltipText: "Refresh"
              foreground: root.bar.foreground
              enabled: !root.busy
              onClicked: root.refresh()
            }
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "PRINTERS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              id: queueRepeater
              model: root.snapshot.queues

              CursorSurface {
                id: queueRow
                required property var modelData
                required property int index
                width: parent.width
                height: Style.space(54)
                bordered: true
                hasCursor: root.cursorActive && root.cursorIndex === index
                current: root.selectedQueueIndex === index

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: queueRow.borderLeft + Style.spacing.rowPaddingX
                  anchors.rightMargin: queueRow.borderRight + Style.spacing.rowPaddingX
                  spacing: Style.space(10)

                  Text {
                    text: modelData.online ? "●" : "○"
                    color: modelData.online ? Color.flatColor("green", root.bar.foreground) : Color.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Column {
                    width: parent.width - parent.children[0].width - parent.spacing
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: modelData.name
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: modelData.isDefault
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      text: PrinterState.queueStatus(modelData)
                      color: Color.muted
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: !root.busy
                  onPositionChanged: function(mouse) { root.setPointerCursor(index, queueRow, mouse) }
                  onClicked: root.selectQueue(index)
                }
              }
            }

            Text {
              visible: root.snapshot.queues.length === 0
              width: parent.width
              text: root.busy ? "Checking printers…" : "No printers added"
              color: Color.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Column {
            visible: root.selectedQueue && root.commonOptions.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator {
              foreground: root.bar.foreground
            }

            PanelSectionHeader {
              text: "QUICK DEFAULTS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              id: optionRepeater
              model: root.commonOptions

              Dropdown {
                required property var modelData
                required property int index
                width: parent.width
                label: modelData.label
                value: String(root.optionValues[modelData.name] || "")
                options: modelData.choices || []
                foreground: root.bar.foreground
                hasCursor: root.cursorActive && root.cursorIndex === root.optionOffset + index
                onHovered: function(on) {
                  if (on) {
                    root.cursorActive = true
                    root.cursorIndex = root.optionOffset + index
                  }
                }
                onPopupOpenChanged: root.controlPopupOpen = popupOpen
                onChanged: function(value) {
                  var next = Object.assign({}, root.optionValues)
                  next[modelData.name] = value
                  root.optionValues = next
                }
              }
            }

            CursorSurface {
              id: saveRow
              width: parent.width
              height: Style.spacing.controlHeight
              bordered: true
              hasCursor: root.cursorActive && root.cursorIndex === root.saveIndex

              Text {
                anchors.centerIn: parent
                text: root.busy && root.activeCommand === "set-options"
                  ? "Saving…" : "Save defaults"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                enabled: !root.busy
                onPositionChanged: function(mouse) { root.setPointerCursor(root.saveIndex, saveRow, mouse) }
                onClicked: root.saveOptions()
              }
            }
          }

          Text {
            visible: root.statusMessage !== ""
            width: parent.width
            text: root.statusMessage
            color: root.statusKind === "error" ? Color.urgent
              : (root.statusKind === "success" ? Color.flatColor("green", root.bar.foreground) : Color.muted)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          CursorSurface {
            id: settingsRow
            width: parent.width
            height: Style.spacing.controlHeight
            hasCursor: root.cursorActive && root.cursorIndex === root.settingsIndex

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Open printer settings"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "󰅂"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.icon
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: function(mouse) {
                root.setPointerCursor(root.settingsIndex, settingsRow, mouse)
              }
              onClicked: root.openSettings()
            }
          }
        }
      }
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: viewport
  }

  Process {
    id: backend
    stdout: StdioCollector {
      id: backendOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text) console.warn("omarchy-printers:", text.trim())
    }
    onExited: root.handleBackendResult()
  }

  Timer {
    id: backendTimeout
    interval: root.activeCommand === "set-options" ? 150000 : 15000
    onTriggered: {
      root.backendTimedOut = true
      backend.signal(15)
      root.statusKind = "error"
      root.statusMessage = "Printer operation timed out"
    }
  }
}
