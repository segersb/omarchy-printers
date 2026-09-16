import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PrinterState.js" as PrinterState

Item {
  id: root

  property var shell: null
  property bool closingFromHost: false
  property string viewName: "main"
  property var snapshot: ({ queues: [], available: [] })
  property string focusSection: ""
  property int selectedIndex: -1
  property string selectedIdentity: ""
  property var selectedQueue: null
  property var selectedDevice: null
  property var jobs: []
  property var models: []
  property var options: []
  property var optionValues: ({})
  property var submittedOptionValues: ({})
  property bool scanVisible: false
  property bool activeLegacyDiscovery: false
  property string selectedModelId: ""
  property string statusMessage: ""
  property string statusKind: ""
  property string failedIdentity: ""
  property string activeCommand: ""
  property string activeIdentity: ""
  property bool controlPopupOpen: false
  property bool backendTimedOut: false
  property bool pendingSnapshotAfterQueues: false
  property bool pendingSnapshotIncludesLegacy: false
  property bool pendingQueueEnabled: false
  property bool busy: backend.running
  readonly property bool fullScanActive: pendingSnapshotAfterQueues
    ? pendingSnapshotIncludesLegacy : activeLegacyDiscovery
  readonly property var managementOptions: PrinterState.quickOptions(options)
  readonly property bool managementDirty: PrinterState.optionsDirty(
    managementOptions, optionValues)

  readonly property string pluginDir: {
    var path = Qt.resolvedUrl(".").toString()
    if (path.indexOf("file://") === 0) path = decodeURIComponent(path.substring(7))
    return path.replace(/\/$/, "")
  }
  readonly property string backendPath: pluginDir + "/backend/printers.py"
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent

  onViewNameChanged: {
    controlPopupOpen = false
    if (viewName === "main") restoreCursor()
  }

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    snapshot = {
      queues: queuesWithoutPresence(snapshot.queues),
      available: []
    }
    scanVisible = false
    statusMessage = ""
    viewName = "main"
    restoreCursor()
    loadQueues()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function queuesWithoutPresence(queues) {
    return (queues || []).map(function(queue) {
      var copy = Object.assign({}, queue)
      delete copy.online
      delete copy.presenceStale
      return copy
    })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (viewName !== "main") {
      controlPopupOpen = false
      statusMessage = ""
      viewName = "main"
      restoreCursor()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }
    if (shell && typeof shell.hide === "function")
      shell.hide("segersb.omarchy-printers")
    else
      window.visible = false
  }

  function keyboardHint() {
    if (viewName === "main")
      return "j/k or arrows navigate · enter select · r network scan · f full scan · esc close"
    if (viewName === "details")
      return "j/k or arrows navigate · enter activate · esc back"
    return "j/k or arrows navigate · enter select · esc back"
  }

  function rowIdentity() {
    var rows = focusSection === "installed" ? snapshot.queues : snapshot.available
    if (!rows || selectedIndex < 0 || selectedIndex >= rows.length) return ""
    return String(rows[selectedIndex].identity || "")
  }

  function restoreCursor() {
    var cursor = PrinterState.preserveCursor(snapshot, focusSection, selectedIdentity)
    focusSection = cursor.section
    selectedIndex = cursor.index
    selectedIdentity = rowIdentity()
    pointerGate.reset()
    Qt.callLater(function() { mainView.ensureCursorVisible() })
  }

  function moveCursor(delta) {
    pointerGate.reset()
    var cursor = PrinterState.moveCursor(snapshot, focusSection, selectedIndex, delta)
    focusSection = cursor.section
    selectedIndex = cursor.index
    selectedIdentity = rowIdentity()
    Qt.callLater(function() { mainView.ensureCursorVisible() })
  }

  function selectedRow() {
    var rows = focusSection === "installed" ? snapshot.queues : snapshot.available
    if (!rows || selectedIndex < 0 || selectedIndex >= rows.length) return null
    return rows[selectedIndex]
  }

  function selectFromPointer(section, index, identity, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    focusSection = section
    selectedIndex = index
    selectedIdentity = identity
  }

  function activateMainRow() {
    var row = selectedRow()
    if (!row || busy) return
    if (focusSection === "installed") {
      selectedQueue = row
      jobs = []
      options = []
      optionValues = ({})
      viewName = "details"
      selectedIndex = 0
      runBackend("manage", ["--queue", selectedQueue.name], selectedQueue.identity)
    } else {
      if (!PrinterState.scanResultCanInstall(row)) return
      selectedDevice = row
      if (row.driverless) {
        runBackend("add", [
          "--name", row.name,
          "--uri", row.uri,
          "--queue", row.queueName,
          "--model", "everywhere"
        ], row.identity)
      } else {
        var args = ["--device-uri", row.uri]
        if (row["device-id"]) args.push("--device-id", row["device-id"])
        if (row["device-make-and-model"])
          args.push("--device-make-and-model", row["device-make-and-model"])
        if (row["device-uuid"]) args.push("--device-uuid", row["device-uuid"])
        runBackend("models", args, row.identity)
      }
    }
  }

  function activateDetails() {
    if (!selectedQueue) return
    if (selectedIndex < 0) return
    var actions = managementActions()
    var action = selectedIndex < actions.length ? actions[selectedIndex] : ""
    if (action === "default")
      runBackend("set-default", ["--queue", selectedQueue.name], selectedQueue.identity)
    else if (action === "enabled") {
      pendingQueueEnabled = !selectedQueue.enabled
      runBackend("set-enabled", [
        "--queue", selectedQueue.name,
        "--enabled", pendingQueueEnabled ? "true" : "false"
      ], selectedQueue.identity)
    }
    else if (action === "test")
      runBackend("test-page", ["--queue", selectedQueue.name], selectedQueue.identity)
    else if (action === "remove") {
      confirmDialog.message = "Remove " + selectedQueue.name + "?"
      confirmDialog.selectedIndex = 0
      confirmDialog.opened = true
    } else if (selectedIndex < managementSaveIndex()) {
      var optionItem = managementView.optionItem(
        selectedIndex - managementOptionOffset())
      if (optionItem) optionItem.toggle()
    } else if (managementDirty && selectedIndex === managementSaveIndex()) {
      saveManagementOptions()
    } else {
      var jobIndex = selectedIndex - managementJobsOffset()
      if (jobIndex >= 0 && jobIndex < jobs.length)
        runBackend("cancel-job", ["--job-id", String(jobs[jobIndex].id)],
          selectedQueue.identity)
    }
  }

  function managementActions() {
    if (!selectedQueue) return []
    var actions = []
    if (!selectedQueue.isDefault) actions.push("default")
    actions.push("enabled", "test", "remove")
    return actions
  }

  function managementOptionOffset() {
    return managementActions().length
  }

  function managementSaveIndex() {
    return managementOptionOffset() + managementOptions.length
  }

  function managementJobsOffset() {
    return managementSaveIndex() + (managementDirty ? 1 : 0)
  }

  function managementTargetCount() {
    return managementJobsOffset() + jobs.length
  }

  function saveManagementOptions() {
    if (!selectedQueue || !managementDirty || busy) return
    var values = {}
    for (var i = 0; i < managementOptions.length; i++) {
      var option = managementOptions[i]
      values[option.name] = optionValues[option.name]
    }
    submittedOptionValues = Object.assign({}, values)
    runBackend("set-options", [
      "--queue", selectedQueue.name,
      "--options", JSON.stringify(values)
    ], selectedQueue.identity)
  }

  function loadQueues() {
    if (busy) return
    selectedIdentity = rowIdentity()
    activeLegacyDiscovery = false
    pendingSnapshotAfterQueues = false
    pendingSnapshotIncludesLegacy = false
    runBackend("queues", ["--json", "{}"], "")
  }

  function scan(includeLegacy) {
    if (busy) return
    selectedIdentity = rowIdentity()
    snapshot = {
      queues: queuesWithoutPresence(snapshot.queues),
      available: []
    }
    scanVisible = true
    pendingSnapshotAfterQueues = true
    pendingSnapshotIncludesLegacy = includeLegacy === true
    runBackend("queues", ["--json", "{}"], "")
  }

  function runPendingSnapshot() {
    if (!pendingSnapshotAfterQueues || backend.running) return
    pendingSnapshotAfterQueues = false
    activeLegacyDiscovery = pendingSnapshotIncludesLegacy
    pendingSnapshotIncludesLegacy = false
    var args = ["--timeout", "2"]
    if (activeLegacyDiscovery) args.push("--include-legacy", "true")
    runBackend("snapshot", args, "")
  }

  function runBackend(command, args, identity) {
    if (backend.running) {
      statusKind = ""
      statusMessage = "Please wait for the current printer operation"
      return
    }
    activeCommand = command
    activeIdentity = identity || ""
    backendTimedOut = false
    if (command !== "snapshot") statusMessage = ""
    backend.command = ["python3", backendPath, command].concat(args || [])
    backend.running = true
    backendTimeout.restart()
  }

  function responseData(response) {
    return response && response.data ? response.data : ({})
  }

  function updateSelectedQueue() {
    if (!selectedQueue) return
    var updatedQueue = null
    for (var i = 0; i < snapshot.queues.length; i++) {
      if (snapshot.queues[i].identity === selectedQueue.identity) {
        updatedQueue = snapshot.queues[i]
        break
      }
    }
    selectedQueue = updatedQueue
    if (!selectedQueue && viewName !== "main") viewName = "main"
  }

  function handleSuccess(command, data) {
    failedIdentity = ""
    if (command === "queues") {
      var queues = data.queues || []
      snapshot = {
        queues: queues,
        available: PrinterState.mergeAvailable(snapshot.available, [], queues)
      }
      updateSelectedQueue()
      if (viewName === "main") restoreCursor()
      return
    }
    if (command === "snapshot") {
      var currentAvailable = data.scanResults || data.available || data.discovered || []
      snapshot = {
        queues: data.queues || [],
        available: currentAvailable
      }
      if (data.warning) {
        statusKind = ""
        statusMessage = String(data.warning.message || "Printer discovery is unavailable")
      }
      updateSelectedQueue()
      if (viewName === "main") {
        restoreCursor()
      }
      return
    }
    if (command === "models") {
      var recommendation = data.recommendation || null
      var recommendedName = recommendation ? String(recommendation.name || "") : ""
      models = (data.models || []).map(function(model) {
        var id = String(model.name || "")
        return {
          id: id,
          label: String(model.makeAndModel || id),
          description: String(model.deviceId || ""),
          recommended: id === recommendedName,
          reason: id === recommendedName ? String(data.reason || "") : ""
        }
      })
      selectedModelId = recommendedName || (models.length ? models[0].id : "")
      viewName = "models"
      selectedIndex = 0
      return
    }
    if (command === "manage") {
      if (!selectedQueue) return
      options = data.options || []
      var values = {}
      for (var i = 0; i < options.length; i++)
        values[options[i].name] = options[i].default
      optionValues = values
      jobs = data.jobs || []
      selectedIndex = Math.max(-1, Math.min(
        selectedIndex, managementTargetCount() - 1))
      return
    }
    if (command === "cancel-job") {
      if (!selectedQueue) return
      statusMessage = "Print job cancelled"
      managementReload.restart()
      return
    }
    if (command === "add") {
      statusMessage = "Printer added"
      snapshot = {
        queues: snapshot.queues,
        available: snapshot.available.map(function(device) {
          if (device.identity !== activeIdentity) return device
          var installed = Object.assign({}, device)
          installed.installed = true
          installed.installedQueue = device.queueName || ""
          delete installed.queueName
          return installed
        })
      }
      viewName = "main"
      selectedDevice = null
      selectedModelId = ""
    }
    else if (command === "remove") {
      statusMessage = "Printer removed"
      viewName = "main"
      selectedQueue = null
    } else if (command === "set-enabled" && selectedQueue) {
      var updated = Object.assign({}, selectedQueue)
      updated.enabled = pendingQueueEnabled
      updated.accepting = pendingQueueEnabled
      selectedQueue = updated
      statusMessage = pendingQueueEnabled ? "Printer resumed" : "Printer paused"
    } else if (command === "test-page") statusMessage = "Test page sent"
    else if (command === "set-options") {
      options = options.map(function(option) {
        var updatedOption = Object.assign({}, option)
        updatedOption.default = submittedOptionValues[option.name]
        return updatedOption
      })
      optionValues = Object.assign({}, submittedOptionValues)
      selectedIndex = Math.max(-1, Math.min(
        selectedIndex, managementTargetCount() - 1))
      statusMessage = "Defaults saved"
    }
    if (["add", "remove", "set-default", "set-enabled", "set-options"].indexOf(command) >= 0)
      quickRefreshAfterAction.restart()
    if (["add", "remove", "set-default", "set-enabled"].indexOf(command) >= 0)
      refreshAfterAction.restart()
  }

  function friendlyError(command, error) {
    if (error && error.message) return String(error.message)
    if (command === "add") return "Couldn’t add printer"
    if (command === "remove") return "Couldn’t remove printer"
    if (command === "snapshot") return "Couldn’t load printers"
    return "Printer operation failed"
  }

  function handleBackendResult() {
    backendTimeout.stop()
    if (backendTimedOut) return
    var response = null
    try {
      response = JSON.parse(backendOut.text)
    } catch (e) {
      statusKind = "error"
      statusMessage = "Printer service returned an invalid response"
      return
    }
    if (!response.ok) {
      failedIdentity = activeIdentity
      statusKind = "error"
      statusMessage = friendlyError(activeCommand, response.error)
      return
    }
    statusKind = activeCommand === "snapshot" || activeCommand === "queues" ? "" : "success"
    if (activeCommand === "snapshot" || activeCommand === "queues") statusMessage = ""
    handleSuccess(activeCommand, responseData(response))
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
    onExited: function(exitCode) {
      if (root.backendTimedOut) return
      if (exitCode !== 0 && backendOut.text.trim() === "") {
        root.statusKind = "error"
        root.statusMessage = "Printer service stopped unexpectedly"
      } else {
        root.handleBackendResult()
      }
      Qt.callLater(root.runPendingSnapshot)
    }
  }

  Timer {
    id: backendTimeout
    interval: 25000
    onTriggered: {
      root.backendTimedOut = true
      backend.signal(15)
      root.failedIdentity = root.activeIdentity
      root.statusKind = "error"
      root.statusMessage = "Printer operation timed out"
    }
  }

  Timer {
    id: refreshAfterAction
    interval: 350
    onTriggered: root.loadQueues()
  }

  Timer {
    id: quickRefreshAfterAction
    interval: 500
    onTriggered: Quickshell.execDetached([
      "omarchy-shell", "segersb.omarchy-printers.quick", "refresh"
    ])
  }

  Timer {
    id: managementReload
    interval: 50
    onTriggered: {
      if (backend.running) {
        restart()
        return
      }
      if (root.selectedQueue && root.viewName === "details")
        root.runBackend("manage", ["--queue", root.selectedQueue.name],
          root.selectedQueue.identity)
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: window.contentItem
  }

  FloatingWindow {
    id: window
    title: "Printers"
    color: root.background
    implicitWidth: Style.space(600)
    implicitHeight: Style.space(620)
    minimumSize: Qt.size(Style.space(460), Style.space(440))
    visible: false

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("segersb.omarchy-printers")
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.controlPopupOpen
      onMoveRequested: function(dx, dy) {
        if (confirmDialog.opened) {
          if (dx !== 0) confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (dy === 0) return
        pointerGate.reset()
        if (root.viewName === "main") root.moveCursor(dy)
        else {
          var count = root.viewName === "details"
            ? root.managementTargetCount()
            : (root.viewName === "models" ? 2 : 0)
          if (count > 0) {
            root.selectedIndex = Math.max(-1, Math.min(count - 1, root.selectedIndex + dy))
            if (root.viewName === "details")
              Qt.callLater(function() { managementView.ensureCursorVisible() })
          } else root.selectedIndex = -1
        }
      }
      onActivateRequested: {
        if (confirmDialog.opened) {
          if (confirmDialog.selectedIndex === 0) confirmDialog.canceled()
          else confirmDialog.confirmed()
          return
        }
        if (root.viewName !== "main" && root.selectedIndex === -1)
          root.requestClose()
        else if (root.viewName === "main") root.activateMainRow()
        else if (root.viewName === "details") root.activateDetails()
        else if (root.viewName === "models") modelsView.activate(root.selectedIndex)
      }
      onCloseRequested: {
        if (confirmDialog.opened) confirmDialog.canceled()
        else root.requestClose()
      }
      onTabRequested: function(direction) {
        if (confirmDialog.opened)
          confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
        else if (root.viewName === "models")
          root.selectedIndex = Math.max(-1, Math.min(1, root.selectedIndex + direction))
        else if (root.viewName === "details") {
          root.selectedIndex = Math.max(-1, Math.min(
            root.managementTargetCount() - 1, root.selectedIndex + direction))
          Qt.callLater(function() { managementView.ensureCursorVisible() })
        }
      }
      onDeleteRequested: {
        if (root.viewName === "details" && root.selectedQueue) {
          confirmDialog.message = "Remove " + root.selectedQueue.name + "?"
          confirmDialog.selectedIndex = 0
          confirmDialog.opened = true
        }
      }
      onTextKey: function(text) {
        if (text === "r" && root.viewName === "main") root.scan()
        else if (text === "f" && root.viewName === "main") root.scan(true)
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.panelGap

        RowLayout {
          Layout.fillWidth: true

          Button {
            visible: root.viewName !== "main"
            text: "Back"
            iconText: "󰁍"
            hasCursor: root.selectedIndex === -1
            onHovered: function(on) {
              if (on) root.selectedIndex = -1
            }
            onClicked: root.requestClose()
          }

          Text {
            text: {
              if (root.viewName === "details" && root.selectedQueue) return root.selectedQueue.name
              if (root.viewName === "models") return "Choose a driver"
              return "Printers"
            }
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
            Layout.fillWidth: true
            elide: Text.ElideRight
          }

          Button {
            visible: root.viewName === "main"
            text: root.busy && !root.fullScanActive ? "Scanning…" : "Network scan"
            iconText: "󰌗"
            tooltipText: "Find driverless network printers"
            enabled: !root.busy
            onClicked: root.scan()
          }

          Button {
            visible: root.viewName === "main"
            text: root.busy && root.fullScanActive ? "Scanning…" : "Full scan"
            iconText: "󰐷"
            tooltipText: "Find all printers · May require authentication"
            enabled: !root.busy
            onClicked: root.scan(true)
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        MainView {
          id: mainView
          visible: root.viewName === "main"
          Layout.fillWidth: true
          Layout.fillHeight: true
        }

        DetailsView {
          id: managementView
          visible: root.viewName === "details"
          Layout.fillWidth: true
          Layout.fillHeight: true
        }

        ModelsView {
          id: modelsView
          visible: root.viewName === "models"
          Layout.fillWidth: true
          Layout.fillHeight: true
        }

        Text {
          visible: root.statusMessage !== ""
          text: root.statusMessage
          color: root.statusKind === "error" ? root.urgent
            : (root.statusKind === "success" ? Color.flatColor("green", root.accent) : Color.muted)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
        }

        Text {
          text: root.keyboardHint()
          color: Util.alpha(Color.muted, 0.75)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignHCenter
        }
      }
    }

    ConfirmDialog {
      id: confirmDialog
      anchors.fill: parent
      confirmText: "Remove"
      onCanceled: opened = false
      onConfirmed: {
        opened = false
        if (root.selectedQueue)
          root.runBackend("remove", ["--queue", root.selectedQueue.name], root.selectedQueue.identity)
      }
    }
  }

  component MainView: Item {
    id: main

    function ensureCursorVisible() {
      if (root.focusSection === "installed" && root.selectedIndex >= 0)
        installedList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      else if (root.focusSection === "available" && root.selectedIndex >= 0)
        availableList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    }

    Column {
      anchors.fill: parent
      spacing: Style.spacing.panelGap

      Column {
        width: parent.width
        height: childrenRect.height
        spacing: Style.spacing.rowGap

        SectionTitle { text: "Installed" }

        EmptyText {
          visible: root.snapshot.queues.length === 0
          text: root.busy && root.activeCommand === "queues"
            ? "Checking installed printers…" : "No printers added"
        }

        ListView {
          id: installedList
          visible: root.snapshot.queues.length > 0
          width: parent.width
          height: visible ? Math.min(contentHeight, Style.space(230)) : 0
          clip: true
          spacing: Style.spacing.rowGap
          model: root.snapshot.queues
          currentIndex: root.focusSection === "installed" ? root.selectedIndex : -1
          delegate: PrinterRow {
            required property var modelData
            required property int index
            width: ListView.view.width
            title: modelData.name
            subtitle: PrinterState.queueStatus(modelData)
            statusColor: PrinterState.queueStateKind(modelData) === "attention"
              ? Color.urgent
              : (PrinterState.queueStateKind(modelData) === "paused"
                ? Color.muted : Color.flatColor("green", root.accent))
            hasCursor: root.focusSection === "installed" && root.selectedIndex === index
            actionText: "Manage"
            busy: root.busy && root.activeIdentity === modelData.identity
            failed: root.failedIdentity === modelData.identity
            onPointerMoved: function(item, mouse) {
              root.selectFromPointer("installed", index, modelData.identity, item, mouse)
            }
            onActivated: {
              root.focusSection = "installed"
              root.selectedIndex = index
              root.selectedIdentity = modelData.identity
              root.activateMainRow()
            }
          }
        }
      }

      Column {
        visible: root.scanVisible
        width: parent.width
        height: Math.max(0, main.height - y)
        spacing: Style.spacing.rowGap

        SectionTitle { text: "Scan results" }

        EmptyText {
          visible: root.snapshot.available.length === 0
          text: root.busy ? "Looking for printers…" : "No printers found"
        }

        ListView {
          id: availableList
          visible: root.snapshot.available.length > 0
          width: parent.width
          height: visible ? Math.max(0, parent.height - y) : 0
          clip: true
          spacing: Style.spacing.rowGap
          model: root.snapshot.available
          currentIndex: root.focusSection === "available" ? root.selectedIndex : -1
          delegate: PrinterRow {
            required property var modelData
            required property int index
            width: ListView.view.width
            title: modelData.name
            subtitle: modelData.installed
              ? (modelData.transportLabel || "Printer")
              : (modelData.driverless
                ? (modelData.transportLabel || "Ready to add")
                : ((modelData.transportLabel || "Printer") + " · Choose a driver"))
            hasCursor: root.focusSection === "available" && root.selectedIndex === index
            actionText: modelData.installed
              ? "Installed"
              : (root.failedIdentity === modelData.identity ? "Retry" : "Install")
            actionItalic: modelData.installed === true
            actionable: PrinterState.scanResultCanInstall(modelData)
            busy: root.busy && root.activeIdentity === modelData.identity
            failed: root.failedIdentity === modelData.identity
            onPointerMoved: function(item, mouse) {
              root.selectFromPointer("available", index, modelData.identity, item, mouse)
            }
            onActivated: {
              root.focusSection = "available"
              root.selectedIndex = index
              root.selectedIdentity = modelData.identity
              root.activateMainRow()
            }
          }

        }
      }
    }
  }

  component DetailsView: Item {
    id: details
    readonly property var actions: root.managementActions()
    readonly property var routineActions: actions.filter(function(action) {
      return action !== "remove"
    })

    function actionLabel(action) {
      if (action === "default")
        return root.busy && root.activeCommand === "set-default"
          ? "Setting…" : "Make default"
      if (action === "enabled") {
        if (root.busy && root.activeCommand === "set-enabled")
          return root.pendingQueueEnabled ? "Resuming…" : "Pausing…"
        return root.selectedQueue && root.selectedQueue.enabled ? "Pause" : "Resume"
      }
      if (action === "test")
        return root.busy && root.activeCommand === "test-page"
          ? "Sending…" : "Test page"
      return "Remove"
    }

    function actionIcon(action) {
      if (action === "default") return "󰓎"
      if (action === "enabled")
        return root.selectedQueue && root.selectedQueue.enabled ? "󰏤" : "󰐊"
      if (action === "test") return "󰐪"
      return "󰆴"
    }

    function optionItem(index) {
      return settingsRepeater.itemAt(index)
    }

    function targetItem(index) {
      if (index < routineActions.length) return actionRepeater.itemAt(index)
      if (index === actions.length - 1) return removeAction
      if (index < root.managementSaveIndex())
        return settingsRepeater.itemAt(index - root.managementOptionOffset())
      if (root.managementDirty && index === root.managementSaveIndex())
        return saveDefaults
      return jobsRepeater.itemAt(index - root.managementJobsOffset())
    }

    function ensureCursorVisible() {
      if (root.selectedIndex < root.managementOptionOffset()) return
      var item = targetItem(root.selectedIndex)
      var flickable = dashboardScroll.contentItem
      if (!item || !flickable) return
      var point = item.mapToItem(dashboardContent, 0, 0)
      var top = point.y
      var bottom = top + item.height
      if (top < flickable.contentY)
        flickable.contentY = Math.max(0, top)
      else if (bottom > flickable.contentY + dashboardScroll.availableHeight)
        flickable.contentY = bottom - dashboardScroll.availableHeight
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.panelGap

      Text {
        text: root.selectedQueue ? PrinterState.queueStatus(root.selectedQueue) : ""
        color: root.selectedQueue
          && PrinterState.queueStateKind(root.selectedQueue) === "attention"
            ? Color.urgent
            : (root.selectedQueue
                && PrinterState.queueStateKind(root.selectedQueue) !== "paused"
              ? Color.flatColor("green", root.accent) : Color.muted)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.controlGap

        Repeater {
          id: actionRepeater
          model: details.routineActions
          delegate: Button {
            required property string modelData
            required property int index
            text: details.actionLabel(modelData)
            iconText: details.actionIcon(modelData)
            hasCursor: root.selectedIndex === index
            enabled: !root.busy
            onHovered: function(on) {
              if (on) root.selectedIndex = index
            }
            onClicked: {
              root.selectedIndex = index
              root.activateDetails()
            }
          }
        }

        Item { Layout.fillWidth: true }

        Button {
          id: removeAction
          text: "Remove"
          iconText: details.actionIcon("remove")
          foreground: root.urgent
          hasCursor: root.selectedIndex === details.actions.length - 1
          enabled: !root.busy
          onHovered: function(on) {
            if (on) root.selectedIndex = details.actions.length - 1
          }
          onClicked: {
            root.selectedIndex = details.actions.length - 1
            root.activateDetails()
          }
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      ScrollView {
        id: dashboardScroll
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
          id: dashboardContent
          width: dashboardScroll.availableWidth
          spacing: Style.spacing.panelGap

          SectionTitle { text: "Printer settings" }

          EmptyText {
            visible: root.managementOptions.length === 0
            text: root.busy && root.activeCommand === "manage"
              ? "Loading printer settings…" : "No printer settings available"
          }

          Repeater {
            id: settingsRepeater
            model: root.managementOptions
            delegate: Item {
              id: settingRow
              required property var modelData
              required property int index
              width: dashboardContent.width
              height: settingDropdown.implicitHeight

              function toggle() { settingDropdown.toggle() }

              Text {
                anchors.left: parent.left
                anchors.right: settingDropdown.left
                anchors.rightMargin: Style.spacing.rowGap
                anchors.verticalCenter: parent.verticalCenter
                text: PrinterState.optionLabel(settingRow.modelData)
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Dropdown {
                id: settingDropdown
                width: parent.width * 0.55
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                showLabel: false
                enabled: !root.busy
                hasCursor: root.selectedIndex
                  === root.managementOptionOffset() + settingRow.index
                value: String(root.optionValues[settingRow.modelData.name] || "")
                options: PrinterState.optionChoices(settingRow.modelData)
                onHovered: function(on) {
                  if (on)
                    root.selectedIndex = root.managementOptionOffset() + settingRow.index
                }
                onPopupOpenChanged: root.controlPopupOpen = popupOpen
                onChanged: function(value) {
                  var next = Object.assign({}, root.optionValues)
                  next[settingRow.modelData.name] = value
                  root.optionValues = next
                }
              }
            }
          }

          Button {
            id: saveDefaults
            text: root.busy && root.activeCommand === "set-options"
              ? "Saving…" : "Save defaults"
            iconText: "󰆓"
            hasCursor: root.managementDirty
              && root.selectedIndex === root.managementSaveIndex()
            enabled: root.managementDirty && !root.busy
            opacity: root.managementDirty ? 1 : 0.5
            onHovered: function(on) {
              if (on) root.selectedIndex = root.managementSaveIndex()
            }
            onClicked: root.saveManagementOptions()
          }

          PanelSeparator { width: parent.width }
          SectionTitle { text: "Print jobs" }

          EmptyText {
            visible: root.jobs.length === 0
            text: root.busy && root.activeCommand === "manage"
              ? "Loading print jobs…" : "No print jobs"
          }

          Repeater {
            id: jobsRepeater
            model: root.jobs
            delegate: PrinterRow {
              required property var modelData
              required property int index
              width: dashboardContent.width
              title: modelData.name || ("Job " + modelData.id)
              subtitle: (modelData.user || "")
                + (modelData.stateLabel ? " · " + modelData.stateLabel : "")
              actionText: "Cancel"
              actionColor: root.urgent
              hasCursor: root.selectedIndex === root.managementJobsOffset() + index
              busy: root.busy && root.activeCommand === "cancel-job"
              onPointerMoved: function(item, mouse) {
                if (pointerGate.moved(item, mouse))
                  root.selectedIndex = root.managementJobsOffset() + index
              }
              onActivated: {
                root.selectedIndex = root.managementJobsOffset() + index
                root.activateDetails()
              }
            }
          }

          Item { width: 1; height: Style.spacing.panelGap }
        }
      }
    }
  }

  component ModelsView: Item {
    function activate(index) {
      if (index === 0) {
        modelPicker.toggle()
      } else if (root.selectedDevice && root.selectedModelId) {
        root.runBackend("add",
          ["--name", root.selectedDevice.name,
           "--uri", root.selectedDevice.uri,
           "--queue", root.selectedDevice.queueName,
           "--model", root.selectedModelId],
          root.selectedDevice.identity)
      }
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.panelGap

      Text {
        text: root.selectedDevice ? "Confirm a local driver for " + root.selectedDevice.name : ""
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }

      SearchableDropdown {
        id: modelPicker
        Layout.fillWidth: true
        label: "Driver"
        hasCursor: root.selectedIndex === 0
        value: root.selectedModelId
        options: root.models.map(function(model) {
          return {
            value: model.id,
            label: model.label,
            description: model.recommended ? "Recommended · " + (model.reason || "") : (model.description || "")
          }
        })
        onPopupOpenChanged: root.controlPopupOpen = popupOpen
        onChanged: function(value) { root.selectedModelId = value }
      }

      Button {
        text: root.busy ? "Adding…" : "Add printer"
        iconText: "󰐕"
        bordered: true
        hasCursor: root.selectedIndex === 1
        enabled: !root.busy && root.selectedDevice && root.selectedModelId !== ""
        onClicked: root.runBackend("add",
          ["--name", root.selectedDevice.name,
           "--uri", root.selectedDevice.uri,
           "--queue", root.selectedDevice.queueName,
           "--model", root.selectedModelId],
          root.selectedDevice.identity)
      }

      Item { Layout.fillHeight: true }
    }
  }

  component PrinterRow: CursorSurface {
    id: row
    property string title: ""
    property string subtitle: ""
    property color statusColor: Color.muted
    property string actionText: ""
    property color actionColor: root.foreground
    property bool actionItalic: false
    property bool actionable: true
    property bool busy: false
    property bool failed: false
    signal activated()
    signal pointerMoved(var item, var mouse)

    implicitHeight: Style.space(58)
    bordered: true

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.actionable && !row.busy
        ? Qt.PointingHandCursor : Qt.ArrowCursor
      onPositionChanged: function(mouse) { row.pointerMoved(row, mouse) }
      onClicked: if (row.actionable && !row.busy) row.activated()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: row.borderLeft + Style.spacing.rowPaddingX
      anchors.rightMargin: row.borderRight + Style.spacing.rowPaddingX
      spacing: Style.spacing.rowGap

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.xs
        Text {
          text: row.title
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
        Text {
          text: row.busy ? "Working…" : (row.failed ? root.statusMessage : row.subtitle)
          color: row.failed ? root.urgent : row.statusColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
      }

      Text {
        textFormat: Text.PlainText
        text: row.actionText
        color: row.actionable ? row.actionColor : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.italic: row.actionItalic
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component SectionTitle: Text {
    Layout.fillHeight: false
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Style.spaceReal(1)
  }

  component EmptyText: Text {
    Layout.fillHeight: false
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    Layout.fillWidth: true
  }
}
