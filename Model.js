.pragma library

// Presentation logic for the Port Manager panel. Kept out of the QML so the
// bindings stay declarative and the string shaping is testable in isolation.

var GROUP_DEV = "dev"
var GROUP_OTHER = "other"
var GROUP_SYSTEM = "system"

function parseResult(text) {
  try {
    var result = JSON.parse(String(text || "{}"))
    if (!result || typeof result !== "object") return { ok: false, ports: [], error: "Unreadable response." }
    return result
  } catch (e) {
    return { ok: false, ports: [], error: "Unable to read listening ports." }
  }
}

// A row matches when every whitespace-separated term appears somewhere in it,
// so "vite 3000" and "3000 vite" both find the same server.
function matches(row, query) {
  var q = String(query || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  if (q === "") return true
  var haystack = [
    row.port, row.protocol, row.process, row.pid,
    row.project, row.stack, row.address, row.cwd
  ].join(" ").toLowerCase()
  var terms = q.split(/\s+/)
  for (var i = 0; i < terms.length; i++) {
    if (haystack.indexOf(terms[i]) < 0) return false
  }
  return true
}

function inGroup(ports, group) {
  var out = []
  for (var i = 0; i < ports.length; i++) if (ports[i].group === group) out.push(ports[i])
  return out
}

function filtered(ports, query) {
  var out = []
  for (var i = 0; i < ports.length; i++) if (matches(ports[i], query)) out.push(ports[i])
  return out
}

// The flat list the cursor walks: dev servers always, the other two sections
// only while they are expanded. Keeping one array means j/k crosses section
// headers without the panel tracking a section index.
function visibleRows(ports, query, showOther, showSystem) {
  var rows = filtered(ports, query)
  var out = inGroup(rows, GROUP_DEV)
  if (showOther) out = out.concat(inGroup(rows, GROUP_OTHER))
  if (showSystem) out = out.concat(inGroup(rows, GROUP_SYSTEM))
  return out
}

function countExposed(ports) {
  var n = 0
  for (var i = 0; i < ports.length; i++) if (ports[i].group === GROUP_DEV && ports[i].exposed) n++
  return n
}

function formatUptime(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h " + (m % 60) + "m"
  var d = Math.floor(h / 24)
  return d + "d " + (h % 24) + "h"
}

function formatMemory(bytes) {
  var b = Number(bytes) || 0
  if (b <= 0) return ""
  var mb = b / (1024 * 1024)
  if (mb < 1024) return Math.round(mb) + " MB"
  return (mb / 1024).toFixed(1) + " GB"
}

// The bold line of a row. A project name is the most useful label a dev
// server has; the stack or the process name stands in when there is none.
function rowTitle(row) {
  if (row.project) return row.project
  if (row.container) return "container " + row.container
  if (row.stack) return row.stack
  if (row.process && row.process !== "unknown") return row.process
  if (row.service) return row.service
  return "System service"
}

// The quiet line under it: whatever is true and not already in the title.
function rowMeta(row) {
  var parts = []
  if (row.project && row.stack) parts.push(row.stack)
  if (row.process && row.process !== "unknown" && row.process !== row.stack.toLowerCase())
    parts.push(row.process)
  if (row.pid) parts.push("PID " + row.pid)
  if (row.uptime) parts.push(formatUptime(row.uptime))
  var mem = formatMemory(row.memory)
  if (mem) parts.push(mem)
  if (!row.mine) parts.push("not yours")
  return parts.join("  ·  ")
}

function rowProtocol(row) {
  return row.protocol === "TCP" ? "" : row.protocol
}

function exposureLabel(row) {
  return row.exposed ? "EXPOSED" : "LOCAL"
}

function exposureTooltip(row) {
  return row.exposed
    ? "Bound to " + row.address + " — reachable from your network"
    : "Bound to " + row.address + " — this machine only"
}

function canOpen(row) {
  return !!row.url
}

// The bar tooltip wants the whole picture in one line.
function headline(ports) {
  var exposed = countExposed(ports)
  var parts = [heroMeta(ports)]
  if (exposed > 0) parts.push(exposed + " exposed")
  return parts.join("  ·  ")
}

// The panel hero says only the count; the pill beside it already carries
// the exposure warning, and saying it twice reads as a stutter.
function heroMeta(ports) {
  var dev = inGroup(ports, GROUP_DEV).length
  return dev + (dev === 1 ? " dev server" : " dev servers")
}

function barLabel(ports) {
  return String(inGroup(ports, GROUP_DEV).length)
}

function stopResultText(result, name, force) {
  if (!result.ok) return result.error || "Could not stop the process."
  if (result.exited) return "Stopped " + name + "."
  if (force) return name + " did not exit."
  return name + " is still shutting down. Press X to force."
}
