const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')
const source = fs.readFileSync(path.join(__dirname, '../PrintDialog.qml'), 'utf8')
const ctx = {
  settings: {adjustments: {}}, previewing: true, state: {direct: true},
  revision: 0, dirty: false, terminal: false, initialized: true,
  renderDelay: {restart() {}}, window: {visible: true}, finished() {},
}
ctx.root = ctx
vm.createContext(ctx)
for (const name of ['change', 'applyState', 'setPageAdjustment', 'applyToAll', 'zoomAt']) {
  const match = source.match(new RegExp('^  function ' + name + '\\([^]*?^  }', 'm'))
  assert.ok(match)
  vm.runInContext(match[0], ctx)
}
ctx.sourcePage = 2
ctx.setPageAdjustment({zoom: 150, x: 20, y: -10})
assert.equal(ctx.revision, 1)
assert.equal(ctx.dirty, true)
ctx.applyState(JSON.stringify({stage: 'preview', revision: 0, busy: false, settings: {adjustments: {}}}))
assert.equal(ctx.dirty, true, 'old preview must not re-enable Print while new settings debounce')
assert.equal(ctx.settings.adjustments['2'].zoom, 150, 'old state must not overwrite an edit')
assert.equal(ctx.settings.adjustments['1'], undefined, 'edits only affect the current source page')
ctx.pageAdjustment = ctx.settings.adjustments['2']
ctx.applyToAll()
assert.equal(ctx.settings.defaultAdjustment.zoom, 150)
assert.equal(Object.keys(ctx.settings.adjustments).length, 0)
ctx.setPageAdjustment({zoom: 100, x: 0, y: 0})
assert.equal(ctx.settings.adjustments['2'].zoom, 100, 'reset current page overrides the shared default')
assert.equal(ctx.settings.defaultAdjustment.zoom, 150)
ctx.revision = 1
ctx.applyState(JSON.stringify({stage: 'preview', revision: 1, busy: false}))
assert.equal(ctx.dirty, false)
ctx.terminal = true
ctx.applyState('{broken')
assert.equal(ctx.state.stage, 'preview', 'late output cannot revive a closed dialog')
console.log('Print preview revision tests passed')

const hasDocument = source.match(/readonly property bool hasDocument: ([^\n]+)/)[1]
for (const stage of ['preview', 'submitting', 'done', 'error']) {
  ctx.state = {stage, metadata: {pages: [{scale: 1}]}}
  assert.equal(vm.runInContext(hasDocument, ctx), true, 'sizing layout remains visible in ' + stage)
}
ctx.state = {stage: 'loading'}
assert.equal(vm.runInContext(hasDocument, ctx), false)

// A point under the pointer keeps its position through zoom, including mid-drag.
ctx.paper = {width: 600, height: 800}
ctx.dragX = 15
ctx.dragY = -5
ctx.pageAdjustment = {zoom: 100, x: 20, y: -10}
ctx.zoomAt(105, 450, 250)
let edit = ctx.settings.adjustments['2']
assert.equal(edit.zoom, 105)
const before = {x: (450 - 300 - 20 - 15), y: (250 - 400 + 10 + 5)}
assert.ok(Math.abs(300 + edit.x + 15 + before.x * 1.05 - 450) < 1e-9)
assert.ok(Math.abs(400 + edit.y - 5 + before.y * 1.05 - 250) < 1e-9)
ctx.pageAdjustment = edit
ctx.zoomAt(500, 450, 250)
assert.equal(ctx.settings.adjustments['2'].zoom, 400)
ctx.pageAdjustment = ctx.settings.adjustments['2']
const revisionAtLimit = ctx.revision
ctx.zoomAt(405, 450, 250)
assert.equal(ctx.revision, revisionAtLimit, 'zoom at limit must not queue another render')
ctx.zoomAt(0, 450, 250)
assert.equal(ctx.settings.adjustments['2'].zoom, 10)
console.log('Pointer-anchored print zoom tests passed')

const panelSource = fs.readFileSync(path.join(__dirname, '../PrinterPanel.qml'), 'utf8')
const lifecycle = {window: {visible: false}, printSetup: {opened: true, busy: false},
  printDialogs: {}, closingFromHost: false, hidden: 0}
lifecycle.shell = {hide() { lifecycle.hidden++ }}
vm.createContext(lifecycle)
vm.runInContext(panelSource.match(/^  function releaseIfUnused\([^]*?^  }/m)[0], lifecycle)
lifecycle.releaseIfUnused()
assert.equal(lifecycle.hidden, 0, 'closing settings must leave integration alive')
lifecycle.printSetup.opened = false
lifecycle.window.visible = true
lifecycle.releaseIfUnused()
assert.equal(lifecycle.hidden, 0, 'closing integration must leave settings alive')
lifecycle.window.visible = false
lifecycle.printSetup.busy = true
lifecycle.releaseIfUnused()
assert.equal(lifecycle.hidden, 0, 'setup operations finish before unloading')
lifecycle.printSetup.busy = false
lifecycle.printDialogs.job = {}
lifecycle.releaseIfUnused()
assert.equal(lifecycle.hidden, 0, 'print requests remain alive')
delete lifecycle.printDialogs.job
lifecycle.releaseIfUnused()
assert.equal(lifecycle.hidden, 1, 'unload only after the final window and operation finish')
console.log('Independent window lifecycle tests passed')

const setupSource = fs.readFileSync(path.join(__dirname, '../PrintSetup.qml'), 'utf8')
const controls = Array.from({length: 6}, () => ({enabled: true, visible: true, activeFocus: false}))
controls.forEach(control => control.forceActiveFocus = () => {
  controls.forEach(other => other.activeFocus = false)
  control.activeFocus = true
})
const focusCtx = {integrations: {count: 3, itemAt: i => ({control: controls[i]})},
  enableAll: controls[3], restoreDefaults: controls[4], closeButton: controls[5], Qt: {TabFocusReason: 1}}
vm.createContext(focusCtx)
vm.runInContext(setupSource.match(/^  function moveFocus\([^]*?^  }/m)[0], focusCtx)
focusCtx.moveFocus(1)
assert.equal(controls[0].activeFocus, true)
focusCtx.moveFocus(1)
assert.equal(controls[1].activeFocus, true)
focusCtx.moveFocus(1)
controls[3].enabled = false
focusCtx.moveFocus(1)
assert.equal(controls[4].activeFocus, true, 'arrows skip disabled actions')
focusCtx.moveFocus(-1)
assert.equal(controls[2].activeFocus, true)
controls[5].forceActiveFocus()
focusCtx.moveFocus(1)
assert.equal(controls[5].activeFocus, true, 'focus stays at the last control')
console.log('Integration arrow navigation tests passed')
