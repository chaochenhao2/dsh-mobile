/**
 * Prove the scope checker rejects a function that uses a value it never received.
 *
 * A guard that only ever passes is worthless. This copies the plugin source,
 * removes one parameter the function still uses, and requires the checker to
 * report that function by name.
 */

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { execFileSync } = require('node:child_process')

const checker = path.join(__dirname, 'settings-scope-check.cjs')
const source = fs.readFileSync(path.join(__dirname, '..', 'dsh-mobile-bridge', 'bridge.js'), 'utf8')

const cases = [
  {
    label: 'download archive drops settings',
    from: 'async function sendArchive(ctx, settings, controller, req, res, sessionId, selection) {',
    to: 'async function sendArchive(ctx, controller, req, res, sessionId, selection) {',
    expect: 'sendArchive uses settings',
  },
  {
    label: 'upload listing drops origin',
    from: 'async function listUploads(ctx, controller, res, sessionId, origin) {',
    to: 'async function listUploads(ctx, controller, res, sessionId) {',
    expect: 'listUploads uses origin',
  },
  {
    label: 'stream writer drops settings',
    from: 'async function streamSession(ctx, settings, req, res, sessionId, url) {',
    to: 'async function streamSession(ctx, req, res, sessionId, url) {',
    expect: 'streamSession uses settings',
  },
]

let failures = 0
for (const testCase of cases) {
  if (!source.includes(testCase.from)) {
    failures += 1
    console.log(`  FAIL ${testCase.label} — anchor not found`)
    continue
  }
  const probeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-probe-'))
  const probeSource = path.join(probeDir, 'bridge.js')
  fs.writeFileSync(probeSource, source.replace(testCase.from, testCase.to), 'utf8')

  let output = ''
  let failed = false
  try {
    output = execFileSync(process.execPath, [checker], {
      cwd: path.join(__dirname, '..'),
      env: { ...process.env, DSH_SCOPE_TARGET: probeSource },
      stdio: 'pipe',
    }).toString()
  } catch (error) {
    failed = true
    output = `${error.stdout ?? ''}${error.stderr ?? ''}`
  }

  const reported = output.includes(testCase.expect)
  if (!failed || !reported) {
    failures += 1
    console.log(`  FAIL ${testCase.label} — checker did not report "${testCase.expect}"`)
  } else {
    console.log(`  ok   ${testCase.label}`)
  }
  fs.rmSync(probeDir, { recursive: true, force: true })
}

console.log(failures === 0 ? '\nscope checker rejects undeclared identifiers' : `\n${failures} failure(s)`)
process.exitCode = failures === 0 ? 0 : 1
