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
  property bool scanVisible: false
  property bool activeLegacyDiscovery: false
  property string selectedModelId: ""
  property string statusMessage: ""
  property string statusKind: ""
  property string failedIdentity: ""
  property string activeCommand: ""
  property string activeIdentity: ""
  property bool controlPopupOpen: false
  property string selectedActionId: ""
  property bool backendTimedOut: false
  property bool pendingSnapshotAfterQueues: false
  property bool pendingSnapshotIncludesLegacy: false
  property bool busy: backend.running
  readonly property bool fullScanActive: pendingSnapshotAfterQueues
    ? pendingSnapshotIncludesLegacy : activeLegacyDiscovery

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
      if ((viewName === "jobs" || viewName === "options") && selectedQueue) {
        var parentAction = viewName
        viewName = "details"
        var actions = detailActions()
        selectedIndex = Math.max(0, actions.indexOf(parentAction))
        selectedActionId = actions[selectedIndex]
      } else {
        viewName = "main"
        restoreCursor()
      }
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }
    if (shell && typeof shell.hide === "function")
      shell.hide("segersb.omarchy-printers")
    else
      window.visible = false
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
      viewName = "details"
      selectedIndex = 0
      selectedActionId = detailActions().length ? detailActions()[0] : ""
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
    var actions = detailActions()
    if (selectedIndex < 0 || selectedIndex >= actions.length) return
    var action = actions[selectedIndex]
    selectedActionId = action
    if (action === "default")
      runBackend("set-default", ["--queue", selectedQueue.name], selectedQueue.identity)
    else if (action === "enabled")
      runBackend("set-enabled", ["--queue", selectedQueue.name, "--enabled", selectedQueue.enabled ? "false" : "true"], selectedQueue.identity)
    else if (action === "jobs")
      runBackend("jobs", ["--queue", selectedQueue.name], selectedQueue.identity)
    else if (action === "options")
      runBackend("options", ["--queue", selectedQueue.name], selectedQueue.identity)
    else if (action === "test")
      runBackend("test-page", ["--queue", selectedQueue.name], selectedQueue.identity)
    else if (action === "remove") {
      confirmDialog.message = "Remove " + selectedQueue.name + "?"
      confirmDialog.selectedIndex = 0
      confirmDialog.opened = true
    }
  }

  function detailActions() {
    if (!selectedQueue) return []
    var actions = []
    if (!selectedQueue.isDefault) actions.push("default")
    actions.push("enabled", "jobs", "options", "test", "remove")
    return actions
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

  function handleSuccess(command, data) {
    failedIdentity = ""
    if (command === "queues") {
      var queues = data.queues || []
      snapshot = {
        queues: queues,
        available: PrinterState.mergeAvailable(snapshot.available, [], queues)
      }
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
      if (selectedQueue) {
        var updatedQueue = null
        for (var i = 0; i < snapshot.queues.length; i++) {
          if (snapshot.queues[i].identity === selectedQueue.identity) {
            updatedQueue = snapshot.queues[i]
            break
          }
        }
        selectedQueue = updatedQueue
        if (!selectedQueue && viewName !== "main")
          viewName = "main"
      }
      if (viewName === "main") {
        restoreCursor()
      } else if (viewName === "details") {
        var actions = detailActions()
        var actionIndex = actions.indexOf(selectedActionId)
        selectedIndex = actionIndex >= 0 ? actionIndex : Math.max(0, Math.min(selectedIndex, actions.length - 1))
        selectedActionId = actions.length ? actions[selectedIndex] : ""
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
    if (command === "jobs") {
      if (!selectedQueue) return
      jobs = data.jobs || []
      viewName = "jobs"
      selectedIndex = jobs.length ? 0 : -1
      return
    }
    if (command === "options") {
      if (!selectedQueue) return
      options = data.options || []
      var values = {}
      for (var i = 0; i < options.length; i++)
        values[options[i].name] = options[i].default
      optionValues = values
      viewName = "options"
      selectedIndex = 0
      return
    }
    if (command === "cancel-job") {
      if (!selectedQueue) return
      runBackend("jobs", ["--queue", selectedQueue.name], selectedQueue.identity)
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
    } else if (command === "test-page") statusMessage = "Test page sent"
    else if (command === "set-options") statusMessage = "Defaults saved"
    if (["add", "remove", "set-default", "set-enabled", "set-options"].indexOf(command) >= 0)
      quickRefreshAfterAction.restart()
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
          var count = root.viewName === "details" ? root.detailActions().length
            : (root.viewName === "jobs" ? root.jobs.length
              : (root.viewName === "models" ? 2
                : (root.viewName === "options" ? root.options.length + 1 : 0)))
          if (count > 0) {
            root.selectedIndex = Math.max(0, Math.min(count - 1, root.selectedIndex + dy))
            if (root.viewName === "details")
              root.selectedActionId = root.detailActions()[root.selectedIndex]
            else if (root.viewName === "jobs")
              Qt.callLater(function() { jobsView.ensureCursorVisible() })
            else if (root.viewName === "options")
              Qt.callLater(function() { optionsView.ensureCursorVisible() })
          }
        }
      }
      onActivateRequested: {
        if (confirmDialog.opened) {
          if (confirmDialog.selectedIndex === 0) confirmDialog.canceled()
          else confirmDialog.confirmed()
          return
        }
        if (root.viewName === "main") root.activateMainRow()
        else if (root.viewName === "details") root.activateDetails()
        else if (root.viewName === "jobs" && root.selectedQueue && root.selectedIndex >= 0)
          root.runBackend("cancel-job", ["--job-id", String(root.jobs[root.selectedIndex].id)], root.selectedQueue.identity)
        else if (root.viewName === "models") modelsView.activate(root.selectedIndex)
        else if (root.viewName === "options") optionsView.activate(root.selectedIndex)
      }
      onCloseRequested: {
        if (confirmDialog.opened) confirmDialog.canceled()
        else root.requestClose()
      }
      onTabRequested: function(direction) {
        if (confirmDialog.opened)
          confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
        else if (root.viewName === "models")
          root.selectedIndex = Math.max(0, Math.min(1, root.selectedIndex + direction))
        else if (root.viewName === "options") {
          root.selectedIndex = Math.max(0, Math.min(root.options.length, root.selectedIndex + direction))
          Qt.callLater(function() { optionsView.ensureCursorVisible() })
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
            onClicked: root.requestClose()
          }

          Text {
            text: {
              if (root.viewName === "details" && root.selectedQueue) return root.selectedQueue.name
              if (root.viewName === "models") return "Choose a driver"
              if (root.viewName === "jobs") return "Print jobs"
              if (root.viewName === "options") return "Printer defaults"
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

        JobsView {
          id: jobsView
          visible: root.viewName === "jobs"
          Layout.fillWidth: true
          Layout.fillHeight: true
        }

        OptionsView {
          id: optionsView
          visible: root.viewName === "options"
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
          visible: root.viewName === "main"
          text: "j/k or arrows navigate · enter select · r network scan · f full scan · esc close"
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
    readonly property var actions: root.detailActions()

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.rowGap

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

      Repeater {
        model: details.actions
        delegate: ActionRow {
          required property string modelData
          required property int index
          Layout.fillWidth: true
          hasCursor: root.selectedIndex === index
          urgentAction: modelData === "remove"
          title: {
            if (modelData === "default") return "Make default"
            if (modelData === "enabled") return root.selectedQueue && root.selectedQueue.enabled ? "Pause printer" : "Resume printer"
            if (modelData === "jobs") return "Print jobs"
            if (modelData === "options") return "Printer defaults"
            if (modelData === "test") return "Print test page"
            return "Remove printer"
          }
          description: {
            if (modelData === "default") return "Use this printer unless another is selected"
            if (modelData === "enabled") return "Temporarily stop or resume this queue"
            if (modelData === "jobs") return "View and cancel queued jobs"
            if (modelData === "options") return "Paper, duplex, quality, and other defaults"
            if (modelData === "test") return "Send the standard CUPS test page"
            return "Delete this printer queue"
          }
          onPointerMoved: function(item, mouse) {
            if (!pointerGate.moved(item, mouse)) return
            root.selectedIndex = index
            root.selectedActionId = modelData
          }
          onActivated: {
            root.selectedIndex = index
            root.activateDetails()
          }
        }
      }

      Item { Layout.fillHeight: true }
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

  component JobsView: Item {
    function ensureCursorVisible() {
      if (root.selectedIndex >= 0)
        jobsList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.rowGap

      ListView {
        id: jobsList
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.spacing.rowGap
        model: root.jobs
        delegate: ActionRow {
          required property var modelData
          required property int index
          width: ListView.view.width
          title: modelData.name || ("Job " + modelData.id)
          description: (modelData.user || "") + (modelData.stateLabel ? " · " + modelData.stateLabel : "")
          hasCursor: root.selectedIndex === index
          urgentAction: true
          onPointerMoved: function(item, mouse) {
            if (pointerGate.moved(item, mouse)) root.selectedIndex = index
          }
          onActivated: {
            if (root.selectedQueue)
              root.runBackend("cancel-job", ["--job-id", String(modelData.id)], root.selectedQueue.identity)
          }
        }
      }

      EmptyText {
        visible: root.jobs.length === 0
        text: "No print jobs"
      }
    }
  }

  component OptionsView: Item {
    function ensureCursorVisible() {
      var item = root.selectedIndex < root.options.length
        ? optionsRepeater.itemAt(root.selectedIndex) : saveOptionsButton
      var flickable = optionsScroll.contentItem
      if (!item || !flickable) return
      var top = item.mapToItem(optionsScroll.contentItem.contentItem, 0, 0).y
      if (top < flickable.contentY)
        flickable.contentY = top
      else if (top + item.height > flickable.contentY + optionsScroll.availableHeight)
        flickable.contentY = top + item.height - optionsScroll.availableHeight
    }

    function activate(index) {
      if (!root.selectedQueue) return
      if (index < root.options.length) {
        var item = optionsRepeater.itemAt(index)
        if (item) item.toggle()
      } else {
        root.runBackend("set-options",
          ["--queue", root.selectedQueue.name, "--options", JSON.stringify(root.optionValues)],
          root.selectedQueue.identity)
      }
    }

    ScrollView {
      id: optionsScroll
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

      ColumnLayout {
        width: optionsScroll.availableWidth
        spacing: Style.spacing.panelGap

        Repeater {
          id: optionsRepeater
          model: root.options
          delegate: Dropdown {
            required property var modelData
            Layout.fillWidth: true
            hasCursor: root.selectedIndex === index
            label: modelData.label
            value: String(root.optionValues[modelData.name] || "")
            options: modelData.choices || []
            onPopupOpenChanged: root.controlPopupOpen = popupOpen
            onChanged: function(value) {
              var next = Object.assign({}, root.optionValues)
              next[modelData.name] = value
              root.optionValues = next
            }
          }
        }

        Button {
          id: saveOptionsButton
          text: root.busy ? "Saving…" : "Save defaults"
          iconText: "󰆓"
          bordered: true
          hasCursor: root.selectedIndex === root.options.length
          enabled: !root.busy && root.selectedQueue
          onClicked: {
            if (root.selectedQueue)
              root.runBackend("set-options",
                ["--queue", root.selectedQueue.name, "--options", JSON.stringify(root.optionValues)],
                root.selectedQueue.identity)
          }
        }
      }
    }
  }

  component PrinterRow: CursorSurface {
    id: row
    property string title: ""
    property string subtitle: ""
    property color statusColor: Color.muted
    property string actionText: ""
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
        color: row.actionable ? root.foreground : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.italic: row.actionItalic
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property string title: ""
    property string description: ""
    property bool urgentAction: false
    signal activated()
    signal pointerMoved(var item, var mouse)

    implicitHeight: Style.space(62)
    bordered: true

    Column {
      anchors.left: parent.left
      anchors.right: chevron.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: actionRow.borderLeft + Style.spacing.rowPaddingX
      spacing: Style.spacing.xs

      Text {
        text: actionRow.title
        color: actionRow.urgentAction ? root.urgent : root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        width: parent.width
        elide: Text.ElideRight
      }
      Text {
        text: actionRow.description
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        width: parent.width
        elide: Text.ElideRight
      }
    }

    Text {
      id: chevron
      anchors.right: parent.right
      anchors.rightMargin: actionRow.borderRight + Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      text: "󰅂"
      color: actionRow.urgentAction ? root.urgent : root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.icon
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: function(mouse) { actionRow.pointerMoved(actionRow, mouse) }
      onClicked: actionRow.activated()
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
