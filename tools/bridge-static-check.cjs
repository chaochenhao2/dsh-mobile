/**
 * Static checks over the bridge source: routes exist, the mode-name table
 * covers the shipped presets, and each mutation calls the documented service
 * method. This is not a substitute for the running plugin; it catches the
 * wiring mistakes that a restart would otherwise be needed to reveal.
 */

const fs = require('node:fs')

const source = fs.readFileSync('dsh-mobile-bridge/bridge.js', 'utf8')
let failures = 0

/**
 * Assert one condition and print its outcome.
 * @param label - what is being checked.
 * @param ok - whether the source satisfies it.
 */
function check(label, ok) {
  if (!ok) failures += 1
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}`)
}

console.log('routes:')
check('GET /api/workspaces', /segments\[1\] === 'workspaces'/.test(source))
check('GET /api/modes', /segments\[1\] === 'modes'/.test(source))
check('GET /api/permissions', /segments\[1\] === 'permissions'/.test(source))
check('POST /api/session/:id/permission', /tail === 'permission'/.test(source))

console.log('session creation:')
check('accepts workspaceId', /body\.workspaceId/.test(source))
check('accepts cwd', /body\.cwd/.test(source))
check('accepts agentPreset', /body\.agentPreset/.test(source))

console.log('services:')
check('permissionPresets.catalog()', /service\.catalog\(\)/.test(source))
check('permissionPresets.current(session)', /service\.current\(session\)/.test(source))
check('permissionPresets.set(session, value)', /service\.set\(session, body\.value\)/.test(source))
check('workspaceRegistry.list()', /registry\.list\(\)/.test(source))
check('workspace.status()', /workspace\.status\(\)/.test(source))
check('agentPresets.list()', /registry\.list\(\)/.test(source))

console.log('mode labels:')
for (const [id, label] of [
  ['standard', '普通'],
  ['ptc', 'PTC'],
  ['minimal', '极简'],
  ['cordis', '创造'],
]) {
  check(`${id} -> ${label}`, source.includes(`${id}: '${label}'`))
}

console.log('request id:')
check('prompt honours caller requestId', /body\.requestId/.test(source))
check('prompt echoes requestId', /requestId \}/.test(source))

console.log('workspace files:')
check('GET /api/session/:id/files', /tail === 'files' && req\.method === 'GET'/.test(source))
check('POST /api/session/:id/files/archive', /segments\[4\] === 'archive'/.test(source))
check('listing absolutized', /absolutize\(scope\.workspaceRoot/.test(source))
check('single file sent directly', /async function sendSingleFile/.test(source))
check('single file avoids zip wrapper', /selection\.length === 1/.test(source))
check('single file streams from disk', /createReadStream\(absolute\)/.test(source))
check('archive written to temp disk', /async function collectToDisk/.test(source))
check('archive uses createWriteStream', /createWriteStream\(archivePath\)/.test(source))
check('archive streamed back', /createReadStream\(collected\.path\)/.test(source))
check('archive cleanup on close', /collected\.cleanup\(\)/.test(source))
check('crc32 retained for central directory', /function crc32/.test(source))
check('no whole-archive buffer', !/buildZip/.test(source))
check('zip sets UTF-8 name flag', /local\.writeUInt16LE\(0x0800, 6\)/.test(source))
check('archive sets content-disposition', /filename\*=UTF-8''/.test(source))
check('single file sets content type', /contentTypeFor\(name\)/.test(source))

console.log(`\n${failures === 0 ? 'all checks passed' : `${failures} failure(s)`}`)
process.exit(failures === 0 ? 0 : 1)
