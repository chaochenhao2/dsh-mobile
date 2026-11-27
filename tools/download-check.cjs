/**
 * Exercise the download writers against a mocked request and response.
 *
 * The 500 "settings is not defined" only appears when the function actually
 * runs, so a syntax check cannot catch it. This drives `sendArchive` and
 * `sendSingleFile` with a fake context, request and response, and fails if they
 * throw instead of writing a body.
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
  // `async` must survive extraction: dropping it turns every `await` in the
  // body into a syntax error.
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`))
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

/** Constant declarations the writers read. */
function constants() {
  const names = [
    'MAX_ARCHIVE_DEPTH',
    'UPLOAD_DIR',
    'UPLOAD_SUBDIR',
    'MAX_ATTACHMENTS',
    'MAX_INLINE_IMAGE_BYTES',
    'PROTOCOL',
    'BRIDGE_VERSION',
  ]
  const single = names
    .map((name) => {
      const match = new RegExp(`const ${name} = [^\\n]+`).exec(source)
      return match === null ? '' : match[0]
    })
    .filter(Boolean)
    .join('\n')
  // CRC_TABLE is a multi-line initialiser, so it needs its own extraction.
  const tableStart = source.indexOf('const CRC_TABLE')
  const tableEnd = source.indexOf('function crc32')
  if (tableStart < 0 || tableEnd < 0) throw new Error('missing CRC_TABLE')
  return `${single}\n${source.slice(tableStart, tableEnd).trim()}`
}

const harness = `
const { createWriteStream, createReadStream, unlinkSync, mkdirSync, readFileSync, statSync, readdirSync } = require('node:fs')
const { join, basename, dirname } = require('node:path')
const { tmpdir } = require('node:os')
const { randomUUID } = require('node:crypto')
const { execFileSync } = require('node:child_process')
${constants()}
${take('crc32')}
${take('joinPath')}
${take('absolutize')}
${take('isAbsolutePath')}
${take('platformIsWindows')}
${take('baseName')}
${take('contentTypeFor')}
${take('corsHeaders')}
${take('liveSession')}
${take('ensureSession')}
${take('sessionRoot')}
${take('fileScope')}
${take('collectToDisk')}
${take('sendSingleFile')}
${take('sendArchive')}

// \`sendJson\` is nested inside the plugin's start function, so it cannot be
// extracted; this stand-in writes the same headers and body for the assertions.
function sendJson(res, status, value, settings, origin) {
  const body = Buffer.from(JSON.stringify(value))
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(body.byteLength),
    ...corsHeaders(settings, origin),
  })
  res.end(body)
}

module.exports = { sendArchive, sendSingleFile }
`

const harnessPath = path.join(os.tmpdir(), `dsh-download-${process.pid}.cjs`)
fs.writeFileSync(harnessPath, harness, 'utf8')

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

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-dl-'))
const root = work
const filePath = path.join(root, 'a.txt')
fs.writeFileSync(filePath, 'hello download\n')
const secondPath = path.join(root, 'b.txt')
fs.writeFileSync(secondPath, 'second file\n')

/** A service that answers for the fixture files only. */
const service = {
  async list(_scope, absolute) {
    if (absolute !== root) throw new Error('not a directory')
    return {
      path: absolute,
      truncated: false,
      entries: [
        { name: 'a.txt', type: 'file', size: fs.statSync(filePath).size },
        { name: 'b.txt', type: 'file', size: fs.statSync(secondPath).size },
      ],
    }
  },
  async stat(_scope, absolute) {
    const stat = fs.statSync(absolute)
    return { absolutePath: absolute, version: '1', bytes: stat.size }
  },
  async readBytes(_scope, absolute) {
    const data = fs.readFileSync(absolute)
    return { absolutePath: absolute, version: '1', bytes: data.length, offset: 0, data, eof: true }
  },
}

/** Minimal settings object the writers read. */
const settings = { auth: 'open', token: 'x', port: 5180 }

/**
 * Build a fake ServerResponse that records what was written.
 *
 * It extends Writable because both writers end by piping a file stream into the
 * response, and `pipe` needs a real destination to emit into.
 * @returns the response plus the captured state.
 */
function makeResponse() {
  const { Writable } = require('node:stream')
  const state = { status: 0, headers: null, body: Buffer.alloc(0), finished: false }
  const response = new Writable({
    write(chunk, _encoding, callback) {
      state.body = Buffer.concat([state.body, Buffer.from(chunk)])
      callback()
    },
  })
  response.headersSent = false
  response.writeHead = (status, headers) => {
    state.status = status
    state.headers = headers
    response.headersSent = true
    return response
  }
  // `res.on('close')` is how the writers learn the caller went away.
  response.destroy = () => {
    state.finished = true
    response.emit('close')
  }
  return { response, state }
}

/** A fake request carrying only the headers the writers read. */
function makeRequest(origin) {
  const listeners = new Map()
  return {
    headers: origin === undefined ? {} : { origin },
    on(event, handler) { listeners.set(event, handler); return this },
    once() { return this },
  }
}

/**
 * Await a promise with a timer, so a hang fails instead of blocking.
 * @param promise - the work to await.
 * @param label - description used in the timeout message.
 * @returns the resolved value.
 */
async function withTimeout(promise, label) {
  let timer
  const guard = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out`)), 8000)
  })
  try {
    return await Promise.race([promise, guard])
  } finally {
    clearTimeout(timer)
  }
}

;(async () => {
  const { sendArchive, sendSingleFile } = require(harnessPath)
  const ctx = { logger: { warn() {}, info() {} }, get: () => undefined }

  console.log('single file:')
  {
    const { response, state } = makeResponse()
    const req = makeRequest()
    const sent = await withTimeout(
      sendSingleFile(ctx, settings, service, { sessionId: 's', workspaceRoot: root }, req, response, filePath, new AbortController().signal),
      'sendSingleFile'
    )
    check('reports the file was sent', sent === true)
    check('status is 200', state.status === 200, `got ${state.status}`)
    check('content type is text', String(state.headers?.['content-type']).startsWith('text/plain'))
    check('filename header present', String(state.headers?.['content-disposition']).includes('a.txt'))
    check('no CORS origin for a tokenless local caller', state.headers?.['access-control-allow-origin'] === undefined)
  }

  console.log('single file with a local origin:')
  {
    const { response, state } = makeResponse()
    const req = makeRequest('http://127.0.0.1:54540')
    await withTimeout(
      sendSingleFile(ctx, settings, service, { sessionId: 's', workspaceRoot: root }, req, response, filePath, new AbortController().signal),
      'sendSingleFile with origin'
    )
    check('local origin echoed', state.headers?.['access-control-allow-origin'] === 'http://127.0.0.1:54540')
  }

  console.log('multi-file archive:')
  {
    const { response, state } = makeResponse()
    const ctxWithService = {
      logger: { warn() {}, info() {} },
      sessions: { get: () => undefined },
      get: (name) => (name === 'workspaceFiles' ? service : undefined),
    }
    const req = makeRequest()
    // The Session list supplies the working directory, which becomes the scope
    // root; the fixture tree is rooted there.
    const controller = { list: async () => ({ items: [{ sessionId: 's', cwd: root }] }) }
    await withTimeout(
      sendArchive(ctxWithService, settings, controller, req, response, 's', [filePath, secondPath]),
      'sendArchive'
    )
    // The body streams in through the file reader, so wait for the pipe to end.
    await new Promise((resolve) => setTimeout(resolve, 800))
    const body = state.body
    check('archive status is 200', state.status === 200,
      `got ${state.status}: ${body.toString('utf8').slice(0, 300)}`)
    check('archive has bytes', body.length > 0, `got ${body.length}`)
    check('archive is a zip', body.length >= 4 && body[0] === 0x50 && body[1] === 0x4b,
      body.length >= 2 ? `magic ${body[0].toString(16)} ${body[1].toString(16)}` : 'empty')
  }
})().finally(() => {
  fs.rmSync(work, { recursive: true, force: true })
  fs.rmSync(harnessPath, { force: true })
  const leftovers = path.join(os.tmpdir(), 'dsh-mobile-bridge')
  if (fs.existsSync(leftovers)) {
    for (const entry of fs.readdirSync(leftovers)) {
      if (entry.startsWith('archive-')) {
        try { fs.rmSync(path.join(leftovers, entry), { force: true }) } catch {}
      }
    }
  }
  console.log(failures === 0 ? '\ndownload writers verified' : `\n${failures} failure(s)`)
  process.exitCode = failures === 0 ? 0 : 1
})
