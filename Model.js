// Pure parsing and validation helpers for Omaspot. Keeping these outside the
// QML entry point makes the backend protocol easy to test without Quickshell.

function defaults() {
  return {
    ssid: "Omaspot",
    password: "omaspot123",
    band: "2.4",
    channelMode: "auto",
    channel: "1",
    upstream: "auto",
    lastState: "inactive"
  }
}

function parseState(raw) {
  var result = defaults()
  if (!raw || String(raw).trim() === "") return result

  try {
    var value = JSON.parse(String(raw)) || {}
    var keys = ["ssid", "password", "band", "channelMode", "channel", "upstream", "lastState"]
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      if (value[key] !== undefined && value[key] !== null)
        result[key] = String(value[key])
    }
  } catch (e) {
    // A malformed state should never stop the shell. Defaults remain usable.
  }

  if (result.band !== "2.4" && result.band !== "5") result.band = "2.4"
  if (result.channelMode !== "auto" && result.channelMode !== "manual") result.channelMode = "auto"
  if (result.ssid === "") result.ssid = "Omaspot"
  return result
}

function parseStatus(raw) {
  var line = String(raw || "").trim().split(/\r?\n/)[0] || "inactive"
  var fields = line.split("\t")
  return {
    state: fields[0] === "active" ? "active" : "inactive",
    hotspotInterface: fields[1] || "",
    pid: fields[2] || "",
    upstream: fields[3] || ""
  }
}

function parseInterfaces(raw) {
  var lines = String(raw || "").split(/\r?\n/)
  var result = []
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].split("\t")
    var name = String(fields[0] || "").trim()
    var type = String(fields[1] || "").trim()
    if (name === "" || seen[name]) continue
    seen[name] = true
    result.push({ value: name, label: name + (type ? " · " + type : "") })
  }
  return result
}

function parseAsciiQr(raw) {
  // qrencode's ASCII renderer uses two characters per QR module and retains
  // the quiet zone. Do not trim lines: leading/trailing spaces are data.
  var lines = String(raw || "").replace(/\r/g, "").split("\n")
  while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
  if (lines.length === 0) return { rows: [], size: 0 }

  var maxWidth = 0
  for (var i = 0; i < lines.length; i++) maxWidth = Math.max(maxWidth, lines[i].length)
  if (maxWidth < 21 || maxWidth % 2 !== 0 || lines.length !== maxWidth / 2)
    return { rows: [], size: 0 }

  var rows = []
  for (var r = 0; r < lines.length; r++) {
    var line = lines[r]
    while (line.length < maxWidth) line += " "
    var row = ""
    for (var c = 0; c < maxWidth; c += 2)
      row += (line.charAt(c) === "#" || line.charAt(c + 1) === "#") ? "1" : "0"
    rows.push(row)
  }
  return { rows: rows, size: rows.length }
}

function parseClients(raw) {
  // Backend protocol: one device per line, tab separated, as
  // mac, ip, hostname, state. Every field is re-validated here so a malformed
  // or spoofed backend response still cannot put unexpected text in the flyout.
  var lines = String(raw || "").replace(/\r/g, "").split("\n")
  var result = []
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() === "") continue
    var fields = lines[i].split("\t")
    if (fields.length < 4) continue

    var mac = String(fields[0] || "").trim()
    var ip = String(fields[1] || "").trim()
    var name = String(fields[2] || "").trim()
    var state = String(fields[3] || "").trim()

    if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac)) continue
    if (seen[mac]) continue
    seen[mac] = true

    if (ip !== "*" && !/^([0-9]{1,3}\.){3}[0-9]{1,3}$/.test(ip)) ip = "*"
    if (!/^[A-Za-z0-9._-]{1,64}$/.test(name)) name = mac

    result.push({ mac: mac, ip: ip, name: name, connected: state === "connected" })
  }
  return result
}

// Dependency report from `omaspotctl doctor`.
//
// Per dependency line: state <TAB> command <TAB> package <TAB> level, where
// state is ok|missing and level is blocking|optional. A final
// `install <TAB> <command>` line appears only when something blocking is
// absent. Only missing entries are returned; `blocking` is what gates the UI.
function parseDoctor(raw) {
  var lines = String(raw || "").replace(/\r/g, "").split("\n")
  var blocking = []
  var optional = []
  var install = ""
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() === "") continue
    var fields = lines[i].split("\t")
    if (fields[0] === "install") {
      // Only ever offer to copy a plain pacman invocation. The backend is
      // trusted, but this string lands on the clipboard, so it is constrained
      // here rather than passed through unchecked.
      var candidate = String(fields[1] || "").trim()
      if (/^yay -S --needed( [A-Za-z0-9._+-]+)+$/.test(candidate)) install = candidate
      continue
    }
    if (fields.length < 4 || fields[0] !== "missing") continue
    var pkg = String(fields[2] || "").trim()
    if (!/^[A-Za-z0-9._+-]+$/.test(pkg)) continue
    var entry = { command: String(fields[1] || "").trim(), package: pkg }
    if (fields[3] === "optional") optional.push(entry)
    else blocking.push(entry)
  }
  return { blocking: blocking, optional: optional, install: install }
}

function validChannel(value) {
  return /^(1|2|3|4|5|6|7|8|9|10|11|12|13|14|36|40|44|48|52|56|60|64|100|104|108|112|116|120|124|128|132|136|140|144|149|153|157|161|165)$/.test(String(value))
}

function validate(state) {
  var errors = []
  if (!state.ssid || state.ssid.length < 1 || state.ssid.length > 32)
    errors.push("Hotspot name must be 1–32 characters")
  if (!state.password || state.password.length < 8 || state.password.length > 63)
    errors.push("Security key must be 8–63 characters")
  if (state.channelMode === "manual" && !validChannel(state.channel))
    errors.push("Choose a valid Wi-Fi channel")
  return errors
}

if (typeof module !== "undefined") {
  module.exports = {
    defaults: defaults,
    parseState: parseState,
    parseStatus: parseStatus,
    parseInterfaces: parseInterfaces,
    parseClients: parseClients,
    parseDoctor: parseDoctor,
    parseAsciiQr: parseAsciiQr,
    validChannel: validChannel,
    validate: validate
  }
}
