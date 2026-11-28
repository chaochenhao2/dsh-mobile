/**
 * Verify that the phone and the desktop race, and the first answer wins.
 *
 * Both halves are offered the prompt at the same time. Whichever returns first
 * settles it, and the other is ignored — including a desktop answer that arrives
 * after the phone already replied, which is the case a naive implementation gets
 * wrong by resolving twice or leaving a stale card behind.
 */

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')

const BRIDGE = path.join(__dirname, '..', 'dsh-mobile-bridge', 'bridge.js')
const source = fs.readFileSync(BRIDGE, 'utf8')

/**
 * Cut a top-level function out of the plugin source, keeping `async`.
 * @param name - the function name.
 * @returns its source text.
 */
function take(name) {
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

const harness = `
const { randomUUID } = require('node:crypto')
const pendingApprovals = new Map()
const pendingQuestions = new Map()
${take('normalizeQuestions')}
${take('awaitPhoneApproval')}
${take('awaitPhoneAnswer')}
${take('approvalList')}
${take('questionList')}
${take('settleApproval')}
${take('settleQuestion')}
module.exports = {
  awaitPhoneApproval, awaitPhoneAnswer,
  approvalList, questionList,
  settleApproval, settleQuestion,
}
`

const harnessPath = path.join(os.tmpdir(), `dsh-race-${process.pid}.cjs`)
fs.writeFileSync(harnessPath, harness, 'utf8')
const api = require(harnessPath)

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

/** A logger that keeps output clean. */
const ctx = { logger: { info() {}, warn() {} } }

/**
 * Wait for a pending entry, so a test never races registration.
 * @param list - the function returning pending items.
 * @returns the pending id.
 */
async function waitFor(list) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const items = list()
    if (items.length > 0) return items[0].id
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error('nothing became pending')
}

/**
 * A desktop answerer that resolves only when released.
 * @param outcome - the value it should return.
 * @returns the answerer plus its release control.
 */
function deferredDesktop(outcome) {
  let release
  const promise = new Promise((resolve) => { release = () => resolve(outcome) })
  return { next: () => promise, release }
}

const approvalRequest = { toolName: 'bash', reason: 'run a command' }
const questionRequest = {
  agent: { id: 'session-1' },
  questions: [{ id: 'q1', question: 'Pick one', options: [{ label: 'A' }, { label: 'B' }] }],
}

;(async () => {
  console.log('phone answers first:')
  {
    const desktop = deferredDesktop('rejected')
    const promise = api.awaitPhoneApproval(ctx, approvalRequest, desktop.next)
    const id = await waitFor(api.approvalList)
    check('prompt is offered to the phone immediately', id !== undefined)
    api.settleApproval(id, true)
    const outcome = await promise
    check('phone answer wins', outcome === 'allowed-once', `got ${outcome}`)
    check('card cleared', api.approvalList().length === 0)
    // The desktop later answers; it must not change anything.
    desktop.release()
    await new Promise((resolve) => setTimeout(resolve, 30))
    check('late desktop answer is ignored', api.approvalList().length === 0)
  }

  console.log('desktop answers first:')
  {
    const desktop = deferredDesktop('rejected')
    const promise = api.awaitPhoneApproval(ctx, approvalRequest, desktop.next)
    const id = await waitFor(api.approvalList)
    desktop.release()
    const outcome = await promise
    check('desktop answer wins', outcome === 'rejected', `got ${outcome}`)
    check('phone card disappears without answering', api.approvalList().length === 0)
    check('answering the stale card is refused', api.settleApproval(id, true) === false)
  }

  console.log('no stream required:')
  {
    // Both handlers must offer the prompt even with no phone streaming, which is
    // what makes "whichever side answers" true rather than "phone only".
    const desktop = deferredDesktop('allowed-once')
    const promise = api.awaitPhoneApproval(ctx, approvalRequest, desktop.next)
    const id = await waitFor(api.approvalList)
    check('prompt exists before any stream opens', id !== undefined)
    desktop.release()
    await promise
    check('desktop resolved it', api.approvalList().length === 0)
  }

  console.log('questions race the same way:')
  {
    const desktop = deferredDesktop({ answers: [{ id: 'q1', selected: ['B'] }] })
    const promise = api.awaitPhoneAnswer(ctx, questionRequest, desktop.next)
    const id = await waitFor(api.questionList)
    check('question offered to the phone', id !== undefined)
    api.settleQuestion(id, [{ id: 'q1', selected: [], custom: 'something else' }])
    const answer = await promise
    check('phone answer wins', answer.answers[0].custom === 'something else')
    check('question card cleared', api.questionList().length === 0)
    desktop.release()
    await new Promise((resolve) => setTimeout(resolve, 30))
    check('late desktop answer ignored', api.questionList().length === 0)
  }

  console.log('desktop answers a question first:')
  {
    const desktop = deferredDesktop({ answers: [{ id: 'q1', selected: ['A'] }] })
    const promise = api.awaitPhoneAnswer(ctx, questionRequest, desktop.next)
    await waitFor(api.questionList)
    desktop.release()
    const answer = await promise
    check('desktop answer returned', answer.answers[0].selected[0] === 'A')
    check('phone card disappears', api.questionList().length === 0)
  }

  console.log('cancellation:')
  {
    const controller = new AbortController()
    const desktop = deferredDesktop('allowed-once')
    const promise = api.awaitPhoneApproval(
      ctx,
      { ...approvalRequest, signal: controller.signal },
      desktop.next
    )
    await waitFor(api.approvalList)
    controller.abort()
    const outcome = await promise
    check('cancellation settles the request', outcome === 'cancelled', `got ${outcome}`)
    check('card cleared on cancel', api.approvalList().length === 0)
  }
})()
  .catch((error) => {
    failures += 1
    console.log(`  FAIL unexpected error — ${error?.message ?? error}`)
  })
  .finally(() => {
    fs.rmSync(harnessPath, { force: true })
    console.log(failures === 0 ? '\nrace verified' : `\n${failures} failure(s)`)
    process.exitCode = failures === 0 ? 0 : 1
  })
