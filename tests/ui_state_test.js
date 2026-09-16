const assert = require("node:assert/strict")
const state = require("../PrinterState.js")

const sample = {
  queues: [{ identity: "one", enabled: true, online: true }],
  available: [{ identity: "two" }, { identity: "three" }]
}

assert.deepEqual(state.normalizedCursor(sample, "missing", 9), {
  section: "installed",
  index: 0
})
assert.deepEqual(state.moveCursor(sample, "installed", 0, 1), {
  section: "available",
  index: 0
})
assert.deepEqual(state.moveCursor(sample, "available", 0, 1), {
  section: "available",
  index: 1
})
assert.deepEqual(state.moveCursor(sample, "available", 1, -1), {
  section: "available",
  index: 0
})
assert.deepEqual(state.preserveCursor(sample, "available", "three"), {
  section: "available",
  index: 1
})
assert.deepEqual(state.preserveCursor(sample, "available", "missing"), {
  section: "available",
  index: 0
})
assert.deepEqual(state.preserveCursor({
  queues: [],
  available: [{ name: "Missing identity" }]
}, "", ""), {
  section: "available",
  index: 0
})
assert.deepEqual(state.normalizedCursor({ queues: [], available: [] }, "installed", 0), {
  section: "",
  index: -1
})
assert.deepEqual(state.moveCursor(sample, "available", 1, 1), {
  section: "available",
  index: 1
})
assert.equal(state.queueStatus({
  enabled: true,
  accepting: true,
  state: 3,
  isDefault: true
}), "Ready · Default")
assert.equal(state.queueStatus({
  enabled: true,
  accepting: true,
  state: 3,
  isDefault: true,
  online: true
}), "Ready · Default · Seen on network")
assert.equal(state.queueStatus({
  enabled: true,
  accepting: true,
  state: 3,
  presenceStale: true,
  online: true
}), "Ready · Seen recently")
assert.equal(state.queueStatus({
  enabled: false,
  accepting: false,
  state: 5,
  isDefault: false
}), "Paused")
assert.equal(state.queueStatus({
  enabled: false,
  accepting: false,
  state: 5,
  isDefault: true
}), "Paused · Default")
assert.equal(state.queueStatus({
  enabled: true,
  accepting: true,
  state: 4,
  isDefault: false
}), "Printing")
assert.equal(state.queueStatus({
  enabled: false,
  accepting: true,
  state: 5,
  "printer-state-reasons": ["media-empty-error"],
  isDefault: true
}), "Needs attention · Default")
assert.equal(state.queueStateKind({
  enabled: false,
  accepting: true,
  state: 5,
  "printer-state-reasons": ["media-empty-error"]
}), "attention")
assert.equal(state.queueStateKind({
  enabled: false,
  accepting: true,
  state: 5,
  "printer-state-reasons": ["paused"]
}), "paused")

const present = state.applyPresenceGrace([
  { identity: "printer-a", online: true }
], {}, 1000, 5000)
assert.equal(present.lastSeen["printer-a"], 1000)

const transientMiss = state.applyPresenceGrace([
  { identity: "printer-a", online: false }
], present.lastSeen, 4000, 5000)
assert.equal(transientMiss.queues[0].online, true)
assert.equal(transientMiss.queues[0].presenceStale, true)

const expiredMiss = state.applyPresenceGrace([
  { identity: "printer-a", online: false }
], present.lastSeen, 7000, 5000)
assert.equal(expiredMiss.queues[0].online, false)
assert.equal(expiredMiss.lastSeen["printer-a"], undefined)

assert.deepEqual(state.mergeAvailable(
  [{ identity: "driverless" }],
  [{ identity: "legacy" }, { identity: "driverless" }],
  [{ identity: "installed" }]
).map(item => item.identity), ["driverless", "legacy"])

assert.deepEqual(state.mergeAvailable(
  [],
  [{ identity: "legacy" }],
  [{ identity: "legacy" }]
), [])

assert.deepEqual(state.quickOptions([
  { name: "InputSlot" },
  { name: "Resolution" },
  { name: "Duplex" },
  { name: "PageSize" },
  { name: "ColorModel" },
  { name: "OutputMode" }
]).map(item => item.name), [
  "PageSize", "InputSlot", "Duplex", "ColorModel", "Resolution", "OutputMode"
])

assert.equal(state.optionLabel({ name: "cupsPrintQuality", label: "cupsPrintQuality" }), "Print quality")
assert.equal(state.optionLabel({ name: "PageRegion", label: "PageRegion" }), "Printable area")
assert.deepEqual(state.optionChoices({
  name: "Duplex",
  choices: [
    { value: "None", label: "None" },
    { value: "DuplexNoTumble", label: "DuplexNoTumble" }
  ]
}), [
  { value: "None", label: "Off" },
  { value: "DuplexNoTumble", label: "Long edge" }
])
assert.equal(state.optionsDirty(
  [{ name: "Duplex", default: "None" }],
  { Duplex: "None" }
), false)
assert.equal(state.optionsDirty(
  [{ name: "Duplex", default: "None" }],
  { Duplex: "DuplexNoTumble" }
), true)
assert.equal(state.printerSummary([
  { enabled: true, online: true }
]), "1 printer")
assert.equal(state.printerSummary([
  { enabled: true, online: true },
  { enabled: false, online: true }
]), "2 printers")

assert.deepEqual(state.mergeAvailable(
  [],
  [{ identity: "uri:socket://printer:9100", normalizedUri: "socket://printer:9100" }],
  [{ identity: "uuid:new-queue", normalizedUri: "socket://printer:9100" }]
), [])
assert.equal(state.scanResultCanInstall({ installed: true }), false)
assert.equal(state.scanResultCanInstall({ installed: false }), true)

console.log("ui state tests passed")
