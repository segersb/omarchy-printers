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

function moveMainCursor(state, section, index, delta, busy, wrap) {
  var targets = busy ? [] : [{section: "scan", index: 0}, {section: "scan", index: 1}]
  ;["installed", "available"].forEach(function(name) {
    var rows = name === "installed" ? state.queues : state.available
    ;(rows || []).forEach(function(row, i) { targets.push({section: name, index: i}) })
  })
  if (!targets.length) return {section: "", index: -1}
  var current = targets.findIndex(function(target) {
    return target.section === section && target.index === index
  })
  var next = current < 0 ? (delta > 0 ? 0 : targets.length - 1) : current + delta
  next = wrap ? (next + targets.length) % targets.length : Math.max(0, Math.min(targets.length - 1, next))
  return targets[next]
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
  var kind = queueStateKind(queue)
  var labels = {
    attention: "Needs attention",
    paused: "Paused",
    printing: "Printing",
    ready: "Ready"
  }
  var label = labels[kind]
  if (queue.isDefault) label += " · Default"
  return label
}

function queueStateKind(queue) {
  var reasons = queue && queue["printer-state-reasons"]
  if (!Array.isArray(reasons)) reasons = reasons ? [reasons] : []
  var attention = reasons.some(function(reason) {
    var text = String(reason || "").toLowerCase()
    return /(error|empty|jam|open|offline|unreachable|timed-out|failed|missing)/.test(text)
  })
  if (attention) return "attention"
  if (Number(queue.state) === 5 || !queue.enabled || !queue.accepting) return "paused"
  if (Number(queue.state) === 4) return "printing"
  return "ready"
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

function scanResultCanInstall(device) {
  return !!device && device.installed !== true
}

function quickOptions(options) {
  var preferred = [
    "pagesize", "media",
    "mediatype",
    "inputslot", "mediasource",
    "duplex", "sides",
    "colormodel", "print-color-mode",
    "resolution", "print-quality", "cupsprintquality",
    "pageregion",
    "outputbin"
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
    ranked.push({ rank: rank, sourceIndex: sourceIndex, option: option })
  })
  ranked.sort(function(left, right) {
    if (left.rank !== right.rank) return left.rank - right.rank
    return left.sourceIndex - right.sourceIndex
  })
  return ranked.map(function(item) { return item.option })
}

function humanizeIdentifier(value) {
  var text = String(value || "")
    .replace(/^cups(?=[A-Z])/, "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .trim()
  if (!text) return ""
  return text.charAt(0).toUpperCase() + text.slice(1)
}

function optionLabel(option) {
  var name = String(option && option.name || "")
  var labels = {
    PageSize: "Media size",
    MediaType: "Media type",
    InputSlot: "Media source",
    MediaSource: "Media source",
    Duplex: "Two-sided printing",
    ColorModel: "Color mode",
    OutputMode: "Color mode",
    cupsPrintQuality: "Print quality",
    PageRegion: "Printable area",
    OutputBin: "Output tray"
  }
  return labels[name] || humanizeIdentifier(option && option.label || name)
}

function optionChoiceLabel(optionName, choice) {
  var value = String(choice && typeof choice === "object" ? choice.value : choice)
  var label = String(choice && typeof choice === "object" ? choice.label : choice)
  var key = String(optionName || "") + ":" + value
  var labels = {
    "Duplex:None": "Off",
    "Duplex:DuplexNoTumble": "Long edge",
    "Duplex:DuplexTumble": "Short edge",
    "OutputMode:Gray": "Grayscale",
    "ColorModel:Gray": "Grayscale",
    "InputSlot:Auto": "Automatic",
    "MediaSource:Auto": "Automatic",
    "OutputBin:FaceDown": "Face down",
    "OutputBin:FaceUp": "Face up"
  }
  if (labels[key]) return labels[key]
  if (label === value && /[_-]|[a-z][A-Z]/.test(label))
    return humanizeIdentifier(label)
  return label
}

function optionChoices(option) {
  return (option && option.choices || []).map(function(choice) {
    var value = String(choice && typeof choice === "object" ? choice.value : choice)
    return {
      value: value,
      label: optionChoiceLabel(option && option.name, choice)
    }
  })
}

function optionsDirty(options, values) {
  return (options || []).some(function(option) {
    return String(values && values[option.name] !== undefined ? values[option.name] : "")
      !== String(option.default === undefined ? "" : option.default)
  })
}

function supplyRows(info) {
  function list(value) {
    return value === undefined || value === null ? [] : (Array.isArray(value) ? value : [value])
  }
  var names = list(info["marker-names"])
  var types = list(info["marker-types"])
  var colors = list(info["marker-colors"])
  var levels = list(info["marker-levels"])
  var knownColors = {"#000000": "Black", "#00FFFF": "Cyan", "#FF00FF": "Magenta", "#FFFF00": "Yellow"}
  var rows = []
  var count = Math.max(names.length, types.length, colors.length, levels.length)
  for (var i = 0; i < count; i++) {
    var rawColor = String(colors[i] || "").toUpperCase()
    var swatches = /^(#[0-9A-F]{6})+$/.test(rawColor) ? rawColor.match(/#[0-9A-F]{6}/g) : []
    var name = String(names[i] || "").trim()
    if (name.indexOf("(unknown IPP value tag") === 0) name = ""
    var type = String(types[i] || "supply").replace(/-/g, " ")
    if (type === "unknown" || type === "other") type = "supply"
    var colorName = swatches.length === 1 ? knownColors[swatches[0]] : ""
    var label = name || (colorName ? colorName + " " + type
      : type.charAt(0).toUpperCase() + type.slice(1) + " " + (i + 1))
    var level = levels[i]
    rows.push({label: label, colors: swatches,
      value: typeof level === "number" && level >= 0 && level <= 100 ? level + "%"
        : level === -3 ? "Some remaining" : "Level unavailable"})
  }
  return rows
}

function printerSummary(queues) {
  var items = queues || []
  if (items.length === 0) return "No printers added"
  var noun = items.length === 1 ? "printer" : "printers"
  return items.length + " " + noun
}

if (typeof module !== "undefined") {
  module.exports = {
    clamp: clamp,
    sectionCount: sectionCount,
    visibleSections: visibleSections,
    normalizedCursor: normalizedCursor,
    moveCursor: moveCursor,
    moveMainCursor: moveMainCursor,
    preserveCursor: preserveCursor,
    queueStatus: queueStatus,
    queueStateKind: queueStateKind,
    mergeAvailable: mergeAvailable,
    scanResultCanInstall: scanResultCanInstall,
    quickOptions: quickOptions,
    humanizeIdentifier: humanizeIdentifier,
    optionLabel: optionLabel,
    optionChoices: optionChoices,
    optionsDirty: optionsDirty,
    supplyRows: supplyRows,
    printerSummary: printerSummary
  }
}
