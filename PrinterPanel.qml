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
  onSelectedQueueChanged: {
    if (viewName === "details" && selectedQueue && selectedQueue.isDefault && selectedIndex === 0)
      selectedIndex = 1
  }
  property var selectedDevice: null
  property bool detailsKeyboardFocus: false
  property string detailsTab: "settings"
  property var printerInfo: ({})
  property var jobs: []
  property bool optionsLoadFailed: false
  property bool jobsLoadFailed: false
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
  readonly property var printerService: shell ? shell.serviceFor("segersb.omarchy-printers") : null
  property bool liveUpdatePending: false
  readonly property string watchedQueue: window.visible && viewName === "details" && selectedQueue
    ? selectedQueue.name : ""
  onWatchedQueueChanged: if (printerService) printerService.selectedQueueName = watchedQueue
  onPrinterServiceChanged: if (printerService) printerService.selectedQueueName = watchedQueue
  onBusyChanged: if (!busy && liveUpdatePending) Qt.callLater(applyLiveStatus)

  Process {
    id: infoReader
    onRunningChanged: {
      if (running) infoTimeout.restart()
      else infoTimeout.stop()
    }
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.printerInfo = JSON.parse(text) } catch (error) { root.printerInfo = ({}) }
      }
    }
  }

  Timer {
    id: infoTimeout
    interval: 12000
    onTriggered: infoReader.signal(9)
  }

  function attributeRows() {
    var info = printerInfo
    var queue = selectedQueue || {}
    var rows = []
    function add(label, value) {
      if (value !== undefined && value !== null && String(value).length)
        rows.push({label: label, value: String(value)})
    }
    add("Status", PrinterState.queueStatus(queue))
    add("Details", info["printer-state-message"] || queue.stateMessage)
    add("Model", info["printer-make-and-model"] || queue["printer-make-and-model"])
    add("Description", info["printer-info"] || queue["printer-info"])
    add("Location", info["printer-location"] || queue["printer-location"])
    add("Connection", info.connection)
    add("Address", info.address)
    add("Default printer", queue.isDefault ? "Yes" : "No")
    add("Accepting jobs", queue.accepting ? "Yes" : "No")
    if (info["color-supported"] !== undefined) add("Color printing", info["color-supported"] ? "Supported" : "Monochrome")
    var sides = info["sides-supported"] || []
    if (sides.length) add("Two-sided printing", sides.length > 1 ? "Supported" : "Not supported")
    rows = rows.concat(PrinterState.supplyRows(info))
    var resolutions = info["printer-resolution-supported"] || []
    add("Resolution", resolutions.map(function(value) {
      return value[0] + " × " + value[1] + (value[2] === 4 ? " dpcm" : " dpi")
    }).join(", "))
    add("Printer ID", (info["printer-uuid"] || "").replace(/^urn:uuid:/, ""))
    var alerts = info["printer-alert-description"] || []
    if (typeof alerts === "string") alerts = [alerts]
    add("Printer status", alerts.join(" · "))
    return rows
  }

  function applyLiveStatus() {
    if (!printerService) return
    if (busy) { liveUpdatePending = true; return }
    liveUpdatePending = false
    var identity = viewName === "main" ? rowIdentity() : selectedIdentity
    snapshot = { queues: printerService.queues, available: snapshot.available }
    updateSelectedQueue()
    if (viewName === "main") {
      selectedIdentity = identity
      restoreCursor()
    }
    if (watchedQueue && printerService.jobQueue === watchedQueue) {
      var oldJobIndex = detailsTab === "jobs" ? selectedIndex - managementJobsOffset() : -1
      var jobId = oldJobIndex >= 0 && oldJobIndex < jobs.length ? jobs[oldJobIndex].id : -1
      jobs = printerService.jobs
      jobsLoadFailed = printerService.jobsFailed
      if (jobId >= 0) {
        for (var i = 0; i < jobs.length; i++)
          if (jobs[i].id === jobId) { selectedIndex = managementJobsOffset() + i; break }
      }
      selectedIndex = Math.max(-1, Math.min(selectedIndex, managementTargetCount() - 1))
    }
  }
  Connections {
    target: root.printerService
    function onUpdated() { root.applyLiveStatus() }
  }
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
  readonly property color background: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent

  onViewNameChanged: {
    controlPopupOpen = false
    if (viewName === "main") restoreCursor()
  }

  property var printDialogs: ({})
  Component { id: printDialogComponent; PrintDialog {} }
  PrintSetup {
    id: printSetup
    pluginDir: root.pluginDir
    onOpenedChanged: Qt.callLater(root.releaseIfUnused)
    onBusyChanged: Qt.callLater(root.releaseIfUnused)
  }

  function releaseIfUnused() {
    if (window.visible || printSetup.opened || printSetup.busy || Object.keys(printDialogs).length) return
    if (!closingFromHost && shell && typeof shell.hide === "function")
      shell.hide("segersb.omarchy-printers")
  }

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
    if (payload.integration === true) { printSetup.open(); return }
    if (payload.printRequest && /^[0-9a-f]{48}$/.test(payload.printRequest)) {
      var request = payload.printRequest
      if (!printDialogs[request]) {
        var dialog = printDialogComponent.createObject(root, {requestId: request, pluginDir: pluginDir})
        if (dialog) {
          printDialogs[request] = dialog
          dialog.finished.connect(function() {
            delete root.printDialogs[request]
            dialog.destroy()
            Qt.callLater(root.releaseIfUnused)
          })
        }
      }
      return
    }
    closingFromHost = false
    window.visible = true
    snapshot = {
      queues: snapshot.queues || [],
      available: []
    }
    scanVisible = false
    statusMessage = ""
    viewName = "main"
    restoreCursor()
    loadQueues()
    if (printerService) printerService.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
    window.visible = false
  }

  function rowIdentity() {
    if (focusSection === "scan") return ""
    var rows = focusSection === "installed" ? snapshot.queues : snapshot.available
    if (!rows || selectedIndex < 0 || selectedIndex >= rows.length) return ""
    return String(rows[selectedIndex].identity || "")
  }

  function restoreCursor() {
    if (focusSection === "scan") return
    var cursor = PrinterState.preserveCursor(snapshot, focusSection, selectedIdentity)
    focusSection = cursor.section
    selectedIndex = cursor.index
    selectedIdentity = rowIdentity()
    pointerGate.reset()
    Qt.callLater(function() { mainView.ensureCursorVisible() })
  }

  function moveCursor(delta, wrap) {
    pointerGate.reset()
    var cursor = PrinterState.moveMainCursor(snapshot, focusSection, selectedIndex, delta, busy, !!wrap)
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
    if (focusSection === "scan") {
      if (!busy) scan(selectedIndex === 1)
      return
    }
    var row = selectedRow()
    if (!row || busy) return
    if (focusSection === "installed") {
      selectedQueue = row
      jobs = []
      optionsLoadFailed = false
      jobsLoadFailed = false
      options = []
      optionValues = ({})
      detailsTab = "settings"
      printerInfo = ({})
      infoReader.running = false
      infoReader.command = ["python3", pluginDir + "/backend/printer_info.py", selectedQueue.name]
      infoReader.running = true
      viewName = "details"
      selectedIndex = selectedQueue.isDefault ? 1 : 0
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
    if (selectedIndex === 0) {
      if (!selectedQueue.isDefault) activateManagementAction("default")
    } else if (selectedIndex < 4) {
      activateManagementAction(["default", "enabled", "test", "remove"][selectedIndex])
    } else if (selectedIndex < managementOptionOffset()) {
      selectDetailsTab(["settings", "jobs", "attributes"][selectedIndex - 4])

    } else if (detailsTab === "settings" && selectedIndex < managementSaveIndex()) {
      var optionItem = managementView.optionItem(
        selectedIndex - managementOptionOffset())
      if (optionItem) optionItem.toggle()
    } else if (detailsTab === "settings" && managementDirty && selectedIndex === managementSaveIndex()) {
      saveManagementOptions()
    } else if (detailsTab === "jobs") {
      var jobIndex = selectedIndex - managementJobsOffset()
      if (jobIndex >= 0 && jobIndex < jobs.length)
        runBackend("cancel-job", ["--job-id", String(jobs[jobIndex].id)],
          selectedQueue.identity)
    }
  }

  function activateManagementAction(action) {
    if (!selectedQueue || busy) return
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
    }
  }

  function managementActions() {
    if (!selectedQueue) return []
    var actions = []
    actions.push("enabled", "test", "remove")
    return actions
  }

  function moveDetailsCursor(delta, maximum) {
    var next = Math.max(-1, Math.min(maximum, selectedIndex + delta))
    if (next === 0 && selectedQueue && selectedQueue.isDefault)
      next = delta > 0 ? 1 : -1
    selectedIndex = next
  }

  function selectDetailsTab(tab) {
    detailsTab = tab
    selectedIndex = 4 + ["settings", "jobs", "attributes"].indexOf(tab)
    managementView.resetScroll()
  }

  function managementOptionOffset() {
    return 7
  }

  function managementSaveIndex() {
    return managementOptionOffset() + managementOptions.length
  }

  function managementJobsOffset() {
    return managementOptionOffset()
  }

  function managementTargetCount() {
    if (detailsTab === "attributes") return managementOptionOffset()
    return detailsTab === "jobs"
      ? managementJobsOffset() + jobs.length
      : managementSaveIndex() + (managementDirty ? 1 : 0)
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

  function reloadJobs() {
    if (backend.running) {
      managementReload.restart()
      return
    }
    if (selectedQueue && viewName === "details")
      runBackend("jobs", ["--queue", selectedQueue.name], selectedQueue.identity)
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
      queues: snapshot.queues || [],
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
    if (backend.running) return
    activeCommand = command
    activeIdentity = identity || ""
    backendTimedOut = false
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
    if (["add", "remove", "set-default", "set-enabled", "set-options", "test-page", "cancel-job"].indexOf(command) >= 0
        && printerService) printerService.requestRefresh()
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
      optionsLoadFailed = !!data.optionsError
      jobsLoadFailed = !!data.jobsError
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
    if (command === "jobs") {
      jobs = data.jobs || []
      jobsLoadFailed = false
      selectedIndex = Math.max(-1, Math.min(
        selectedIndex, managementTargetCount() - 1))
      return
    }
    if (command === "cancel-job") {
      if (!selectedQueue) return
      managementReload.restart()
      return
    }
    if (command === "add") {
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
      viewName = "main"
      selectedQueue = null
    } else if (command === "set-enabled" && selectedQueue) {
      var updated = Object.assign({}, selectedQueue)
      updated.enabled = pendingQueueEnabled
      updated.accepting = pendingQueueEnabled
      selectedQueue = updated
    } else if (command === "set-options") {
      options = options.map(function(option) {
        var updatedOption = Object.assign({}, option)
        updatedOption.default = submittedOptionValues[option.name]
        return updatedOption
      })
      optionValues = Object.assign({}, submittedOptionValues)
      selectedIndex = Math.max(-1, Math.min(
        selectedIndex, managementTargetCount() - 1))
    }
    if (["add", "remove", "set-default", "set-enabled", "set-options"].indexOf(command) >= 0)
      quickRefreshAfterAction.restart()
    if (["add", "remove", "set-default", "set-enabled"].indexOf(command) >= 0)
      refreshAfterAction.restart()
  }

  function dismissError() {
    statusMessage = ""
    statusKind = ""
    failedIdentity = ""
    keyCatcher.forceActiveFocus()
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
      if (response.error && ["authorization-cancelled", "authorization-not-granted"].indexOf(response.error.code) >= 0) return
      if (activeCommand === "jobs") jobsLoadFailed = true
      failedIdentity = activeIdentity
      statusKind = "error"
      statusMessage = friendlyError(activeCommand, response.error)
      return
    }
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
    onTriggered: root.reloadJobs()
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: window.contentItem
  }

  FloatingWindow {
    id: window
    onClosed: visible = false
    title: "Printers · Settings"
    color: root.background
    implicitWidth: Style.space(600)
    implicitHeight: Style.space(540)
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: minimumSize
    visible: false

    onVisibleChanged: {
      if (!visible && !root.closingFromHost)
        Qt.callLater(root.releaseIfUnused)
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.controlPopupOpen
      onMoveRequested: function(dx, dy) {
        root.detailsKeyboardFocus = true
        if (confirmDialog.opened) {
          if (dx !== 0) confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (dx !== 0 && root.viewName === "details" && root.selectedIndex < 4) {
          root.moveDetailsCursor(dx, 3)
          return
        }
        if (dx !== 0 && root.viewName === "details"
            && root.selectedIndex >= 4
            && root.selectedIndex < root.managementOptionOffset()) {
          root.selectDetailsTab(["settings", "jobs", "attributes"][Math.max(0, Math.min(2, root.selectedIndex - 4 + dx))])
          return
        }
        if (root.viewName === "main" && root.focusSection === "scan" && dx !== 0) {
          if (!root.busy) root.selectedIndex = dx > 0 ? 1 : 0
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
            if (root.viewName === "details") root.moveDetailsCursor(dy, count - 1)
            else root.selectedIndex = Math.max(-1, Math.min(count - 1, root.selectedIndex + dy))
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
        else if (errorBanner.visible) root.dismissError()
        else root.requestClose()
      }
      onTabRequested: function(direction) {
        root.detailsKeyboardFocus = true
        if (confirmDialog.opened)
          confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
        else if (root.viewName === "main")
          root.moveCursor(direction, true)
        else if (root.viewName === "models")
          root.selectedIndex = Math.max(-1, Math.min(1, root.selectedIndex + direction))
        else if (root.viewName === "details") {
          root.moveDetailsCursor(direction, root.managementTargetCount() - 1)
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

            opacity: enabled ? 1 : 0.4
            visible: root.viewName !== "main"
            tooltipText: "Back"
            Accessible.name: "Back"
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: Math.max(0, (panelTitle.implicitHeight - implicitHeight) / 2)
            iconText: "󰁍"
            hasCursor: enabled && root.selectedIndex === -1
            onHovered: function(on) {
              if (on) root.selectedIndex = -1
            }
            onClicked: root.requestClose()
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(4)
            Item {
              id: titleRow
              Layout.fillWidth: true
              implicitHeight: panelTitle.implicitHeight
              Text {
                textFormat: Text.PlainText
                id: panelTitle
                text: {
                  if (root.viewName === "details" && root.selectedQueue) return root.selectedQueue.name
                  if (root.viewName === "models") return "Choose a driver"
                  return "Printers · Settings"
                }
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.display
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
                width: titleRow.width
                elide: Text.ElideRight
              }

            }
            Text {
              textFormat: Text.PlainText
              visible: root.viewName === "details"
              text: root.selectedQueue ? PrinterState.queueStatus(root.selectedQueue) : ""
              color: root.selectedQueue
                && PrinterState.queueStateKind(root.selectedQueue) === "attention"
                  ? Color.urgent
                  : (root.selectedQueue
                      && PrinterState.queueStateKind(root.selectedQueue) !== "paused"
                    ? Color.flatColor("green", root.accent) : Qt.darker(Color.foreground, 1.4))
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          RowLayout {
            visible: root.viewName === "details"
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(2)
            Repeater {
              model: ["default", "enabled", "test", "remove"]
              delegate: Button {
                id: headerAction
                required property string modelData
                required property int index
                readonly property bool isDefault: !!root.selectedQueue && root.selectedQueue.isDefault
                readonly property bool working: root.busy && root.activeCommand ===
                  ({"default": "set-default", "enabled": "set-enabled", "test": "test-page", "remove": "remove"})[modelData]
                readonly property string label: modelData === "default"
                  ? (isDefault ? "Default printer" : "Make default")
                  : modelData === "test" ? "Print test page"
                  : modelData === "remove" ? "Remove printer" : managementView.actionLabel(modelData)
                Layout.leftMargin: modelData === "remove" ? Style.spacing.controlGap : 0
                text: modelData === "default" ? (isDefault ? "★" : "☆") : ""
                iconText: modelData === "default" ? "" : managementView.actionIcon(modelData)
                foreground: working ? root.accent : modelData === "remove" ? root.urgent
                  : modelData === "default" && isDefault ? root.accent : root.foreground
                enabled: !root.busy && !(modelData === "default" && isDefault)
                opacity: working || enabled || (modelData === "default" && isDefault) ? 1 : 0.4
                hasCursor: enabled && root.selectedIndex === index
                Accessible.name: label
                onHovered: function(on) {
                  if (on && enabled) { root.detailsKeyboardFocus = false; root.selectedIndex = index }
                }
                onClicked: { root.selectedIndex = index; root.activateDetails() }
                ToolTip {
                  visible: window.visible && root.viewName === "details"
                    && headerAction.visible && headerAction.enabled && !confirmDialog.opened
                    && (headerAction.hot
                    && (!headerAction.hasCursor || root.detailsKeyboardFocus || hover.hovered))
                  text: headerAction.label
                  delay: 400
                  padding: Style.spacing.controlPaddingX
                  palette.toolTipText: Color.foreground
                  background: Rectangle {
                    color: Color.tooltip.background
                    border.color: Color.tooltip.border
                    border.width: 1
                  }
                }
                HoverHandler { id: hover }
              }
            }
          }

          Button {

            opacity: enabled ? 1 : 0.4
            visible: root.viewName === "main"
            text: root.busy && !root.fullScanActive ? "Scanning…" : "Network scan"
            iconText: "󰌗"
            tooltipText: "Find driverless network printers"
            hasCursor: enabled && root.focusSection === "scan" && root.selectedIndex === 0
            enabled: !root.busy
            onClicked: root.scan()
          }

          Button {

            opacity: enabled ? 1 : 0.4
            visible: root.viewName === "main"
            text: root.busy && root.fullScanActive ? "Scanning…" : "Full scan"
            iconText: "󰐷"
            tooltipText: "Find all printers · May require authentication"
            hasCursor: enabled && root.focusSection === "scan" && root.selectedIndex === 1
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




      }
    }

    Rectangle {
      id: errorBanner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.spacing.panelPadding
      height: errorContent.implicitHeight + Style.spacing.controlPaddingX * 2
      visible: root.statusKind === "error" && root.statusMessage !== "" && !confirmDialog.opened
      color: root.background
      border.color: root.urgent
      border.width: 1
      // Block clicks through the banner into the controls beneath it.
      MouseArea { anchors.fill: parent }
      RowLayout {
        id: errorContent
        anchors.fill: parent
        anchors.margins: Style.spacing.controlPaddingX
        spacing: Style.spacing.controlGap
        Text {
          textFormat: Text.PlainText
          text: root.statusMessage
          color: root.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Button {
          text: "×"
          tooltipText: "Dismiss error (Esc)"
          Accessible.name: "Dismiss error"
          focusable: true
          onClicked: root.dismissError()
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
                ? Qt.darker(Color.foreground, 1.4) : Color.flatColor("green", root.accent))
            hasCursor: enabled && root.focusSection === "installed" && root.selectedIndex === index
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
            hasCursor: enabled && root.focusSection === "available" && root.selectedIndex === index
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
      if (root.detailsTab === "jobs")
        return jobsRepeater.itemAt(index - root.managementJobsOffset())
      if (index < root.managementSaveIndex())
        return settingsRepeater.itemAt(index - root.managementOptionOffset())
      if (root.managementDirty && index === root.managementSaveIndex())
        return saveDefaults
      return jobsRepeater.itemAt(index - root.managementJobsOffset())
    }

    function resetScroll() {
      dashboardScroll.contentItem.contentY = 0
    }

    function ensureCursorVisible() {
      if (root.selectedIndex < root.managementOptionOffset()) return
      var item = targetItem(root.selectedIndex)
      var flickable = dashboardScroll.contentItem
      if (!item || item === saveDefaults || !flickable) return
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

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          Repeater {
            model: ["settings", "jobs", "attributes"]
            delegate: Button {
              required property string modelData
              required property int index
              readonly property bool current: root.detailsTab === modelData
              text: modelData === "attributes" ? "Attributes" : modelData === "settings" ? "Settings"
                : "Print jobs" + (root.jobs.length ? " · " + root.jobs.length : "")
              foreground: current ? root.accent : root.foreground
              color: "transparent"
              hasCursor: root.detailsKeyboardFocus
                && root.selectedIndex === 4 + index
              borderSpec: hasCursor
                ? Border.controlSpec("focus", foreground, accent) : Border.none()
              Accessible.role: Accessible.PageTab
              Accessible.name: text
              onClicked: {
                root.detailsKeyboardFocus = false
                root.selectDetailsTab(modelData)
              }

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Style.space(2)
                color: root.accent
                visible: parent.current
              }
            }
          }
          Item { Layout.fillWidth: true }
        }

        PanelSeparator { Layout.fillWidth: true }
      }

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

          Column {
            width: parent.width
            spacing: Style.spacing.panelGap
            visible: root.detailsTab === "attributes"

            Repeater {
              model: root.attributeRows()
              delegate: RowLayout {
                required property var modelData
                width: dashboardContent.width
                spacing: Style.spacing.rowGap
                Text {
                  textFormat: Text.PlainText
                  text: modelData.label
                  Layout.preferredWidth: parent.width * 0.32
                  Layout.alignment: Qt.AlignTop
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
                Row {
                  visible: (modelData.colors || []).length > 0
                  Layout.alignment: Qt.AlignVCenter
                  spacing: Style.space(2)
                  Repeater {
                    model: modelData.colors || []
                    delegate: Rectangle {
                      required property string modelData
                      width: Style.space(12)
                      height: width
                      color: modelData
                      border.width: 1
                      border.color: Qt.darker(Color.foreground, 1.4)
                    }
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.value
                  Layout.fillWidth: true
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WrapAnywhere
                }
              }
            }
            EmptyText { visible: infoReader.running; text: "Reading printer information…" }

          }

          Column {
            width: parent.width
            spacing: Style.spacing.panelGap
            visible: root.detailsTab === "settings"

            EmptyText {
              visible: root.managementOptions.length === 0
              text: root.busy && root.activeCommand === "manage"
                ? "Loading printer settings…"
                : (root.optionsLoadFailed ? "Couldn’t load printer settings" : "No printer settings available")
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
                  textFormat: Text.PlainText
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

                  opacity: enabled ? 1 : 0.4
                  id: settingDropdown
                  width: parent.width * 0.55
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  showLabel: false
                  enabled: !root.busy
                  hasCursor: enabled && root.selectedIndex
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


          }

          Column {
            width: parent.width
            spacing: Style.spacing.panelGap
            visible: root.detailsTab === "jobs"

            EmptyText {
              visible: root.jobs.length === 0
              text: root.busy && (root.activeCommand === "manage" || root.activeCommand === "jobs")
                ? "Loading print jobs…"
                : (root.jobsLoadFailed ? "Couldn’t load print jobs" : "No print jobs")
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
                hasCursor: enabled && root.selectedIndex === root.managementJobsOffset() + index
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
          }
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.detailsTab === "settings"
        spacing: Style.spacing.controlGap

        PanelSeparator { Layout.fillWidth: true }

        RowLayout {
          Layout.fillWidth: true
          Item { Layout.fillWidth: true }
          Button {

            opacity: enabled ? 1 : 0.4
            id: saveDefaults
            text: root.busy && root.activeCommand === "set-options"
              ? "Saving…" : "Save defaults"
            iconText: "󰆓"
            hasCursor: enabled && root.managementDirty
              && root.selectedIndex === root.managementSaveIndex()
            enabled: root.managementDirty && !root.busy
            onHovered: function(on) {
              if (on) root.selectedIndex = root.managementSaveIndex()
            }
            onClicked: root.saveManagementOptions()
          }
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
        textFormat: Text.PlainText
        text: root.selectedDevice ? "Confirm a local driver for " + root.selectedDevice.name : ""
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }

      SearchableDropdown {

        opacity: enabled ? 1 : 0.4
        id: modelPicker
        Layout.fillWidth: true
        label: "Driver"
        hasCursor: enabled && root.selectedIndex === 0
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

        opacity: enabled ? 1 : 0.4
        text: root.busy ? "Adding…" : "Add printer"
        iconText: "󰐕"
        bordered: true
        hasCursor: enabled && root.selectedIndex === 1
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
    property color statusColor: Qt.darker(Color.foreground, 1.4)
    property string actionText: ""
    property color actionColor: root.foreground
    property bool actionItalic: false
    property bool actionable: true
    property bool busy: false
    property bool failed: false
    signal activated()
    signal pointerMoved(var item, var mouse)

    implicitHeight: Style.space(58)
    enabled: actionable && !busy
    opacity: enabled ? 1 : 0.4
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
          textFormat: Text.PlainText
          text: row.title
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
        Text {
          textFormat: Text.PlainText
          text: row.busy ? "Working…" : row.subtitle
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
        color: row.actionable ? row.actionColor : Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.italic: row.actionItalic
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component SectionTitle: Text {
    textFormat: Text.PlainText
    Layout.fillHeight: false
    color: Qt.darker(Color.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Style.spaceReal(1)
  }

  component EmptyText: Text {
    textFormat: Text.PlainText
    Layout.fillHeight: false
    color: Qt.darker(Color.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    Layout.fillWidth: true
  }
}
