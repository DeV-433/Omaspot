import QtQuick
// QtQuick.Controls is only needed for ScrollBar on the devices list. It is
// imported before qs.Ui on purpose: QML resolves an unqualified type name to
// the most recent matching import, so keeping qs.Ui last means Button,
// TextField and ToggleSwitch still resolve to the Omarchy widgets rather than
// the Controls ones.
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.devanshu.omaspot"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property string status: "inactive"
  property string hotspotInterface: ""
  property string statusError: ""
  property real lastStatusTickMs: 0
  property string errorMessage: ""
  // Why the last hotspot stopped on its own (suspend, link loss, create_ap
  // exiting). Unlike errorMessage it does not time out, so it is still there
  // when the panel is opened long after the fact; the next start clears it.
  // Diagnostic report for the error on screen, straight from the backend's
  // output. Kept in memory only: the next error or a shell restart drops it.
  property string errorReport: ""
  property bool logCopied: false
  // A failed start reports through three signals in no fixed order (exit,
  // stdout report, stderr headline); finishStart() waits for all of them.
  property string startReport: ""
  property string startStderr: ""
  property int startExitCode: 0
  property bool startExited: false
  property bool startOutDone: false
  property bool startErrDone: false
  // The one error the card shows, most immediate first, already split into
  // title / hint / whether a full log can be copied.
  readonly property string activeError: errorMessage !== "" ? errorMessage : statusError
  readonly property var errorInfo: Model.parseError(activeError)
  readonly property string bandLabel: band === "5" ? "5 GHz" : "2.4 GHz"
  readonly property int connectedCount: {
    var n = 0
    for (var i = 0; i < connectedDevices.length; i++) if (connectedDevices[i].connected) n++
    return n
  }
  readonly property string heroMeta: depsBlocked ? "Hotspot support is not installed"
    : status === "starting" ? "Starting…"
    : status === "stopping" ? "Stopping…"
    : hotspotActive ? (connectedCount === 1 ? "On · 1 device connected" : "On · " + connectedCount + " devices connected")
    : "Off · Personal Wi-Fi hotspot"
  readonly property var cardChips: [
    bandLabel,
    channelMode === "manual" ? "Channel " + channel : "Auto channel",
    hotspotActive && hotspotInterface !== "" ? "via " + hotspotInterface
      : upstream === "auto" ? "Auto source" : "via " + upstream
  ]
  readonly property real settingsLabelWidth: Style.space(64)
  // The flyout's type runs one step above the kit defaults; the headline a
  // little more. Kit components that take a size get these passed in.
  readonly property int fontStep: 1
  readonly property int fontCaption: Style.font.caption + fontStep
  readonly property int fontBodySmall: Style.font.bodySmall + fontStep
  readonly property int fontBody: Style.font.body + fontStep
  readonly property int fontSubtitle: Style.font.subtitle + fontStep
  readonly property int fontHeadline: Style.font.title + 3
  // Field labels match the kit's Dropdown label; hairline is a quiet rule
  // that does not compete with the theme's (often bright) popup border.
  readonly property color labelColor: Qt.darker(foreground, 1.4)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  property string ssid: "Omaspot"
  property string password: "omaspot123"
  property string band: "2.4"
  property string channelMode: "auto"
  property string channel: "1"
  property string upstream: "auto"
  property var upstreamOptions: [{ value: "auto", label: "Auto-detect" }]
  property bool settingsLoaded: false
  property bool qrReady: false
  property var qrRows: []
  property int qrSize: 0
  property bool passwordVisible: false
  property bool startPending: false
  property var connectedDevices: []
  // `depsBlocked` hides the hotspot controls until create_ap is installed.
  property var missingBlocking: []
  property string installCommand: ""
  property bool installCopied: false
  property var pasteJob: null
  property var pasteTargetField: null
  property string pasteSnapshot: ""
  property int pasteSnapshotCursor: -1
  property int pasteSnapshotSelectionStart: -1
  property int pasteSnapshotSelectionEnd: -1

  readonly property string moduleId: "io.github.devanshu.omaspot"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"
  readonly property string statePath: stateDir + "/" + moduleId + ".json"
  readonly property string backendPath: String(Qt.resolvedUrl("backend/omaspotctl")).replace(/^file:\/\//, "")
  readonly property bool busy: status === "starting" || status === "stopping"
  readonly property bool hotspotActive: status === "active"
  readonly property bool settingsEditable: !hotspotActive && !busy
  readonly property bool depsBlocked: missingBlocking.length > 0
  readonly property string statusLabel: status === "active" ? "Active"
    : status === "starting" ? "Starting…"
    : status === "stopping" ? "Stopping…" : "Inactive"
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color statusColor: status === "active" ? Commons.Color.accent
    : (status === "starting" || status === "stopping") ? Commons.Color.accent
    : statusError !== "" || errorMessage !== "" ? Commons.Color.urgent : Commons.Color.muted

  function open() {
    root.controller.show()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    cancelPendingPaste()
    root.controller.hide()
    passwordVisible = false
  }

  function toggle() { root.opened ? root.close() : root.open() }
  function closeForPopoutSwitch() { root.close() }

  function injectBar() {
    if (hostWidget) root.bar = hostWidget.bar
  }

  function loadState(raw) {
    var state = Model.parseState(raw)
    ssid = state.ssid
    password = state.password
    band = state.band
    channelMode = state.channelMode
    channel = state.channel
    upstream = state.upstream
    settingsLoaded = true
    if (upstreamOptions.length === 1 && upstream !== "auto")
      upstreamOptions = [{ value: "auto", label: "Auto-detect" }, { value: upstream, label: upstream + " · saved" }]
  }

  function saveState() {
    if (!settingsLoaded) return
    var state = {
      ssid: ssid,
      password: password,
      band: band,
      channelMode: channelMode,
      channel: channel,
      upstream: upstream
    }
    stateFile.setText(JSON.stringify(state, null, 2) + "\n")
  }

  // report: the backend's diagnostic report for this error, if it sent one.
  function showError(message, report) {
    var clean = String(message || "").replace(/^omaspot:\s*/i, "").trim()
    if (clean === "") clean = "The hotspot operation failed"
    var info = Model.parseError(clean)
    errorMessage = clean
    errorReport = String(report || "").trim()
    logCopied = false
    var body = info.hint !== "" ? info.title + "\n" + info.hint : info.title
    if (errorReport !== "") body += "\nOpen Omaspot to copy the log."
    notifyProc.command = ["notify-send", "--expire-time=15000", "--urgency=normal", "--app-name=Omaspot", "Omaspot", body]
    notifyProc.running = true
    // An error with a log stays until dismissed or the next action, so it is
    // still there to copy when the panel is opened later in this session.
    if (errorReport !== "") errorTimer.stop()
    else errorTimer.restart()
  }

  function clearError() {
    errorMessage = ""
    statusError = ""
    errorReport = ""
    logCopied = false
  }

  // Passed as an argument, not through a shell, so the report is never
  // re-parsed; "--" keeps a leading dash from reading as an option.
  function copyErrorLog() {
    if (errorReport === "") return
    Quickshell.execDetached(["wl-copy", "--", errorReport])
    logCopied = true
    logCopiedTimer.restart()
  }

  function finishStart(force) {
    if (!startExited) return
    if (!force && !(startOutDone && startErrDone)) return
    startExited = false
    startFinishTimer.stop()
    showError(startStderr !== "" ? startStderr
      : startExitCode === 126 ? "Polkit authorization was cancelled" : "Could not start the hotspot",
      startReport)
  }

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshInterfaces() {
    if (!interfacesProc.running) interfacesProc.running = true
  }

  // Dependency check. Runs on every open so returning from a terminal after
  // installing the package immediately reveals the working UI again.
  function refreshDependencies() {
    if (!dependencyProc.running) dependencyProc.running = true
  }

  function applyDependencies(raw) {
    var report = Model.parseDoctor(raw)
    var wasBlocked = root.depsBlocked
    missingBlocking = report.blocking
    installCommand = report.install
    // Refresh the rest of the panel once, the moment the gate opens. Deliberately
    // not refreshAll(): that would re-run this same dependency check.
    if (wasBlocked && !root.depsBlocked) {
      installCopied = false
      refreshStatus()
      refreshInterfaces()
      refreshClients()
    }
  }

  // Copy follows the built-in panels: Util.shellQuote keeps the value a single
  // shell argument, so the command is never re-parsed by bash.
  function copyInstallCommand() {
    if (!installCommand) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(installCommand) + " | wl-copy"])
    installCopied = true
    copiedTimer.restart()
  }

  // Reads DHCP leases and the iw station table from the already-validated
  // instance state, so this never needs polkit and never blocks on a prompt.
  function refreshClients() {
    if (root.hotspotActive && !clientsProc.running) clientsProc.running = true
  }

  function applyClients(raw) {
    connectedDevices = Model.parseClients(raw)
  }

  function refreshAll() {
    refreshDependencies()
    refreshStatus()
    refreshInterfaces()
    refreshClients()
  }

  function applyStatus(raw) {
    var result = Model.parseStatus(raw)
    var previous = status
    if (startPending && result.state === "inactive") return
    status = result.state
    // Sent only on the poll that noticed the hotspot went away.
    if (result.reason !== "") showError(result.reason, result.report)
    hotspotInterface = result.hotspotInterface
    if (result.upstream !== "" && upstream === "auto") upstream = result.upstream
    if (previous !== status && status === "active") {
      startPending = false
      saveState()
      scheduleQr()
      refreshClients()
    }
    if (status === "inactive" && previous === "active") {
      startPending = false
      if (result.reason === "" && errorMessage === "" && statusError === "")
        showError("Hotspot stopped")
      saveState()
      qrReady = false
      qrRows = []
      qrSize = 0
      connectedDevices = []
    }
    if (status === "inactive" && (previous === "stopping" || previous === "starting")) {
      if (previous === "starting" && result.reason === "" && errorMessage === "" && statusError === "")
        showError("The hotspot exited before becoming active")
      saveState()
    }
    if (status !== "active" && connectedDevices.length > 0) connectedDevices = []
  }

  function applyInterfaces(raw) {
    var parsed = Model.parseInterfaces(raw)
    var options = [{ value: "auto", label: "Auto-detect" }]
    for (var i = 0; i < parsed.length; i++) options.push(parsed[i])
    if (upstream !== "auto") {
      var found = false
      for (var j = 0; j < options.length; j++) {
        if (options[j].value === upstream) found = true
      }
      if (!found) options.push({ value: upstream, label: upstream + " · unavailable" })
    }
    upstreamOptions = options
  }

  function startHotspot() {
    // Belt and braces: the toggle is hidden while deps are missing, but never
    // let a start reach pkexec without create_ap behind it.
    if (depsBlocked) {
      showError("Omaspot still needs " + missingBlocking[0].package)
      return
    }
    var errors = Model.validate({ ssid: ssid, password: password, band: band, channelMode: channelMode, channel: channel })
    if (errors.length > 0) {
      showError(errors.join(" · "))
      return
    }
    var selectedUpstream = upstream === "auto" ? "auto" : upstream
    clearError()
    startReport = ""
    startStderr = ""
    startExited = false
    startOutDone = false
    startErrDone = false
    status = "starting"
    startPending = true
    saveState()
    startProc.command = [backendPath, "start", hotspotInterfaceForStart(), selectedUpstream, band, channelMode, channel]
    startProc.running = true
  }

  function hotspotInterfaceForStart() {
    // Keep adapter discovery in the backend so it can inspect iw at action
    // time instead of guessing a distribution-specific name such as wlan0.
    return hotspotInterface !== "" ? hotspotInterface : "auto"
  }

  function stopHotspot() {
    clearError()
    status = "stopping"
    saveState()
    // The backend knows the running create_ap pid, so "auto" still stops a
    // hotspot that was started outside the panel (e.g. from the GUI).
    stopProc.command = [backendPath, "stop", hotspotInterface !== "" ? hotspotInterface : "auto"]
    stopProc.running = true
  }

  function toggleHotspot() {
    if (busy) return
    if (hotspotActive) stopHotspot()
    else startHotspot()
  }

  function scheduleQr() {
    if (hotspotActive) qrTimer.restart()
  }

  function generateQr() {
    if (!hotspotActive || qrProc.running) return
    qrReady = false
    qrRows = []
    qrSize = 0
    qrProc.running = true
  }

  function applyQr(raw) {
    var result = Model.parseAsciiQr(raw)
    qrRows = result.rows
    qrSize = result.size
    qrReady = qrSize > 0
    if (!qrReady) showError("Could not render the hotspot QR code")
  }

  function setUpstream(value) {
    if (!settingsEditable) return
    upstream = value
    saveState()
  }

  function setBand(value) {
    if (!settingsEditable) return
    band = value
    if (!Model.validChannelForBand(band, channel))
      channel = band === "5" ? "149" : "1"
    saveState()
    scheduleQr()
  }

  function setChannelMode(value) {
    if (!settingsEditable) return
    channelMode = value
    saveState()
  }
  function setChannel(value) {
    if (!settingsEditable) return
    channel = value
    saveState()
  }
  function setSsid(value) {
    if (!settingsEditable) return
    ssid = value
    saveState()
  }
  function setPassword(value) {
    if (!settingsEditable) return
    password = value
    saveState()
  }

  function cancelPendingPaste() {
    pasteTargetField = null
    pasteSnapshot = ""
    pasteSnapshotCursor = -1
    pasteSnapshotSelectionStart = -1
    pasteSnapshotSelectionEnd = -1
  }

  function replaceFieldText(field, start, end, insertion) {
    if (!field || !root.opened || !root.settingsEditable) return false
    var isChannel = field === channelField
    var limit = isChannel ? 3 : field === ssidField ? 32 : 63
    var result = Model.replaceTextRange(field.text, start, end, insertion, limit, isChannel)
    if (result === null) return false

    if (field === channelField) {
      if (result.text !== field.text) root.setChannel(result.text)
    } else if (field === ssidField) {
      if (result.text !== field.text) root.setSsid(result.text)
    } else if (field === passwordField) {
      if (result.text !== field.text) root.setPassword(result.text)
    } else return false

    Qt.callLater(function() {
      if (root.opened && root.settingsEditable && field.activeFocus && field.text === result.text) {
        field.cursorPosition = result.cursor
        field.deselect()
      }
    })
    return true
  }

  function handleFieldKey(field, event) {
    var shortcut = (event.modifiers & Qt.ControlModifier) !== 0
    var altShortcut = (event.modifiers & Qt.AltModifier) !== 0
    var metaShortcut = (event.modifiers & Qt.MetaModifier) !== 0
    if (shortcut && !altShortcut && !metaShortcut && event.key === Qt.Key_V) {
      root.beginPaste(field)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier) !== 0) {
      root.beginPaste(field)
      event.accepted = true
      return
    }
    if (shortcut && !altShortcut && !metaShortcut && event.key === Qt.Key_A) {
      field.selectAll()
      event.accepted = true
      return
    }

    var start = field.selectionStart
    var end = field.selectionEnd
    if (start < 0 || end < 0 || start === end) start = end = field.cursorPosition
    else if (start > end) { var swap = start; start = end; end = swap }

    if (event.key === Qt.Key_Backspace) {
      if (start === end && start > 0) {
        start--
        if (start > 0 && field.text.charCodeAt(start) >= 0xdc00 && field.text.charCodeAt(start) <= 0xdfff
            && field.text.charCodeAt(start - 1) >= 0xd800 && field.text.charCodeAt(start - 1) <= 0xdbff)
          start--
      }
      root.replaceFieldText(field, start, end, "")
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Delete) {
      if (start === end && end < field.text.length) {
        end++
        if (end < field.text.length && field.text.charCodeAt(end - 1) >= 0xd800 && field.text.charCodeAt(end - 1) <= 0xdbff
            && field.text.charCodeAt(end) >= 0xdc00 && field.text.charCodeAt(end) <= 0xdfff)
          end++
      }
      root.replaceFieldText(field, start, end, "")
      event.accepted = true
      return
    }

    var shortcutModifiers = event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier)
    var altGr = shortcutModifiers === (Qt.ControlModifier | Qt.AltModifier)
    var printableModifiers = shortcutModifiers === 0 || altGr
    if (printableModifiers && event.text !== "" && !/[\u0000-\u001f\u007f]/.test(event.text)) {
      root.replaceFieldText(field, start, end, event.text)
      event.accepted = true
    }
  }

  function beginPaste(field) {
    if (!root.opened || !root.settingsEditable || root.pasteJob) return
    var job = pasteJobComponent.createObject(root)
    if (!job) {
      root.showError("Could not start bounded clipboard paste")
      return
    }

    pasteTargetField = field
    pasteSnapshot = field.text
    pasteSnapshotCursor = field.cursorPosition
    pasteSnapshotSelectionStart = field.selectionStart
    pasteSnapshotSelectionEnd = field.selectionEnd
    pasteJob = job
    job.running = true
  }

  function completePaste(job, exitCode, clipboardText) {
    if (job !== root.pasteJob) {
      Qt.callLater(function() { job.destroy() })
      return
    }

    var field = pasteTargetField
    var current = field && root.opened && root.settingsEditable && field.activeFocus
      && field.text === pasteSnapshot && field.cursorPosition === pasteSnapshotCursor
      && field.selectionStart === pasteSnapshotSelectionStart
      && field.selectionEnd === pasteSnapshotSelectionEnd

    root.pasteJob = null
    root.cancelPendingPaste()

    if (current && exitCode !== 0) {
      root.showError("Paste failed, timed out, exceeded the size limit, or wl-clipboard is unavailable")
    } else if (current && clipboardText.length >= 256) {
      root.showError("Clipboard text is too large for this field")
    } else if (current && clipboardText !== "") {
      var start = field.selectionStart
      var end = field.selectionEnd
      if (start < 0 || end < 0 || start === end) start = end = field.cursorPosition
      if (!root.replaceFieldText(field, start, end, clipboardText))
        root.showError("Clipboard text is too long or invalid for this field")
    }

    Qt.callLater(function() { job.destroy() })
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.loadState(text())
      secureStatePermissionTimer.restart()
    }
    onLoadFailed: root.loadState("")
    onSaved: secureStatePermissionTimer.restart()
  }

  Process {
    id: ensureStateDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.reload()
  }

  Process {
    id: secureStateFile
    command: ["chmod", "0600", root.statePath]
    onExited: function(code) {
      if (code !== 0 && root.settingsLoaded)
        root.showError("Could not restrict access to Omaspot settings")
    }
  }

  Process {
    id: statusProc
    command: [root.backendPath, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.statusError = message
      }
    }
  }

  Process {
    id: interfacesProc
    command: [root.backendPath, "interfaces"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyInterfaces(text) }
  }

  Process {
    id: dependencyProc
    command: [root.backendPath, "doctor"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyDependencies(text) }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.statusError = message
      }
    }
  }

  Process {
    id: startProc
    stdinEnabled: true
    // stdout carries the diagnostic report on failure, stderr the headline.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.startReport = String(text || "").trim()
        root.startOutDone = true
        root.finishStart(false)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.startStderr = String(text || "").trim()
        root.startErrDone = true
        root.finishStart(false)
      }
    }
    onStarted: {
      // omaspotctl reads credentials from stdin so they never appear in the
      // process command line or shell history.
      write(root.ssid + "\n")
      write(root.password + "\n")
    }
    onExited: function(code) {
      if (code !== 0) {
        root.startPending = false
        root.status = "inactive"
        root.startExitCode = code
        root.startExited = true
        root.finishStart(false)
        // Never wait forever on a stream that does not report its end.
        if (root.startExited) startFinishTimer.restart()
      } else if (root.startPending) {
        root.startPending = false
        root.status = "inactive"
        root.showError("The hotspot exited before becoming active")
      }
      root.refreshStatus()
    }
  }

  Process {
    id: stopProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && String(text).trim() !== "") root.errorMessage = String(text).trim()
    }
    onExited: function(code) {
      if (code !== 0) {
        root.status = "active"
        root.showError(root.errorMessage || (code === 126 ? "Polkit authorization was cancelled" : "Could not stop the hotspot"))
      }
      root.refreshStatus()
    }
  }

  Process {
    id: qrProc
    command: [root.backendPath, "qr"]
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyQr(text) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: function() {} }
    onStarted: {
      write(root.ssid + "\n")
      write(root.password + "\n")
    }
  }

  Process {
    id: clientsProc
    command: [root.backendPath, "clients"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyClients(text) }
  }

  Process { id: notifyProc }

  // This process exists only during an explicit paste. Its bounded output is
  // discarded with the process object as soon as the paste finishes.
  Component {
    id: pasteJobComponent
    Process {
      id: pasteJobInstance
      property bool pasteOutputReady: false
      property bool pasteExitReady: false
      property int pasteExitCode: -1
      command: ["bash", "-c", "set -o pipefail; timeout --kill-after=1s 2s wl-paste --no-newline | head -c 256"]
      stdout: StdioCollector {
        id: pasteOutput
        waitForEnd: true
        onStreamFinished: {
          pasteJobInstance.pasteOutputReady = true
          pasteJobInstance.completeWhenReady()
        }
      }
      function completeWhenReady() {
        if (pasteOutputReady && pasteExitReady)
          root.completePaste(pasteJobInstance, pasteExitCode, pasteOutput.text)
      }
      onExited: function(code, exitStatus) {
        pasteJobInstance.pasteExitCode = code
        pasteJobInstance.pasteExitReady = true
        pasteJobInstance.completeWhenReady()
      }
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: true
    onTriggered: {
      var now = (new Date()).getTime()
      if (root.lastStatusTickMs > 0 && now - root.lastStatusTickMs > 8000) {
        root.refreshAll()
      }
      root.lastStatusTickMs = now
      root.refreshStatus()
    }
  }
  // Only polls while the hotspot is up; the backend exits immediately otherwise.
  Timer {
    id: clientsTimer
    interval: 5000
    repeat: true
    running: root.hotspotActive
    onTriggered: root.refreshClients()
  }
  Timer { id: qrTimer; interval: 220; repeat: false; onTriggered: root.generateQr() }
  Timer {
    id: secureStatePermissionTimer
    interval: 50
    repeat: false
    onTriggered: if (!secureStateFile.running) secureStateFile.running = true
  }
  Timer { id: copiedTimer; interval: 1800; repeat: false; onTriggered: root.installCopied = false }
  Timer { id: errorTimer; interval: 8000; repeat: false; onTriggered: root.clearError() }
  Timer { id: logCopiedTimer; interval: 1800; repeat: false; onTriggered: root.logCopied = false }
  Timer { id: startFinishTimer; interval: 1500; repeat: false; onTriggered: root.finishStart(true) }

  Component.onCompleted: {
    injectBar()
    ensureStateDir.running = true
    refreshAll()
  }

  onOpenedChanged: if (opened) {
    refreshAll()
    if (hotspotActive) scheduleQr()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // A touch wider than the built-in network panel's 380px, for the
    // larger type and the QR card beside its details.
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: ssidField.activeFocus || passwordField.activeFocus || channelField.activeFocus || upstreamDropdown.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Column {
      id: content
      width: parent.width
      spacing: Style.space(12)

      // Header: icon, name, live status and the on/off switch. Hand-built in
      // the shape of the kit's PanelHero so the two text lines can share one
      // exact left edge and take the flyout's larger type.
      Item {
        id: header
        width: parent.width
        height: Math.max(headerIcon.height, headerLabels.implicitHeight, toggleControl.implicitHeight)

        // The same "spot" as the bar icon, sized to the full height of the
        // title and status lines so it reads as their equal, not a bullet.
        BarMark {
          id: headerIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.round(headerLabels.implicitHeight)
          height: width
          mode: root.depsBlocked ? "blocked"
            : root.hotspotActive ? "on"
            : root.busy ? "busy" : "off"
          clients: root.connectedCount
          ink: root.hotspotActive || root.busy ? Commons.Color.accent : root.foreground
          backdrop: Commons.Color.popups.background
          opacity: root.hotspotActive || root.busy ? 1.0 : 0.55
        }

        // Glyphs carry their own left side bearing, larger for a big bold "O"
        // than for small caps, which is what pushed the title right of the
        // status line. Shift the title by the difference so their ink lines up.
        FontMetrics { id: titleMetrics; font: headerTitle.font }
        FontMetrics { id: metaMetrics; font: headerMeta.font }

        Column {
          id: headerLabels
          anchors.left: headerIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: toggleControl.left
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            id: headerTitle
            // tightBoundingRect(x) of a single glyph is its left bearing.
            x: Math.round(metaMetrics.tightBoundingRect(headerMeta.text.charAt(0)).x
              - titleMetrics.tightBoundingRect(text.charAt(0)).x)
            width: parent.width - x
            textFormat: Text.PlainText
            text: "OMASPOT"
            color: root.foreground
            elide: Text.ElideRight
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.fontHeadline
            font.bold: true
            font.letterSpacing: 0.6
          }
          Text {
            id: headerMeta
            width: parent.width
            textFormat: Text.PlainText
            text: root.heroMeta.toUpperCase()
            color: root.labelColor
            elide: Text.ElideRight
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.fontCaption
            font.bold: true
            font.letterSpacing: 1.2
          }
        }

        ToggleSwitch {
          id: toggleControl
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.depsBlocked
          // A hotspot cannot be started without create_ap, so do not offer it.
          checked: root.hotspotActive || root.status === "starting"
          busy: root.busy
          enabled: !root.busy
          foreground: root.foreground
          accent: Commons.Color.accent
          onToggled: root.toggleHotspot()
        }
      }

      // Shown instead of the hotspot controls while a required package is absent.
      // Everything here is backend-provided text; the copy button is the only action
      // so a first-run user cannot start a half-working configuration.
      Rectangle {
        width: parent.width
        height: installCardInner.implicitHeight + Style.space(24)
        radius: Style.cornerRadius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
        border.color: root.hairline
        border.width: Math.max(1, Style.space(1))
        visible: root.depsBlocked

        Column {
          id: installCardInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: "Install the required package to enable the hotspot:"
            color: root.foreground
            wrapMode: Text.Wrap
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.fontBody
            font.bold: true
          }

          Repeater {
            model: root.missingBlocking
            Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(10)
                text: "•"
                color: Commons.Color.urgent
                font.family: Style.font.family
                font.pixelSize: root.fontBodySmall
              }
              Text {
                width: parent.width - Style.space(10) - parent.spacing
                text: modelData.package
                color: root.foreground
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: root.fontBodySmall
              }
            }
          }

          Text {
            width: parent.width
            visible: root.installCommand !== ""
            text: "Run this in a terminal, then select Re-check:"
            color: Commons.Color.muted
            wrapMode: Text.Wrap
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.fontCaption
          }

          Rectangle {
            width: parent.width
            height: Style.space(38)
            radius: Style.space(6)
            color: Commons.Color.popups.background
            border.color: root.installCopied ? Commons.Color.accent : Commons.Color.popups.border
            border.width: Math.max(1, Style.space(1))

            Text {
              anchors.left: parent.left
              anchors.right: copyInstall.left
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: root.installCommand !== "" ? root.installCommand : "yay -S --needed linux-wifi-hotspot"
              color: root.foreground
              elide: Text.ElideRight
              font.family: "monospace"
              font.pixelSize: root.fontCaption
            }

            Button {
              fontSize: root.fontBody
              id: copyInstall
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.rightMargin: Style.space(4)
              text: root.installCopied ? "Copied" : "Copy"
              onClicked: root.copyInstallCommand()
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              fontSize: root.fontBody
              id: recheckButton
              text: "Re-check"
              onClicked: {
                root.installCopied = false
                root.refreshDependencies()
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - recheckButton.width - Style.space(8)
              text: "After installing, select Re-check to continue."
              color: Commons.Color.muted
              wrapMode: Text.Wrap
              font.family: Style.font.family
              font.pixelSize: root.fontCaption
            }
          }
        }
      }

      // Hotspot card: the QR tile beside the network it joins. While the
      // hotspot is off the tile is a quiet placeholder rather than a fake code.
      Rectangle {
        id: hotspotCard
        visible: !root.depsBlocked
        width: parent.width
        height: Math.max(qrTile.height, cardInfo.implicitHeight) + Style.space(24)
        radius: Style.cornerRadius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
        border.color: root.hotspotActive
          ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.45)
          : root.hairline
        border.width: Math.max(1, Style.space(1))
        Behavior on border.color { ColorAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

        Rectangle {
          id: qrTile
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          width: Style.space(168)
          height: width
          radius: Style.cornerRadius
          color: root.hotspotActive && root.qrReady
            ? "white"
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)

          Rectangle {
            id: qrCanvas
            anchors.centerIn: parent
            property int moduleSize: root.qrReady && root.qrSize > 0
              ? Math.max(3, Math.floor((qrTile.width - Style.space(16)) / root.qrSize)) : 0
            width: root.qrSize * moduleSize
            height: width
            color: "white"
            visible: root.hotspotActive && root.qrReady
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

            Grid {
              anchors.centerIn: parent
              columns: root.qrSize
              Repeater {
                model: root.qrSize * root.qrSize
                Rectangle {
                  required property int index
                  readonly property int row: Math.floor(index / root.qrSize)
                  readonly property int column: index % root.qrSize
                  width: qrCanvas.moduleSize
                  height: qrCanvas.moduleSize
                  color: root.qrRows[row] && root.qrRows[row].charAt(column) === "1" ? "#111111" : "transparent"
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(6)
            visible: !(root.hotspotActive && root.qrReady)
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "\u{f0432}"
              color: root.foreground
              opacity: root.busy || root.hotspotActive ? 0.55 : 0.22
              font.family: Style.font.family
              font.pixelSize: Style.font.display * 1.6
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.hotspotActive ? "Generating…" : root.busy ? root.statusLabel : "Off"
              color: Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: root.fontCaption
            }
          }
        }

        Column {
          id: cardInfo
          anchors.left: qrTile.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: qrTile.verticalCenter
          spacing: Style.space(10)

          Column {
            width: parent.width
            spacing: Style.space(2)
            PanelSectionHeader {
              fontSize: root.fontCaption
              text: "Network"
              foreground: root.foreground
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.ssid !== "" ? root.ssid : "Omaspot"
              color: root.foreground
              elide: Text.ElideRight
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.fontSubtitle
              font.bold: true
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.cardChips
              Rectangle {
                required property var modelData
                width: chipText.implicitWidth + Style.space(14)
                height: chipText.implicitHeight + Style.space(6)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                Text {
                  id: chipText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: modelData
                  color: root.foreground
                  opacity: 0.85
                  font.family: Style.font.family
                  font.pixelSize: root.fontCaption
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.hotspotActive ? "Scan the code with a phone camera to join."
              : root.status === "starting" ? "Bringing the access point up…"
              : root.status === "stopping" ? "Shutting the access point down…"
              : "Turn on to share this network and its QR code."
            color: Commons.Color.muted
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: root.fontCaption
          }
        }
      }

      // Error banner: what went wrong and what to do, with the full report one
      // click away when the backend sent one.
      Rectangle {
        id: errorCard
        visible: !root.depsBlocked && root.errorInfo.title !== ""
        width: parent.width
        height: errorInner.implicitHeight + Style.space(24)
        radius: Style.cornerRadius
        color: Qt.rgba(Commons.Color.urgent.r, Commons.Color.urgent.g, Commons.Color.urgent.b, 0.10)
        border.color: Qt.rgba(Commons.Color.urgent.r, Commons.Color.urgent.g, Commons.Color.urgent.b, 0.40)
        border.width: Math.max(1, Style.space(1))
        // Entrance only: confirms the failure without jumping into place.
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

        Rectangle {
          id: errorStripe
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(10)
          width: Style.space(3)
          radius: width / 2
          color: Commons.Color.urgent
        }

        Column {
          id: errorInner
          anchors.left: errorStripe.right
          anchors.leftMargin: Style.space(12)
          anchors.right: errorClose.left
          anchors.rightMargin: Style.space(6)
          anchors.top: parent.top
          anchors.topMargin: Style.space(12)
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              id: errorIcon
              textFormat: Text.PlainText
              text: "\u{f0028}"
              color: Commons.Color.urgent
              font.family: Style.font.family
              font.pixelSize: root.fontBody
            }
            Text {
              width: parent.width - errorIcon.width - parent.spacing
              textFormat: Text.PlainText
              text: root.errorInfo.title
              color: root.foreground
              wrapMode: Text.Wrap
              font.family: Style.font.family
              font.pixelSize: root.fontBodySmall
              font.bold: true
            }
          }
          Text {
            width: parent.width
            visible: root.errorInfo.hint !== ""
            textFormat: Text.PlainText
            text: root.errorInfo.hint
            color: Commons.Color.muted
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: root.fontCaption
          }
          Item {
            width: parent.width
            // Bound to the condition itself: a child of a hidden item always
            // reads as hidden, so the button cannot decide this for its parent.
            visible: root.errorReport !== "" && root.errorMessage !== ""
            height: visible ? copyLogButton.height + Style.space(6) : 0
            Button {
              id: copyLogButton
              anchors.bottom: parent.bottom
              bordered: true
              iconText: root.logCopied ? "\u{f012c}" : "\u{f018f}"
              text: root.logCopied ? "Copied" : "Copy log"
              tooltipText: "Copies a full diagnostic report to paste into an agent"
              fontSize: root.fontCaption
              onClicked: root.copyErrorLog()
            }
          }
        }

        Button {
          fontSize: root.fontBody
          id: errorClose
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.space(6)
          iconText: "\u{f0156}"
          tooltipText: "Dismiss"
          foreground: Commons.Color.muted
          onClicked: root.clearError()
        }
      }

      // Recently connected devices, newest first. Backend-parsed values only.
      // The list is capped and scrolls rather than growing the flyout, so a busy
      // hotspot cannot push the settings below it off screen. ListView contributes
      // no implicitHeight, which is what keeps the card the same size as before.
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: !root.depsBlocked && root.hotspotActive

        Row {
          spacing: Style.space(8)
          PanelSectionHeader {
            fontSize: root.fontCaption
            text: "Connected devices"
            foreground: root.foreground
          }
          Rectangle {
            visible: root.connectedCount > 0
            anchors.verticalCenter: parent.verticalCenter
            width: countText.implicitWidth + Style.space(12)
            height: countText.implicitHeight + Style.space(2)
            radius: height / 2
            color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.18)
            Text {
              id: countText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: String(root.connectedCount)
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: root.fontCaption
              font.bold: true
            }
          }
        }

        Text {
          width: parent.width
          visible: root.connectedDevices.length === 0
          textFormat: Text.PlainText
          text: "Nothing has joined yet."
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: root.fontCaption
        }

        ListView {
          visible: root.connectedDevices.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(132))
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          // Keep the newest row in view as entries arrive while the list scrolls.
          onCountChanged: if (count > 0 && contentHeight > height) positionViewAtPosition(0, ListView.Beginning)

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.connectedDevices

          delegate: Rectangle {
            required property var modelData
            width: ListView.view.width
            height: deviceRowInner.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, modelData.connected ? 0.04 : 0)

            Row {
              id: deviceRowInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                id: deviceIcon
                textFormat: Text.PlainText
                text: "\u{f011c}"
                color: modelData.connected ? Commons.Color.accent : Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: root.fontBody
                anchors.verticalCenter: parent.verticalCenter
              }
              Column {
                width: deviceRowInner.width - deviceIcon.width - deviceIp.width - deviceRowInner.spacing * 2
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: modelData.name
                  color: modelData.connected ? root.foreground : Commons.Color.muted
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: root.fontBodySmall
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.connected ? "Connected" : "Recently seen"
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: root.fontCaption
                }
              }
              Text {
                id: deviceIp
                textFormat: Text.PlainText
                text: modelData.ip !== "*" ? modelData.ip : ""
                color: Commons.Color.muted
                anchors.verticalCenter: parent.verticalCenter
                font.family: Style.font.family
                font.pixelSize: root.fontCaption
              }
            }
          }
        }
      }

      PanelSeparator {
        visible: !root.depsBlocked
        foreground: root.foreground
      }

      // Settings. Locked while the hotspot runs; the note says so up front
      // instead of leaving the controls to look broken.
      Item {
        visible: !root.depsBlocked
        width: parent.width
        height: settingsHeader.implicitHeight
        PanelSectionHeader {
          fontSize: root.fontCaption
          id: settingsHeader
          text: "Network settings"
          foreground: root.foreground
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: settingsHeader.verticalCenter
          visible: !root.settingsEditable
          textFormat: Text.PlainText
          text: root.hotspotActive ? "\u{f033e}  Turn off to edit" : "\u{f033e}  Busy"
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: root.fontCaption
        }
      }

      Dropdown {
        visible: !root.depsBlocked
        id: upstreamDropdown
        enabled: root.opened && root.settingsEditable
        width: parent.width
        label: "Internet source"
        value: root.upstream
        options: root.upstreamOptions
        foreground: root.foreground
        onChanged: root.setUpstream(value)
      }

      // Label column at a fixed width so the two segmented rows line up.
      Row {
        visible: !root.depsBlocked
        width: parent.width
        spacing: Style.space(10)
        Text {
          width: root.settingsLabelWidth
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Band"
          color: root.labelColor
          font.family: Style.font.family
          font.pixelSize: root.fontCaption
          font.bold: true
        }
        Rectangle {
          width: bandRow.implicitWidth + Style.space(6)
          height: bandRow.implicitHeight + Style.space(6)
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
          border.color: root.hairline
          border.width: Math.max(1, Style.space(1))
          Row {
            id: bandRow
            anchors.centerIn: parent
            spacing: Style.space(2)
            Button {
              fontSize: root.fontBody
              text: "2.4 GHz"
              enabled: root.opened && root.settingsEditable
              selected: root.band === "2.4"
              onClicked: root.setBand("2.4")
            }
            Button {
              fontSize: root.fontBody
              text: "5 GHz"
              enabled: root.opened && root.settingsEditable
              selected: root.band === "5"
              onClicked: root.setBand("5")
            }
          }
        }
      }

      Row {
        visible: !root.depsBlocked
        width: parent.width
        spacing: Style.space(10)
        Text {
          width: root.settingsLabelWidth
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Channel"
          color: root.labelColor
          font.family: Style.font.family
          font.pixelSize: root.fontCaption
          font.bold: true
        }
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: channelModeRow.implicitWidth + Style.space(6)
          height: channelModeRow.implicitHeight + Style.space(6)
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
          border.color: root.hairline
          border.width: Math.max(1, Style.space(1))
          Row {
            id: channelModeRow
            anchors.centerIn: parent
            spacing: Style.space(2)
            Button {
              fontSize: root.fontBody
              text: "Auto"
              enabled: root.opened && root.settingsEditable
              selected: root.channelMode === "auto"
              onClicked: root.setChannelMode("auto")
            }
            Button {
              fontSize: root.fontBody
              text: "Manual"
              enabled: root.opened && root.settingsEditable
              selected: root.channelMode === "manual"
              onClicked: root.setChannelMode("manual")
            }
          }
        }
        TextField {
          font.pixelSize: root.fontBody
          id: channelField
          anchors.verticalCenter: parent.verticalCenter
          enabled: root.opened && root.settingsEditable
          readOnly: true
          visible: root.channelMode === "manual"
          width: Style.space(70)
          text: root.channel
          placeholderText: root.band === "5" ? "149" : "1"
          validator: IntValidator { bottom: 1; top: 165 }
          Keys.onPressed: function(event) { root.handleFieldKey(channelField, event) }
        }
      }

      Row {
        visible: !root.depsBlocked
        width: parent.width
        spacing: Style.space(10)
        Column {
          width: (parent.width - parent.spacing) / 2
          spacing: Style.space(4)
          Text { textFormat: Text.PlainText; text: "Hotspot name"; color: root.labelColor; font.family: Style.font.family; font.pixelSize: root.fontCaption; font.bold: true }
          TextField {
            font.pixelSize: root.fontBody
            id: ssidField
            enabled: root.opened && root.settingsEditable
            readOnly: true
            width: parent.width
            text: root.ssid
            placeholderText: "Omaspot"
            Keys.onPressed: function(event) { root.handleFieldKey(ssidField, event) }
          }
        }
        Column {
          width: (parent.width - parent.spacing) / 2
          spacing: Style.space(4)
          Text { textFormat: Text.PlainText; text: "Security key"; color: root.labelColor; font.family: Style.font.family; font.pixelSize: root.fontCaption; font.bold: true }
          Row {
            width: parent.width
            spacing: Style.space(4)
            TextField {
              font.pixelSize: root.fontBody
              id: passwordField
              enabled: root.opened && root.settingsEditable
              readOnly: true
              width: parent.width - showPassword.width - parent.spacing
              text: root.password
              password: !root.passwordVisible
              placeholderText: "8+ characters"
              Keys.onPressed: function(event) { root.handleFieldKey(passwordField, event) }
            }
            Button {
              fontSize: root.fontBody
              id: showPassword
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.passwordVisible ? "\u{f0209}" : "\u{f0208}"
              tooltipText: root.passwordVisible ? "Hide key" : "Show key"
              foreground: Commons.Color.muted
              onClicked: root.passwordVisible = !root.passwordVisible
            }
          }
        }
      }
    }
  }
}
