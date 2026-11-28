/**
 * Verify the bridge's question handling against a mocked request.
 *
 * The waterfall only runs when a phone is watching and the harness waits on the
 * returned promise, so both halves matter: what the phone receives, and what the
 * harness gets back. Driving the real functions is the only way to catch a
 * mismatch between the two without a live tool call.
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
const QUESTION_TIMEOUT_MS = ${/const QUESTION_TIMEOUT_MS = ([^\n]+)/.exec(source)[1]}
const pendingQuestions = new Map()
let streamCount = 0
function activeStreamCount() { return streamCount }
${take('normalizeQuestions')}
${take('awaitPhoneAnswer')}
${take('questionList')}
${take('settleQuestion')}
module.exports = {
  awaitPhoneAnswer, questionList, settleQuestion,
  pendingQuestions,
  setStreams: (n) => { streamCount = n },
}
`

const harnessPath = path.join(os.tmpdir(), `dsh-questions-${process.pid}.cjs`)
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
  console.log(`  ${ok ? '  ok  ' : '  FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`)
}

/** A logger that keeps the test output clean. */
const ctx = { logger: { info() {}, warn() {} } }

/** The question set the harness would send. */
const request = {
  agent: { id: 'session-1' },
  wait: { callId: 'call-1', timed: true },
  questions: [
    {
      id: 'q1',
      question: 'Which database?',
      header: 'Storage',
      detail: 'Applies to the new service only.',
      options: [
        { label: 'Postgres', description: 'Relational' },
        { label: 'SQLite', description: 'Embedded' },
      ],
    },
    {
      id: 'q2',
      question: 'Which features?',
      multiSelect: true,
      options: [{ label: 'Auth' }, { label: 'Cache' }],
    },
    {
      id: 'q3',
      question: 'Anything else?',
    },
  ],
}

/**
 * Wait for a pending entry to appear, so the test never races registration.
 * @returns the pending id.
 */
async function waitForPending() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    const items = api.questionList()
    if (items.length > 0) return items[0].id
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  throw new Error('no pending question appeared')
}

;(async () => {
  console.log('no phone watching:')
  {
    api.setStreams(0)
    let delegated = false
    const answer = await api.awaitPhoneAnswer(ctx, request, async () => {
      delegated = true
      return { answers: [{ id: 'q1', selected: ['Postgres'] }] }
    })
    check('delegates to the desktop answerer', delegated)
    check('returns the desktop answer', answer.answers[0].selected[0] === 'Postgres')
    check('nothing left pending', api.questionList().length === 0)
  }

  console.log('phone watching:')
  {
    api.setStreams(1)
    const promise = api.awaitPhoneAnswer(ctx, request, async () => ({ answers: [] }))
    const id = await waitForPending()
    const listed = api.questionList().find((entry) => entry.id === id)
    check('question set exposed', listed !== undefined)
    check('all three questions listed', listed.questions.length === 3, `got ${listed.questions.length}`)
    check('options preserved', listed.questions[0].options[1].label === 'SQLite')
    check('option description preserved', listed.questions[0].options[1].description === 'Embedded')
    check('multi-select flag preserved', listed.questions[1].multiSelect === true)
    check('question without options kept', listed.questions[2].options.length === 0)
    check('session reported', listed.sessionId === 'session-1')

    // A chosen option plus a typed answer, which is the "other" row.
    const settled = api.settleQuestion(id, [
      { id: 'q1', selected: ['SQLite'] },
      { id: 'q2', selected: ['Auth', 'Cache'], custom: 'and metrics' },
      { id: 'q3', selected: [], custom: 'nothing else' },
    ])
    check('settle accepted the answers', settled === true)
    const answer = await promise
    check('one answer per question', answer.answers.length === 3, `got ${answer.answers.length}`)
    check('single selection kept', answer.answers[0].selected[0] === 'SQLite')
    check('multi-select keeps labels and custom',
      answer.answers[1].selected.length === 2 && answer.answers[1].custom === 'and metrics')
    check('custom-only answer carries text', answer.answers[2].custom === 'nothing else')
    check('cleared after settle', api.questionList().length === 0)
  }

  console.log('answer shaping:')
  {
    api.setStreams(1)
    const promise = api.awaitPhoneAnswer(ctx, request, async () => ({ answers: [] }))
    const id = await waitForPending()

    check('unknown id rejected', api.settleQuestion(id, [{ id: 'nope', selected: ['x'] }]) === false)
    check('empty answer rejected', api.settleQuestion(id, [{ id: 'q1', selected: [] }]) === false)
    check('blank custom rejected', api.settleQuestion(id, [{ id: 'q1', selected: [], custom: '   ' }]) === false)

    // Answering only one question still produces a complete set.
    api.settleQuestion(id, [{ id: 'q1', selected: ['Postgres'] }])
    const answer = await promise
    check('skipped questions reported as empty',
      answer.answers.length === 3 && answer.answers[1].selected.length === 0)
    check('skipped question has no custom text', answer.answers[1].custom === undefined)
  }

  console.log('cancellation:')
  {
    api.setStreams(1)
    const controller = new AbortController()
    let delegated = false
    const promise = api.awaitPhoneAnswer(
      ctx,
      { ...request, signal: controller.signal },
      async () => {
        delegated = true
        return { answers: [] }
      }
    )
    await waitForPending()
    controller.abort()
    await promise
    check('cancellation releases to the desktop', delegated)
    check('pending cleared after cancel', api.questionList().length === 0)
  }
})()
  .catch((error) => {
    failures += 1
    console.log(`  FAIL unexpected error — ${error?.message ?? error}`)
  })
  .finally(() => {
    fs.rmSync(harnessPath, { force: true })
    console.log(failures === 0 ? '\nquestion handling verified' : `\n${failures} failure(s)`)
    process.exitCode = failures === 0 ? 0 : 1
  })
