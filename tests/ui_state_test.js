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
}), "Ready · Default")
assert.equal(state.queueStatus({
  enabled: true,
  accepting: true,
  state: 3,
  presenceStale: true,
  online: true
}), "Ready")
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

// Exercise the panel's real handlers without requiring a running desktop.
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const panelSource = fs.readFileSync(path.join(__dirname, "../PrinterPanel.qml"), "utf8")
function panelFunction(name) {
  const start = panelSource.indexOf("  function " + name + "(")
  assert.notEqual(start, -1)
  const end = panelSource.indexOf("\n  }", start + 1) + 4
  return panelSource.slice(start, end)
}
const panel = {
  printerService: null,
  selectedQueue: { name: "Office", identity: "uuid:office" },
  viewName: "details",
  selectedIndex: 0,
  backend: { running: false },
  managementTargetCount: () => 1,
  managementReload: { restart() { panel.reloadJobs() } },
  runBackend(command, args, identity) {
    assert.equal(command, "jobs")
    assert.deepEqual(Array.from(args), ["--queue", "Office"])
    assert.equal(identity, "uuid:office")
    panel.handleSuccess(command, { jobs: [] })
  }
}
vm.createContext(panel)
vm.runInContext(panelFunction("handleSuccess") + panelFunction("reloadJobs"), panel)
panel.handleSuccess("manage", {
  options: [{ name: "Duplex", default: "None" }], jobs: [{ id: 4 }]
})
panel.optionValues.Duplex = "DuplexNoTumble"
panel.handleSuccess("cancel-job", {})
assert.equal(panel.jobs.length, 0)
assert.equal(panel.optionValues.Duplex, "DuplexNoTumble")
assert.equal(panel.options[0].default, "None")
assert.equal(state.optionsDirty(panel.options, panel.optionValues), true)

panel.handleSuccess("manage", {
  options: [], optionsError: { code: "cups-error" }, jobs: [{ id: 4 }]
})
assert.equal(panel.optionsLoadFailed, true)
assert.equal(panel.jobsLoadFailed, false)
assert.equal(panel.jobs[0].id, 4)
panel.handleSuccess("manage", {
  options: [{ name: "Duplex", default: "None" }], jobs: [],
  jobsError: { code: "cups-error" }
})
assert.equal(panel.optionsLoadFailed, false)
assert.equal(panel.jobsLoadFailed, true)
assert.equal(panel.options[0].name, "Duplex")

console.log("ui state tests passed")

// Hidden tabs must never receive keyboard actions, even at overlapping indexes.
const details = {
  selectedQueue: { name: "Office", identity: "office", isDefault: true },
  detailsTab: "settings", selectedIndex: 0, managementDirty: true,
  managementOptions: [{ name: "Duplex" }], jobs: [{ id: 42 }],
  managementView: { resetScroll() {}, optionItem() { return { toggle() { details.openedOption = true } } } },
  saveManagementOptions() { details.saved = true },
  runBackend(command) { details.command = command }
}
vm.createContext(details)
for (const name of ["managementActions", "managementOptionOffset", "managementSaveIndex",
  "managementJobsOffset", "managementTargetCount", "selectDetailsTab", "activateDetails"])
  vm.runInContext(panelFunction(name), details)
assert.equal(details.managementTargetCount(), 9)
details.selectedIndex = 7
details.activateDetails()
assert.equal(details.openedOption, true)
assert.equal(details.command, undefined)
details.selectDetailsTab("jobs")
assert.equal(details.selectedIndex, 5)
assert.equal(details.managementTargetCount(), 8)
details.selectedIndex = 7
details.activateDetails()
assert.equal(details.command, "cancel-job")
assert.equal(details.saved, undefined)
details.jobs = []
assert.equal(details.managementTargetCount(), 7, "empty queue retains shared actions and tabs")
details.selectDetailsTab("settings")
assert.equal(details.managementDirty, true, "tab switches retain unsaved settings")
console.log("Printer details tab navigation tests passed")

assert.deepEqual(state.moveMainCursor(sample, "installed", 0, -1, false, false), {section:"scan", index:1})
assert.deepEqual(state.moveMainCursor(sample, "scan", 1, -1, false, false), {section:"scan", index:0})
assert.deepEqual(state.moveMainCursor(sample, "scan", 1, 1, false, false), {section:"installed", index:0})
assert.deepEqual(state.moveMainCursor(sample, "available", 1, 1, false, true), {section:"scan", index:0})
assert.deepEqual(state.moveMainCursor(sample, "scan", 0, -1, false, true), {section:"available", index:1})
assert.deepEqual(state.moveMainCursor({queues:[],available:[]}, "", -1, 1, false, false), {section:"scan", index:0})
assert.deepEqual(state.moveMainCursor(sample, "scan", 0, 1, true, true), {section:"installed", index:0})
console.log("Scan button keyboard navigation tests passed")

assert.deepEqual(state.supplyRows({
  'marker-names': ['Photo cartridge', '', '', ''],
  'marker-types': ['ink', 'toner', 'toner', 'ink'],
  'marker-colors': ['#a1b2c3', '#000000', '#123456', '#00FFFF#FF00FF#FFFF00'],
  'marker-levels': [80, 100, -2, 25]
}), [
  {label: 'Photo cartridge', colors: ['#A1B2C3'], value: '80%'},
  {label: 'Black toner', colors: ['#000000'], value: '100%'},
  {label: 'Toner 3', colors: ['#123456'], value: 'Level unavailable'},
  {label: 'Ink 4', colors: ['#00FFFF', '#FF00FF', '#FFFF00'], value: '25%'}
])
assert.deepEqual(state.supplyRows({'marker-types':'toner', 'marker-colors':'none'}),
  [{label:'Toner 1', colors:[], value:'Level unavailable'}])
assert.deepEqual(state.supplyRows({'marker-names':['Black toner'], 'marker-colors':['invalid']}),
  [{label:'Black toner', colors:[], value:'Level unavailable'}])
console.log('Supply label and swatch tests passed')

const feedback = {
  backendTimeout: {stop() {}}, backendTimedOut:false,
  backendOut: {text:''}, activeCommand:'test-page', activeIdentity:'office',
  statusMessage:'', statusKind:'', failedIdentity:'',
  friendlyError: (command,error) => error.message,
  responseData: response => response.data,
  handleSuccess() {}, keyCatcher:{forceActiveFocus() {}}
}
vm.createContext(feedback)
vm.runInContext(panelFunction('handleBackendResult') + panelFunction('dismissError'), feedback)
feedback.backendOut.text = JSON.stringify({ok:false,error:{code:'authorization-cancelled',message:'Cancelled'}})
feedback.handleBackendResult()
assert.equal(feedback.statusMessage,'')
assert.equal(feedback.failedIdentity,'')
feedback.backendOut.text = JSON.stringify({ok:false,error:{code:'authorization-not-granted',message:'Not completed'}})
feedback.handleBackendResult()
assert.equal(feedback.statusMessage,'')
assert.equal(feedback.failedIdentity,'')
feedback.backendOut.text = JSON.stringify({ok:false,error:{code:'authorization-denied',message:'Permission denied'}})
feedback.handleBackendResult()
assert.equal(feedback.statusKind,'error')
assert.equal(feedback.statusMessage,'Permission denied')
feedback.backendOut.text = JSON.stringify({ok:true,data:{}})
feedback.handleBackendResult()
assert.equal(feedback.statusMessage,'Permission denied','errors persist until dismissed')
feedback.dismissError()
assert.equal(feedback.statusMessage,'')
assert.equal(feedback.failedIdentity,'')
console.log('Printer error feedback tests passed')

const navigation = {selectedIndex:-1, selectedQueue:{isDefault:true}}
vm.createContext(navigation)
vm.runInContext(panelFunction('moveDetailsCursor'), navigation)
navigation.moveDetailsCursor(1, 6)
assert.equal(navigation.selectedIndex, 1, 'skip filled star moving forward')
navigation.moveDetailsCursor(-1, 6)
assert.equal(navigation.selectedIndex, -1, 'skip filled star moving backward')
navigation.selectedQueue.isDefault = false
navigation.moveDetailsCursor(1, 6)
assert.equal(navigation.selectedIndex, 0, 'empty star remains reachable')
console.log('Default star navigation tests passed')
