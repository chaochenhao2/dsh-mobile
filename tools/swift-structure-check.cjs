/**
 * Crude Swift structural check: brace/paren/bracket balance outside strings and
 * comments, plus a few conventions that silently break compilation. This is not
 * a compiler; the CI `parse` job is the real syntax gate.
 */

const fs = require('node:fs')
const path = require('node:path')

const ROOT = 'DshMobile/DshMobile'
const PAIRS = { '}': '{', ')': '(', ']': '[' }

function walk(directory, accumulator = []) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name)
    if (entry.isDirectory()) walk(full, accumulator)
    else if (entry.name.endsWith('.swift')) accumulator.push(full)
  }
  return accumulator
}

function check(file) {
  const source = fs.readFileSync(file, 'utf8')
  const depth = { '{': 0, '(': 0, '[': 0 }
  let index = 0
  let line = 1
  let inString = false
  let escaped = false
  let inLineComment = false
  let inBlockComment = false
  const problems = []

  while (index < source.length) {
    const char = source[index]
    const next = source[index + 1]
    if (char === '\n') {
      line += 1
      inLineComment = false
      index += 1
      continue
    }
    if (inLineComment) { index += 1; continue }
    if (inBlockComment) {
      if (char === '*' && next === '/') { inBlockComment = false; index += 2; continue }
      index += 1
      continue
    }
    if (inString) {
      if (escaped) { escaped = false; index += 1; continue }
      if (char === '\\') { escaped = true; index += 1; continue }
      if (char === '"') { inString = false; index += 1; continue }
      index += 1
      continue
    }
    if (char === '/' && next === '/') { inLineComment = true; index += 2; continue }
    if (char === '/' && next === '*') { inBlockComment = true; index += 2; continue }
    if (char === '"') { inString = true; index += 1; continue }
    if (char === '{' || char === '(' || char === '[') depth[char] += 1
    else if (char === '}' || char === ')' || char === ']') {
      depth[PAIRS[char]] -= 1
      if (depth[PAIRS[char]] < 0) problems.push(`extra ${char} at line ${line}`)
    }
    index += 1
  }

  if (inString) problems.push('unterminated string')
  if (inBlockComment) problems.push('unterminated block comment')
  for (const [symbol, count] of Object.entries(depth)) {
    if (count !== 0) problems.push(`unbalanced ${symbol} (${count})`)
  }
  return { source, problems }
}

const files = walk(ROOT).sort()
let failures = 0
for (const file of files) {
  const { source, problems } = check(file)
  const name = path.basename(file)
  if (problems.length > 0) {
    failures += 1
    console.log(`FAIL ${name}: ${problems.join('; ')}`)
    continue
  }
  const lines = source.split('\n').length
  console.log(`ok   ${name.padEnd(22)} ${String(lines).padStart(4)} lines`)
}

console.log(`\n${files.length} Swift files, ${failures} structural problems`)
process.exit(failures === 0 ? 0 : 1)
