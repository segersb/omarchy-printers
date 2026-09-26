import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  property var shell: null
  property var queues: []
  property var jobs: []
  property string jobQueue: ""
  property string selectedQueueName: ""
  property bool jobsFailed: false
  property bool live: false
  property bool fresh: false
  property bool pending: false
  property string readingQueue: ""
  property bool readTimedOut: false
  property bool restarting: false
  property bool recoveryAttempted: false
  signal updated()

  function status() {
    return { live: live, fresh: fresh, reading: reader.running, jobQueue: jobQueue,
      queues: queues.map(function(q) { return { name: q.name, state: q.state } }) }
  }

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")

  Component.onCompleted: {
    watcher.running = true
    requestRefresh()
  }
  Component.onDestruction: {
    watcher.running = false
    reader.running = false
  }
  onSelectedQueueNameChanged: requestRefresh()

  function requestRefresh() {
    pending = true
    if (!coalesce.running) coalesce.start()
  }

  function refresh() {
    recoveryAttempted = false
    // Explicit user refresh can recover a failed bus/subscription, with no retry loop.
    if (!live) {
      if (watcher.running) {
        restarting = true
        watcher.signal(15)
      } else watcher.running = true
    }
    requestRefresh()
  }

  function readStatus() {
    if (!pending || reader.running) return
    pending = false
    readingQueue = selectedQueueName
    readTimedOut = false
    reader.command = ["python3", pluginDir + "/backend/printers.py", "status", "--json",
      JSON.stringify(readingQueue ? { queue: readingQueue } : {})]
    reader.running = true
    readTimeout.restart()
  }

  function applyStatus(data, requestedQueue) {
    queues = data.queues || []
    if (requestedQueue === selectedQueueName) {
      jobQueue = requestedQueue
      jobs = data.jobs || []
      jobsFailed = !!data.jobsError
    }
    fresh = true
    updated()
  }

  Timer { id: coalesce; interval: 250; onTriggered: root.readStatus() }
  // One retry after a helper/bus disconnect; no repeating reconnect loop.
  Timer { id: recover; interval: 1000; onTriggered: watcher.running = true }
  Timer {
    id: readTimeout
    interval: 15000
    onTriggered: {
      root.readTimedOut = true
      root.fresh = false
      reader.signal(15)
    }
  }
  Process {
    id: watcher
    command: ["python3", root.pluginDir + "/backend/watch.py"]
    stdout: SplitParser {
      onRead: function(line) {
        if (line === "ready") {
          root.live = true
          root.requestRefresh()
        } else if (line === "changed") root.requestRefresh()
        else if (line === "unavailable") {
          root.live = false
          root.fresh = false
        }
      }
    }
    onExited: {
      root.live = false
      root.fresh = false
      if (root.restarting) {
        root.restarting = false
        Qt.callLater(function() { watcher.running = true })
      } else if (!root.recoveryAttempted) {
        root.recoveryAttempted = true
        recover.restart()
      }
    }
  }
  Process {
    id: reader
    stdout: StdioCollector { id: output; waitForEnd: true }
    onExited: {
      readTimeout.stop()
      if (!root.readTimedOut) {
        try {
          var result = JSON.parse(output.text)
          if (result.ok) root.applyStatus(result.data, root.readingQueue)
          else root.fresh = false
        } catch (e) { root.fresh = false }
      }
      if (root.pending) coalesce.restart()
    }
  }
}
