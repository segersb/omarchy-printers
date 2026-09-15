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
  property var optionCache: ({})
  property string activeCommand: ""
  property string activeQueueName: ""
  property string statusMessage: ""
  property string statusKind: ""
  property bool backendTimedOut: false
  property bool controlPopupOpen: false
  property bool cursorActive: false
  property int cursorIndex: 0
  property int pendingOptionsQueueIndex: -1

  readonly property var selectedQueue: selectedQueueIndex >= 0
    && selectedQueueIndex < snapshot.queues.length
      ? snapshot.queues[selectedQueueIndex] : null
  readonly property var summaryQueue: {
    if (selectedQueue) return selectedQueue
    for (var i = 0; i < snapshot.queues.length; i++)
      if (snapshot.queues[i].isDefault) return snapshot.queues[i]
    return snapshot.queues.length > 0 ? snapshot.queues[0] : null
  }
  readonly property var displayOptions: PrinterState.quickOptions(options)
  readonly property int targetCount: snapshot.queues.length
    + displayOptions.length
    + (displayOptions.length > 0 ? 1 : 0)
    + 1
  readonly property int optionOffset: snapshot.queues.length
  readonly property int saveIndex: optionOffset + displayOptions.length
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
      pendingOptionsQueueIndex = -1
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

  function expandQueue(index) {
    if (busy || index < 0 || index >= snapshot.queues.length) return
    selectedQueueIndex = index
    var queueName = snapshot.queues[index].name
    var cached = optionCache[queueName]
    if (cached !== undefined) {
      applyOptions(cached)
      return
    }
    options = []
    optionValues = ({})
    cursorIndex = Math.min(cursorIndex, settingsIndex)
    activeQueueName = queueName
    runBackend("options", ["--queue", queueName])
  }

  function toggleQueue(index) {
    if (index < 0 || index >= snapshot.queues.length) return
    if (selectedQueueIndex === index) {
      if (busy && activeCommand !== "options") return
      closeOptionPopups()
      selectedQueueIndex = -1
      options = []
      optionValues = ({})
      cursorIndex = Math.min(cursorIndex, settingsIndex)
      return
    }
    if (busy) return
    expandQueue(index)
  }

  function applyOptions(nextOptions) {
    options = nextOptions || []
    var values = {}
    for (var i = 0; i < options.length; i++)
      values[options[i].name] = options[i].default
    optionValues = values
    cursorIndex = Math.min(cursorIndex, settingsIndex)
  }

  function cacheOptions(queueName, nextOptions) {
    var next = Object.assign({}, optionCache)
    next[queueName] = nextOptions || []
    optionCache = next
  }

  function closeOptionPopups() {
    for (var i = 0; i < optionRepeater.count; i++) {
      var optionItem = optionRepeater.itemAt(i)
      if (optionItem && optionItem.popupOpen) optionItem.close()
    }
  }

  function saveOptions() {
    if (!selectedQueue || displayOptions.length === 0) return
    var values = {}
    for (var i = 0; i < displayOptions.length; i++) {
      var option = displayOptions[i]
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
    if (displayOptions.length > 0 && index === saveIndex) return saveRow
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
      toggleQueue(activeIndex)
      return
    }
    if (activeIndex < saveIndex) {
      var optionItem = optionRepeater.itemAt(activeIndex - optionOffset)
      if (optionItem) optionItem.toggle()
      return
    }
    if (displayOptions.length > 0 && activeIndex === saveIndex) {
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
      var previousQueueName = selectedQueue ? selectedQueue.name : ""
      snapshot = {
        queues: data.queues || [],
        available: data.available || []
      }
      if (snapshot.queues.length === 0) {
        selectedQueueIndex = -1
        options = []
        optionValues = ({})
        pendingOptionsQueueIndex = -1
        cursorIndex = settingsIndex
        return
      }
      var defaultIndex = 0
      for (var i = 0; i < snapshot.queues.length; i++) {
        if (snapshot.queues[i].name === previousQueueName) {
          defaultIndex = i
          break
        }
        if (snapshot.queues[i].isDefault) {
          defaultIndex = i
        }
      }
      selectedQueueIndex = defaultIndex
      var cached = optionCache[snapshot.queues[defaultIndex].name]
      if (cached !== undefined) {
        applyOptions(cached)
      } else {
        options = []
        optionValues = ({})
        pendingOptionsQueueIndex = defaultIndex
        deferredOptionsLoad.restart()
      }
      return
    }
    if (command === "options") {
      var loadedOptions = data.options || []
      cacheOptions(activeQueueName, loadedOptions)
      if (selectedQueue && selectedQueue.name === activeQueueName)
        applyOptions(loadedOptions)
      return
    }
    if (command === "set-options") {
      var updatedOptions = options.map(function(option) {
        var updated = Object.assign({}, option)
        updated.default = optionValues[option.name]
        return updated
      })
      options = updatedOptions
      if (selectedQueue) cacheOptions(selectedQueue.name, updatedOptions)
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
      if (activeCommand === "options"
          && (!selectedQueue || selectedQueue.name !== activeQueueName))
        return
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
                text: root.summaryQueue ? root.summaryQueue.name : "Printers"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.summaryQueue
                  ? PrinterState.queueStatus(root.summaryQueue).toUpperCase()
                  : (root.busy ? "CHECKING PRINTERS" : "NO PRINTERS ADDED")
                color: root.summaryQueue && root.summaryQueue.online
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
                    id: presenceDot
                    text: modelData.online ? "●" : "○"
                    color: modelData.online ? Color.flatColor("green", root.bar.foreground) : Color.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Column {
                    width: parent.width - presenceDot.width - expandIcon.width - parent.spacing * 2
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

                  Text {
                    id: expandIcon
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.selectedQueueIndex === index ? "󰅃" : "󰅀"
                    color: Color.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: !root.busy
                    || (root.activeCommand === "options" && root.selectedQueueIndex === index)
                  onPositionChanged: function(mouse) { root.setPointerCursor(index, queueRow, mouse) }
                  onClicked: root.toggleQueue(index)
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
            visible: root.selectedQueue && root.displayOptions.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator {
              foreground: root.bar.foreground
            }

            PanelSectionHeader {
              text: "PRINTER OPTIONS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              id: optionRepeater
              model: root.displayOptions

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

          Column {
            visible: root.selectedQueue && root.displayOptions.length === 0
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator {
              foreground: root.bar.foreground
            }

            PanelSectionHeader {
              text: "PRINTER OPTIONS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Text {
              width: parent.width
              text: root.busy ? "Loading printer options…" : "No configurable options"
              color: Color.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
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
    id: deferredOptionsLoad
    interval: 10
    onTriggered: {
      if (backend.running) {
        restart()
        return
      }
      var index = root.pendingOptionsQueueIndex
      root.pendingOptionsQueueIndex = -1
      if (root.opened && index >= 0 && root.selectedQueueIndex === index)
        root.expandQueue(index)
    }
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
