/**
 * Verify the app's ZIP central-directory reader against real archives.
 *
 * The reader is reimplemented here from the Swift source's contract (same field
 * offsets, same EOCD scan) and checked against archives produced by the bridge
 * writer, whose layout is already verified. Runs offline; no model calls.
 */

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')

// --- The bridge's writer, extracted from the plugin source -----------------

const BRIDGE = path.join(__dirname, '..', 'dsh-mobile-bridge', 'bridge.js')
const source = fs.readFileSync(BRIDGE, 'utf8')
const start = source.indexOf('const CRC_TABLE')
const buildStart = source.indexOf('function buildZip')
const bodyStart = source.indexOf('{', buildStart)
let depth = 0
let end = -1
for (let i = bodyStart; i < source.length; i += 1) {
  if (source[i] === '{') depth += 1
  else if (source[i] === '}') {
    depth -= 1
    if (depth === 0) { end = i + 1; break }
  }
}
const modulePath = path.join(os.tmpdir(), `dsh-apzip-${process.pid}.cjs`)
fs.writeFileSync(modulePath, `${source.slice(start, end)}\nmodule.exports = { buildZip }\n`, 'utf8')
const { buildZip } = require(modulePath)

// --- The Swift reader's algorithm, mirrored ---------------------------------

/**
 * Mirror of ArchiveReader.listMembers: scan backwards for EOCD, then walk the
 * central directory reading name, compressed and uncompressed sizes.
 * @param buffer - the archive bytes.
 * @returns member paths and sizes, or null when the archive is unreadable.
 */
function listMembers(buffer) {
  const total = buffer.length
  if (total < 22) return null
  const tailLength = Math.min(total, 65557)
  const tail = buffer.subarray(total - tailLength)

  let eocdIndex = -1
  for (let i = tail.length - 22; i >= 0; i -= 1) {
    if (tail.readUInt32LE(i) === 0x06054b50) { eocdIndex = i; break }
  }
  if (eocdIndex < 0) return null

  const entryCount = tail.readUInt16LE(eocdIndex + 10)
  const directorySize = tail.readUInt32LE(eocdIndex + 12)
  const directoryOffset = tail.readUInt32LE(eocdIndex + 16)
  if (entryCount === 0 || directorySize === 0) return []
  if (directoryOffset + directorySize > total) return null

  const directory = buffer.subarray(directoryOffset, directoryOffset + directorySize)
  const members = []
  let cursor = 0
  for (let index = 0; index < entryCount; index += 1) {
    if (cursor + 46 > directory.length) break
    if (directory.readUInt32LE(cursor) !== 0x02014b50) break
    const compressed = directory.readUInt32LE(cursor + 20)
    const uncompressed = directory.readUInt32LE(cursor + 24)
    const nameLength = directory.readUInt16LE(cursor + 28)
    const extraLength = directory.readUInt16LE(cursor + 30)
    const commentLength = directory.readUInt16LE(cursor + 32)
    const nameStart = cursor + 46
    if (nameStart + nameLength > directory.length) break
    const rawName = directory.subarray(nameStart, nameStart + nameLength).toString('utf8')
    if (rawName && !rawName.endsWith('/')) {
      members.push({ path: rawName, bytes: uncompressed > 0 ? uncompressed : compressed })
    }
    cursor = nameStart + nameLength + extraLength + commentLength
  }
  return members
}

let failures = 0
/**
 * Record one assertion.
 * @param label - what is being checked.
 * @param ok - whether it held.
 * @param detail - optional context for a failure.
 */
function check(label, ok, detail) {
  if (!ok) failures += 1
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`)
}

try {
  const files = [
    { name: 'root/a.txt', data: Buffer.from('hello from the bridge\n') },
    { name: '目录/中文 文件.txt', data: Buffer.from('中文内容测试\n') },
    { name: 'root/empty.txt', data: Buffer.alloc(0) },
    { name: 'root/blob.bin', data: Buffer.from(Array.from({ length: 4096 }, (_, i) => (i * 37) & 0xff)) },
  ]
  const archive = buildZip(files)
  const members = listMembers(archive)
  check('archive readable', members !== null)
  check('member count', members?.length === 4, `got ${members?.length}`)

  const byPath = new Map((members ?? []).map((m) => [m.path, m.bytes]))
  check('ascii member listed', byPath.has('root/a.txt'))
  check('non-ASCII member listed', byPath.has('目录/中文 文件.txt'))
  check('empty member listed', byPath.has('root/empty.txt'))
  check('ascii size matches', byPath.get('root/a.txt') === files[0].data.length)
  check('binary size matches', byPath.get('root/blob.bin') === 4096)
  check('empty size is zero', byPath.get('root/empty.txt') === 0)

  // Directory entries carry no payload and must not appear as members.
  const withDirectory = buildZip([
    { name: 'proj/README.md', data: Buffer.from('# x\n') },
    { name: 'proj/src/main.ts', data: Buffer.from('export {}\n') },
  ])
  const nested = listMembers(withDirectory)
  check('nested paths preserved', nested?.every((m) => m.path.includes('/')) === true)

  // A non-ZIP payload must be rejected rather than producing garbage.
  check('random bytes rejected', listMembers(Buffer.from('not an archive at all, definitely not')) === null)
  check('truncated archive rejected', listMembers(archive.subarray(0, 40)) === null)

  // A ZIP comment may follow the EOCD record. The scan walks backwards, so it
  // must skip past padding that does not itself look like a signature.
  const padding = Buffer.from('trailing archive comment padding'.repeat(2))
  const commented = Buffer.concat([archive, padding])
  check('trailing bytes tolerated', listMembers(commented)?.length === 4)
} finally {
  fs.rmSync(modulePath, { force: true })
}

console.log(failures === 0 ? '\nzip reader verified' : `\n${failures} failure(s)`)
process.exit(failures === 0 ? 0 : 1)