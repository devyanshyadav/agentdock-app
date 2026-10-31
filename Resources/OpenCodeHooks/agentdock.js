import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { randomUUID } from "node:crypto"

const requestTimeoutMs = 2_000

// One bounded outbox per observer. Event ingestion never waits for bridge I/O.
const observe = (directory) => {
  const sourceID = randomUUID()
  const sourceStartedAt = Date.now()
  const sessions = new Map()
  const pending = new Map()
  const preview = (text) => typeof text === "string" ? text.slice(0, 512).trim().split(/\r?\n/, 1)[0].slice(0, 240) : ""
  let sequence = 0, worker, request, transmittingID, retryTimer, retryDelay = 1000, disposed = false

  const post = async (payload, signal) => {
    // No port or secret means the app is not running: fail (and retry later) rather than guess a port.
    const directory = join(homedir(), "Library/Application Support/AgentDock")
    const [raw, token] = (await Promise.all([readFile(join(directory, "bridge-port"), "utf8"),
      readFile(join(directory, "bridge-token"), "utf8")])).map((value) => value.trim())
    if (!/^[0-9A-Fa-f-]+$/.test(token)) throw new Error("Invalid bridge secret")
    const port = Number(raw)
    if (!/^\d+$/.test(raw) || port < 1024 || port > 65535) throw new Error("Invalid bridge port")
    const response = await fetch(`http://127.0.0.1:${port}/opencode-event`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-AgentDock-Ppid": String(process.pid), "X-AgentDock-Token": token },
      body: JSON.stringify(payload), signal,
    })
    await response.body?.cancel()
    if (!response.ok) throw new Error("Bridge rejected state")
  }
  const flush = () => {
    if (disposed || worker || retryTimer || !pending.size) return
    worker = (async () => {
      while (!disposed && pending.size) {
        const [id, payload] = pending.entries().next().value
        pending.delete(id)
        transmittingID = id
        request = new AbortController()
        try {
          await post(payload, AbortSignal.any([request.signal, AbortSignal.timeout(requestTimeoutMs)]))
          retryDelay = 1000
        } catch {
          if (disposed) break
          // A newer state (especially completion) supersedes a failed in-flight update.
          if (!pending.has(id)) pending.set(id, payload)
          retryTimer = setTimeout(() => { retryTimer = undefined; flush() }, retryDelay)
          retryTimer.unref?.()
          retryDelay = Math.min(retryDelay * 2, 30000)
          break
        } finally { request = undefined; transmittingID = undefined }
      }
    })().finally(() => { worker = undefined; flush() })
  }
  const publish = (id, state, force = false) => {
    const status = state.live ? (state.approvals.size ? "waiting_approval" : "working") : state.status
    const message = state.approvals.values().next().value ?? state.lastText
    const signature = [state.turn, status, state.model, message, JSON.stringify(state.usage)].join("|")
    // A small event-driven refresh also restores live state after AgentDock restarts.
    // There is no timer or network work for successfully delivered, quiet sessions.
    if (!force && signature === state.signature && Date.now() - state.publishedAt < 5000) return
    state.signature = signature; state.publishedAt = Date.now()
    pending.set(id, { sessionID: id, sourceID, sourceStartedAt, turn: state.turn, sequence: ++sequence,
      status, message, model: state.model, usage: state.usage,
      environment: process.execPath.includes(".app/") ? "dedicatedWindow" : "cli" })
    if (force && retryTimer) { clearTimeout(retryTimer); retryTimer = undefined }
    flush()
  }
  const retain = (id) => {
    if (sessions.has(id)) return sessions.get(id)
    if (sessions.size >= 256) {
      let evicted = false
      for (const [oldID, state] of sessions) {
        if (state.live || pending.has(oldID) || transmittingID === oldID) continue
        sessions.delete(oldID); evicted = true; break
      }
      if (!evicted) return
    }
    const state = { live: false, turn: 0, status: "idle", model: "", assistant: "", approvals: new Map(),
      tools: new Map(), lastText: "", lastProgress: 0, publishedAt: 0, signature: "" }
    sessions.set(id, state)
    return state
  }
  const progress = (id, state, text, immediate = false) => {
    text = preview(text)
    if (!state.live || !text) return
    if (state.lastText === text) { publish(id, state); return }
    state.lastText = text
    if (!immediate && Date.now() - state.lastProgress < 100) return
    state.lastProgress = Date.now()
    publish(id, state)
  }
  const finish = (id, state, status, message) => {
    if (!state.live) return
    state.live = false; state.status = status; state.approvals.clear(); state.tools.clear()
    state.part = undefined
    if (message) state.lastText = message
    publish(id, state, true)
  }
  return {
    event(event) {
      const p = event.data ?? {}
      const id = p.sessionID ?? p.form?.sessionID
      if (typeof id !== "string" || !id.startsWith("ses_") || id.length > 256) return
      const location = event.location?.directory ?? p.location?.directory
      if (location ? location !== directory : !sessions.has(id)) return
      const state = retain(id)
      if (!state) return
      if (event.type === "session.usage.updated") {
        // This event reports cumulative session totals. Never add per-step costs again.
        const number = value => typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined
        const tokens = p.tokens ?? {}
        state.usage = { cost: number(p.cost), tokens: {
          input: number(tokens.input), output: number(tokens.output), reasoning: number(tokens.reasoning),
          cache: { read: number(tokens.cache?.read), write: number(tokens.cache?.write) },
        } }
        if (state.turn > 0) publish(id, state, true)
        return
      }
      if (event.type === "session.execution.started") {
        if (state.live) return
        state.live = true; state.turn++; state.approvals.clear(); state.tools.clear()
        state.assistant = ""; state.part = undefined; state.lastText = ""; state.lastProgress = 0
        publish(id, state, true); return
      }
      if (event.type === "session.execution.succeeded") { finish(id, state, "completed"); return }
      if (event.type === "session.execution.interrupted") { finish(id, state, "idle"); return }
      if (event.type === "session.execution.failed") {
        finish(id, state, "error", preview(p.error?.message) || "OpenCode reported an error"); return
      }
      if (event.type === "session.deleted") {
        finish(id, state, "idle")
        // Keep an undelivered terminal state until it is acknowledged.
        if (!pending.has(id) && transmittingID !== id) sessions.delete(id)
        return
      }
      if (event.type === "session.created" || event.type === "session.model.selected" || event.type === "session.step.started") {
        if (event.type === "session.step.started") { state.assistant = p.assistantMessageID; state.part = undefined }
        const model = [p.model?.providerID, p.model?.id].filter(Boolean).join("/")
        if (model) state.model = model
        if (state.live) publish(id, state)
        return
      }
      if (!state.live) return
      if (event.type === "session.retry.scheduled") { progress(id, state, preview(p.error?.message) || "Retrying response", true); return }
      if (p.assistantMessageID === state.assistant) {
        const match = /^session\.(text|reasoning)\.(started|delta|ended)$/.exec(event.type)
        if (match) {
          const [, kind, phase] = match
          if (phase === "started") state.part = { kind, ordinal: p.ordinal, text: "" }
          const part = state.part
          if (!part || part.kind !== kind || part.ordinal !== p.ordinal) return
          if (phase === "delta") part.text = (part.text + (typeof p.delta === "string" ? p.delta.slice(0, 240) : "")).slice(0, 240)
          if (phase === "ended") part.text = preview(p.text)
          if (!part.text) return
          progress(id, state, `${kind === "reasoning" ? "Thought" : "Response"}: ${part.text}`, phase === "ended"); return
        }
        if (event.type === "session.tool.input.started") {
          if (state.tools.size < 128) state.tools.set(p.id, preview(p.name))
          progress(id, state, preview(p.name), true); return
        }
        if (event.type === "session.tool.called") {
          const input = p.input ?? {}
          const detail = preview(input.command) || preview(input.filePath) || preview(input.pattern)
          const name = state.tools.get(p.id) || "Tool"
          progress(id, state, `${name}${detail ? ": " + detail : ""}`, true); return
        }
        if (event.type === "session.tool.success" || event.type === "session.tool.failed") state.tools.delete(p.id)
      }
      if (event.type === "permission.asked" || event.type === "form.created") {
        const form = event.type === "form.created"
        const requestID = form ? p.form?.id : p.id
        if (typeof requestID !== "string") return
        const fields = form && Array.isArray(p.form?.fields) ? p.form.fields : []
        const field = fields.find(field => !field.hidden && (preview(field.description) || preview(field.title)))
        const text = form ? `Question: ${preview(field?.description) || preview(field?.title) || preview(p.form?.title) || "Needs your input"}`
          : `Permission: ${preview(p.action) || "Needs approval"}`
        state.approvals.set(`${form ? "form" : "permission"}:${requestID}`, text)
        publish(id, state); return
      }
      if (event.type === "permission.replied" || event.type === "form.replied" || event.type === "form.cancelled") {
        const key = event.type === "permission.replied" ? `permission:${p.requestID}` : `form:${p.id}`
        if (state.approvals.delete(key)) publish(id, state)
      }
    },
    async dispose() {
      disposed = true; clearTimeout(retryTimer); pending.clear(); request?.abort()
      await worker
      if (![...sessions.values()].some(state => state.live)) return
      try {
        await post({ event: "disconnect", sourceID }, AbortSignal.timeout(requestTimeoutMs))
      } catch { /* Cleanup is one best-effort request, never one timeout per session. */ }
    },
  }
}

export default {
  id: "agentdock",
  setup(ctx) {
    const directory = ctx.location.directory
    const observer = observe(directory)
    const controller = new AbortController()
    const subscription = (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          if (controller.signal.aborted) break
          observer.event(event)
        }
      } catch { /* OpenCode and its normal permission flow stay independent of the dock. */ }
      finally { await observer.dispose() }
    })()
    return async () => { controller.abort(); await subscription }
  },
}
