import QtQuick
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "io.github.devanshu.omaspot"

  readonly property string status: panelLoader.item ? panelLoader.item.status : "inactive"
  // Surfaced from the panel so the bar warns before the flyout is even opened.
  readonly property bool depsBlocked: panelLoader.item
    ? panelLoader.item.depsBlocked === true : false
  // Access-point is deliberately different from the regular Wi-Fi glyph used
  // by omarchy.network. Keep this a single, neutral bar mark in every state;
  // status and color belong in the flyout, not in the compact bar slot.
  readonly property string statusIcon: "󰀂"

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
    text: root.statusIcon
    active: false
    useActiveColor: false
    tooltipText: root.depsBlocked ? "Omaspot needs linux-wifi-hotspot · open to install"
      : root.status === "active" ? "Hotspot active · open Omaspot"
      : "Hotspot inactive · open Omaspot"
    slotSize: Style.bar.statusSlot
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }
}
