/**
 * Smoke test for the DSH Mobile bridge, driven exactly like the iOS app:
 * read the info document, create a Session, follow it over SSE, submit a
 * prompt, and cancel when the turn does not settle.
 *
 * Usage: node tools/bridge-smoke.mjs [--base http://127.0.0.1:5180] [--token <token>]
 */

import { request } from 'node:http'
import { readFileSync } from 'node:fs'

/**
 * Parse `--name value` pairs.
 * @param argv - process arguments after the script name.
 * @returns the named options.
 */
function parseArgs(argv) {
  const options = {}
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (!argument.startsWith('--')) continue
    const key = argument.slice(2)
    const next = argv[index + 1]
    if (next !== undefined && !next.startsWith('--')) {
      options[key] = next
      index += 1
    } else {
      options[key] = 'true'
    }
  }
  return options
}

const options = parseArgs(process.argv.slice(2))
const base = new URL(options.base ?? 'http://127.0.0.1:5180')
const configPath = `${process.env.DSH_HOME ?? `${process.env.USERPROFILE}/.dsh`}/mobile-bridge/config.json`
const TARGET = options.token ?? JSON.parse(readFileSync(configPath, 'utf8')).token

/**
 * Issue one JSON request against the bridge.
 * @param method - HTTP method.
 * @param path - absolute path with query.
 * @param body - optional JSON body.
 * @returns the decoded response.
 */
async function call(method, path, body) {
  const url = new URL(path, base)
  const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body), 'utf8')
  const response = await fetch(url, {
    method,
    headers: {
      authorization: `Bearer ${TARGET}`,
      ...(payload === undefined ? {} : { 'content-type': 'application/json' }),
    },
    body: payload,
  })
  const text = await response.text()
  if (!response.ok) throw new Error(`${method} ${path} -> ${response.status} ${text}`)
  return text === '' ? null : JSON.parse(text)
}

/**
 * Follow one Session and resolve with every SSE frame received before `stopMs`.
 * Collection also ends shortly after the followed turn settles.
 * @param sessionId - the Session to follow.
 * @param stopMs - absolute time when collection ends.
 * @returns the ordered frames.
 */
function follow(sessionId, stopMs) {
  return new Promise((resolve, reject) => {
    const frames = []
    let settled = false
    const url = new URL(`/api/session/${encodeURIComponent(sessionId)}/stream`, base)
    const req = request({
      hostname: url.hostname,
      port: url.port,
      path: `${url.pathname}${url.search}`,
      headers: { authorization: `Bearer ${TARGET}` },
    }, (res) => {
      if (res.statusCode !== 200) {
        reject(new Error(`stream -> ${res.statusCode}`))
        return
      }
      let buffer = ''
      res.setEncoding('utf8')
      res.on('data', (chunk) => {
        buffer += chunk
        let index = buffer.indexOf('\n\n')
        while (index >= 0) {
          const frame = buffer.slice(0, index)
          buffer = buffer.slice(index + 2)
          const line = frame.split('\n').find((entry) => entry.startsWith('data: '))
          if (line !== undefined) {
            let parsed
            try {
              parsed = JSON.parse(line.slice('data: '.length))
            } catch (error) {
              parsed = { type: 'unparsed', raw: line, error: String(error) }
            }
            frames.push(parsed)
            // The turn settled: keep a short grace window for the committed
            // assistant message, then stop following instead of waiting out the cap.
            if (!settled && parsed.type === 'status' && parsed.phase === 'idle'
              && frames.some((entry) => entry.type === 'op')) {
              settled = true
              setTimeout(() => {
                req.destroy()
                resolve(frames)
              }, 1_500)
            }
          }
          index = buffer.indexOf('\n\n')
        }
      })
      res.on('end', () => {
        clearTimeout(timer)
        resolve(frames)
      })
    })
    req.on('error', (error) => {
      clearTimeout(timer)
      if (settled) resolve(frames)
      else reject(error)
    })
    req.end()
    const timer = setTimeout(() => {
      req.destroy()
      resolve(frames)
    }, Math.max(1_000, stopMs - Date.now()))
  })
}

/**
 * Print a short, readable summary of one transcript node.
 * @param node - one bridge node.
 * @returns a one-line description.
 */
function describe(node) {
  const text = typeof node.text === 'string' ? node.text.replaceAll('\n', ' ⏎ ') : ''
  const head = text.length > 80 ? `${text.slice(0, 80)}…` : text
  const streaming = node.streaming === true ? ' (streaming)' : ''
  const tool = node.tool === undefined ? '' : ` status=${node.tool.status}`
  return `${String(node.id).padEnd(9)}${node.role.padEnd(9)}${streaming}${tool} ${head}`
}

const started = Date.now()
const info = await call('GET', '/api/info')
console.log(`info: dsh=${info.dsh.version} host=${info.host.hostname} addr=${info.host.preferredAddress}:${info.bridge.port}`)

const sessions = await call('GET', '/api/sessions')
console.log(`sessions: ${sessions.items.length} rows, newest "${sessions.items[0]?.title ?? '—'}"`)

const created = await call('POST', '/api/sessions', {})
console.log(`created: ${created.sessionId}`)

const collected = follow(created.sessionId, Date.now() + 90_000)
await new Promise((resolve) => setTimeout(resolve, 600))
const prompted = await call('POST', `/api/session/${encodeURIComponent(created.sessionId)}/prompt`, {
  text: 'Reply with exactly: BRIDGE-OK',
  clientTimeZone: 'Asia/Shanghai',
})
console.log(`prompt accepted: ${JSON.stringify(prompted)}`)

const frames = await collected
const kinds = new Map()
for (const frame of frames) kinds.set(frame.type, (kinds.get(frame.type) ?? 0) + 1)
console.log(`frames: ${frames.length} -> ${[...kinds].map(([kind, count]) => `${kind}×${count}`).join(', ')}`)

const reset = frames.find((frame) => frame.type === 'reset')
const nodes = new Map()
if (reset !== undefined) for (const node of reset.nodes) nodes.set(node.id, node)
for (const frame of frames) {
  if (frame.type !== 'op') continue
  if (frame.op === 'delta') {
    const node = nodes.get(frame.id) ?? { id: frame.id, role: 'assistant', text: '' }
    node.text = `${node.text}${frame.text}`
    nodes.set(frame.id, node)
    continue
  }
  if (frame.op === 'remove') {
    nodes.delete(frame.id)
    continue
  }
  if (frame.node !== undefined) nodes.set(frame.node.id, frame.node)
}

console.log('--- transcript ---')
for (const node of nodes.values()) console.log(describe(node))

const final = await call('GET', `/api/session/${encodeURIComponent(created.sessionId)}`)
console.log('--- state ---')
console.log(JSON.stringify(final.state))
if (final.state.running === true) {
  const cancelled = await call('POST', `/api/session/${encodeURIComponent(created.sessionId)}/cancel`, {})
  console.log(`cancel: ${JSON.stringify(cancelled)}`)
}
console.log(`elapsed: ${Date.now() - started} ms`)
