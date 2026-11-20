/**
 * Verify the bridge's store-only ZIP writer end to end.
 *
 * The writer body is extracted from the plugin source rather than copied, so
 * this check fails if the shipped code and the tested code ever diverge. Each
 * archive is then unpacked by the platform's own reader: a hand-rolled ZIP has
 * many ways to look plausible and still be unreadable.
 */

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { execFileSync } = require('node:child_process')

const BRIDGE = path.join(__dirname, '..', 'dsh-mobile-bridge', 'bridge.js')
const source = fs.readFileSync(BRIDGE, 'utf8')

const start = source.indexOf('const CRC_TABLE')
const buildStart = source.indexOf('function buildZip')
const bodyStart = source.indexOf('{', buildStart)
if (start < 0 || buildStart < 0 || bodyStart < 0) {
  console.error('could not locate the zip writer in bridge.js')
  process.exit(1)
}

// Trim at the closing brace of buildZip: slicing to the next function would
// drag in its `async` keyword and produce an unparseable fragment.
let depth = 0
let end = -1
for (let index = bodyStart; index < source.length; index += 1) {
  const character = source[index]
  if (character === '{') depth += 1
  else if (character === '}') {
    depth -= 1
    if (depth === 0) {
      end = index + 1
      break
    }
  }
}
if (end < 0) {
  console.error('could not find the end of the zip writer')
  process.exit(1)
}

const modulePath = path.join(os.tmpdir(), `dsh-zipmod-${process.pid}.cjs`)
fs.writeFileSync(modulePath, `${source.slice(start, end)}\nmodule.exports = { buildZip }\n`, 'utf8')
const { buildZip } = require(modulePath)

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-zip-'))
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

/**
 * Unpack an archive with the platform reader.
 *
 * Extraction goes through .NET's own zip reader rather than `Expand-Archive`:
 * the cmdlet is reached through a shell command line, and a non-ASCII temp path
 * is mangled by that hop, which would make this check fail for reasons that
 * have nothing to do with the writer under test.
 * @param archive - bytes to unpack.
 * @param name - directory name to create.
 * @returns the extraction directory.
 */
function unpack(archive, name) {
  const archivePath = path.join(work, `${name}.zip`)
  fs.writeFileSync(archivePath, archive)
  const destination = path.join(work, name)
  fs.mkdirSync(destination)
  const script = [
    'Add-Type -AssemblyName System.IO.Compression.FileSystem',
    "[System.IO.Compression.ZipFile]::ExtractToDirectory($env:DSH_ZIP_SRC, $env:DSH_ZIP_DST)",
  ].join('; ')
  execFileSync('powershell', ['-NoProfile', '-Command', script], {
    stdio: 'pipe',
    // Pass the paths through the environment so the console code page never
    // participates in carrying them.
    env: { ...process.env, DSH_ZIP_SRC: archivePath, DSH_ZIP_DST: destination },
  })
  return destination
}

try {
  const ascii = Buffer.from('hello from the bridge\n', 'utf8')
  const unicode = Buffer.from('中文内容测试\n', 'utf8')
  const empty = Buffer.alloc(0)
  const binary = Buffer.from(Array.from({ length: 4096 }, (_, index) => (index * 37) & 0xff))

  const archive = buildZip([
    { name: 'root/a.txt', data: ascii },
    { name: '目录/中文 文件.txt', data: unicode },
    { name: 'root/empty.txt', data: empty },
    { name: 'root/blob.bin', data: binary },
  ])
  console.log(`archive: ${archive.length} bytes for 4 entries`)

  const out = unpack(archive, 'multi')
  const read = (relative) => fs.readFileSync(path.join(out, ...relative.split('/')))

  check('ascii file extracted', fs.existsSync(path.join(out, 'root', 'a.txt')))
  check('ascii content round-trips', read('root/a.txt').equals(ascii))
  check('non-ASCII path preserved', fs.existsSync(path.join(out, '目录', '中文 文件.txt')))
  check('non-ASCII content round-trips', read('目录/中文 文件.txt').equals(unicode))
  check('empty file preserved', read('root/empty.txt').length === 0)
  check('binary content round-trips', read('root/blob.bin').equals(binary))

  const single = buildZip([{ name: 'note.md', data: Buffer.from('# note\n', 'utf8') }])
  const singleOut = unpack(single, 'single')
  check('single file at archive root', fs.existsSync(path.join(singleOut, 'note.md')))

  const nested = buildZip([
    { name: 'proj/README.md', data: Buffer.from('# proj\n', 'utf8') },
    { name: 'proj/src/main.ts', data: Buffer.from('export {}\n', 'utf8') },
  ])
  const nestedOut = unpack(nested, 'nested')
  check('nested directory recreated', fs.existsSync(path.join(nestedOut, 'proj', 'src', 'main.ts')))
} finally {
  fs.rmSync(work, { recursive: true, force: true })
  fs.rmSync(modulePath, { force: true })
}

console.log(failures === 0 ? '\nzip writer verified' : `\n${failures} failure(s)`)
process.exit(failures === 0 ? 0 : 1)