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

  function showError(message) {
    var clean = String(message || "").replace(/^omaspot:\s*/i, "").trim()
    if (clean === "") clean = "The hotspot operation failed"
    errorMessage = clean
    notifyProc.command = ["notify-send", "--urgency=critical", "--app-name=Omaspot", "Omaspot", clean]
    notifyProc.running = true
    errorTimer.restart()
  }

  function clearError() {
    errorMessage = ""
    statusError = ""
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
      if (errorMessage === "" && statusError === "")
        showError("Hotspot stopped")
      saveState()
      qrReady = false
      qrRows = []
      qrSize = 0
      connectedDevices = []
    }
    if (status === "inactive" && (previous === "stopping" || previous === "starting")) {
      if (previous === "starting" && errorMessage === "" && statusError === "")
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
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && String(text).trim() !== "") root.errorMessage = String(text).trim()
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
        root.showError(root.errorMessage || (code === 126 ? "Polkit authorization was cancelled" : "Could not start the hotspot"))
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

  Component.onCompleted: {
    injectBar()
    ensureStateDir.running = true
    refreshAll()
  }

  onOpenedChanged: if (opened) {
    refreshAll()
    if (hotspotActive) scheduleQr()
  }

  RightAlignedPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Match the built-in network panel's 380px fitted width.
    contentWidth: panel.fittedContentWidth(Style.space(380))
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
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(10)

        Column {
          width: parent.width - toggleControl.width - Style.space(10)
          spacing: Style.space(2)
          Text {
            text: "Omaspot"
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            text: root.depsBlocked
              ? "Hotspot support is not installed"
              : root.hotspotInterface !== "" ? "Sharing via " + root.hotspotInterface : "Personal Wi-Fi hotspot"
            color: root.depsBlocked ? Commons.Color.urgent : Commons.Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        ToggleSwitch {
          id: toggleControl
          anchors.verticalCenter: parent.verticalCenter
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
        color: Commons.Color.background
        border.color: Commons.Color.popups.border
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
            font.pixelSize: Style.font.body
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
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width - Style.space(10) - parent.spacing
                text: modelData.package
                color: root.foreground
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
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
            font.pixelSize: Style.font.caption
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
              font.pixelSize: Style.font.caption
            }

            Button {
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
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Row {
        visible: !root.depsBlocked
        width: parent.width
        spacing: Style.space(10)
        Text {
          text: "●  " + root.statusLabel
          color: root.statusColor
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          visible: root.hotspotActive && root.upstream !== "auto"
          text: "·  route " + root.upstream
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      Rectangle {
        visible: !root.depsBlocked
        width: parent.width
        height: Style.space(220)
        radius: Style.cornerRadius
        color: Commons.Color.background
        border.color: Commons.Color.popups.border
        border.width: Math.max(1, Style.space(1))

        Rectangle {
          id: qrCanvas
          anchors.centerIn: parent
          width: root.qrReady && root.qrSize > 0 ? root.qrSize * moduleSize : Style.space(220)
          height: width
          color: "white"
          radius: Style.cornerRadius
          property int moduleSize: root.qrReady && root.qrSize > 0
            ? Math.max(3, Math.floor(Style.space(220) / root.qrSize)) : 0
          visible: root.hotspotActive && root.qrReady

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

        // A soft, low-detail placeholder keeps the panel height stable while
        // the hotspot is off. The overlay intentionally obscures credentials.
        Rectangle {
          anchors.fill: parent
          radius: parent.radius
          color: Commons.Color.background
          opacity: root.hotspotActive && root.qrReady ? 0 : 0.82
          Behavior on opacity { NumberAnimation { duration: 140 } }
        }
        Grid {
          anchors.centerIn: parent
          columns: 13
          opacity: root.hotspotActive && root.qrReady ? 0 : 0.13
          Repeater {
            model: 169
            Rectangle {
              required property int index
              width: Style.space(10)
              height: width
              color: (index * 17) % 5 < 2 ? Commons.Color.accent : Commons.Color.foreground
            }
          }
        }
        Column {
          anchors.centerIn: parent
          spacing: Style.space(4)
          visible: !(root.hotspotActive && root.qrReady)
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.hotspotActive ? "Generating QR…" : "Hotspot off"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.hotspotActive ? "Preparing a scannable code" : "QR appears when Omaspot is active"
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        visible: !root.depsBlocked && (root.errorMessage !== "" || root.statusError !== "")
        width: parent.width
        text: root.errorMessage !== "" ? root.errorMessage : root.statusError
        color: Commons.Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      // Recently connected devices, newest first. Backend-parsed values only.
      // The list is capped and scrolls rather than growing the flyout, so a busy
      // hotspot cannot push the settings below it off screen. ListView contributes
      // no implicitHeight, which is what keeps the card the same size as before.
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: !root.depsBlocked && root.hotspotActive

        Text {
          text: "Connected devices"
          color: root.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          width: parent.width
          visible: root.connectedDevices.length === 0
          text: "Nothing has joined yet"
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        ListView {
          visible: root.connectedDevices.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(120))
          spacing: Style.space(4)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          // Keep the newest row in view as entries arrive while the list scrolls.
          onCountChanged: if (count > 0 && contentHeight > height) positionViewAtPosition(0, ListView.Beginning)

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.connectedDevices

          delegate: Item {
            required property var modelData
            width: ListView.view.width
            height: deviceRowInner.implicitHeight

            Row {
              id: deviceRowInner
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(10)
                text: modelData.connected ? "●" : "○"
                color: modelData.connected ? root.statusColor : Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                id: deviceName
                width: Math.max(Style.space(40),
                  deviceRowInner.width - Style.space(10) - deviceRowInner.spacing
                  - deviceIp.width - Style.space(8))
                text: modelData.name
                color: modelData.connected ? root.foreground : Commons.Color.muted
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                id: deviceIp
                text: modelData.ip
                visible: modelData.ip !== "*"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      Text {
        visible: !root.depsBlocked
        text: "Network settings"
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        visible: !root.depsBlocked && !root.settingsEditable
        width: parent.width
        text: root.hotspotActive
          ? "Stop the hotspot to change network settings"
          : "Wait for the hotspot operation to finish before changing settings"
        color: Commons.Color.muted
        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Dropdown {
        visible: !root.depsBlocked
        id: upstreamDropdown
        enabled: root.opened && root.settingsEditable
        width: parent.width
        label: "Upstream interface"
        value: root.upstream
        options: root.upstreamOptions
        foreground: root.foreground
        onChanged: root.setUpstream(value)
      }

      Row {
        visible: !root.depsBlocked
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "Band"
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Button {
          text: "2.4 GHz"
          enabled: root.opened && root.settingsEditable
          selected: root.band === "2.4"
          onClicked: root.setBand("2.4")
        }
        Button {
          text: "5 GHz"
          enabled: root.opened && root.settingsEditable
          selected: root.band === "5"
          onClicked: root.setBand("5")
        }
      }

      Row {
        visible: !root.depsBlocked
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "Channel"
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Button {
          text: "Auto"
          enabled: root.opened && root.settingsEditable
          selected: root.channelMode === "auto"
          onClicked: root.setChannelMode("auto")
        }
        Button {
          text: "Manual"
          enabled: root.opened && root.settingsEditable
          selected: root.channelMode === "manual"
          onClicked: root.setChannelMode("manual")
        }
        TextField {
          id: channelField
          enabled: root.opened && root.settingsEditable
          readOnly: true
          visible: root.channelMode === "manual"
          width: Style.space(74)
          text: root.channel
          placeholderText: root.band === "5" ? "149" : "1"
          validator: IntValidator { bottom: 1; top: 165 }
          Keys.onPressed: function(event) { root.handleFieldKey(channelField, event) }
        }
      }

      Row {
        visible: !root.depsBlocked
        width: parent.width
        spacing: Style.space(8)
        Column {
          width: (parent.width - parent.spacing) / 2
          spacing: Style.space(4)
          Text { text: "Hotspot name"; color: Commons.Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
          TextField {
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
          Text { text: "Security key"; color: Commons.Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
          Row {
            width: parent.width
            spacing: Style.space(4)
            TextField {
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
              id: showPassword
              text: root.passwordVisible ? "Hide" : "Show"
              onClicked: root.passwordVisible = !root.passwordVisible
            }
          }
        }
      }

    }
  }
}
