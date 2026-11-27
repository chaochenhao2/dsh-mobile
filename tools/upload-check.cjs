/**
 * Verify the bridge's upload helpers in isolation.
 *
 * File naming and media classification decide what lands on disk and how a
 * prompt treats it, so they are exercised directly from the plugin source. The
 * prompt builder is checked with real temporary files so the image branch runs
 * against actual bytes.
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
const { basename } = require('node:path')
const { statSync, readFileSync } = require('node:fs')
const MAX_INLINE_IMAGE_BYTES = ${/const MAX_INLINE_IMAGE_BYTES = ([^\n]+)/.exec(source)[1]}
const MAX_ATTACHMENTS = ${/const MAX_ATTACHMENTS = ([^\n]+)/.exec(source)[1]}
${take('safeFileName')}
${take('mediaKind')}
${take('readImagePart')}
${take('buildPromptContent')}
module.exports = { safeFileName, mediaKind, readImagePart, buildPromptContent }
`

const harnessPath = path.join(os.tmpdir(), `dsh-upload-${process.pid}.cjs`)
fs.writeFileSync(harnessPath, harness, 'utf8')
const { safeFileName, mediaKind, readImagePart, buildPromptContent } = require(harnessPath)

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

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-up-'))

try {
  console.log('naming:')
  check('plain name kept', safeFileName('photo.jpg', 'x') === 'photo.jpg')
  check('path stripped', safeFileName('../../etc/passwd', 'x') === 'passwd')
  check('backslashes stripped', safeFileName('C:\\\\temp\\\\a.txt', 'x') === 'a.txt')
  check('reserved characters replaced', safeFileName('a<b>c.txt', 'x') === 'a_b_c.txt')
  check('empty falls back', safeFileName('', 'fallback') === 'fallback')
  check('dot traversal falls back', safeFileName('..', 'fallback') === 'fallback')

  console.log('classification:')
  check('image by media type', mediaKind('image/png', 'x.bin') === 'image')
  check('video by media type', mediaKind('video/mp4', 'x.bin') === 'video')
  check('image by extension', mediaKind('application/octet-stream', 'a.JPG') === 'image')
  check('video by extension', mediaKind('', 'clip.mov') === 'video')
  check('other is file', mediaKind('application/pdf', 'doc.pdf') === 'file')

  // Real files so the image branch reads actual bytes.
  const png = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex')
  const imagePath = path.join(work, 'shot.png')
  fs.writeFileSync(imagePath, png)
  const textPath = path.join(work, 'notes.md')
  fs.writeFileSync(textPath, '# notes\n')
  const videoPath = path.join(work, 'clip.mp4')
  fs.writeFileSync(videoPath, Buffer.alloc(64))

  console.log('image inlining:')
  const part = readImagePart(imagePath)
  check('png produces an image part', part?.type === 'image')
  check('media type is png', part?.mediaType === 'image/png')
  check('bytes are base64 of the file', Buffer.from(part.data, 'base64').equals(png))
  check('unsupported extension rejected', readImagePart(path.join(work, 'a.bmp')) === null)

  console.log('prompt content:')
  const withImage = buildPromptContent([{ path: imagePath, kind: 'image' }], '看这张图')
  check('text part leads', withImage[0].type === 'text')
  check('text preserved', withImage[0].text === '看这张图')
  check('image part follows', withImage[1].type === 'image')

  const withFile = buildPromptContent([{ path: textPath, kind: 'file' }], '读一下')
  check('file is described by path', withFile.length === 1 && withFile[0].text.includes(textPath))
  check('file text keeps the prompt', withFile[0].text.startsWith('读一下'))

  const withVideo = buildPromptContent([{ path: videoPath, kind: 'video' }], '')
  check('video is described, not inlined', withVideo[0].text.includes(videoPath))
  check('attachment-only prompt yields text', withVideo.length === 1)

  const onlyImage = buildPromptContent([{ path: imagePath, kind: 'image' }], '')
  check('image-only prompt has no empty text part', onlyImage.length === 1 && onlyImage[0].type === 'image')

  const many = Array.from({ length: 30 }, () => ({ path: textPath, kind: 'file' }))
  const capped = buildPromptContent(many, 'x')
  // One line is the prompt, two are blank/header, and at most MAX_ATTACHMENTS
  // are the described files.
  const describedLines = capped[0].text.split('\n').filter((line) => line.startsWith('- '))
  check('attachment count is bounded', describedLines.length === 20, `got ${describedLines.length}`)
} finally {
  fs.rmSync(work, { recursive: true, force: true })
  fs.rmSync(harnessPath, { force: true })
}

console.log('routes:')
check('POST upload route', /tail === 'upload'/.test(source))
check('GET uploads route', /tail === 'uploads'/.test(source))
check('upload folder under .dsh', /const UPLOAD_DIR = '\.dsh'/.test(source))
check('uploads subfolder', /const UPLOAD_SUBDIR = 'uploads'/.test(source))
check('hidden attribute on Windows', /attrib/.test(source))
check('upload size bounded', /MAX_UPLOAD_BYTES/.test(source))
check('prompt accepts attachments', /body\.attachments/.test(source))
check('capability advertised', /'session\.upload'/.test(source))

console.log(failures === 0 ? '\nupload helpers verified' : `\n${failures} failure(s)`)
process.exitCode = failures === 0 ? 0 : 1
