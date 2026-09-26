const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
function install(ctx, file, names) {
  const source = fs.readFileSync(path.join(__dirname, '..', file), 'utf8')
  vm.createContext(ctx)
  for (const name of names) {
    const match = source.match(new RegExp('^  function ' + name + '\\([^]*?^  }', 'm'))
    assert.ok(match, name)
    vm.runInContext(match[0], ctx)
  }
}
let starts = 0
const service = {
  pending: false, selectedQueueName: 'Office', pluginDir: '/plugin',
  reader: { running: false },
  coalesce: { running: false, start() { this.running = true; starts++ } },
  readTimeout: { restart() {} }, updated() {}, jobs: [{id:9}], jobQueue: 'Office'
}
install(service, 'PrinterService.qml', ['requestRefresh', 'readStatus', 'applyStatus'])
for (let i = 0; i < 100; i++) service.requestRefresh()
assert.equal(starts, 1, 'event burst schedules one read')
service.readStatus()
assert.equal(service.reader.running, true)
assert.equal(service.reader.command[2], 'status')
assert.equal(JSON.parse(service.reader.command[4]).queue, 'Office')
assert.equal(service.pending, false)
service.requestRefresh()
service.readStatus()
assert.equal(service.pending, true, 'events during an in-flight read are retained')
service.reader.running = false
service.readStatus()
assert.equal(service.pending, false)
service.applyStatus({queues:[{name:'Other', state:4}], jobs:[{id:3}]}, 'Other')
assert.equal(service.jobQueue, 'Office', 'late jobs for another selection are ignored')
assert.equal(service.jobs[0].id, 9)
service.applyStatus({queues:[{name:'Office',state:4}], jobs:[]}, 'Office')
assert.equal(service.jobs.length, 0)
assert.equal(service.fresh, true)

const quick = {
  printerService: { queues: [{name:'A'}, {name:'Office',state:4}] },
  selectedQueue: {name:'Office'}, selectedQueueIndex:0,
  snapshot: {queues:[{name:'Office'}]},
  options:[{name:'Duplex',default:'None'}], optionValues:{Duplex:'DuplexNoTumble'},
  cursorIndex:1, settingsIndex:5
}
install(quick, 'PrinterQuickPanel.qml', ['applyLiveQueues'])
quick.applyLiveQueues()
assert.equal(quick.selectedQueueIndex, 1)
assert.equal(quick.cursorIndex, 2, 'option cursor follows inserted queue row')
assert.equal(quick.optionValues.Duplex, 'DuplexNoTumble')
assert.equal(quick.options[0].default, 'None')
quick.printerService.queues = [{name:'A'}]
quick.applyLiveQueues()
assert.equal(quick.selectedQueueIndex, -1)
assert.equal(quick.options.length, 0)

const panel = {
  printerService: {queues:[{name:'Office',state:4}], jobs:[{id:2}], jobQueue:'Office', jobsFailed:false},
  busy:true, liveUpdatePending:false, viewName:'details', detailsTab:'jobs', selectedIdentity:'office',
  watchedQueue:'Office', snapshot:{queues:[],available:[{name:'Discovered'}]},
  jobs:[{id:1},{id:2}], selectedIndex:5,
  options:[{name:'Duplex',default:'None'}], optionValues:{Duplex:'DuplexNoTumble'},
  updateSelectedQueue(){}, managementJobsOffset:()=>4, managementTargetCount:()=>5
}
install(panel, 'PrinterPanel.qml', ['applyLiveStatus'])
panel.applyLiveStatus()
assert.equal(panel.liveUpdatePending, true)
assert.equal(panel.jobs.length, 2)
panel.busy = false
panel.applyLiveStatus()
assert.equal(panel.jobs[0].id, 2)
assert.equal(panel.selectedIndex, 4, 'job selection follows job identity')
assert.equal(panel.optionValues.Duplex, 'DuplexNoTumble')
assert.equal(panel.snapshot.available[0].name, 'Discovered')

const quickSource = fs.readFileSync(path.join(__dirname, '../PrinterQuickPanel.qml'), 'utf8')
const printingExpression = quickSource.match(/readonly property bool isPrinting: ([\s\S]*?\n  \}\))/)[1]
const colorExpression = quickSource.match(/activeColor: ([^\n]+)/)[1]
const activity = { liveStatus:true, snapshot:{queues:[{state:3},{state:4}]},
  root:{hasProblem:false}, Color:{urgent:'#f00',accent:'#00f'} }
vm.createContext(activity)
assert.equal(vm.runInContext(printingExpression, activity), true, 'any active printer lights the bar')
assert.equal(vm.runInContext(colorExpression, activity), '#00f')
activity.Color.accent = '#0f0'
assert.equal(vm.runInContext(colorExpression, activity), '#0f0', 'theme changes are not cached')
activity.root.hasProblem = true
assert.equal(vm.runInContext(colorExpression, activity), '#f00', 'attention overrides printing color')
activity.liveStatus = false
assert.equal(vm.runInContext(printingExpression, activity), false, 'stale activity never keeps the highlight on')
activity.liveStatus = true
activity.snapshot.queues = [{state:3},{state:3}]
assert.equal(vm.runInContext(printingExpression, activity), false)

console.log('live state tests passed')
