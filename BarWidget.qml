import QtQuick
import qs.Ui
import qs.Commons
import qs.Commons as Commons

BarWidget {
  id: root
  moduleName: "io.github.devanshu.omaspot"

  readonly property string status: panelLoader.item ? panelLoader.item.status : "inactive"
  // Surfaced from the panel so the bar warns before the flyout is even opened.
  readonly property bool depsBlocked: panelLoader.item
    ? panelLoader.item.depsBlocked === true : false
  readonly property int clients: panelLoader.item && panelLoader.item.connectedCount
    ? panelLoader.item.connectedCount : 0
  // Omaspot's own mark (BarMark.qml) rather than a stock Wi-Fi glyph, so it
  // never reads as omarchy.network's icon. It stays in the bar's foreground
  // colour; the state shows in its shape and motion, not in colour.
  readonly property string ssid: panelLoader.item && panelLoader.item.ssid
    ? panelLoader.item.ssid : "Omaspot"
  // Plain text in the bar's tooltip, so the network name is never read as markup.
  readonly property string tooltip: root.depsBlocked ? "Omaspot needs linux-wifi-hotspot · click to install"
    : root.status === "active"
      ? "Broadcasting " + root.ssid + " · "
        + (root.clients === 0 ? "no one joined yet"
          : root.clients === 1 ? "1 device joined" : root.clients + " devices joined")
    : root.status === "starting" ? "Omaspot is waking up…"
    : root.status === "stopping" ? "Omaspot is winding down…"
    : "Omaspot is napping · click to wake it"
  readonly property string markMode: root.depsBlocked ? "blocked"
    : root.status === "active" ? "on"
    : root.status === "starting" || root.status === "stopping" ? "busy"
    : "off"

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.settings = root.settings
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item && panelLoader.item.open) panelLoader.item.open() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function toggle() { togglePanel() }
  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      BarMark {
        mode: root.markMode
        clients: root.clients
        ink: root.bar ? root.bar.barForeground : Commons.Color.foreground
      }
    }
    active: root.status === "active"
    useActiveColor: false
    tooltipText: root.tooltip
    slotSize: Style.bar.statusSlot
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }
}
