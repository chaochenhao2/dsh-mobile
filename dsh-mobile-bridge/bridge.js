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
import { execFileSync } from 'node:child_process'
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { hostname, networkInterfaces, platform, release, homedir, tmpdir } from 'node:os'
import { dirname, join, basename } from 'node:path'
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
  createWriteStream,
  createReadStream,
  unlinkSync,
  readdirSync,
  statSync,
} from 'node:fs'

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
/** Recursion bound for directory selection; guards against symlink loops. */
const MAX_ARCHIVE_DEPTH = 32
/** Largest single upload the bridge accepts, streamed to disk rather than buffered. */
const MAX_UPLOAD_BYTES = 512 * 1024 * 1024
/** Folder under the workspace that holds uploads; hidden on Windows. */
const UPLOAD_DIR = '.dsh'
/** Subfolder inside it, so uploads stay separated from other Harness state. */
const UPLOAD_SUBDIR = 'uploads'
/** A prompt may carry this many attachments in one submission. */
const MAX_ATTACHMENTS = 20
/** Largest image inlined as a prompt part; bigger ones are named by path instead. */
const MAX_INLINE_IMAGE_BYTES = 8 * 1024 * 1024

/** Open transcript streams, so approval interception knows a phone is watching. */
const OPEN_STREAMS = new Set()

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
  'session.upload',
  'session.attach',
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
    // `path` is bookkeeping the caller attaches to settings so later writes know
    // where to go; persisting it would fold that path into the file itself and
    // carry it forward on every read.
    const { path: _ignored, ...persisted } = value
    writeFileSync(path, `${JSON.stringify(persisted, null, 2)}\n`, 'utf8')
  } catch (error) {
    console.warn(`dsh-mobile-bridge: could not write ${path}: ${error?.message ?? error}`)
  }
}

/**
 * Read the authentication mode.
 * @param candidates - values in priority order.
 * @param fallback - mode to use when none is usable.
 * @returns `token` or `open`.
 */
function pickAuth(candidates, fallback) {
  for (const candidate of candidates) {
    if (candidate === 'token' || candidate === 'open') return candidate
  }
  return fallback
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
  // Absent means open: the bridge is a LAN convenience, and pairing with a long
  // token typed on a phone is the main reason it was painful. A deployment that
  // wants the token back sets `auth: "token"` in config.json.
  const auth = pickAuth([config.auth, stored.auth], 'open')
  const persistedToken = typeof stored.token === 'string' && stored.token.length >= 16 ? stored.token : undefined
  const nextToken = persistedToken ?? randomBytes(16).toString('hex')
  const settings = {
    host: pickHost([config.host, stored.host], DEFAULT_HOST),
    port: pickPort([config.port, stored.port], DEFAULT_PORT),
    auth,
    discovery: pickBoolean([config.discovery, stored.discovery], true),
    discoveryPort: pickPort([config.discoveryPort, stored.discoveryPort], DEFAULT_DISCOVERY_PORT),
    includeTokenInBeacon: pickBoolean([config.includeTokenInBeacon, stored.includeTokenInBeacon], false),
    token: nextToken,
    // Identity and pairing survive restarts, so they are carried through rather
    // than rebuilt on every launch.
    ...(typeof stored.deviceId === 'string' && stored.deviceId !== '' ? { deviceId: stored.deviceId } : {}),
    ...(typeof stored.deviceName === 'string' && stored.deviceName !== '' ? { deviceName: stored.deviceName } : {}),
    ...(Array.isArray(stored.pairedDevices) ? { pairedDevices: stored.pairedDevices } : {}),
  }
  const changed = persistedToken === undefined
    || stored.port !== settings.port
    || stored.host !== settings.host
    || stored.auth !== settings.auth
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
function sendJson(res, status, value, settings, origin) {
    // An omitted pair yields no permissive origin, which is the safe default:
    // a response without the header cannot be read cross-origin.
  const body = Buffer.from(`${JSON.stringify(value)}\n`, 'utf8')
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(body.byteLength),
    'cache-control': 'no-store',
    ...corsHeaders(settings, origin),
  })
  res.end(body)
}

/**
 * CORS headers for a request.
 *
 * Only a page served from this machine gets a permissive origin. The native app
 * sends no `Origin` and needs none of this, so an open bridge never advertises
 * itself to a website it did not come from: with `*` any page could read the
 * transcript cross-origin while the tokenless API accepted the call.
 * @param settings - bridge settings; a token-protected bridge is safe with `*`.
 * @param origin - the request's `Origin` header, when present.
 * @returns the header set.
 */
function corsHeaders(settings, origin) {
  // Mirror the admission rule: a token-protected bridge may advertise any origin
  // because the token gates every call, while an open one may only re-affirm a
  // local page. Echoing a foreign origin would promise access that `isAuthorized`
  // then refuses, which is inconsistent and reads as consent to the browser.
  const localOrigin = typeof origin === 'string' && origin !== ''
    && (origin.startsWith('http://127.0.0.1:')
      || origin.startsWith('http://localhost:')
      || origin.startsWith('http://[::1]:'))
  const allowed = settings?.auth === 'token' ? '*' : (localOrigin ? origin : null)
  return {
    ...(allowed === null ? {} : { 'access-control-allow-origin': allowed }),
    ...(allowed === null ? {} : { vary: 'origin' }),
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
 * Whether a request is admissible under this bridge's authentication mode.
 *
 * With a token configured, the caller must present it. Without one, the bridge
 * is open on the LAN, so two cheaper checks take over: a browser-originated
 * request must come from a page on this machine, which stops any website from
 * reaching the API cross-origin, and the caller must not be replaying a form
 * post from elsewhere.
 *
 * A page on this machine is allowed because the Harness UI itself is served from
 * localhost and the settings panel reads through the same rules.
 * @param req - the request being served.
 * @param url - its parsed URL.
 * @param settings - bridge settings.
 * @returns whether the request may proceed.
 */
function isAuthorized(req, url, settings) {
  if (settings.auth === 'token') {
    return tokenMatches(presentedToken(req, url), settings.token)
  }
  const origin = req.headers.origin
  if (typeof origin === 'string' && origin !== '' && origin !== 'null') {
    // `Origin` is the browser's own claim about the calling page and cannot be
    // forged by page script, so it is the check that actually blocks a hostile
    // site. The native app sends no Origin at all.
    const local = origin.startsWith('http://127.0.0.1:')
      || origin.startsWith('http://localhost:')
      || origin.startsWith('http://[::1]:')
    if (!local) return false
  }
  return true
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
// Device identity and pairing
// ---------------------------------------------------------------------------

/**
 * Whether a request came from this machine.
 *
 * The panel endpoint is unauthenticated by necessity — the page displaying the
 * token cannot already hold it — so it must be unreachable from the network.
 * @param req - the incoming request.
 * @returns true only for a loopback peer address.
 */
function isLoopbackRequest(req) {
  const address = req.socket?.remoteAddress ?? ''
  // IPv4 loopback, IPv6 loopback, and the IPv4-mapped form Node reports when the
  // listener is bound to a dual-stack socket.
  return address === '127.0.0.1'
    || address === '::1'
    || address === '::ffff:127.0.0.1'
}

/**
 * Settings the in-app panel renders.
 *
 * Reports the pairing token, the dialable addresses, and the paired devices, all
 * of which the person needs in order to pair a phone. Callers must be loopback;
 * `handleRequest` enforces that.
 * @param ctx - the Host plugin context.
 * @param settings - bridge settings.
 * @returns the panel state.
 */
async function panelState(ctx, settings) {
  const payload = await infoPayload(ctx, settings)
  return {
    device: deviceIdentity(settings),
    token: settings.token,
    port: settings.port,
    discovery: settings.discovery
      ? { enabled: true, port: settings.discoveryPort }
      : { enabled: false, port: null },
    bridge: payload.bridge,
    dsh: payload.dsh,
    host: payload.host,
    pairedDevices: pairedDevices(settings),
    configPath: settings.path,
  }
}

/**
 * Read this machine's stable device identity.
 *
 * The id is generated once and persisted next to the bridge settings, so a phone
 * that paired with this computer keeps recognizing it across restarts and DHCP
 * changes. It is not a secret and is safe to show in a device list.
 * @param settings - bridge settings object.
 * @returns the identity record.
 */
function deviceIdentity(settings) {
  if (settings.deviceId === undefined || settings.deviceId === '') {
    // Derived rather than random only when a settings file already exists; a
    // random id keeps two installs from ever colliding.
    settings.deviceId = randomUUID()
    try {
      writeSettingsFile(settings.path, settings)
    } catch (error) {
      // A read-only settings file still yields a usable in-process identity.
    }
  }
  return {
    deviceId: settings.deviceId,
    name: settings.deviceName ?? hostname(),
    platform: platform(),
  }
}

/**
 * Read the devices that have paired with this computer.
 *
 * Kept beside the settings rather than in memory: a phone that paired last week
 * should still appear in the list after a restart, with its last-seen time
 * explaining why it shows as offline.
 * @param settings - bridge settings object.
 * @returns the paired device records.
 */
function pairedDevices(settings) {
  return Array.isArray(settings.pairedDevices) ? settings.pairedDevices : []
}

/**
 * Persist one paired device, replacing any record with the same id.
 * @param settings - bridge settings object.
 * @param record - the device to remember.
 * @returns the updated list.
 */
function rememberDevice(settings, record) {
  const existing = pairedDevices(settings).filter((entry) => entry.deviceId !== record.deviceId)
  const merged = [...existing, record]
  settings.pairedDevices = merged
  try {
    writeSettingsFile(settings.path, settings)
  } catch (error) {
    // The pairing still works for this session even if it cannot be persisted.
  }
  return merged
}

/**
 * Resolve the directory a Session's files are browsed from.
 *
 * A live Session answers from the working-directory service. A cold one is read
 * from its recorded `cwd` through the Session list, which is a warm read and
 * avoids activating an Agent merely to browse files.
 * @param ctx - the Host plugin context.
 * @param controller - the Host Session API.
 * @param sessionId - the Session whose root is wanted.
 * @param signal - cancellation for the list read.
 * @returns the absolute root directory, or null when none can be determined.
 */
async function sessionRoot(ctx, controller, sessionId, signal) {
  const session = liveSession(ctx, sessionId)
  if (session !== undefined) {
    const working = ctx.get('workingDirectory')
    if (working !== undefined) {
      try {
        const directory = working.get(session)
        if (typeof directory === 'string' && directory !== '') return directory
      } catch (error) {
        ctx.logger.warn(`dsh-mobile-bridge: working directory read failed: ${error?.message ?? error}`)
      }
    }
  }
  try {
    const list = await controller.list({}, signal)
    const row = (list.items ?? []).find((item) => item.sessionId === sessionId)
    if (typeof row?.cwd === 'string' && row.cwd !== '') return row.cwd
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: Session root lookup failed: ${error?.message ?? error}`)
  }
  const registry = ctx.get('workspaceRegistry')
  if (registry !== undefined) {
    try {
      const first = registry.list()[0]
      if (typeof first?.path === 'string') return first.path
    } catch {
      // No registry opinion; fall through to the process directory.
    }
  }
  return null
}

/**
 * Read the Session's file scope, or null when the filesystem is unavailable.
 * @param ctx - the Host plugin context.
 * @param controller - the Host Session API.
 * @param sessionId - the Session being browsed.
 * @param signal - cancellation for the root lookup.
 * @returns the scope the file service expects.
 */
async function fileScope(ctx, controller, sessionId, signal) {
  const root = await sessionRoot(ctx, controller, sessionId, signal)
  if (root === null) return null
  return { sessionId, workspaceRoot: root }
}

/**
 * Stream a ZIP of the selected files and folders.
 *
 * Binary rather than JSON: a base64 body would inflate the transfer by a third
 * and force the phone to decode it before it can write the file.
 * @param ctx - the Host plugin context.
 * @param controller - the Host Session API.
 * @param res - the response being written.
 * @param sessionId - the Session whose files are read.
 * @param selection - absolute paths chosen on the phone.
 */
async function sendArchive(ctx, settings, controller, req, res, sessionId, selection) {
  const service = ctx.get('workspaceFiles')
  const signal = new AbortController().signal
  const scope = await fileScope(ctx, controller, sessionId, signal)
  if (service === undefined || scope === null) {
    sendJson(res, 404, { error: 'unsupported', message: 'This Harness exposes no workspace files.' })
    return
  }

  // One file is sent as itself, never wrapped in a ZIP: the person asked for
  // that file, and an archive would both rename it and buffer it in memory.
  if (selection.length === 1) {
    const direct = await sendSingleFile(ctx, settings, service, scope, req, res, selection[0], signal)
    if (direct) return
    // Not a regular file after all (a folder, or a vanished path): fall through
    // to the archive path so the selection still produces something.
  }

  const collected = await collectToDisk(ctx, service, scope, selection, signal)
  if (collected.entries === 0) {
    sendJson(res, collected.skipped.length > 0 ? 422 : 404, {
      error: 'archive/empty',
      message: '选中的内容无法读取。',
      skipped: collected.skipped.slice(0, 20),
    })
    return
  }
  // Name the archive after the single chosen folder, or after the workspace when
  // several items went in; naming a bundle after one of its members would
  // mislead the person about what they downloaded.
  const singleTop = selection.length === 1 ? baseName(selection[0]) : null
  const stem = singleTop ?? baseName(scope.workspaceRoot)
  const fileName = `${stem}-${collected.entries}项.zip`
  const incomplete = collected.skipped.length
  res.writeHead(200, {
    'content-type': 'application/zip',
    'content-length': String(collected.bytes),
    'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(fileName)}`,
    'cache-control': 'no-store',
    ...(incomplete === 0 ? {} : { 'x-skipped-entries': String(incomplete) }),
    ...corsHeaders(settings, req.headers.origin),
    'access-control-expose-headers': 'x-skipped-entries, content-disposition',
  })
  // The archive lives in a temporary file, so it reaches the phone by stream
  // rather than as one buffer: a large folder never has to fit in memory.
  const stream = createReadStream(collected.path)
  stream.on('error', () => {
    res.destroy()
  })
  res.on('close', () => {
    stream.destroy()
    collected.cleanup()
  })
  stream.pipe(res)
}

/**
 * Send one regular file as itself.
 *
 * The bytes are streamed straight from disk: no ZIP wrapper, no size limit, and
 * nothing loaded into the host process.
 * @param ctx - the Host plugin context.
 * @param service - the workspace files service.
 * @param scope - the Session's file scope.
 * @param res - the response being written.
 * @param absolute - the file to send.
 * @param signal - cancellation for the stat.
 * @returns whether the file was sent; false when it is not a regular file.
 */
async function sendSingleFile(ctx, settings, service, scope, req, res, absolute, signal) {
  let stat
  try {
    stat = await service.stat(scope, absolute, signal)
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: stat failed for ${absolute}: ${error?.message ?? error}`)
    return false
  }
  // A directory reports no byte count through this service; anything else is a
  // regular file as far as the phone is concerned.
  if (typeof stat.bytes !== 'number') return false
  const name = basename(absolute)
  res.writeHead(200, {
    'content-type': contentTypeFor(name),
    'content-length': String(stat.bytes),
    'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
    'cache-control': 'no-store',
    ...corsHeaders(settings, req.headers.origin),
    'access-control-expose-headers': 'content-disposition',
  })
  const stream = createReadStream(absolute)
  stream.on('error', (error) => {
    ctx.logger.warn(`dsh-mobile-bridge: stream failed for ${absolute}: ${error?.message ?? error}`)
    res.destroy()
  })
  res.on('close', () => stream.destroy())
  stream.pipe(res)
  return true
}

/**
 * Build a ZIP of the selection in a temporary file.
 *
 * Entries are appended one at a time and each member's local header is written
 * before its bytes, so only one file is in memory at any moment. The central
 * directory is collected as small descriptors and appended last, which keeps the
 * whole archive out of the process even for a multi-gigabyte folder.
 * @param ctx - the Host plugin context.
 * @param service - the workspace files service.
 * @param scope - the Session's file scope.
 * @param selection - absolute paths chosen on the phone.
 * @param signal - cancellation for the reads.
 * @returns the temporary archive path, its byte size, the entry count and a cleanup.
 */
async function collectToDisk(ctx, service, scope, selection, signal) {
  const directory = join(tmpdir(), 'dsh-mobile-bridge')
  try {
    mkdirSync(directory, { recursive: true })
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: could not create temp directory: ${error?.message ?? error}`)
  }
  const archivePath = join(directory, `archive-${randomUUID()}.zip`)
  const output = createWriteStream(archivePath)
  const descriptors = []
  const skipped = []
  const seenDirectories = new Set()
  let offset = 0
  let entryCount = 0
  const now = new Date()
  const dosTime = ((now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1)) & 0xffff
  const dosDate = (((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate()) & 0xffff

  /**
   * Append bytes and advance the running offset.
   * @param buffer - the bytes to write.
   */
  const write = (buffer) => new Promise((resolve) => {
    offset += buffer.length
    if (output.write(buffer)) resolve()
    else output.once('drain', resolve)
  })

  /**
   * Add one path, descending into directories.
   * @param absolute - absolute path to include.
   * @param name - name recorded inside the archive.
   * @param depth - recursion depth, bounded to stop link loops.
   */
  const add = async (absolute, name, depth) => {
    if (signal.aborted) return
    let listing = null
    try {
      listing = await service.list(scope, absolute, signal)
    } catch {
      // Not a directory: fall through to the file read.
    }
    if (listing !== null) {
      if (seenDirectories.has(absolute) || depth > MAX_ARCHIVE_DEPTH) return
      seenDirectories.add(absolute)
      for (const child of listing.entries ?? []) {
        await add(
          joinPath(absolutize(scope.workspaceRoot, absolute, listing.path), child.name),
          `${name}/${child.name}`,
          depth + 1,
        )
      }
      return
    }
    try {
      const file = await service.readBytes(scope, absolute, {}, signal)
      const data = Buffer.from(file.data)
      const nameBytes = Buffer.from(name, 'utf8')
      const checksum = crc32(data)
      const localOffset = offset
      const local = Buffer.alloc(30)
      local.writeUInt32LE(0x04034b50, 0)
      local.writeUInt16LE(20, 4)
      local.writeUInt16LE(0x0800, 6)
      local.writeUInt16LE(0, 8)
      local.writeUInt16LE(dosTime, 10)
      local.writeUInt16LE(dosDate, 12)
      local.writeUInt32LE(checksum, 14)
      local.writeUInt32LE(data.length, 18)
      local.writeUInt32LE(data.length, 22)
      local.writeUInt16LE(nameBytes.length, 26)
      local.writeUInt16LE(0, 28)
      await write(local)
      await write(nameBytes)
      await write(data)
      descriptors.push({ name: nameBytes, checksum, bytes: data.length, offset: localOffset })
      entryCount += 1
    } catch (error) {
      skipped.push(`${absolute}: ${error?.message ?? error}`)
    }
  }

  for (const selected of selection) {
    await add(selected, basename(selected), 0)
  }

  // Central directory, written after every member so the offsets are final.
  const centralStart = offset
  for (const descriptor of descriptors) {
    const central = Buffer.alloc(46)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE(20, 4)
    central.writeUInt16LE(20, 6)
    central.writeUInt16LE(0x0800, 8)
    central.writeUInt16LE(0, 10)
    central.writeUInt16LE(dosTime, 12)
    central.writeUInt16LE(dosDate, 14)
    central.writeUInt32LE(descriptor.checksum, 16)
    central.writeUInt32LE(descriptor.bytes, 20)
    central.writeUInt32LE(descriptor.bytes, 24)
    central.writeUInt16LE(descriptor.name.length, 28)
    central.writeUInt16LE(0, 30)
    central.writeUInt16LE(0, 32)
    central.writeUInt16LE(0, 34)
    central.writeUInt16LE(0, 36)
    central.writeUInt32LE(0, 38)
    central.writeUInt32LE(descriptor.offset, 42)
    await write(central)
    await write(descriptor.name)
  }
  const centralSize = offset - centralStart
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(0, 4)
  end.writeUInt16LE(0, 6)
  end.writeUInt16LE(entryCount, 8)
  end.writeUInt16LE(entryCount, 10)
  end.writeUInt32LE(centralSize, 12)
  end.writeUInt32LE(centralStart, 16)
  end.writeUInt16LE(0, 20)
  await write(end)

  await new Promise((resolve) => output.end(resolve))
  return {
    path: archivePath,
    bytes: offset,
    entries: entryCount,
    skipped,
    cleanup: () => {
      try {
        unlinkSync(archivePath)
      } catch {
        // The file is already gone; nothing remains to reclaim.
      }
    },
  }
}

/**
 * Guess a content type from a file name.
 *
 * Sent so the phone writes the extension it expects; an unknown type falls back
 * to binary, which every client handles.
 * @param name - the file name.
 * @returns an HTTP content type.
 */
function contentTypeFor(name) {
  const extension = name.toLowerCase().split('.').pop() ?? ''
  const known = {
    txt: 'text/plain; charset=utf-8',
    md: 'text/markdown; charset=utf-8',
    json: 'application/json',
    xml: 'application/xml',
    yml: 'text/yaml; charset=utf-8',
    yaml: 'text/yaml; charset=utf-8',
    csv: 'text/csv; charset=utf-8',
    html: 'text/html; charset=utf-8',
    css: 'text/css; charset=utf-8',
    js: 'text/javascript; charset=utf-8',
    ts: 'text/plain; charset=utf-8',
    png: 'image/png',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    gif: 'image/gif',
    webp: 'image/webp',
    svg: 'image/svg+xml',
    pdf: 'application/pdf',
    zip: 'application/zip',
    ico: 'image/x-icon',
  }
  return known[extension] ?? 'application/octet-stream'
}

/**
 * List one directory level for the phone.
 *
 * `path` is optional; without it the Session's own root is listed. The parent is
 * reported so the app can render a `..` row without re-deriving paths, and a
 * selection at the filesystem root simply has no parent.
 * @param ctx - the Host plugin context.
 * @param controller - the Host Session API.
 * @param sessionId - the Session being browsed.
 * @param requested - absolute or workspace-relative directory path.
 * @param signal - cancellation for the read.
 * @returns the listing with its parent, or null when files are unavailable.
 */
async function listFiles(ctx, controller, sessionId, requested, signal) {
  const service = ctx.get('workspaceFiles')
  const scope = await fileScope(ctx, controller, sessionId, signal)
  if (service === undefined || scope === null) return null
  const target = typeof requested === 'string' && requested !== '' ? requested : scope.workspaceRoot
  const listing = await service.list(scope, target, signal)
  // The backend may answer with the path verbatim (relative when the request
  // was relative). Resolve it against the workspace root so every entry path the
  // phone receives is absolute and directly usable by the archive request.
  const absolute = absolutize(scope.workspaceRoot, target, listing.path)
  const parent = parentOf(absolute)
  return {
    root: scope.workspaceRoot,
    path: absolute,
    parent,
    truncated: listing.truncated === true,
    entries: (listing.entries ?? []).map((entry) => ({
      name: entry.name,
      type: entry.type,
      size: typeof entry.size === 'number' ? entry.size : null,
      path: joinPath(absolute, entry.name),
    })),
  }
}

/**
 * Produce an absolute directory path from whatever the backend echoed back.
 * @param root - the Session's workspace root.
 * @param requested - the path that was asked for.
 * @param reported - the path the backend returned, possibly relative or empty.
 * @returns an absolute path.
 */
function absolutize(root, requested, reported) {
  const candidate = typeof reported === 'string' && reported !== '' ? reported : requested
  if (typeof candidate !== 'string' || candidate === '') return root
  if (isAbsolutePath(candidate)) return candidate
  return joinPath(root, candidate)
}

/**
 * Whether a path already names a filesystem location.
 * @param path - the path to inspect.
 * @returns true for a drive-letter, UNC, or POSIX absolute path.
 */
function isAbsolutePath(path) {
  if (path.startsWith('/')) return true
  if (path.startsWith('\\\\')) return true
  return /^[A-Za-z]:[\\/]/.test(path)
}

/**
 * Join one path segment the way the host filesystem expects.
 * @param parent - absolute parent directory.
 * @param name - child name.
 * @returns the joined path using the host separator.
 */
function joinPath(parent, name) {
  if (parent.endsWith('/') || parent.endsWith('\\')) return `${parent}${name}`
  return `${parent}${platformIsWindows() ? '\\' : '/'}${name}`
}

/**
 * Report the parent directory, or null at the filesystem root.
 * @param path - absolute path.
 * @returns the parent path.
 */
function parentOf(path) {
  const trimmed = path.replace(/[\\/]+$/, '')
  const separatorIndex = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'))
  if (separatorIndex < 0) return null
  // Keep "C:\" intact rather than collapsing it to "C:".
  if (separatorIndex === 2 && /^[A-Za-z]:/.test(trimmed)) return trimmed.slice(0, 3)
  if (separatorIndex === 0) return '/'
  return trimmed.slice(0, separatorIndex)
}

/**
 * Whether the host uses backslash separators.
 * @returns true on Windows.
 */
function platformIsWindows() {
  return process.platform === 'win32'
}

// ---------------------------------------------------------------------------
// Zip archive
// ---------------------------------------------------------------------------

/** CRC-32 lookup table, built once. */
const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let index = 0; index < 256; index += 1) {
    let value = index
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) !== 0 ? (0xedb88320 ^ (value >>> 1)) >>> 0 : value >>> 1
    }
    table[index] = value >>> 0
  }
  return table
})()

/**
 * Compute the CRC-32 of a buffer, as the ZIP format requires.
 * @param buffer - the bytes to checksum.
 * @returns the unsigned checksum.
 */
function crc32(buffer) {
  let crc = 0xffffffff
  for (let index = 0; index < buffer.length; index += 1) {
    crc = (CRC_TABLE[(crc ^ buffer[index]) & 0xff] ^ (crc >>> 8)) >>> 0
  }
  return (crc ^ 0xffffffff) >>> 0
}


/**
 * Take the last path segment, treating both separators as separators.
 * @param path - absolute path.
 * @returns the final segment.
 */
function baseName(path) {
  const trimmed = path.replace(/[\\/]+$/, '')
  const separatorIndex = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'))
  return separatorIndex < 0 ? trimmed : trimmed.slice(separatorIndex + 1)
}

// ---------------------------------------------------------------------------
// User questions
// ---------------------------------------------------------------------------

/**
 * Pending `ask_user_question` prompts keyed by an id the phone answers.
 *
 * The harness asks through a waterfall and waits on the returned promise, so the
 * resolver is held here until the phone answers, the request is cancelled, or
 * the wait expires.
 */
const pendingQuestions = new Map()
/** How long a phone has to answer before the request is released. */
const QUESTION_TIMEOUT_MS = 600_000

/**
 * Publish a question set to waiting phones and wait for an answer.
 *
 * Returning `next()` would let the desktop decide; with a phone watching, the
 * phone decides. Unlike approvals, a question has no safe default: releasing it
 * on timeout lets the desktop answerer take over rather than inventing a reply.
 * @param ctx - the Host plugin context.
 * @param request - the pending question set.
 * @param next - the desktop's own answerers.
 * @returns the answer the harness applies.
 */
function awaitPhoneAnswer(ctx, request, next) {
  if (activeStreamCount() === 0) return next()

  const id = randomUUID()
  return new Promise((resolve, reject) => {
    let settled = false
    const settle = (answer) => {
      if (settled) return
      settled = true
      const entry = pendingQuestions.get(id)
      if (entry !== undefined) {
        pendingQuestions.delete(id)
        clearTimeout(entry.timer)
      }
      resolve(answer)
    }
    // Releasing to the desktop is the honest outcome when nobody answers: the
    // harness keeps its own prompt rather than receiving an invented choice.
    const release = () => {
      if (settled) return
      settled = true
      const entry = pendingQuestions.get(id)
      if (entry !== undefined) {
        pendingQuestions.delete(id)
        clearTimeout(entry.timer)
      }
      next().then(resolve, reject)
    }
    const timer = setTimeout(release, QUESTION_TIMEOUT_MS)
    pendingQuestions.set(id, {
      id,
      settle,
      timer,
      createdAt: Date.now(),
      sessionId: request.agent?.id ?? null,
      callId: request.wait?.callId ?? null,
      questions: normalizeQuestions(request.questions),
    })
    if (typeof request.signal?.addEventListener === 'function') {
      request.signal.addEventListener('abort', release, { once: true })
    }
    ctx.logger.info(`dsh-mobile-bridge: ${request.questions?.length ?? 0} question(s) waiting on the phone`)
  })
}

/**
 * Reduce a question set to what the phone renders.
 *
 * The last option is always the free-text one: the official UI appends it the
 * same way, so a set that already lists a custom-looking option still ends with
 * exactly one input row.
 * @param questions - the harness question items.
 * @returns the wire questions.
 */
function normalizeQuestions(questions) {
  return (questions ?? []).map((item) => ({
    id: String(item.id ?? ''),
    question: typeof item.question === 'string' ? item.question : '',
    detail: typeof item.detail === 'string' ? item.detail : null,
    header: typeof item.header === 'string' ? item.header : null,
    multiSelect: item.multiSelect === true,
    options: (item.options ?? []).map((option) => ({
      label: String(option.label ?? ''),
      description: typeof option.description === 'string' ? option.description : null,
    })),
  }))
}

/**
 * Snapshot the pending question sets.
 * @returns one entry per unanswered request.
 */
function questionList() {
  return [...pendingQuestions.values()].map((entry) => ({
    id: entry.id,
    createdAt: entry.createdAt,
    expiresAt: entry.createdAt + QUESTION_TIMEOUT_MS,
    sessionId: entry.sessionId,
    callId: entry.callId,
    questions: entry.questions,
  }))
}

/**
 * Answer one pending question set.
 *
 * Answers are matched by question id, and an entry with neither a selection nor
 * custom text is dropped: the harness treats a missing id as unanswered, while
 * an empty answer would look like the person chose nothing.
 * @param id - the request to settle.
 * @param answers - the phone's answers, keyed by question id.
 * @returns whether a request was waiting.
 */
function settleQuestion(id, answers) {
  const entry = pendingQuestions.get(id)
  if (entry === undefined) return false
  const known = new Set(entry.questions.map((question) => question.id))
  const shaped = []
  for (const answer of Array.isArray(answers) ? answers : []) {
    const questionId = typeof answer?.id === 'string' ? answer.id : ''
    if (!known.has(questionId)) continue
    const selected = Array.isArray(answer.selected)
      ? answer.selected.filter((value) => typeof value === 'string' && value !== '')
      : []
    const custom = typeof answer.custom === 'string' && answer.custom.trim() !== ''
      ? answer.custom.trim()
      : undefined
    if (selected.length === 0 && custom === undefined) continue
    shaped.push({
      id: questionId,
      selected,
      ...(custom === undefined ? {} : { custom }),
    })
  }
  if (shaped.length === 0) return false
  // The harness expects a complete answer set; a question the person skipped is
  // reported with an empty selection so the model knows it was declined.
  for (const question of entry.questions) {
    if (shaped.some((answer) => answer.id === question.id)) continue
    shaped.push({ id: question.id, selected: [] })
  }
  entry.settle({ answers: shaped })
  return true
}

// ---------------------------------------------------------------------------
// Approval prompts
// ---------------------------------------------------------------------------

/**
 * Pending approval requests, keyed by an id the phone uses to answer.
 *
 * The harness asks for a decision through a waterfall and waits for the
 * promise, so the bridge holds the resolver here and hands it to whoever answers
 * from the phone. An entry is removed on answer, timeout, or cancellation.
 */
/**
 * Pending approval requests, keyed by an id the phone uses to answer.
 *
 * The harness asks for a decision through a waterfall and waits for the
 * promise, so the bridge holds the resolver here and hands it to whoever answers
 * from the phone. An entry is removed on answer, timeout, or cancellation.
 */
const pendingApprovals = new Map()
/** How long a phone has to answer before the request fails closed. */
const APPROVAL_TIMEOUT_MS = 120_000

/**
 * How many transcript streams are open right now.
 *
 * Approval prompts are only intercepted while a phone is actually watching: with
 * no stream open the desktop's own answerers keep full control.
 * @returns the number of open streams.
 */
function activeStreamCount() {
  return OPEN_STREAMS.size
}

/**
 * Publish an approval prompt to waiting phones and wait for a decision.
 *
 * Returning `next()` would let the desktop answer; the bridge answers itself so
 * a phone decides either way. A timeout resolves `cancelled`, which the harness
 * treats as "no grant", so a lost phone never silently permits an operation.
 * @param ctx - the Host plugin context.
 * @param request - the pending decision from the harness.
 * @param next - the desktop's own answerers, used when the phone cannot answer.
 * @returns the outcome the harness applies.
 */
function awaitPhoneApproval(ctx, request, next) {
  // No phone connected is not an error: fall back to whatever answers the
  // desktop already composed, so behaviour is unchanged without the app.
  if (activeStreamCount() === 0) return next()

  const id = randomUUID()
  return new Promise((resolve) => {
    const settle = (outcome) => {
      const entry = pendingApprovals.get(id)
      if (entry === undefined) return
      pendingApprovals.delete(id)
      clearTimeout(entry.timer)
      ctx.logger.info(`dsh-mobile-bridge: approval ${id} -> ${outcome}`)
      resolve(outcome)
    }
    const timer = setTimeout(() => settle('cancelled'), APPROVAL_TIMEOUT_MS)
    pendingApprovals.set(id, {
      id,
      settle,
      timer,
      toolName: request.toolName,
      reason: typeof request.reason === 'string' ? request.reason : null,
      displayReason: request.displayReason ?? null,
      callId: request.callId ?? null,
      sessionId: request.agent?.id ?? null,
      createdAt: Date.now(),
    })
    if (typeof request.signal?.addEventListener === 'function') {
      request.signal.addEventListener('abort', () => settle('cancelled'), { once: true })
    }
    ctx.logger.info(`dsh-mobile-bridge: approval ${id} requested for ${request.toolName}`)
  })
}

/**
 * Snapshot the pending approvals for the phone.
 * @returns one entry per unanswered prompt.
 */
function approvalList() {
  return [...pendingApprovals.values()].map((entry) => ({
    id: entry.id,
    toolName: entry.toolName,
    reason: entry.reason,
    displayReason: entry.displayReason,
    callId: entry.callId,
    sessionId: entry.sessionId,
    createdAt: entry.createdAt,
    expiresAt: entry.createdAt + APPROVAL_TIMEOUT_MS,
  }))
}

/**
 * Answer one pending approval.
 * @param id - the prompt to settle.
 * @param allow - whether to grant it once.
 * @returns whether an entry was waiting.
 */
function settleApproval(id, allow) {
  const entry = pendingApprovals.get(id)
  if (entry === undefined) return false
  entry.settle(allow ? 'allowed-once' : 'rejected')
  return true
}

// ---------------------------------------------------------------------------
// Session uploads
// ---------------------------------------------------------------------------

/**
 * Resolve the folder that holds one Session's uploads.
 *
 * Uploads live under `<workspace>/.dsh/uploads` so they sit beside the rest of
 * the Harness state and stay out of the way of the project itself. The `.dsh`
 * directory is marked hidden on Windows, where a leading dot carries no such
 * meaning.
 * @param ctx - the Host plugin context.
 * @param controller - the Host Session API.
 * @param sessionId - the Session receiving the uploads.
 * @param signal - cancellation for the root lookup.
 * @returns the absolute upload directory.
 */
async function uploadDirectory(ctx, controller, sessionId, signal) {
  const root = await sessionRoot(ctx, controller, sessionId, signal)
  const base = root ?? process.cwd()
  const hidden = join(base, UPLOAD_DIR)
  const directory = join(hidden, UPLOAD_SUBDIR)
  mkdirSync(directory, { recursive: true })
  if (platform() === 'win32') markHidden(hidden)
  return directory
}

/**
 * Mark a directory hidden on Windows.
 *
 * A leading dot is a Unix convention that Explorer ignores, and the person asked
 * for a hidden folder, so the attribute has to be set explicitly.
 * @param path - the directory to hide.
 */
function markHidden(path) {
  try {
    execFileSync('attrib', ['+h', path], { stdio: 'ignore', windowsHide: true })
  } catch {
    // Hiding is cosmetic; a failure must not break the upload that created it.
  }
}

/**
 * Reduce a client-supplied name to one safe leaf.
 *
 * The name arrives from a phone and may carry separators or traversal, so only
 * the final segment survives and control characters are dropped.
 * @param name - the suggested file name.
 * @param fallback - name to use when nothing usable remains.
 * @returns a safe leaf name.
 */
function safeFileName(name, fallback) {
  const raw = typeof name === 'string' && name.trim() !== '' ? name.trim() : fallback
  const leaf = basename(raw.replace(/\\/g, '/'))
  const cleaned = leaf.replace(/[\u0000-\u001f<>:"|?*]/g, '_').trim()
  return cleaned === '' || cleaned === '.' || cleaned === '..' ? fallback : cleaned
}

/**
 * Receive one uploaded file and write it into the Session's upload folder.
 *
 * The body is the raw file, streamed straight to disk: base64 in JSON would
 * inflate a video by a third and force the whole thing through memory, and the
 * phone has no reason to encode what it already has as bytes.
 * @param ctx - the Host plugin context.
 * @param controller - the Host Session API.
 * @param req - the request carrying the bytes.
 * @param res - the response to write.
 * @param sessionId - the Session receiving the upload.
 * @param url - the parsed request URL, holding `name` and `mediaType`.
 */
async function receiveUpload(ctx, settings, controller, req, res, sessionId, url) {
  const signal = new AbortController().signal
  const directory = await uploadDirectory(ctx, controller, sessionId, signal)
  const suggested = url.searchParams.get('name') ?? ''
  const mediaType = url.searchParams.get('mediaType') ?? 'application/octet-stream'
  const name = safeFileName(suggested, `upload-${Date.now()}`)
  // A timestamp prefix keeps two files with the same name from colliding while
  // still leaving the original name readable.
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, '').slice(0, 14)
  const target = join(directory, `${stamp}-${name}`)

  const output = createWriteStream(target)
  let written = 0
  let aborted = false
  req.on('aborted', () => {
    aborted = true
    output.destroy()
  })
  try {
    for await (const chunk of req) {
      written += chunk.length
      if (written > MAX_UPLOAD_BYTES) {
        aborted = true
        output.destroy()
        try {
          unlinkSync(target)
        } catch {
          // A missing partial file is the desired state anyway.
        }
        sendJson(res, 413, {
          error: 'upload/too-large',
          message: `Upload exceeds ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB.`,
        }, settings, req.headers.origin)
        return
      }
      if (!output.write(chunk)) {
        await new Promise((resolve) => output.once('drain', resolve))
      }
    }
    await new Promise((resolve, reject) => {
      output.end(resolve)
      output.on('error', reject)
    })
  } catch (error) {
    output.destroy()
    try {
      unlinkSync(target)
    } catch {
      // Nothing to clean up.
    }
    if (!res.headersSent) {
      sendJson(res, 500, {
        error: 'upload/failed',
        message: error?.message ?? String(error),
      }, settings, req.headers.origin)
    }
    return
  }
  if (aborted) return

  sendJson(res, 200, {
    name,
    path: target,
    bytes: written,
    mediaType,
    kind: mediaKind(mediaType, name),
  }, settings, req.headers.origin)
}

/**
 * Classify a file for the prompt builder.
 * @param mediaType - declared MIME type.
 * @param name - file name, used when the type is generic.
 * @returns `image`, `video`, or `file`.
 */
function mediaKind(mediaType, name) {
  if (typeof mediaType === 'string' && mediaType.startsWith('image/')) return 'image'
  if (typeof mediaType === 'string' && mediaType.startsWith('video/')) return 'video'
  const extension = String(name).toLowerCase().split('.').pop() ?? ''
  if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'heif'].includes(extension)) return 'image'
  if (['mp4', 'mov', 'm4v', 'webm', 'avi', 'mkv'].includes(extension)) return 'video'
  return 'file'
}

/**
 * List the files already uploaded for one Session.
 * @param ctx - the Host plugin context.
 * @param controller - the Host Session API.
 * @param res - the response to write.
 * @param sessionId - the Session whose uploads are listed.
 * @param origin - the calling page's origin, for the CORS header.
 */
async function listUploads(ctx, settings, controller, res, sessionId, origin) {
  const signal = new AbortController().signal
  const directory = await uploadDirectory(ctx, controller, sessionId, signal)
  let entries = []
  try {
    entries = readdirSync(directory, { withFileTypes: true })
      .filter((entry) => entry.isFile())
      .map((entry) => {
        const path = join(directory, entry.name)
        let bytes = 0
        try {
          bytes = statSync(path).size
        } catch {
          // A file removed mid-listing simply reports no size.
        }
        return { name: entry.name, path, bytes, kind: mediaKind('', entry.name) }
      })
  } catch {
    // An unreadable directory reads as empty rather than failing the request.
  }
  entries.sort((left, right) => right.name.localeCompare(left.name))
  sendJson(res, 200, { directory, files: entries }, settings, origin)
}

/**
 * Turn chosen attachments into prompt content parts.
 *
 * Images become `image` parts so the model receives them directly. Everything
 * else — video included, which no current model accepts inline — is named in the
 * text with its absolute path, so the model can open it with its own tools
 * instead of the bridge pretending it was attached as pixels.
 * @param attachments - the client's `{ path, kind }` list.
 * @param text - the prompt text to extend.
 * @returns the content parts, in order.
 */
function buildPromptContent(attachments, text) {
  const parts = []
  const described = []
  for (const attachment of attachments.slice(0, MAX_ATTACHMENTS)) {
    const path = typeof attachment?.path === 'string' ? attachment.path : ''
    if (path === '') continue
    const name = basename(path)
    const kind = typeof attachment?.kind === 'string' ? attachment.kind : mediaKind('', name)
    if (kind === 'image') {
      const read = readImagePart(path)
      if (read !== null) {
        parts.push(read)
        continue
      }
    }
    described.push(`- ${name}: ${path}`)
  }
  if (described.length > 0) {
    const header = text.trim() === '' ? '' : `${text}\n\n`
    parts.unshift({
      type: 'text',
      text: `${header}以下是本次附带的文件，请按需用工具读取：\n${described.join('\n')}`,
    })
  } else if (text.trim() !== '') {
    parts.unshift({ type: 'text', text })
  }
  return parts
}

/**
 * Read one image file as a prompt image part.
 *
 * A file over the inline limit is skipped so the request still goes through: the
 * caller then describes it by path like any other file.
 * @param path - absolute image path.
 * @returns the image part, or null when it cannot be inlined.
 */
function readImagePart(path) {
  const extension = path.toLowerCase().split('.').pop() ?? ''
  const mediaType = {
    png: 'image/png',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    gif: 'image/gif',
    webp: 'image/webp',
  }[extension]
  if (mediaType === undefined) return null
  let bytes
  try {
    const stat = statSync(path)
    if (stat.size > MAX_INLINE_IMAGE_BYTES) return null
    bytes = readFileSync(path)
  } catch {
    return null
  }
  return { type: 'image', mediaType, data: bytes.toString('base64'), name: basename(path) }
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
 * Read the set of Session ids that are archived in any workspace.
 *
 * The Session summary carries no archive flag: archival is recorded by the
 * workspace that owns the Session, so membership in a workspace's `sessionIds`
 * is what marks it archived.
 * @param ctx - the Host plugin context.
 * @returns the archived ids, or an empty set when no registry is composed.
 */
function archivedSessionIds(ctx) {
  const registry = ctx.get('workspaceRegistry')
  const ids = new Set()
  if (registry === undefined) return ids
  try {
    for (const workspace of registry.list()) {
      for (const id of workspace.sessionIds ?? []) ids.add(id)
    }
  } catch (error) {
    ctx.logger.warn(`dsh-mobile-bridge: archived id read failed: ${error?.message ?? error}`)
  }
  return ids
}

/**
 * Report whether one Session is a subagent.
 *
 * Delegation records `origin: 'subagent'` on the summary; the parent link is a
 * second signal used when a row predates that field.
 * @param row - the Session summary.
 * @returns true for a delegated child.
 */
function isSubagentRow(row) {
  return row?.origin === 'subagent' || (row?.parentSessionId !== undefined && row?.parentSessionId !== null)
}

/**
 * Shape one row for the phone, including its delegation and archive state.
 * @param row - the Session summary.
 * @param archived - the archived id set.
 * @returns the wire row.
 */
function summarizeWithState(row, archived) {
  const base = summarize(row)
  return {
    ...base,
    subagent: isSubagentRow(row),
    archived: archived.has(row.sessionId),
  }
}

/**
 * Read a bounded transcript page for one Session.
 * @param controller - the Host Session API.
 * @param sessionId - the Session to read.
 * @param signal - cancellation for the read.
 * @returns the folded nodes, the state, and the page cursor.
 */
async function readSession(controller, sessionId, signal) {
  const page = await controller.events({
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
      res.writeHead(204, corsHeaders(settings, req.headers.origin))
      res.end()
      return
    }
    if (segments.length === 2 && segments[0] === 'api' && segments[1] === 'health') {
      sendJson(res, 200, { ok: true, protocol: PROTOCOL, bridge: BRIDGE_VERSION })
      return
    }
    // The settings panel runs in the Harness page on this machine, so it needs
    // the pairing facts without already holding the token it is meant to show.
    // This route is therefore unauthenticated but restricted to a loopback
    // caller: a phone on the LAN cannot read it.
    if (segments.length === 3 && segments[0] === 'api' && segments[1] === 'panel' && segments[2] === 'state') {
      if (!isLoopbackRequest(req)) {
        sendJson(res, 403, { error: 'forbidden', message: 'This endpoint is loopback-only.' })
        return
      }
      sendJson(res, 200, await panelState(ctx, settings))
      return
    }
    if (!isAuthorized(req, url, settings)) {      sendJson(res, 401, {
        error: 'unauthorized',
        message: settings.auth === 'token'
          ? 'Send the bridge token as `Authorization: Bearer <token>` or `?token=<token>`.'
          : 'Cross-origin access to an open bridge is refused; a browser must call from this machine.',
      })
      return
    }
    const controller = ctx.sessionController
    if (segments[0] !== 'api' || segments.length < 2) {
      sendJson(res, 404, { error: 'not-found' })
      return
    }
    if (segments[1] === 'info' && segments.length === 2) {
      const payload = await infoPayload(ctx, settings)
      // The identity travels with every info read, so a phone can learn which
      // computer it just reached and detect a changed address for a known one.
      //
      // The token is included too: this endpoint already requires the token as a
      // bearer credential, so returning it reveals nothing to a caller that does
      // not hold it, and it is the one place a person can read it back when
      // pairing a second device.
      sendJson(res, 200, {
        ...payload,
        device: deviceIdentity(settings),
        bridge: { ...payload.bridge, token: settings.token },
      })
      return
    }
    if (segments[1] === 'devices' && segments.length === 2 && req.method === 'GET') {
      const self = deviceIdentity(settings)
      sendJson(res, 200, {
        self,
        devices: pairedDevices(settings),
      })
      return
    }
    if (segments[1] === 'devices' && segments.length === 2 && req.method === 'POST') {
      const body = await readJsonBody(req)
      const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : ''
      if (deviceId === '') {
        sendJson(res, 400, { error: 'bad-request', message: '`deviceId` is required.' })
        return
      }
      const name = typeof body.name === 'string' && body.name.trim() !== ''
        ? body.name.trim()
        : '未命名设备'
      // Recording a pairing on this side is what makes the device show up in
      // the computer's list; the phone does the same for this machine.
      const devices = rememberDevice(settings, {
        deviceId,
        name,
        platform: typeof body.platform === 'string' ? body.platform : 'unknown',
        address: typeof body.address === 'string' ? body.address : null,
        pairedAt: new Date().toISOString(),
      })
      sendJson(res, 200, { self: deviceIdentity(settings), devices })
      return
    }
    if (segments[1] === 'devices' && segments[3] === 'forget' && req.method === 'POST') {
      const target = decodeURIComponent(segments[2] ?? '')
      settings.pairedDevices = pairedDevices(settings).filter((entry) => entry.deviceId !== target)
      try {
        writeSettingsFile(settings.path, settings)
      } catch (error) {
        sendJson(res, 500, { error: 'devices/persist-failed', message: String(error?.message ?? error) })
        return
      }
      sendJson(res, 200, { self: deviceIdentity(settings), devices: settings.pairedDevices })
      return
    }
    if (segments[1] === 'questions' && segments.length === 2 && req.method === 'GET') {
      sendJson(res, 200, { items: questionList() }, settings, req.headers.origin)
      return
    }
    if (segments[1] === 'questions' && segments[3] === 'answer' && req.method === 'POST') {
      const body = await readJsonBody(req)
      const id = decodeURIComponent(segments[2] ?? '')
      if (!Array.isArray(body.answers)) {
        sendJson(res, 400, {
          error: 'bad-request',
          message: '`answers` must be an array.',
        }, settings, req.headers.origin)
        return
      }
      if (!settleQuestion(id, body.answers)) {
        sendJson(res, 409, {
          error: 'question/not-pending',
          message: 'That question is no longer waiting for an answer.',
        }, settings, req.headers.origin)
        return
      }
      sendJson(res, 200, { ok: true, id }, settings, req.headers.origin)
      return
    }
    if (segments[1] === 'approvals' && segments.length === 2 && req.method === 'GET') {
      sendJson(res, 200, { items: approvalList() }, settings, req.headers.origin)
      return
    }
    if (segments[1] === 'approvals' && segments[3] === 'answer' && req.method === 'POST') {
      const body = await readJsonBody(req)
      const id = decodeURIComponent(segments[2] ?? '')
      if (typeof body.allow !== 'boolean') {
        sendJson(res, 400, { error: 'bad-request', message: '`allow` must be true or false.' }, settings, req.headers.origin)
        return
      }
      if (!settleApproval(id, body.allow)) {
        // Already answered, expired, or cancelled; the phone should drop the card
        // rather than show an error, because the outcome is no longer actionable.
        sendJson(res, 409, {
          error: 'approval/not-pending',
          message: 'That request is no longer waiting for a decision.',
        }, settings, req.headers.origin)
        return
      }
      sendJson(res, 200, { ok: true, id, allow: body.allow }, settings, req.headers.origin)
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
    // Session search spans transcripts, so it is its own endpoint rather than a
    // filter on the list: the Harness matches message bodies, which the list
    // rows never carry.
    if (segments[1] === 'search' && segments.length === 2 && req.method === 'GET') {
      const query = url.searchParams.get('q') ?? ''
      if (query.trim() === '') {
        sendJson(res, 200, { items: [], hasMore: false, mode: 'empty' })
        return
      }
      const signal = new AbortController().signal
      const list = await controller.list({}, signal)
      const rows = list.items ?? []
      const needle = query.toLowerCase()
      try {
        // The Harness's own transcript index is the better search when the
        // deployment enabled it, so try it first.
        const found = await controller.search({ query }, signal)
        const titles = new Map(rows.map((row) => [row.sessionId, row]))
        sendJson(res, 200, {
          mode: 'transcript',
          hasMore: found.hasMore === true,
          items: (found.items ?? []).map((item) => {
            const row = titles.get(item.sessionId)
            return {
              id: item.sessionId,
              title: typeof row?.projections?.values?.title === 'string'
                ? row.projections.values.title
                : 'Session',
              running: row?.running === true,
              snippet: typeof item.snippet === 'string' ? item.snippet : null,
            }
          }),
        })
        return
      } catch (error) {
        // transcript index disabled. Many deployments configure it with
        // `openAt: "never"`, which is a supported configuration, so fall back to
        // filtering titles rather than failing the search outright.
        ctx.logger.info(`dsh-mobile-bridge: transcript search unavailable, filtering titles: ${error?.message ?? error}`)
      }
      const matches = []
      for (const row of rows) {
        const title = row?.projections?.values?.title
        if (typeof title === 'string' && title.toLowerCase().includes(needle)) {
          matches.push({
            id: row.sessionId,
            title,
            running: row.running === true,
            snippet: null,
          })
        }
      }
      sendJson(res, 200, { mode: 'title', hasMore: false, items: matches })
      return
    }
    if (segments[1] === 'sessions') {
      if (segments.length === 2 && req.method === 'GET') {
        const signal = new AbortController().signal
        const list = await controller.list({}, signal)
        // Archived membership and delegation are decided here rather than on the
        // phone: the app receives one row that already says whether it belongs in
        // a default list.
        const archived = archivedSessionIds(ctx)
        const rows = list.items.map((row) => summarizeWithState(row, archived))
        rows.sort((left, right) => (right.updatedAt ?? 0) - (left.updatedAt ?? 0))
        sendJson(res, 200, {
          items: rows,
          counts: {
            total: rows.length,
            subagents: rows.filter((row) => row.subagent).length,
            archived: rows.filter((row) => row.archived).length,
          },
        })
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
        await streamSession(ctx, settings, req, res, sessionId, url)
        return
      }
      if (tail === 'files' && req.method === 'GET') {
        const signal = new AbortController().signal
        const listing = await listFiles(ctx, controller, sessionId, url.searchParams.get('path'), signal)
        if (listing === null) {
          sendJson(res, 404, { error: 'unsupported', message: 'This Harness exposes no workspace files.' })
          return
        }
        sendJson(res, 200, listing)
        return
      }
      if (tail === 'files' && segments[4] === 'archive' && req.method === 'POST') {
        const body = await readJsonBody(req)
        const selection = Array.isArray(body.paths)
          ? body.paths.filter((value) => typeof value === 'string' && value !== '')
          : []
        if (selection.length === 0) {
          sendJson(res, 400, { error: 'bad-request', message: '`paths` must list at least one path.' })
          return
        }
        await sendArchive(ctx, settings, controller, req, res, sessionId, selection)
        return
      }
      if (tail === 'upload' && req.method === 'POST') {
        await receiveUpload(ctx, settings, controller, req, res, sessionId, url)
        return
      }
      if (tail === 'uploads' && req.method === 'GET') {
        await listUploads(ctx, settings, controller, res, sessionId, req.headers.origin)
        return
      }
      if (tail === 'prompt' && req.method === 'POST') {
        const body = await readJsonBody(req)
        const text = typeof body.text === 'string' ? body.text : ''
        const attachments = Array.isArray(body.attachments) ? body.attachments : []
        // An attachment-only prompt is legitimate; only refuse when there is
        // neither text nor anything attached.
        if (text.trim() === '' && attachments.length === 0) {
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
          content: buildPromptContent(attachments, text),
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
      if (tail === 'rename' && req.method === 'POST') {
        const body = await readJsonBody(req)
        const title = typeof body.title === 'string' ? body.title.trim() : ''
        if (title === '') {
          sendJson(res, 400, { error: 'bad-request', message: '`title` is required.' })
          return
        }
        sendJson(res, 200, await controller.rename({ sessionId, title }))
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
 * @param settings - resolved bridge settings, for the response's CORS rule.
 * @param req - the incoming request.
 * @param res - the response being written.
 * @param sessionId - the Session to follow.
 * @param url - the parsed request URL.
 */
async function streamSession(ctx, settings, req, res, sessionId, url) {
  const abort = new AbortController()
  // Registering the stream is what enables phone approvals; the entry is
  // removed on every exit path.
  OPEN_STREAMS.add(res)
  res.on('close', () => OPEN_STREAMS.delete(res))
  req.on('close', () => abort.abort())
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache, no-transform',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
    ...corsHeaders(settings, req.headers.origin),
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
      // The identity lets a phone match a beacon to a device it already paired
      // with, even after DHCP handed it a new address.
      deviceId: deviceIdentity(settings).deviceId,
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
  // Take over approval prompts while a phone is watching.
  //
  // The listener must call `next()` when it declines to decide — that is the
  // waterfall contract — so a bridge with no connected phone behaves exactly as
  // it did before this plugin existed.
  ctx.effect(
    () => ctx.on('approval/request', (request, next) => awaitPhoneApproval(ctx, request, next)),
    'dsh-mobile-bridge: phone approvals',
  )
  // Questions follow the same rule: intercept only while a phone is watching,
  // and delegate otherwise so the desktop flow is untouched.
  ctx.effect(
    () => ctx.on('user-questions/request', (request, next) => awaitPhoneAnswer(ctx, request, next)),
    'dsh-mobile-bridge: phone questions',
  )
  ctx.effect(() => {
    const stopBeacon = startBeacon(settings)
    server.listen(settings.port, settings.host, () => {
      listening = true
      const address = preferredAddress()
      const identity = deviceIdentity(settings)
      // Print the token, not where it lives: pairing fails without it, and asking
      // someone to open a JSON file to find it is a poor answer.
      ctx.logger.info(`dsh-mobile-bridge: 设备名称 ${identity.name} (${identity.deviceId})`)
      ctx.logger.info(`dsh-mobile-bridge: 地址 http://${address}:${settings.port}`)
      ctx.logger.info(`dsh-mobile-bridge: 令牌 ${settings.token}`)
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
