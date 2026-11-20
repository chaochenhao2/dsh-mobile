/**
 * dsh-mobile-bridge — serve this DeepSeek Harness to the DSH Mobile iOS app.
 *
 * The bridge starts with the Host, listens on a LAN port, and exposes a small
 * JSON + Server-Sent-Events API over the Harness Session API: list Sessions,
 * read one transcript, follow it live, submit a prompt, and cancel a turn.
 *
 * @module dsh-mobile-bridge
 */

import { createServer } from 'node:http'
import { createSocket } from 'node:dgram'
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { hostname, networkInterfaces, platform, release, homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'

/** Loader id for the single row this bundle inserts. */
export const name = 'dsh-mobile-bridge'

/** The Host Session API is the only hard dependency; other services are optional. */
export const inject = ['sessionController', 'sessions']

/** Bumped when the wire protocol with the iOS app changes incompatibly. */
const BRIDGE_VERSION = '1.0.0'

const PROTOCOL = 'dsh-mobile-bridge/1'

const DEFAULT_PORT = 5180
const DEFAULT_DISCOVERY_PORT = 5181
const DEFAULT_HOST = '0.0.0.0'
const MAX_BODY_BYTES = 1 << 20
const MAX_HISTORY_MESSAGES = 400
const KEEPALIVE_MS = 15_000
/** How often an open stream reconciles run state with the Session API. */
const STATE_POLL_MS = 2_000
const BEACON_INTERVAL_MS = 3_000
const TOOL_RESULT_CHARS = 4_000

/**
 * Describe what the app can rely on, so it can degrade instead of failing.
 */
const CAPABILITIES = [
  'info',
  'sessions.list',
  'session.read',
  'session.follow',
  'session.prompt',
  'session.cancel',
  'session.create',
  'models.list',
  'session.select-model',
]

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/**
 * Resolve the profile home that owns the bridge's own settings file.
 * @returns absolute directory under the user's Harness home.
 */
function homeDirectory() {
  const configured = process.env.DSH_HOME
  if (typeof configured === 'string' && configured.trim() !== '') return configured
  return join(homedir(), '.dsh')
}

/**
 * Read and parse the persisted settings file, tolerating absence and damage.
 * @param path - absolute settings path.
 * @returns the parsed object, or an empty object when unreadable.
 */
function readSettingsFile(path) {
  let raw
  try {
    raw = readFileSync(path, 'utf8')
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      console.warn(`dsh-mobile-bridge: could not read ${path}: ${error?.message ?? error}`)
    }
    return {}
  }
  try {
    const parsed = JSON.parse(raw)
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? parsed : {}
  } catch (error) {
    console.warn(`dsh-mobile-bridge: ${path} is not valid JSON (${error?.message ?? error}); using defaults`)
    return {}
  }
}

/**
 * Write the settings file, creating its directory when needed.
 * @param path - absolute settings path.
 * @param value - complete settings object to persist.
 */
function writeSettingsFile(path, value) {
  try {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
  } catch (error) {
    console.warn(`dsh-mobile-bridge: could not write ${path}: ${error?.message ?? error}`)
  }
}

/**
 * Pick the first of several candidates, ignoring absent or mistyped values.
 * @param candidates - values in priority order.
 * @returns the first usable boolean, or the fallback.
 */
function pickBoolean(candidates, fallback) {
  for (const value of candidates) if (typeof value === 'boolean') return value
  return fallback
}

/**
 * Pick the first usable port number.
 * @param candidates - values in priority order.
 * @param fallback - port used when none is usable.
 * @returns a port number.
 */
function pickPort(candidates, fallback) {
  for (const value of candidates) {
    const port = typeof value === 'string' ? Number.parseInt(value, 10) : value
    if (Number.isInteger(port) && port > 0 && port <= 65_535) return port
  }
  return fallback
}

/**
 * Pick the first usable bind address.
 * @param candidates - values in priority order.
 * @param fallback - address used when none is usable.
 * @returns a bind address.
 */
function pickHost(candidates, fallback) {
  for (const value of candidates) {
    if (typeof value === 'string' && value.trim() !== '') return value.trim()
  }
  return fallback
}

/**
 * Merge the bundle row's config over the persisted settings, minting a token on
 * first run and persisting it so the phone keeps its pairing across restarts.
 * @param rowConfig - the Loader row's `config` object.
 * @returns resolved settings, including the file path that owns them.
 */
function resolveSettings(rowConfig) {
  const path = join(homeDirectory(), 'mobile-bridge', 'config.json')
  const stored = readSettingsFile(path)
  const config = typeof rowConfig === 'object' && rowConfig !== null ? rowConfig : {}
  const persistedToken = typeof stored.token === 'string' && stored.token.length >= 16 ? stored.token : undefined
  const nextToken = persistedToken ?? randomBytes(16).toString('hex')
  const settings = {
    host: pickHost([config.host, stored.host], DEFAULT_HOST),
    port: pickPort([config.port, stored.port], DEFAULT_PORT),
    discovery: pickBoolean([config.discovery, stored.discovery], true),
    discoveryPort: pickPort([config.discoveryPort, stored.discoveryPort], DEFAULT_DISCOVERY_PORT),
    includeTokenInBeacon: pickBoolean([config.includeTokenInBeacon, stored.includeTokenInBeacon], false),
    token: nextToken,
  }
  const changed = persistedToken === undefined
    || stored.port !== settings.port
    || stored.host !== settings.host
    || stored.discovery !== settings.discovery
    || stored.discoveryPort !== settings.discoveryPort
    || stored.includeTokenInBeacon !== settings.includeTokenInBeacon
  if (changed) writeSettingsFile(path, settings)
  return { ...settings, path }
}

// ---------------------------------------------------------------------------
// Environment facts
// ---------------------------------------------------------------------------

/**
 * Candidate directories that hold the `@deepseek-ai/dsh` manifest.
 *
 * The Host process does not receive `DSH_INSTALL_DIR`, which the shell
 * environment service injects per call; it only exports those variables into
 * spawned shells. The Desktop app instead exposes the packaged archive root
 * through Electron's `process.resourcesPath`.
 * @returns candidate install anchors in priority order.
 */
function installAnchorCandidates() {
  const candidates = []
  const configured = process.env.DSH_INSTALL_DIR
  if (typeof configured === 'string' && configured !== '') candidates.push(configured)
  const resources = process.resourcesPath
  if (typeof resources === 'string' && resources !== '') {
    candidates.push(join(resources, 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh'))
    candidates.push(join(resources, 'app', 'dsh', 'node_modules', '@deepseek-ai', 'dsh'))
  }
  return candidates
}

/**
 * Read the running Harness version from its installation manifest.
 * @returns the version string, or null when no manifest is readable.
 */
function dshVersion() {
  for (const candidate of installAnchorCandidates()) {
    try {
      const manifest = JSON.parse(readFileSync(join(candidate, 'package.json'), 'utf8'))
      if (manifest.name === '@deepseek-ai/dsh' && typeof manifest.version === 'string') return manifest.version
    } catch {
      // Try the next anchor: only the one that names the CLI package is usable.
    }
  }
  return null
}

/**
 * Recover the profile name a launcher passed on the command line.
 * @returns the profile name, or null when the process was booted without one.
 */
function profileName() {
  const configured = process.env.DSH_PROFILE
  if (typeof configured === 'string' && configured !== '') return configured
  const argv = process.argv
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--profile') {
      const next = argv[index + 1]
      return typeof next === 'string' && next !== '' && !next.startsWith('-') ? next : null
    }
    if (argument.startsWith('--profile=')) {
      const value = argument.slice('--profile='.length)
      return value === '' ? null : value
    }
  }
  return null
}

/**
 * Classify an address so the app can pick the transport that reaches it.
 *
 * The phone may be on the same Wi-Fi, joined to a Tailscale tailnet, or dialing
 * a public relay. The label is advisory: the app dials whatever it is given,
 * but it can prefer a tailnet address when the home LAN is unreachable.
 * @param address - dotted IPv4 address.
 * @returns 'lan', 'tailnet', or 'other'.
 */
function addressKind(address) {
  if (address.startsWith('192.168.')) return 'lan'
  if (address.startsWith('10.')) return 'lan'
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(address)) return 'lan'
  // 100.64/10 is carrier-grade NAT; Tailscale assigns peers from this range.
  if (/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(address)) return 'tailnet'
  return 'other'
}

/**
 * Rank a dialing candidate so a same-network address is offered first.
 * @param address - dotted IPv4 address.
 * @returns a smaller-is-better rank.
 */
function addressRank(address) {
  const kind = addressKind(address)
  if (kind === 'lan') return 0
  if (kind === 'tailnet') return 1
  if (address.startsWith('169.254.')) return 9
  return 5
}

/**
 * List the non-internal IPv4 interfaces, best candidate first.
 * @returns one entry per usable LAN address.
 */
function lanInterfaces() {
  const result = []
  const interfaces = networkInterfaces()
  for (const [name, addresses] of Object.entries(interfaces)) {
    for (const address of addresses ?? []) {
      if (address.family !== 'IPv4' || address.internal) continue
      result.push({
        name,
        address: address.address,
        netmask: address.netmask,
        kind: addressKind(address.address),
      })
    }
  }
  result.sort((left, right) => addressRank(left.address) - addressRank(right.address))
  return result
}

/**
 * Convert a dotted IPv4 address and netmask into their directed broadcast address.
 * @param address - dotted IPv4 address.
 * @param netmask - dotted IPv4 netmask of the same interface.
 * @returns the directed broadcast address, or null when either input is malformed.
 */
function broadcastAddress(address, netmask) {
  const toBytes = (value) => {
    const parts = value.split('.')
    if (parts.length !== 4) return null
    const bytes = parts.map((part) => Number.parseInt(part, 10))
    return bytes.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255) ? bytes : null
  }
  const host = toBytes(address)
  const mask = toBytes(netmask)
  if (host === null || mask === null) return null
  return host.map((byte, index) => (byte & mask[index]) | (~mask[index] & 0xff)).join('.')
}

/**
 * Choose the address a phone should dial.
 * @returns the preferred LAN address, or loopback when none exists.
 */
function preferredAddress() {
  const [first] = lanInterfaces()
  return first?.address ?? '127.0.0.1'
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

/**
 * Write one JSON response.
 * @param res - the response being served.
 * @param status - HTTP status code.
 * @param value - JSON-serializable body.
 */
function sendJson(res, status, value) {
  const body = Buffer.from(`${JSON.stringify(value)}\n`, 'utf8')
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(body.byteLength),
    'cache-control': 'no-store',
    ...corsHeaders(),
  })
  res.end(body)
}

/**
 * CORS headers, so a desktop browser can exercise the same API while debugging.
 * @returns the shared header set.
 */
function corsHeaders() {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'authorization, content-type, x-dsh-token',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
  }
}

/**
 * Read and parse one JSON request body.
 * @param req - the request being served.
 * @returns the parsed body, or an empty object when absent.
 * @throws Error when the body exceeds the bound or is not valid JSON.
 */
async function readJsonBody(req) {
  const chunks = []
  let total = 0
  for await (const chunk of req) {
    total += chunk.length
    if (total > MAX_BODY_BYTES) throw new Error(`request body exceeds ${MAX_BODY_BYTES} bytes`)
    chunks.push(chunk)
  }
  if (total === 0) return {}
  try {
    const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new Error('request body must be a JSON object')
    }
    return parsed
  } catch (error) {
    throw new Error(error instanceof Error ? error.message : 'request body is not valid JSON')
  }
}

/**
 * Compare two tokens without leaking their common prefix length.
 * @param presented - token from the request, possibly absent.
 * @param expected - the configured token.
 * @returns whether the request may proceed.
 */
function tokenMatches(presented, expected) {
  if (typeof presented !== 'string' || presented.length === 0) return false
  const left = Buffer.from(presented, 'utf8')
  const right = Buffer.from(expected, 'utf8')
  if (left.length !== right.length) return false
  return timingSafeEqual(left, right)
}

/**
 * Extract the caller's token from the header set or the query string.
 * @param req - the request being served.
 * @param url - its parsed URL.
 * @returns the presented token, or undefined.
 */
function presentedToken(req, url) {
  const header = req.headers.authorization
  if (typeof header === 'string' && header.toLowerCase().startsWith('bearer ')) {
    return header.slice('bearer '.length).trim()
  }
  const explicit = req.headers['x-dsh-token']
  if (typeof explicit === 'string' && explicit !== '') return explicit
  const query = url.searchParams.get('token')
  return query === null ? undefined : query
}

// ---------------------------------------------------------------------------
// Transcript folding
// ---------------------------------------------------------------------------

/**
 * Join the text blocks of one model-facing content array.
 * @param content - the message `content` blocks, possibly absent.
 * @returns the concatenated visible text.
 */
function textOfContent(content) {
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const block of content) {
    if (typeof block !== 'object' || block === null) continue
    if (block.type === 'text' && typeof block.text === 'string') parts.push(block.text)
  }
  return parts.join('\n').trim()
}

/**
 * Join the reasoning blocks of one model-facing content array.
 *
 * Reasoning reaches the durable log as its own block type, separate from the
 * visible text, so the phone shows it as a distinct collapsible section rather
 * than mixed into the answer.
 * @param content - the message `content` blocks, possibly absent.
 * @returns the concatenated reasoning text, or an empty string.
 */
function reasoningOfContent(content) {
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const block of content) {
    if (typeof block !== 'object' || block === null) continue
    if (block.type === 'reasoning' && typeof block.text === 'string') parts.push(block.text)
  }
  return parts.join('\n').trim()
}

/**
 * Bound one long string so a phone never receives an unbounded tool result.
 * @param text - the raw text.
 * @returns the text, truncated with an explicit marker when too long.
 */
function clamp(text) {
  if (typeof text !== 'string') return ''
  return text.length <= TOOL_RESULT_CHARS
    ? text
    : `${text.slice(0, TOOL_RESULT_CHARS)}\n… (${text.length - TOOL_RESULT_CHARS} more characters)`
}

/**
 * Fold Session wire events into the flat message list the app renders.
 *
 * The Harness event vocabulary is wide and grows; the bridge reduces it to four
 * roles (user, assistant, tool, notice) and emits idempotent upserts keyed by a
 * stable id, so the app never needs to understand Session events.
 */
class Transcript {
  constructor() {
    /** @type {Map<string, object>} */
    this.byId = new Map()
    /** @type {object[]} */
    this.nodes = []
    /**
     * The attempt whose provisional assistant node is on screen. Only the
     * `start` frame names its turn and step; the committed `assistant/message`
     * replaces this node, so the node id is attempt-scoped.
     * @type {{ attemptId: string, id: string } | null}
     */
    this.provisional = null
  }

  /**
   * Return every node in display order.
   * @returns the current transcript.
   */
  snapshot() {
    return this.nodes
  }

  /**
   * Add or replace one node, preserving its position when it already exists.
   * @param node - the complete node to store.
   * @returns the operator that describes the change.
   */
  upsert(node) {
    if (this.byId.has(node.id)) {
      const index = this.nodes.findIndex((candidate) => candidate.id === node.id)
      if (index >= 0) this.nodes[index] = node
      this.byId.set(node.id, node)
      return { op: 'update', node }
    }
    this.byId.set(node.id, node)
    this.nodes.push(node)
    return { op: 'add', node }
  }

  /**
   * Drop one node.
   * @param id - the node identity.
   * @returns the operator that describes the removal, or null when absent.
   */
  remove(id) {
    const index = this.nodes.findIndex((candidate) => candidate.id === id)
    this.byId.delete(id)
    if (index < 0) return null
    this.nodes.splice(index, 1)
    return { op: 'remove', id }
  }

  /**
   * Read one stored node.
   * @param id - the node identity.
   * @returns the node, or undefined.
   */
  get(id) {
    return this.byId.get(id)
  }

  /**
   * Forget the provisional node, emitting its removal.
   * @returns operators for the removal, possibly empty.
   */
  dropProvisional() {
    if (this.provisional === null) return []
    const { id } = this.provisional
    this.provisional = null
    const removed = this.remove(id)
    return removed === null ? [] : [removed]
  }

  /**
   * Fold one assistant stream frame into the transcript.
   * @param frame - one `SessionAssistantStreamFrame`.
   * @returns operators to relay, possibly empty.
   */
  applyStream(frame) {
    if (typeof frame !== 'object' || frame === null) return []
    const attemptId = typeof frame.attemptId === 'string' ? frame.attemptId : 'unknown'
    if (frame.type === 'start') {
      const id = 'a:live'
      const ops = this.provisional !== null && this.provisional.id !== id
        ? this.dropProvisional()
        : []
      this.provisional = { attemptId, id }
      const existing = this.get(id)
      ops.push(this.upsert({
        id,
        role: 'assistant',
        text: existing?.text ?? '',
        ts: Date.now(),
        seq: null,
        streaming: true,
      }))
      return ops
    }
    if (frame.type === 'chunk') {
      const chunk = frame.chunk
      if (typeof chunk !== 'object' || chunk === null) return []
      // Both visible text and reasoning stream as deltas; they land in separate
      // fields of the same provisional node so the app can fold thinking away.
      const isText = chunk.type === 'text-delta'
      const isReasoning = chunk.type === 'reasoning-delta'
      if (!isText && !isReasoning) return []
      const text = typeof chunk.text === 'string' ? chunk.text : ''
      if (text === '') return []
      const id = this.provisional?.id ?? 'a:live'
      const node = this.get(id) ?? {
        id, role: 'assistant', text: '', reasoning: '', ts: Date.now(), seq: null, streaming: true,
      }
      if (isText) node.text = `${node.text ?? ''}${text}`
      else node.reasoning = `${node.reasoning ?? ''}${text}`
      node.streaming = true
      this.upsert(node)
      return [{ op: 'delta', id, field: isText ? 'text' : 'reasoning', text }]
    }
    if (frame.type === 'end') {
      const outcome = typeof frame.outcome === 'object' && frame.outcome !== null ? frame.outcome.kind : undefined
      if (outcome === 'committed') {
        // The committed `assistant/message` follows immediately and replaces
        // this node; only clear the streaming flag in the meantime.
        const id = this.provisional?.id
        const existing = id === undefined ? undefined : this.get(id)
        if (existing === undefined) return []
        const node = { ...existing, streaming: false }
        this.upsert(node)
        return [{ op: 'update', node }]
      }
      return this.dropProvisional()
    }
    return []
  }

  /**
   * Fold one durable Session event into operators.
   * @param event - one `SessionWireEvent`.
   * @returns operators to relay, possibly empty.
   */
  applyEvent(event) {
    const data = event?.data
    if (typeof data !== 'object' || data === null) return []
    const seq = typeof event.seq === 'number' ? event.seq : 0
    switch (event.type) {
      case 'user/message': {
        const text = textOfContent(data.content)
        // Synthetic context injection carries no user-visible line of its own.
        if (text === '') return []
        const source = typeof data.source === 'object' && data.source !== null ? data.source.kind : undefined
        // Only a real human prompt is `user`; runtime context, skill bodies, and
        // notices share the event but are background material for the phone.
        const isPrompt = typeof source !== 'string' || source === 'user'
        return [this.upsert({
          id: `u:${seq}`,
          role: isPrompt ? 'user' : 'notice',
          text,
          ts: event.time ?? null,
          seq,
          source: typeof source === 'string' ? source : null,
        })]
      }
      case 'assistant/message': {
        const message = data.message
        const text = textOfContent(message?.content)
        const reasoning = reasoningOfContent(message?.content)
        const ops = this.dropProvisional()
        if (text === '' && reasoning === '') return ops
        const turn = data.turn ?? 0
        const step = data.step ?? 0
        ops.push(this.upsert({
          id: `a:${turn}:${step}`,
          role: 'assistant',
          text,
          reasoning,
          ts: event.time ?? null,
          seq,
          streaming: false,
          interrupted: data.interrupted === true,
        }))
        return ops
      }
      case 'assistant/attempt': {
        // A failed or retried attempt commits no surface message; the
        // provisional node it streamed must not survive it.
        return this.dropProvisional()
      }
      case 'tool/call': {
        const callId = typeof data.callId === 'string' ? data.callId : `seq:${seq}`
        const args = typeof data.arguments === 'string' ? data.arguments : ''
        return [this.upsert({
          id: `t:${callId}`,
          role: 'tool',
          text: typeof data.name === 'string' ? data.name : 'tool',
          ts: event.time ?? null,
          seq,
          tool: {
            name: typeof data.name === 'string' ? data.name : 'tool',
            arguments: clamp(args),
            status: 'running',
            result: null,
          },
        })]
      }
      case 'tool/result': {
        const message = data.message
        const callId = typeof message?.toolCallId === 'string' ? message.toolCallId : `seq:${seq}`
        const id = `t:${callId}`
        const existing = this.get(id)
        const failed = message?.isError === true || typeof data.error === 'object'
        const result = clamp(textOfContent(message?.content))
        const reason = typeof data.error?.reason === 'string'
          ? data.error.reason
          : typeof data.error?.code === 'string' ? data.error.code : null
        return [this.upsert({
          id,
          role: 'tool',
          text: existing?.text ?? (typeof message?.source?.toolName === 'string' ? message.source.toolName : 'tool'),
          ts: existing?.ts ?? event.time ?? null,
          seq: existing?.seq ?? seq,
          tool: {
            name: existing?.tool?.name ?? 'tool',
            arguments: existing?.tool?.arguments ?? '',
            status: failed ? 'error' : 'done',
            result,
            reason,
          },
        })]
      }
      default:
        return []
    }
  }
}

/**
 * Describe one tool reference or notice operator from a non-message event.
 * @param event - one `SessionWireEvent`.
 * @returns operators that carry state rather than transcript content.
 */
function statusOf(event) {
  const data = event?.data
  if (typeof data !== 'object' || data === null) return null
  if (event.type === 'turn/start') return { phase: 'running', turn: data.turn ?? null, reason: null }
  if (event.type === 'turn/end') {
    const reason = typeof data.reason?.kind === 'string' ? data.reason.kind : null
    return { phase: 'idle', turn: data.turn ?? null, reason }
  }
  return null
}

/**
 * Read the authoritative run state of one Session.
 *
 * `running` is whether an Agent turn is executing right now; `pendingInput` is
 * why it may be waiting on a human. Both come from the Session API rather than
 * from event inference, because a stream that opens mid-turn never sees the
 * events that preceded it.
 * @param ctx - the Host plugin context.
 * @param sessionId - the Session to read.
 * @param signal - cancellation for the read.
 * @returns the state, or undefined when the read failed.
 */
async function readState(ctx, sessionId, signal) {
  try {
    const state = await ctx.sessionController.state({ sessionId }, signal)
    return {
      running: state?.running === true,
      pendingInput: Array.isArray(state?.pendingInput) ? state.pendingInput : [],
    }
  } catch (error) {
    if (signal.aborted) return undefined
    ctx.logger.warn(`dsh-mobile-bridge: state read failed for ${sessionId}: ${error?.message ?? error}`)
    return undefined
  }
}

/**
 * Keep the advertised run state accurate while one stream is open.
 *
 * Event-derived status is emitted immediately and is usually right, but it
 * cannot see a turn that was already running when the stream opened, nor one
 * that settles while the client is reconnecting. A slow poll reconciles the
 * two and only reports genuine changes.
 * @param ctx - the Host plugin context.
 * @param sessionId - the Session being followed.
 * @param abort - cancellation for this stream.
 * @param write - the SSE frame writer.
 * @param initial - the state already sent with the opening snapshot.
 */
function startStateWatcher(ctx, sessionId, abort, write, initial) {
  let lastRunning = initial.running
  let lastPending = initial.pendingInput
  const timer = setInterval(() => {
    if (abort.signal.aborted) {
      clearInterval(timer)
      return
    }
    void readState(ctx, sessionId, abort.signal).then((state) => {
      if (state === undefined || abort.signal.aborted) return
      const pendingChanged = state.pendingInput.join(',') !== lastPending.join(',')
      if (state.running === lastRunning && !pendingChanged) return
      lastRunning = state.running
      lastPending = state.pendingInput
      write({
        type: 'status',
        phase: state.running ? 'running' : 'idle',
        turn: null,
        reason: null,
        pendingInput: state.pendingInput,
      })
    })
  }, STATE_POLL_MS)
  if (typeof timer.unref === 'function') timer.unref()
  abort.signal.addEventListener('abort', () => clearInterval(timer), { once: true })
}

// ---------------------------------------------------------------------------
// Session reads
// ---------------------------------------------------------------------------

/**
 * Read the model currently selected for one Session, from its durable log.
 *
 * The selection is a `model/selection` event, so the last one in the log is the
 * live answer. Reading the log rather than the projection keeps this correct for
 * cold Sessions and for Sessions nobody else is observing, and it needs no
 * activation: a phone can open a finished Session and still see which model it
 * last ran on.
 * @param ctx - the Host plugin context.
 * @param sessionId - the Session to read.
 * @returns the selection, or null when the Session has none.
 */
async function currentSelection(ctx, sessionId) {
  try {
    const query = ctx.get('sessionQuery')
    if (query === undefined) return null
    // `readSession` returns the full log snapshot with event payloads; the
    // lighter `listEvents` carries only metadata and no `data` field.
    const snapshot = await query.readSession(sessionId)
    let chosen = null
    for (const event of snapshot?.events ?? []) {
      if (event?.type !== 'model/selection') continue
      const data = event.data
      if (typeof data !== 'object' || data === null) continue
      if (typeof data.provider !== 'string' || typeof data.model !== 'string') continue
      chosen = {
        provider: data.provider,
        model: data.model,
        reasoningEffort: typeof data.reasoningEffort === 'string' ? data.reasoningEffort : null,
      }
    }
    return chosen
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: model selection read failed for ${sessionId}: ${error?.message ?? error}`)
    return null
  }
}

/**
 * Adapt the Host model catalog for a phone picker.
 *
 * The Host catalog already groups by provider and carries reasoning efforts;
 * what the app needs on top is a stable identity per row and the provider's
 * display name flattened onto it, so a list cell can render without walking
 * back up the tree.
 * @param ctx - the Host plugin context.
 * @param controller - the Host Session API.
 * @returns the catalog plus the provider-level shape the picker renders.
 */
async function modelCatalogFor(ctx, controller) {
  const catalog = await controller.modelCatalog()
  const groups = (catalog.groups ?? []).map((group) => ({
    provider: group.id,
    providerName: group.name,
    models: (group.models ?? []).map((model) => ({
      key: `${group.id}/${model.id}`,
      id: model.id,
      name: model.name,
      description: typeof model.description === 'string' ? model.description : null,
      badge: model.badge === undefined ? null : model.badge,
      // An absent `reasoning` means the route exposes no effort choice, which
      // the picker renders by hiding the control entirely.
      reasoning: model.reasoning === undefined
        ? null
        : {
          efforts: (model.reasoning.efforts ?? []).map((effort) => ({
            id: effort.id,
            name: effort.name,
            description: typeof effort.description === 'string' ? effort.description : null,
          })),
          defaultEffort: typeof model.reasoning.defaultEffort === 'string'
            ? model.reasoning.defaultEffort
            : null,
        },
    })),
  }))
  return {
    default: catalog.default,
    routableProviders: catalog.routableProviders ?? [],
    groups,
    failures: catalog.failures ?? [],
  }
}

/**
 * Read the display title of one Session.
 * @param controller - the Host Session API.
 * @param sessionId - the Session to look up.
 * @param signal - cancellation for the read.
 * @returns the title, or null when unset.
 */
async function titleOf(controller, sessionId, signal) {  const list = await controller.list({}, signal)
  const row = list.items.find((item) => item.sessionId === sessionId)
  const title = row?.projections?.values?.title
  return typeof title === 'string' && title !== '' ? title : null
}

/**
 * Project one Session list row into the app's row type.
 * @param row - one `SessionSummary`.
 * @returns the app-facing row.
 */
function summarize(row) {
  const values = row.projections?.values ?? {}
  return {
    id: row.sessionId,
    title: typeof values.title === 'string' && values.title !== '' ? values.title : 'New session',
    updatedAt: row.updatedAt ?? null,
    running: row.running === true,
    blank: row.blank === true,
    cwd: row.cwd ?? null,
    agentAvailable: row.agentAvailable === true,
    origin: row.origin ?? null,
    parentSessionId: row.parentSessionId ?? null,
  }
}

// ---------------------------------------------------------------------------
// Workspaces, agent modes, and permissions
// ---------------------------------------------------------------------------

/**
 * Read every durable workspace.
 *
 * A new Session is anchored to one: either an existing workspace or a directory
 * the person names. The phone needs both the list and each workspace's health,
 * because a workspace whose directory disappeared cannot host a new Session.
 * @param ctx - the Host plugin context.
 * @returns one row per workspace, plus the process default directory.
 */
async function workspacesPayload(ctx) {
  const registry = ctx.get('workspaceRegistry')
  const rows = []
  if (registry !== undefined) {
    for (const workspace of registry.list()) {
      let status = 'unknown'
      try {
        status = await workspace.status()
      } catch (error) {
        ctx.logger.warn(`dsh-mobile-bridge: workspace status failed for ${workspace.id}: ${error?.message ?? error}`)
      }
      rows.push({
        id: workspace.id,
        path: workspace.path,
        title: workspace.title,
        createdAt: typeof workspace.createdAt === 'string' ? workspace.createdAt : null,
        updatedAt: typeof workspace.updatedAt === 'string' ? workspace.updatedAt : null,
        status,
        sessionCount: Array.isArray(workspace.sessionIds) ? workspace.sessionIds.length : 0,
      })
    }
  }
  const working = ctx.get('workingDirectory')
  let defaultDirectory = null
  try {
    defaultDirectory = typeof working?.defaultDirectory === 'string' ? working.defaultDirectory : null
  } catch {
    // A composition without a working-directory service has no opinion here.
  }
  return { workspaces: rows, defaultDirectory }
}

/**
 * Read the selectable agent modes and which one is the current default.
 *
 * The shipped roster carries `standard`, `ptc`, `minimal` and `cordis`; their
 * display copy lives in dictionaries keyed by id, because a shipped preset
 * publishes no name of its own. The phone gets resolved labels so it never has
 * to know that rule.
 * @param ctx - the Host plugin context.
 * @returns modes in roster order, marking the selected default.
 */
async function presetsPayload(ctx) {
  const registry = ctx.get('agentPresets')
  if (registry === undefined) return { modes: [], selectedDefault: null }
  let roster = []
  try {
    roster = await registry.list()
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: preset roster failed: ${error?.message ?? error}`)
  }
  const builtInNames = {
    standard: '普通',
    ptc: 'PTC',
    minimal: '极简',
    cordis: '创造',
  }
  const builtInDescriptions = {
    standard: '完整能力：文件、命令、搜索、子代理与工作流。',
    ptc: '以代码方式调用工具，适合批量操作。',
    minimal: '只保留最基本的对话与工具。',
    cordis: '可自我扩展，能编写并加载新插件。',
  }
  let selectedDefault = null
  try {
    const settings = ctx.get('agentPresetRegistrySettings')
    if (settings !== undefined && typeof settings.selectedDefault === 'string') {
      selectedDefault = settings.selectedDefault
    }
  } catch {
    // Optional settings service; a composition without it still lists modes.
  }
  const modes = roster
    .map((preset, index) => {
      const isBuiltIn = preset.name === undefined && builtInNames[preset.id] !== undefined
      return {
        id: preset.id,
        name: isBuiltIn ? builtInNames[preset.id] : (preset.name ?? preset.id),
        description: isBuiltIn
          ? builtInDescriptions[preset.id] ?? null
          : (preset.description ?? null),
        builtIn: isBuiltIn,
        broken: typeof preset.broken === 'string' ? preset.broken : null,
        order: typeof preset.order === 'number' ? preset.order : index,
      }
    })
    .sort((left, right) => left.order - right.order)
  return { modes, selectedDefault }
}

/**
 * Look up one live Session without throwing for a cold one.
 *
 * Reads that are optional for the response — permissions, for instance — must
 * degrade to "unknown" rather than failing the whole endpoint, because a
 * Session on disk has not been activated until something opens it.
 * @param ctx - the Host plugin context.
 * @param sessionId - the Session to look up.
 * @returns the live Session, or undefined when it is cold.
 */
function liveSession(ctx, sessionId) {
  try {
    return ctx.sessions.get(sessionId)
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: live Session lookup failed for ${sessionId}: ${error?.message ?? error}`)
    return undefined
  }
}

/**
 * Resolve a Session, activating it when it is currently cold.
 *
 * A freshly created Session, or one opened after a restart, may not be in the
 * in-memory store until something activates it. Activation goes through the
 * Session API, and the resolved Agent's own Session object is used directly:
 * the registry lookup can still miss it when activation registered the Agent
 * through another path.
 * @param ctx - the Host plugin context.
 * @param sessionId - the Session to resolve.
 * @returns the live Session, or undefined when it cannot be activated.
 */
async function ensureSession(ctx, sessionId) {
  const existing = liveSession(ctx, sessionId)
  if (existing !== undefined) return existing
  const controller = ctx.get('sessionController')
  if (controller === undefined) return undefined
  try {
    const result = await controller.resolveAgent(sessionId)
    // The resolved Agent owns the Session object; the registry lookup may still
    // miss it when activation registered the Agent through another path.
    const session = result?.agent?.session
    if (session !== undefined) return session
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: Session ${sessionId} could not be activated: ${error?.message ?? error}`)
  }
  return liveSession(ctx, sessionId)
}

/**
 * Read the permission presets a Session may switch to, and its current one.
 *
 * Permission presets are a process-level catalog (they change with live
 * contributions), while the Session's own choice is a durable projection. Both
 * are needed: the catalog fills the menu, the projection marks the current row.
 * @param ctx - the Host plugin context.
 * @param session - the live Session, or undefined for a catalog-only read.
 * @returns selectable options plus the current value, or null without a service.
 */
function permissionsPayload(ctx, session) {
  const service = ctx.get('permissionPresets')
  if (service === undefined) return null
  let catalog
  try {
    catalog = service.catalog()
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: permission catalog failed: ${error?.message ?? error}`)
    return null
  }
  let currentValue = null
  if (session !== undefined) {
    try {
      currentValue = service.current(session)
    } catch (error) {
      ctx.logger.warn(`dsh-mobile-bridge: permission current failed: ${error?.message ?? error}`)
    }
  }
  return {
    options: (catalog.options ?? []).map((option) => ({
      value: option.value,
      name: option.name,
      description: typeof option.description === 'string' ? option.description : null,
    })),
    defaultPreset: typeof catalog.defaultPreset === 'string' ? catalog.defaultPreset : null,
    currentValue,
  }
}

/**
 * Read a bounded transcript page for one Session.
 * @param controller - the Host Session API.
 * @param sessionId - the Session to read.
 * @param signal - cancellation for the read.
 * @returns the folded nodes, the state, and the page cursor.
 */
async function readSession(controller, sessionId, signal) {  const page = await controller.events({
    address: { kind: 'session', sessionId },
    maxMessages: MAX_HISTORY_MESSAGES,
  }, signal)
  const transcript = new Transcript()
  for (const record of page.records ?? []) {
    if (record?.type !== 'event') continue
    transcript.applyEvent(record.event)
  }
  return {
    nodes: transcript.snapshot(),
    cursor: page.cursor ?? null,
    hasMore: page.hasMore === true,
  }
}

// ---------------------------------------------------------------------------
// HTTP surface
// ---------------------------------------------------------------------------

/**
 * Serve one request.
 * @param ctx - the Host plugin context.
 * @param settings - resolved bridge settings.
 * @param req - the incoming request.
 * @param res - the response being written.
 */
async function handleRequest(ctx, settings, req, res) {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
  const segments = url.pathname.split('/').filter((segment) => segment !== '')
  try {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, corsHeaders())
      res.end()
      return
    }
    if (segments.length === 2 && segments[0] === 'api' && segments[1] === 'health') {
      sendJson(res, 200, { ok: true, protocol: PROTOCOL, bridge: BRIDGE_VERSION })
      return
    }
    if (!tokenMatches(presentedToken(req, url), settings.token)) {
      sendJson(res, 401, {
        error: 'unauthorized',
        message: 'Send the bridge token as `Authorization: Bearer <token>` or `?token=<token>`.',
      })
      return
    }
    const controller = ctx.sessionController
    if (segments[0] !== 'api' || segments.length < 2) {
      sendJson(res, 404, { error: 'not-found' })
      return
    }
    if (segments[1] === 'info' && segments.length === 2) {
      sendJson(res, 200, await infoPayload(ctx, settings))
      return
    }
    if (segments[1] === 'models' && segments.length === 2) {
      sendJson(res, 200, await modelCatalogFor(ctx, controller))
      return
    }
    if (segments[1] === 'workspaces' && segments.length === 2) {
      sendJson(res, 200, await workspacesPayload(ctx))
      return
    }
    if (segments[1] === 'modes' && segments.length === 2) {
      sendJson(res, 200, await presetsPayload(ctx))
      return
    }
    if (segments[1] === 'permissions' && segments.length === 2) {
      const catalog = permissionsPayload(ctx, undefined)
      if (catalog === null) {
        sendJson(res, 404, { error: 'unsupported', message: 'This Harness composes no permission service.' })
        return
      }
      sendJson(res, 200, catalog)
      return
    }
    if (segments[1] === 'sessions') {
      if (segments.length === 2 && req.method === 'GET') {
        const signal = new AbortController().signal
        const list = await controller.list({}, signal)
        const rows = list.items.map(summarize)
        rows.sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0))
        sendJson(res, 200, { items: rows })
        return
      }
      if (segments.length === 2 && req.method === 'POST') {
        const body = await readJsonBody(req)
        const created = await controller.create({
          ...(typeof body.cwd === 'string' && body.cwd !== '' ? { cwd: body.cwd } : {}),
          ...(typeof body.agentPreset === 'string' && body.agentPreset !== '' ? { agentPreset: body.agentPreset } : {}),
          ...(typeof body.workspaceId === 'string' && body.workspaceId !== '' ? { workspaceId: body.workspaceId } : {}),
        })
        sendJson(res, 200, created)
        return
      }
    }
    if (segments[1] === 'session' && segments.length >= 3) {
      const sessionId = decodeURIComponent(segments[2])
      const tail = segments[3]
      if (tail === undefined && req.method === 'GET') {
        const signal = new AbortController().signal
        const [page, state, title] = await Promise.all([
          readSession(controller, sessionId, signal),
          controller.state({ sessionId }, signal),
          titleOf(controller, sessionId, signal),
        ])
        sendJson(res, 200, {
          sessionId,
          title,
          state,
          // The model this Session will use for its next prompt.
          model: await currentSelection(ctx, sessionId),
          // The permission preset in force for this Session. A Cold Session has
          // no live object yet, so activation is attempted; when it still fails
          // the catalog is returned without a current value rather than failing
          // the whole read.
          permissions: permissionsPayload(ctx, await ensureSession(ctx, sessionId)),
          ...page,
        })
        return
      }
      if (tail === 'stream' && req.method === 'GET') {
        await streamSession(ctx, req, res, sessionId, url)
        return
      }
      if (tail === 'prompt' && req.method === 'POST') {
        const body = await readJsonBody(req)
        const text = typeof body.text === 'string' ? body.text : ''
        if (text.trim() === '') {
          sendJson(res, 400, { error: 'empty-prompt', message: '`text` must contain non-whitespace characters.' })
          return
        }
        const accept = new AbortController()
        // Honour a caller-supplied identity so a retried prompt is deduplicated
        // by the Session instead of being enqueued twice. The app reuses its
        // request id across retries of the same submission.
        const requestId = typeof body.requestId === 'string' && body.requestId !== ''
          ? body.requestId
          : randomUUID()
        const result = await controller.prompt({
          requestId,
          sessionId,
          mode: body.mode === 'steer' ? 'steer' : 'queue',
          content: [{ type: 'text', text }],
          ...(typeof body.clientTimeZone === 'string' && body.clientTimeZone !== ''
            ? { clientTimeZone: body.clientTimeZone }
            : {}),
        }, accept.signal)
        sendJson(res, 200, { ...result, requestId })
        return
      }
      if (tail === 'cancel' && req.method === 'POST') {
        sendJson(res, 200, controller.cancel({ sessionId }))
        return
      }
      if (tail === 'permission' && req.method === 'POST') {
        const body = await readJsonBody(req)
        if (typeof body.value !== 'string' || body.value === '') {
          sendJson(res, 400, { error: 'bad-request', message: '`value` is required.' })
          return
        }
        const service = ctx.get('permissionPresets')
        if (service === undefined) {
          sendJson(res, 404, { error: 'unsupported', message: 'This Harness composes no permission service.' })
          return
        }
        // A Session can be cold — freshly created, or opened after a restart —
        // and `permissionPresets.set` needs the live object. Resolve it through
        // the Session API, which activates on demand, instead of failing.
        const session = await ensureSession(ctx, sessionId)
        if (session === undefined) {
          sendJson(res, 404, { error: 'session/not-found', message: `No Session ${sessionId}.` })
          return
        }
        try {
          // `set` applies the preset's sandbox and approval knobs to this
          // Session only; it does not change the default for future Sessions.
          service.set(session, body.value)
        } catch (error) {
          sendJson(res, 400, {
            error: 'permission/unknown-preset',
            message: error instanceof Error ? error.message : String(error),
          })
          return
        }
        sendJson(res, 200, permissionsPayload(ctx, session))
        return
      }
      if (tail === 'model' && req.method === 'POST') {
        const body = await readJsonBody(req)
        if (typeof body.provider !== 'string' || typeof body.model !== 'string') {
          sendJson(res, 400, { error: 'bad-request', message: '`provider` and `model` are required.' })
          return
        }
        const result = await controller.selectModel({
          sessionId,
          provider: body.provider,
          model: body.model,
          ...(typeof body.reasoningEffort === 'string' && body.reasoningEffort !== ''
            ? { reasoningEffort: body.reasoningEffort }
            : {}),
        })
        // Re-read the projection so the caller gets the selection that is
        // actually installed, including an adapter-resolved default effort.
        sendJson(res, 200, { ...result, current: await currentSelection(ctx, sessionId) })
        return
      }
    }
    sendJson(res, 404, { error: 'not-found', message: `No route for ${req.method} ${url.pathname}.` })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (res.headersSent) {
      try {
        res.end()
      } catch {
        // The peer already closed the response; nothing remains to report.
      }
      return
    }
    const code = typeof error?.code === 'string' ? error.code : 'bridge/error'
    sendJson(res, code.endsWith('/not-found') ? 404 : 500, { error: code, message })
  }
}

/**
 * Build the identity payload that answers "which Harness is this".
 * @param ctx - the Host plugin context.
 * @param settings - resolved bridge settings.
 * @returns the info document.
 */
async function infoPayload(ctx, settings) {
  const addresses = lanInterfaces()
  return {
    protocol: PROTOCOL,
    bridge: {
      version: BRIDGE_VERSION,
      port: settings.port,
      discoveryPort: settings.discovery ? settings.discoveryPort : null,
      auth: 'bearer',
      capabilities: CAPABILITIES,
    },
    dsh: {
      version: dshVersion(),
      electron: typeof process.versions.electron === 'string' ? process.versions.electron : null,
      node: process.versions.node,
    },
    profile: {
      name: profileName(),
      directory: process.env.DSH_PROFILE_DIR ?? null,
    },
    host: {
      hostname: hostname(),
      platform: platform(),
      release: release(),
      addresses: addresses.map((entry) => entry.address),
      // Every dialable candidate with its transport label, so the app can offer
      // "same Wi-Fi" and "Tailscale" as separate choices instead of guessing.
      candidates: addresses.map((entry) => ({
        address: entry.address,
        kind: entry.kind,
        interface: entry.name,
        url: `http://${entry.address}:${settings.port}`,
      })),
      preferredAddress: preferredAddress(),
      webUrl: safeWebUrl(ctx),
    },
  }
}

/**
 * Read the Web GUI origin when the Web runtime is mounted.
 * @param ctx - the Host plugin context.
 * @returns the advertised URL, or null.
 */
function safeWebUrl(ctx) {
  const webApp = ctx.get('webApp')
  try {
    return typeof webApp?.getAdvertisedUrl === 'function' ? webApp.getAdvertisedUrl() : null
  } catch {
    return null
  }
}

/**
 * Stream one Session as Server-Sent Events of transcript operators.
 * @param ctx - the Host plugin context.
 * @param req - the incoming request.
 * @param res - the response being written.
 * @param sessionId - the Session to follow.
 * @param url - the parsed request URL.
 */
async function streamSession(ctx, req, res, sessionId, url) {
  const abort = new AbortController()
  req.on('close', () => abort.abort())
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache, no-transform',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
    ...corsHeaders(),
  })
  /**
   * Send one SSE frame and swallow write failures on a closed peer.
   * @param value - JSON-serializable frame body.
   */
  const write = (value) => {
    if (abort.signal.aborted) return
    try {
      res.write(`data: ${JSON.stringify(value)}\n\n`)
    } catch (error) {
      abort.abort()
      console.warn(`dsh-mobile-bridge: stream write failed: ${error?.message ?? error}`)
    }
  }
  res.write(': dsh-mobile-bridge connected\n\n')
  const keepalive = setInterval(() => {
    try {
      res.write(': ping\n\n')
    } catch {
      // A keepalive on a closed socket is expected during teardown.
    }
  }, KEEPALIVE_MS)
  if (typeof keepalive.unref === 'function') keepalive.unref()
  const transcript = new Transcript()
  const activate = url.searchParams.get('activate') !== '0'
  try {
    const frames = ctx.sessionController.follow({
      address: { kind: 'session', sessionId },
      assistantStream: true,
      activate,
      maxMessages: MAX_HISTORY_MESSAGES,
    }, abort.signal)
    for await (const frame of frames) {
      if (abort.signal.aborted) break
      if (frame.type === 'snapshot') {
        for (const record of frame.records ?? []) {
          if (record?.type !== 'event') continue
          transcript.applyEvent(record.event)
        }
        // The snapshot is history, not a status claim: a turn that ended before
        // this connection opened produced its `turn/end` somewhere we never
        // saw. Ask the Session API for the authoritative state instead of
        // inferring it, and keep re-reading while the stream is open.
        const state = await readState(ctx, sessionId, abort.signal)
        write({
          type: 'reset',
          sessionId,
          cursor: frame.cursor ?? null,
          running: state?.running ?? false,
          pendingInput: state?.pendingInput ?? [],
          header: {
            id: frame.header?.id ?? sessionId,
            cwd: frame.header?.cwd ?? null,
            agentPreset: frame.header?.agentPreset ?? null,
            createdAt: frame.header?.createdAt ?? null,
          },
          nodes: transcript.snapshot(),
        })
        if (state !== undefined) startStateWatcher(ctx, sessionId, abort, write, state)
        continue
      }
      if (frame.type === 'event') {
        const event = frame.event
        const status = statusOf(event)
        if (status !== null) write({ type: 'status', ...status })
        for (const operator of transcript.applyEvent(event)) {
          write({ type: 'op', ...operator })
        }
        continue
      }
      if (frame.type === 'assistant-stream') {
        for (const operator of transcript.applyStream(frame.frame)) {
          write({ type: 'op', ...operator })
        }
      }
    }
  } catch (error) {
    if (!abort.signal.aborted) {
      write({ type: 'error', message: error instanceof Error ? error.message : String(error) })
    }
  } finally {
    clearInterval(keepalive)
    try {
      res.end()
    } catch {
      // The peer closed first; the response is already unusable.
    }
  }
}

// ---------------------------------------------------------------------------
// Discovery beacon
// ---------------------------------------------------------------------------

/**
 * Announce the bridge on the LAN so the app can find it without typing an address.
 * @param settings - resolved bridge settings.
 * @returns a disposer that stops the beacon.
 */
function startBeacon(settings) {
  if (!settings.discovery) return () => {}
  const socket = createSocket({ type: 'udp4' })
  /**
   * Broadcast the current identity to every reachable broadcast address.
   */
  const announce = () => {
    const addresses = lanInterfaces()
    const payload = Buffer.from(JSON.stringify({
      protocol: PROTOCOL,
      service: 'dsh-mobile-bridge',
      name: hostname(),
      host: addresses[0]?.address ?? '127.0.0.1',
      addresses: addresses.map((entry) => entry.address),
      port: settings.port,
      dsh: dshVersion(),
      bridge: BRIDGE_VERSION,
      ...(settings.includeTokenInBeacon ? { token: settings.token } : {}),
    }), 'utf8')
    const targets = new Set(['255.255.255.255'])
    for (const entry of lanInterfaces()) {
      const directed = broadcastAddress(entry.address, entry.netmask)
      if (directed !== null) targets.add(directed)
    }
    for (const target of targets) {
      socket.send(payload, settings.discoveryPort, target, (error) => {
        if (error !== undefined && error !== null) {
          // A network without broadcast support rejects the datagram; discovery is optional.
          return
        }
      })
    }
  }
  socket.on('error', (error) => {
    console.warn(`dsh-mobile-bridge: discovery beacon error: ${error?.message ?? error}`)
  })
  socket.bind(() => {
    try {
      socket.setBroadcast(true)
    } catch (error) {
      console.warn(`dsh-mobile-bridge: could not enable broadcast: ${error?.message ?? error}`)
      return
    }
    announce()
  })
  const timer = setInterval(announce, BEACON_INTERVAL_MS)
  if (typeof timer.unref === 'function') timer.unref()
  return () => {
    clearInterval(timer)
    try {
      socket.close()
    } catch {
      // The socket may already be closed by a failed bind.
    }
  }
}

// ---------------------------------------------------------------------------
// Plugin entry
// ---------------------------------------------------------------------------

/**
 * Start the LAN bridge for this Harness process.
 * @param ctx - the Host plugin context, carrying `sessionController`.
 * @param config - the Loader row's config object.
 */
export function startBridge(ctx, config = {}) {
  const settings = resolveSettings(config)
  const server = createServer((req, res) => {
    void handleRequest(ctx, settings, req, res)
  })
  let listening = false
  server.on('error', (error) => {
    if (error?.code === 'EADDRINUSE') {
      ctx.logger.warn(`dsh-mobile-bridge: port ${settings.port} is already in use; the phone bridge is not serving`)
      return
    }
    ctx.logger.warn(`dsh-mobile-bridge: server error: ${error?.message ?? error}`)
  })
  ctx.effect(() => {
    const stopBeacon = startBeacon(settings)
    server.listen(settings.port, settings.host, () => {
      listening = true
      ctx.logger.info(
        `dsh-mobile-bridge: http://${preferredAddress()}:${settings.port} (token in ${settings.path})`,
      )
    })
    return () => {
      stopBeacon()
      if (listening) {
        server.close()
        listening = false
      }
    }
  }, 'dsh-mobile-bridge: LAN server')
}
