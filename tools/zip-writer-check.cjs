/**
 * Verify the bridge's streaming ZIP writer against a mocked filesystem.
 *
 * `collectToDisk` is extracted from the plugin source so this check fails if the
 * shipped code and the tested code diverge. The fixture service mimics the
 * workspaceFiles contract (list/stat/readBytes), and the resulting archive is
 * unpacked by the platform's own reader: a hand-rolled ZIP has many ways to look
 * plausible and still be unreadable.
 */

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { execFileSync } = require('node:child_process')

const BRIDGE = path.join(__dirname, '..', 'dsh-mobile-bridge', 'bridge.js')
const source = fs.readFileSync(BRIDGE, 'utf8')

/**
 * Cut one top-level function out of the bridge source.
 * @param name - the function name to locate.
 * @returns the source text of that function.
 */
function extractFunction(name) {
  const start = source.indexOf(`async function ${name}(`)
  const startSync = start >= 0 ? start : source.indexOf(`function ${name}(`)
  if (startSync < 0) throw new Error(`could not locate ${name}`)
  const bodyStart = source.indexOf('{', startSync)
  let depth = 0
  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1
    else if (source[index] === '}') {
      depth -= 1
      if (depth === 0) return source.slice(startSync, index + 1)
    }
  }
  throw new Error(`could not find the end of ${name}`)
}

// Dependencies collectToDisk relies on, taken from the real source.
const helpers = [
  extractFunction('crc32'),
  extractFunction('joinPath'),
  extractFunction('absolutize'),
  extractFunction('isAbsolutePath'),
  extractFunction('platformIsWindows'),
  extractFunction('baseName'),
  extractFunction('collectToDisk'),
].join('\n\n')

const CRCTable = source.slice(
  source.indexOf('const CRC_TABLE'),
  source.indexOf('function crc32'),
)

const harness = `
const { mkdirSync, createWriteStream, unlinkSync } = require('node:fs')
const { tmpdir } = require('node:os')
const { join, basename } = require('node:path')
const { randomUUID } = require('node:crypto')
const MAX_ARCHIVE_DEPTH = 32
${CRCTable}
${helpers}
module.exports = { collectToDisk }
`

const harnessPath = path.join(os.tmpdir(), `dsh-writer-${process.pid}.cjs`)
fs.writeFileSync(harnessPath, harness, 'utf8')
const { collectToDisk } = require(harnessPath)

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

/**
 * Build a fake workspaceFiles service over an in-memory tree.
 *
 * A node is either `{ dir: { name: node } }` or `{ file: Buffer }`, which mirrors
 * the two shapes the real service distinguishes by byte count.
 * @param tree - the fixture filesystem.
 * @param root - its absolute root path.
 * @returns the service and the number of readBytes calls made.
 */
function makeService(tree, root) {
  const reads = { count: 0 }

  /**
   * Resolve a path against the tree.
   * @param absolute - the path to look up.
   * @returns the node, or undefined.
   */
  const resolve = (absolute) => {
    const normalized = absolute.replace(/\\/g, '/')
    const relative = normalized.startsWith(root.replace(/\\/g, '/'))
      ? normalized.slice(root.replace(/\\/g, '/').length)
      : normalized
    const parts = relative.split('/').filter(Boolean)
    let node = tree
    for (const part of parts) {
      if (node?.dir === undefined) return undefined
      node = node.dir[part]
      if (node === undefined) return undefined
    }
    return node
  }

  return {
    reads,
    async list(_scope, absolute) {
      const node = resolve(absolute)
      if (node?.dir === undefined) throw new Error('not a directory')
      return {
        path: absolute,
        truncated: false,
        entries: Object.entries(node.dir).map(([name, child]) => ({
          name,
          type: child.dir !== undefined ? 'directory' : 'file',
          size: child.file === undefined ? undefined : child.file.length,
        })),
      }
    },
    async stat(_scope, absolute) {
      const node = resolve(absolute)
      if (node === undefined) throw new Error('missing')
      if (node.dir !== undefined) return { absolutePath: absolute, version: '1' }
      return { absolutePath: absolute, version: '1', bytes: node.file.length }
    },
    async readBytes(_scope, absolute) {
      const node = resolve(absolute)
      if (node?.file === undefined) throw new Error('not a file')
      reads.count += 1
      return { absolutePath: absolute, version: '1', bytes: node.file.length, offset: 0, data: node.file, eof: true }
    },
  }
}

/**
 * Unpack an archive through .NET's reader.
 * @param archivePath - the archive on disk.
 * @param name - directory name to create.
 * @returns the extraction directory.
 */
function unpack(archivePath, name) {
  const destination = path.join(os.tmpdir(), `dsh-unzip-${process.pid}-${name}`)
  fs.rmSync(destination, { recursive: true, force: true })
  fs.mkdirSync(destination, { recursive: true })
  const script = [
    'Add-Type -AssemblyName System.IO.Compression.FileSystem',
    '[System.IO.Compression.ZipFile]::ExtractToDirectory($env:DSH_ZIP_SRC, $env:DSH_ZIP_DST)',
  ].join('; ')
  execFileSync('powershell', ['-NoProfile', '-Command', script], {
    stdio: 'pipe',
    env: { ...process.env, DSH_ZIP_SRC: archivePath, DSH_ZIP_DST: destination },
  })
  return destination
}

const root = 'C:\\fixture'
const ascii = Buffer.from('hello from the bridge\n', 'utf8')
const unicode = Buffer.from('中文内容测试\n', 'utf8')
const binary = Buffer.from(Array.from({ length: 40_000 }, (_, index) => (index * 37) & 0xff))

const tree = {
  dir: {
    'a.txt': { file: ascii },
    '中文 文件.txt': { file: unicode },
    'empty.txt': { file: Buffer.alloc(0) },
    blob: { file: binary },
    proj: {
      dir: {
        'README.md': { file: Buffer.from('# proj\n', 'utf8') },
        src: { dir: { 'main.ts': { file: Buffer.from('export {}\n', 'utf8') } } },
      },
    },
  },
}

;(async () => {
  const service = makeService(tree, root)
  const scope = { sessionId: 's', workspaceRoot: root }
  const signal = new AbortController().signal

  // A directory plus a loose file, which is what multi-select produces.
  const result = await collectToDisk(null, service, scope, [
    path.join(root, 'a.txt'),
    path.join(root, 'proj'),
    path.join(root, '中文 文件.txt'),
    path.join(root, 'empty.txt'),
    path.join(root, 'blob'),
  ], signal)

  console.log(`archive: ${result.bytes} bytes, ${result.entries} entries`)
  check('archive file exists', fs.existsSync(result.path))
  check('reported size matches disk', fs.statSync(result.path).size === result.bytes)
  check('entry count covers every file', result.entries === 6, `got ${result.entries}`)
  check('nothing skipped', result.skipped.length === 0, result.skipped.join('; '))

  const out = unpack(result.path, 'out')
  const read = (relative) => fs.readFileSync(path.join(out, ...relative.split('/')))
  check('ascii file round-trips', read('a.txt').equals(ascii))
  check('non-ASCII name preserved', fs.existsSync(path.join(out, '中文 文件.txt')))
  check('non-ASCII content round-trips', read('中文 文件.txt').equals(unicode))
  check('empty file preserved', read('empty.txt').length === 0)
  check('binary content round-trips', read('blob').equals(binary))
  check('directory nested', fs.existsSync(path.join(out, 'proj', 'src', 'main.ts')))

  result.cleanup()
  check('cleanup removes archive', !fs.existsSync(result.path))

  // A missing path must be reported, not silently dropped.
  const partial = await collectToDisk(null, service, scope, [
    path.join(root, 'a.txt'),
    path.join(root, 'nope.txt'),
  ], signal)
  check('missing path is skipped and reported', partial.entries === 1 && partial.skipped.length === 1)
  partial.cleanup()
})().finally(() => {
  fs.rmSync(harnessPath, { force: true })
  console.log(failures === 0 ? '\nstreaming writer verified' : `\n${failures} failure(s)`)
  // Set the code instead of calling process.exit: exiting immediately would
  // truncate whatever stdout has not flushed yet.
  process.exitCode = failures === 0 ? 0 : 1
})