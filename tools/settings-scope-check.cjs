/**
 * Find references to `settings` inside functions that do not declare or receive it.
 *
 * The CORS change added `settings` to several writers, and a function that
 * references it without a parameter compiles fine but throws at request time —
 * exactly the 500 that a stream request hit.
 */

const fs = require('node:fs')

const path = 'dsh-mobile-bridge/bridge.js'
const source = fs.readFileSync(path, 'utf8')
const lines = source.split('\n')

let failures = 0
/**
 * Record one finding.
 * @param label - the function checked.
 * @param ok - whether it is coherent.
 * @param detail - context on failure.
 */
function check(label, ok, detail) {
  if (!ok) failures += 1
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`)
}

// Locate every top-level function with its parameter list and body extent.
const functions = []
for (let index = 0; index < lines.length; index += 1) {
  const match = lines[index].match(/^(?:async )?function (\w+)\(([^)]*)\)/)
  if (!match) continue
  let depth = 0
  let started = false
  let end = index
  for (let cursor = index; cursor < lines.length; cursor += 1) {
    for (const character of lines[cursor]) {
      if (character === '{') { depth += 1; started = true }
      else if (character === '}') depth -= 1
    }
    if (started && depth <= 0) { end = cursor; break }
  }
  functions.push({ name: match[1], params: match[2], start: index, end })
}

const setterNames = new Set(['resolveSettings', 'writeSettingsFile', 'rememberDevice', 'deviceIdentity', 'panelState', 'startBeacon', 'startBridge'])

for (const fn of functions) {
  const body = lines.slice(fn.start, fn.end + 1).join('\n')
  if (!/\bsettings\b/.test(body)) continue
  // A local binding of the same name is not the bridge settings object.
  const localBinding = /(?:const|let|var)\s+settings\s*=/.test(body)
  if (localBinding) {
    console.log(`  --   ${fn.name} declares its own settings`)
    continue
  }
  const declares = /\bsettings\b/.test(fn.params) || setterNames.has(fn.name)
  // A nested arrow function may legitimately receive settings from its owner.
  const nested = fn.params.includes('settings') || body.match(/\(settings[),]/) !== null
  if (!declares && !nested) {
    check(`${fn.name} uses settings`, false, `params were (${fn.params})`)
    continue
  }
  check(`${fn.name} uses settings`, true)
}

console.log(failures === 0 ? '\nsettings references coherent' : `\n${failures} failure(s)`)
process.exitCode = failures === 0 ? 0 : 1
