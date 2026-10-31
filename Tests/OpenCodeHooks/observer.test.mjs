import test from "node:test"
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import { SourceTextModule, SyntheticModule } from "node:vm"
import { createContext } from "node:vm"
import { setImmediate } from "node:timers/promises"

const source = await readFile(new URL("../../Resources/OpenCodeHooks/agentdock.js", import.meta.url), "utf8")

async function harness() {
  const queue = [], timers = new Set(), requests = []
  let wake, closed = false, now = 10000
  const h = { requests, timers, network: async () => ({ ok: true }),
    advance(ms) { now += ms },
    async settle() { await setImmediate() },
    async retry() {
      const timer = timers.values().next().value
      assert.ok(timer, "a single retry should be scheduled")
      timers.delete(timer); timer.fn(); await setImmediate()
    },
    emit(type, data = {}, directory = "/project") {
      return new Promise(resolve => {
        queue.push({ event: { type, data: { sessionID: "ses_test", ...data }, location: { directory } }, resolve })
        wake?.(); wake = undefined
      })
    },
  }
  const context = createContext({ console, process: { pid: 123, execPath: "/bin/opencode" }, AbortController, AbortSignal,
    Date: class extends Date { static now() { return now } },
    setTimeout(fn, delay) { const timer = { fn, delay, unref() {} }; timers.add(timer); return timer },
    clearTimeout(timer) { timers.delete(timer) },
    fetch: async (_url, options) => {
      const payload = JSON.parse(options.body)
      requests.push(payload)
      return h.network(payload, options.signal)
    },
  })
  const module = new SourceTextModule(source, { context })
  const imports = {
    "node:fs/promises": { readFile: async () => "49152\n" },
    "node:os": { homedir: () => "/test-home" },
    "node:path": { join: (...parts) => parts.join("/") },
    "node:crypto": { randomUUID: () => "test-observer" },
  }
  await module.link(name => new SyntheticModule(Object.keys(imports[name]), function () {
    for (const [key, value] of Object.entries(imports[name])) this.setExport(key, value)
  }, { context }))
  await module.evaluate()
  const cleanup = module.namespace.default.setup({ location: { directory: "/project" }, event: {
    async *subscribe({ signal }) {
      signal.addEventListener("abort", () => { closed = true; wake?.() }, { once: true })
      while (!closed) {
        if (!queue.length) await new Promise(resolve => { wake = resolve })
        const item = queue.shift()
        if (!item) continue
        yield item.event
        item.resolve()
      }
    },
  } })
  h.close = async () => { h.network = async () => ({ ok: true }); await cleanup() }
  return h
}

async function start(h, id = "ses_test") {
  await h.emit("session.execution.started", { sessionID: id })
  await h.emit("session.step.started", { sessionID: id, assistantMessageID: "assistant", model: { providerID: "provider", id: "model" } })
}
const form = (id, description) => ({ id, sessionID: "ses_test", fields: [{ description }] })

test("cumulative usage travels with state and cannot revive stopped work", async () => {
  const h = await harness()
  try {
    await start(h)
    await h.emit("session.usage.updated", { cost: 0.12, tokens: { input: 100, output: 20, reasoning: 5, cache: { read: 30, write: 0 } } })
    await h.settle()
    assert.equal(h.requests.at(-1).usage.cost, 0.12)
    assert.equal(h.requests.at(-1).usage.tokens.input, 100)
    await h.emit("session.execution.interrupted")
    await h.emit("session.usage.updated", { cost: 0.15, tokens: { input: 120, output: 25 } })
    await h.settle()
    assert.equal(h.requests.at(-1).status, "idle")
    assert.equal(h.requests.at(-1).usage.tokens.input, 120)
    assert.equal(h.requests.at(-1).usage.cost, 0.15)
  } finally { await h.close() }
})

test("background activity cannot replace a pending question; multiple requests resolve independently", async () => {
  const h = await harness()
  try {
    await start(h)
    await h.emit("form.created", { form: form("first", "Which file?") })
    await h.emit("form.created", { form: form("second", "Which format?") })
    await h.emit("session.tool.input.started", { assistantMessageID: "assistant", id: "call", name: "read" })
    await h.settle()
    assert.equal(h.requests.at(-1).status, "waiting_approval")
    assert.equal(h.requests.at(-1).message, "Question: Which file?")
    await h.emit("form.replied", { id: "first" }); await h.settle()
    assert.equal(h.requests.at(-1).message, "Question: Which format?")
    await h.emit("form.cancelled", { id: "second" }); await h.settle()
    assert.equal(h.requests.at(-1).status, "working")
    assert.equal(h.requests.at(-1).message, "read")
  } finally { await h.close() }
})

test("slow bridge cannot block ingestion or build an activity backlog ahead of stop", async () => {
  const h = await harness()
  let release
  h.network = (_payload, signal) => new Promise((resolve, reject) => {
    release = resolve
    signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true })
  })
  try {
    await start(h)
    for (let i = 0; i < 100; i++) {
      await h.emit("session.tool.input.started", { assistantMessageID: "assistant", id: String(i), name: "tool " + i })
    }
    await h.emit("session.execution.interrupted")
    assert.equal(h.requests.length, 1, "only one network request may be in flight")
    h.network = async () => ({ ok: true }); release({ ok: true }); await h.settle()
    assert.equal(h.requests.length, 2)
    assert.equal(h.requests.at(-1).status, "idle")
  } finally { await h.close() }
})

test("failed start and HTTP errors retry the latest complete state with one backoff timer", async () => {
  const h = await harness()
  h.network = async () => ({ ok: false })
  try {
    await start(h); await h.settle()
    assert.equal(h.timers.size, 1)
    await h.emit("form.created", { form: form("question", "Proceed?") })
    await h.settle(); assert.equal(h.timers.size, 1)
    h.network = async () => ({ ok: true })
    await h.retry()
    assert.equal(h.requests.at(-1).status, "waiting_approval")
    assert.equal(h.requests.at(-1).message, "Question: Proceed?")
    assert.equal(h.requests.at(-1).turn, 1)
    assert.equal(h.timers.size, 0)
  } finally { await h.close() }
})

test("event-driven refresh can restore unchanged activity after a dock restart without idle polling", async () => {
  const h = await harness()
  try {
    await start(h)
    await h.emit("session.text.started", { assistantMessageID: "assistant", ordinal: 1 })
    await h.emit("session.text.ended", { assistantMessageID: "assistant", ordinal: 1, text: "Stable activity" })
    await h.settle(); const count = h.requests.length
    assert.equal(h.timers.size, 0)
    h.advance(5000)
    await h.emit("session.text.ended", { assistantMessageID: "assistant", ordinal: 1, text: "Stable activity" })
    await h.settle()
    assert.equal(h.requests.length, count + 1)
    assert.equal(h.requests.at(-1).status, "working")
    assert.equal(h.requests.at(-1).message, "Response: Stable activity")
    assert.equal(h.timers.size, 0)
  } finally { await h.close() }
})

test("completion is terminal, later activity is ignored, and a new turn gets a new identity", async () => {
  const h = await harness()
  try {
    await start(h)
    await h.emit("session.execution.succeeded"); await h.settle()
    assert.equal(h.requests.at(-1).status, "completed")
    const count = h.requests.length
    await h.emit("session.tool.called", { assistantMessageID: "assistant", id: "late", input: { command: "late command" } })
    await h.settle(); assert.equal(h.requests.length, count)
    await start(h); await h.settle()
    assert.equal(h.requests.at(-1).turn, 2)
    assert.equal(h.requests.at(-1).status, "working")
  } finally { await h.close() }
})

test("native errors retain available detail and workspace events stay isolated", async () => {
  const h = await harness()
  try {
    await h.emit("session.execution.started", { sessionID: "ses_other" }, "/other")
    await h.settle(); assert.equal(h.requests.length, 0)
    await start(h)
    await h.emit("session.execution.failed", { error: { message: "Provider unavailable" } })
    await h.settle()
    assert.equal(h.requests.at(-1).status, "error")
    assert.equal(h.requests.at(-1).message, "Provider unavailable")
  } finally { await h.close() }
})

test("live session retention is bounded and unloading uses one scoped disconnect", async () => {
  const h = await harness()
  try {
    for (let i = 0; i < 300; i++) await h.emit("session.execution.started", { sessionID: "ses_" + i })
    await h.settle()
    assert.equal(new Set(h.requests.map(p => p.sessionID)).size, 256)
    await h.close()
    assert.equal(h.requests.filter(p => p.event === "disconnect").length, 1)
    assert.equal(h.timers.size, 0)
  } finally { /* already closed */ }
})
