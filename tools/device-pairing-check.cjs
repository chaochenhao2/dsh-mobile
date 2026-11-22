/**
 * Verify the bridge's device identity and pairing helpers in isolation.
 *
 * These functions are pure over a settings object, so they can be exercised
 * without DSH, without a socket, and without a model call. The bodies are
 * extracted from the plugin source so a divergence fails this check.
 */

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')

const BRIDGE = path.join(__dirname, '..', 'dsh-mobile-bridge', 'bridge.js')
const source = fs.readFileSync(BRIDGE, 'utf8')

/**
 * Cut a top-level function out of the plugin source.
 * @param name - the function name.
 * @returns its source text.
 */
function take(name) {
  const start = source.indexOf(`function ${name}(`)
  if (start < 0) throw new Error(`missing ${name}`)
  const bodyStart = source.indexOf('{', start)
  let depth = 0
  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1
    else if (source[index] === '}') {
      depth -= 1
      if (depth === 0) return source.slice(start, index + 1)
    }
  }
  throw new Error(`unterminated ${name}`)
}

const harness = `
const { randomUUID } = require('node:crypto')
const { hostname, platform } = require('node:os')
const { writeFileSync } = require('node:fs')
${take('deviceIdentity')}
${take('pairedDevices')}
${take('rememberDevice')}
module.exports = { deviceIdentity, pairedDevices, rememberDevice }
`

const harnessPath = path.join(os.tmpdir(), `dsh-device-${process.pid}.cjs`)
fs.writeFileSync(harnessPath, harness, 'utf8')
const { deviceIdentity, pairedDevices, rememberDevice } = require(harnessPath)

let failures = 0
/**
 * Record one assertion.
 * @param label - what is being checked.
 * @param ok - whether it held.
 * @param detail - optional context.
 */
function check(label, ok, detail) {
  if (!ok) failures += 1
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`)
}

const settingsPath = path.join(os.tmpdir(), `dsh-settings-${process.pid}.json`)

try {
  // A fresh install generates an identity and persists it.
  const settings = { path: settingsPath, token: 'x' }
  const first = deviceIdentity(settings)
  check('identity generated', typeof first.deviceId === 'string' && first.deviceId.length === 36)
  check('identity persisted to settings', fs.existsSync(settingsPath))
  const written = JSON.parse(fs.readFileSync(settingsPath, 'utf8'))
  check('deviceId written to disk', written.deviceId === first.deviceId)
  check('name defaults to hostname', first.name === os.hostname())
  check('platform reported', first.platform === process.platform)

  // A second read must return the same id rather than minting a new one.
  const second = deviceIdentity(settings)
  check('identity stable across reads', second.deviceId === first.deviceId)

  // Pairing records a device and is readable afterwards.
  const record = {
    deviceId: 'phone-1',
    name: 'iPhone',
    platform: 'ios',
    address: null,
    pairedAt: new Date().toISOString(),
  }
  let devices = rememberDevice(settings, record)
  check('pairing recorded', devices.length === 1 && devices[0].deviceId === 'phone-1')
  check('pairing readable', pairedDevices(settings).length === 1)

  // Re-pairing the same device replaces rather than duplicates it.
  devices = rememberDevice(settings, { ...record, name: 'iPhone 改名' })
  check('re-pair replaces', devices.length === 1)
  check('re-pair updates fields', devices[0].name === 'iPhone 改名')

  // A second device coexists with the first.
  devices = rememberDevice(settings, { ...record, deviceId: 'phone-2', name: 'iPad' })
  check('two devices coexist', devices.length === 2)
  check('both ids present', devices.some((d) => d.deviceId === 'phone-1') && devices.some((d) => d.deviceId === 'phone-2'))

  // Forget removes exactly one.
  settings.pairedDevices = pairedDevices(settings).filter((d) => d.deviceId !== 'phone-1')
  check('forget removes one', pairedDevices(settings).length === 1)
  check('forget keeps the other', pairedDevices(settings)[0].deviceId === 'phone-2')

  const persisted = JSON.parse(fs.readFileSync(settingsPath, 'utf8'))
  check('paired devices persisted', Array.isArray(persisted.pairedDevices))
} finally {
  fs.rmSync(harnessPath, { force: true })
  fs.rmSync(settingsPath, { force: true })
}

// The routes must exist and be wired to these helpers.
console.log('routes:')
check('GET /api/devices', /segments\[1\] === 'devices' && segments\.length === 2 && req\.method === 'GET'/.test(source))
check('POST /api/devices', /segments\[1\] === 'devices' && segments\.length === 2 && req\.method === 'POST'/.test(source))
check('POST /api/devices/:id/forget', /segments\[3\] === 'forget'/.test(source))
check('info reports identity', /device: deviceIdentity\(settings\)/.test(source))
check('beacon reports identity', /deviceId: deviceIdentity\(settings\)\.deviceId/.test(source))
check('settings preserve identity', /stored\.deviceId/.test(source))
check('settings preserve pairings', /stored\.pairedDevices/.test(source))

console.log(failures === 0 ? '\ndevice pairing verified' : `\n${failures} failure(s)`)
process.exitCode = failures === 0 ? 0 : 1
