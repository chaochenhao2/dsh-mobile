/**
 * Static checks over the client half of the bundle.
 *
 * The browser bundle cannot be exercised without a running Shell, so this
 * verifies the declarations the Shell's scanner requires and the registration
 * points the panel depends on. A missing or misnamed piece fails the scan
 * loudly, and this catches it before a restart does.
 */

const fs = require('node:fs')

let failures = 0
/**
 * Record one assertion.
 * @param label - what is being checked.
 * @param ok - whether it held.
 */
function check(label, ok) {
  if (!ok) failures += 1
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}`)
}

const pkg = JSON.parse(fs.readFileSync('dsh-mobile-bridge/package.json', 'utf8'))
const client = fs.readFileSync('dsh-mobile-bridge/client.js', 'utf8')

console.log('manifest:')
check('dsh.client declared', pkg.dsh?.client !== undefined)
check('platform is a string', typeof pkg.dsh?.client?.platform === 'string')
check('immediately is a boolean', typeof pkg.dsh?.client?.immediately === 'boolean')
check('inject is an array', Array.isArray(pkg.dsh?.client?.inject))
check('exports ./client', typeof pkg.exports?.['./client'] === 'string')
check('client.js listed in files', (pkg.files ?? []).includes('client.js'))
check('client.js exists', fs.existsSync('dsh-mobile-bridge/client.js'))
check('bundle patch declared', typeof pkg.dsh?.bundle?.patch === 'string')

console.log('loader:')
check('registers with __ModuleLoader__', client.includes('window.__ModuleLoader__.load'))
check('bundle id equals package name', client.includes("id: 'dsh-mobile-bridge'"))
check('exposes a factory', client.includes('factory(require)'))
check('requires react from the module table', client.includes("require('react')"))
check('injects slots and locale', /inject:\s*\['slots',\s*'locale'\]/.test(client))

console.log('panel:')
check('registers the main slot', client.includes("name: 'main'"))
check('uses a stable panel key', client.includes("key: 'mobile-bridge'"))
check('labels through locale', client.includes("t('panelTitle')"))
check('reads the loopback state route', client.includes('/api/panel/state'))
check('polls instead of navigating', client.includes('setInterval'))
check('clears its timer on dispose', client.includes('clearInterval'))
check('dictionaries registered', client.includes('ctx.locale.register'))
check('no leftover placeholder copy', !client.includes('TODO'))
check('no hardcoded Chinese outside dictionaries', !/[\u4e00-\u9fa5]/.test(
  client.replace(/const ZH = \{[\s\S]*?\n    \}/, '')
))

console.log(failures === 0 ? '\nclient bundle verified' : `\n${failures} failure(s)`)
process.exitCode = failures === 0 ? 0 : 1
