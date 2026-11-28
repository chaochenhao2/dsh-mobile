/**
 * Find identifiers used but not declared inside a function's own scope.
 *
 * The CORS change threaded `settings` and `origin` through several response
 * writers. A writer that references either without receiving it compiles fine
 * and throws at request time, which is how a download answered 500
 * "settings is not defined" after the stream had already been fixed the same way.
 *
 * Only a parameter in the function's own signature counts: a call such as
 * `corsHeaders(settings, ...)` passes the value, it does not declare it. An
 * earlier version of this check accepted any `(settings,` occurrence as a
 * declaration, which is exactly why it missed the bug it exists to catch.
 */

const fs = require('node:fs')

const path = process.env.DSH_SCOPE_TARGET ?? 'dsh-mobile-bridge/bridge.js'
const source = fs.readFileSync(path, 'utf8')
const lines = source.split('\n')

/** Identifiers that must be declared where they are used. */
const WATCHED = ['settings', 'origin']

/** Functions that legitimately own `settings` without receiving it. */
const OWNERS = new Set([
  'resolveSettings',
  'writeSettingsFile',
  'rememberDevice',
  'deviceIdentity',
  'panelState',
  'startBeacon',
  'startBridge',
])

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

// Locate every top-level function with its parameter names and body extent.
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
  const params = match[2]
    .split(',')
    .map((entry) => entry.trim().split(/[=:]/)[0].trim())
    .filter(Boolean)
  functions.push({ name: match[1], params, start: index, end })
}

for (const fn of functions) {
  // Strip string literals before scanning: prose in an error message can contain
  // a watched word such as "Cross-origin" without referring to any variable.
  const raw = lines.slice(fn.start + 1, fn.end + 1).join('\n')
  const body = raw
    .replace(/`(?:[^`\\]|\\.)*`/g, '``')
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""')

  for (const identifier of WATCHED) {
    // A property read (`row.origin`) and an object key (`origin:`) are not
    // variable references, so neither counts as a use of the bare identifier.
    const usage = new RegExp(`(^|[^.\\w])${identifier}(?![\\w:])`)
    if (!usage.test(body)) continue

    // A same-named local binding shadows nothing and is not the bridge value.
    const localBinding = new RegExp(`(?:const|let|var)\\s+${identifier}\\s*=`).test(body)
    if (localBinding) {
      console.log(`  --   ${fn.name} declares its own ${identifier}`)
      continue
    }

    const declared = fn.params.includes(identifier) || (identifier === 'settings' && OWNERS.has(fn.name))
    if (!declared) {
      check(`${fn.name} uses ${identifier}`, false, `params were (${fn.params.join(', ')})`)
      continue
    }
    check(`${fn.name} uses ${identifier}`, true)
  }
}

console.log(failures === 0 ? '\nidentifier scope coherent' : `\n${failures} failure(s)`)

// `sendJson`'s fourth argument is the settings object, which decides CORS. A
// context passed there reads a non-existent `auth` property and every response
// on that route answers 500.
console.log('\nsendJson arguments:')
const sendJsonCalls = [...source.matchAll(/sendJson\(res, [^;]*?\)\n/g)]
let wrongArgument = 0
for (const call of sendJsonCalls) {
  const text = call[0]
  // Count top-level commas to find the fourth argument.
  let depth = 0
  let commas = 0
  let start = text.indexOf('(')
  let fourth = ''
  for (let index = start + 1; index < text.length; index += 1) {
    const character = text[index]
    if ('([{'.includes(character)) depth += 1
    else if (')]}'.includes(character)) {
      if (depth === 0) break
      depth -= 1
    } else if (character === ',' && depth === 0) {
      commas += 1
      if (commas === 3) {
        fourth = text.slice(index + 1).split(')')[0].split(',')[0].trim()
        break
      }
    }
  }
  if (fourth === 'ctx') {
    wrongArgument += 1
    console.log(`  FAIL sendJson called with ctx as settings: ${text.trim().slice(0, 70)}`)
  }
}
if (wrongArgument === 0) {
  console.log(`  ok   ${sendJsonCalls.length} sendJson calls use a settings argument`)
} else {
  failures += wrongArgument
}

process.exitCode = failures === 0 ? 0 : 1
