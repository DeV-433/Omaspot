import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
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

  readonly property string moduleId: "io.github.devanshu.omaspot"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"
  readonly property string statePath: stateDir + "/" + moduleId + ".json"
  readonly property string backendPath: String(Qt.resolvedUrl("backend/omaspotctl")).replace(/^file:\/\//, "")
  readonly property bool busy: status === "starting" || status === "stopping"
  readonly property bool hotspotActive: status === "active"
  readonly property string statusLabel: status === "active" ? "Active"
    : status === "starting" ? "Starting…"
    : status === "stopping" ? "Stopping…" : "Inactive"
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color surface: Color.popups.background
  readonly property color statusColor: status === "active" ? Color.accent
    : (status === "starting" || status === "stopping") ? Color.accent
    : statusError !== "" || errorMessage !== "" ? Color.urgent : Color.muted

  function open() {
    root.controller.show()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
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

  function saveState(lastState) {
    if (!settingsLoaded) return
    var state = {
      ssid: ssid,
      password: password,
      band: band,
      channelMode: channelMode,
      channel: channel,
      upstream: upstream,
      lastState: lastState || (hotspotActive ? "active" : "inactive")
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

  function refreshAll() {
    refreshStatus()
    refreshInterfaces()
    if (!dependencyProc.running) dependencyProc.running = true
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
      startSettleTimer.stop()
      saveState("active")
      scheduleQr()
    }
    if (status === "inactive" && (previous === "stopping" || previous === "starting")) {
      if (previous === "starting" && errorMessage === "" && statusError === "")
        showError("The hotspot exited before becoming active")
      saveState("inactive")
    }
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
    var errors = Model.validate({ ssid: ssid, password: password, band: band, channelMode: channelMode, channel: channel })
    if (errors.length > 0) {
      showError(errors.join(" · "))
      return
    }
    var selectedUpstream = upstream === "auto" ? "auto" : upstream
    clearError()
    status = "starting"
    startPending = true
    startSettleTimer.restart()
    saveState("active")
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
    saveState("inactive")
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
    upstream = value
    saveState()
  }

  function setBand(value) {
    band = value
    if (band === "5" && channel === "1") channel = "149"
    if (band === "2.4" && channel === "149") channel = "1"
    saveState()
    scheduleQr()
  }

  function setChannelMode(value) { channelMode = value; saveState() }
  function setChannel(value) { channel = value; saveState() }
  function setSsid(value) { ssid = value; saveState(); scheduleQr() }
  function setPassword(value) { password = value; saveState(); scheduleQr() }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  Process {
    id: ensureStateDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.reload()
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
    command: [root.backendPath, "deps"]
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: function() {} }
    onExited: function(code) {
      if (code !== 0) root.statusError = "Required hotspot tooling is missing"
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
        startSettleTimer.stop()
        root.status = "inactive"
        root.showError(root.errorMessage || (code === 126 ? "Polkit authorization was cancelled" : "Could not start the hotspot"))
      }
      if (code === 0) startSettleTimer.restart()
      else root.refreshStatus()
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

  Process { id: notifyProc }

  Timer { id: statusTimer; interval: 3000; repeat: true; running: true; onTriggered: root.refreshStatus() }
  Timer {
    id: startSettleTimer
    // create_ap startup (virtual interface, channel scan, hostapd) takes a
    // few seconds; keep polling suppressed until it settles or fails.
    interval: 12000
    repeat: false
    onTriggered: {
      root.startPending = false
      root.refreshStatus()
    }
  }
  Timer { id: qrTimer; interval: 220; repeat: false; onTriggered: root.generateQr() }
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
    alignEnd: true
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
            text: root.hotspotInterface !== "" ? "Sharing via " + root.hotspotInterface : "Personal Wi-Fi hotspot"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        ToggleSwitch {
          id: toggleControl
          anchors.verticalCenter: parent.verticalCenter
          checked: root.hotspotActive || root.status === "starting"
          busy: root.busy
          enabled: !root.busy
          foreground: root.foreground
          accent: Color.accent
          onToggled: root.toggleHotspot()
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)
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
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      Rectangle {
        id: qrCard
        width: parent.width
        height: Style.space(220)
        radius: Style.cornerRadius
        color: Color.background
        border.color: Color.popups.border
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
          color: Color.background
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
              color: (index * 17) % 5 < 2 ? Color.accent : Color.foreground
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
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        visible: root.errorMessage !== "" || root.statusError !== ""
        width: parent.width
        text: root.errorMessage !== "" ? root.errorMessage : root.statusError
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      Text {
        text: "Network settings"
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Dropdown {
        id: upstreamDropdown
        width: parent.width
        label: "Upstream interface"
        value: root.upstream
        options: root.upstreamOptions
        foreground: root.foreground
        onChanged: root.setUpstream(value)
      }

      Row {
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "Band"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Button {
          text: "2.4 GHz"
          selected: root.band === "2.4"
          onClicked: root.setBand("2.4")
        }
        Button {
          text: "5 GHz"
          selected: root.band === "5"
          onClicked: root.setBand("5")
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "Channel"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Button {
          text: "Auto"
          selected: root.channelMode === "auto"
          onClicked: root.setChannelMode("auto")
        }
        Button {
          text: "Manual"
          selected: root.channelMode === "manual"
          onClicked: root.setChannelMode("manual")
        }
        TextField {
          id: channelField
          visible: root.channelMode === "manual"
          width: Style.space(74)
          text: root.channel
          placeholderText: root.band === "5" ? "149" : "1"
          validator: IntValidator { bottom: 1; top: 165 }
          onTextChanged: if (activeFocus) root.setChannel(text)
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)
        Column {
          width: (parent.width - parent.spacing) / 2
          spacing: Style.space(4)
          Text { text: "Hotspot name"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
          TextField {
            id: ssidField
            width: parent.width
            text: root.ssid
            placeholderText: "Omaspot"
            onTextChanged: if (activeFocus) root.setSsid(text)
          }
        }
        Column {
          width: (parent.width - parent.spacing) / 2
          spacing: Style.space(4)
          Text { text: "Security key"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
          Row {
            width: parent.width
            spacing: Style.space(4)
            TextField {
              id: passwordField
              width: parent.width - showPassword.width - parent.spacing
              text: root.password
              password: !root.passwordVisible
              placeholderText: "8+ characters"
              onTextChanged: if (activeFocus) root.setPassword(text)
            }
            Button {
              id: showPassword
              text: root.passwordVisible ? "Hide" : "Show"
              onClicked: root.passwordVisible = !root.passwordVisible
            }
          }
        }
      }

      Text {
        width: parent.width
        text: "Credentials are stored locally. Powered by create_ap (linux-wifi-hotspot)."
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }
  }
}
