function clamp(value, minimum, maximum) {
  if (maximum < minimum) return minimum
  return Math.max(minimum, Math.min(maximum, value))
}

function sectionCount(state, section) {
  if (section === "installed") return (state.queues || []).length
  if (section === "available") return (state.available || []).length
  return 0
}

function visibleSections(state) {
  var sections = []
  if (sectionCount(state, "installed") > 0) sections.push("installed")
  if (sectionCount(state, "available") > 0) sections.push("available")
  return sections
}

function normalizedCursor(state, section, index) {
  var sections = visibleSections(state)
  if (sections.length === 0) return { section: "", index: -1 }
  if (sections.indexOf(section) === -1) section = sections[0]
  return {
    section: section,
    index: clamp(index, 0, sectionCount(state, section) - 1)
  }
}

function moveCursor(state, section, index, delta) {
  var cursor = normalizedCursor(state, section, index)
  var sections = visibleSections(state)
  if (cursor.section === "") return cursor

  var next = cursor.index + delta
  var count = sectionCount(state, cursor.section)
  if (next >= 0 && next < count)
    return { section: cursor.section, index: next }

  var sectionIndex = sections.indexOf(cursor.section) + (delta > 0 ? 1 : -1)
  if (sectionIndex < 0 || sectionIndex >= sections.length) return cursor

  var nextSection = sections[sectionIndex]
  return {
    section: nextSection,
    index: delta > 0 ? 0 : sectionCount(state, nextSection) - 1
  }
}

function preserveCursor(state, section, identity) {
  var rows = section === "installed" ? (state.queues || []) : (state.available || [])
  if (identity) {
    for (var i = 0; i < rows.length; i++) {
      if (String(rows[i].identity || "") === String(identity))
        return normalizedCursor(state, section, i)
    }
  }
  return normalizedCursor(state, section, 0)
}

function queueStatus(queue) {
  if (!queue.enabled) return queue.isDefault ? "Paused · Default" : "Paused"
  if (queue.online === null || typeof queue.online === "undefined")
    return queue.isDefault ? "Status unavailable · Default" : "Status unavailable"
  if (queue.online) return queue.isDefault ? "Online · Default" : "Online"
  return queue.isDefault ? "Unavailable · Default" : "Unavailable"
}

function applyPresenceGrace(queues, lastSeen, now, graceMs) {
  var seen = Object.assign({}, lastSeen || {})
  var result = (queues || []).map(function(queue) {
    var copy = Object.assign({}, queue)
    var identity = String(copy.identity || "")
    if (copy.online === true) {
      if (identity) seen[identity] = now
    } else if (identity && seen[identity] && now - seen[identity] <= graceMs) {
      copy.online = true
      copy.presenceStale = true
    } else if (identity) {
      delete seen[identity]
    }
    return copy
  })
  return { queues: result, lastSeen: seen }
}

function mergeAvailable(current, cached, queues) {
  var installed = {}
  var installedUris = {}
  ;(queues || []).forEach(function(queue) {
    installed[String(queue.identity || "")] = true
    var uri = String(queue.normalizedUri || queue.uri || "")
    if (uri) installedUris[uri] = true
  })
  var seen = {}
  var result = []
  ;(current || []).concat(cached || []).forEach(function(device) {
    var identity = String(device.identity || "")
    var uri = String(device.normalizedUri || device.uri || "")
    if (!identity || installed[identity] || (uri && installedUris[uri]) || seen[identity])
      return
    seen[identity] = true
    result.push(device)
  })
  return result
}

function quickOptions(options) {
  var preferred = [
    "pagesize", "media",
    "duplex", "sides",
    "colormodel", "print-color-mode",
    "resolution", "print-quality"
  ]
  var ranked = []
  ;(options || []).forEach(function(option, sourceIndex) {
    var name = String(option.name || "").toLowerCase()
    var rank = preferred.length
    for (var i = 0; i < preferred.length; i++) {
      if (name === preferred[i] || name.indexOf(preferred[i]) !== -1) {
        rank = i
        break
      }
    }
    if (rank < preferred.length)
      ranked.push({ rank: rank, sourceIndex: sourceIndex, option: option })
  })
  ranked.sort(function(left, right) {
    if (left.rank !== right.rank) return left.rank - right.rank
    return left.sourceIndex - right.sourceIndex
  })
  return ranked.slice(0, 4).map(function(item) { return item.option })
}

if (typeof module !== "undefined") {
  module.exports = {
    clamp: clamp,
    sectionCount: sectionCount,
    visibleSections: visibleSections,
    normalizedCursor: normalizedCursor,
    moveCursor: moveCursor,
    preserveCursor: preserveCursor,
    queueStatus: queueStatus,
    applyPresenceGrace: applyPresenceGrace,
    mergeAvailable: mergeAvailable,
    quickOptions: quickOptions
  }
}
