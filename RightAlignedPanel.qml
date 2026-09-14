import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// Omaspot's bar item lives in the top bar's right section. The shared
// KeyboardPanel centers top-bar cards under their trigger; this local variant
// keeps the same focus/theme lifecycle while pinning the card to the screen's
// right inset when the item is in the bar's right section.
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property bool open: false
  // Kept as a compatibility property for Panel.qml; this component is
  // intentionally end-aligned whenever the bar is horizontal.
  property bool alignEnd: true
  property int gap: Style.gapsOut
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: false
  property Item focusTarget: null

  default property alias contentItem: contentHolder.children

  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  readonly property real barH: anchorWindow ? anchorWindow.height : 0
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - margin * 2) : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, screenH - ((barPos === "top" || barPos === "bottom")
      ? barH + gap + margin : margin * 2)) : 0
  readonly property real verticalContentInset: padding * 2 + Style.space(4)

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    var maxWidth = availableCardWidth > 0 ? availableCardWidth : desired
    if (cap !== undefined && Number(cap) > 0) maxWidth = Math.min(maxWidth, Number(cap))
    return Math.round(Math.min(desired, maxWidth))
  }

  function fittedContentHeight(implicitHeight, cap) {
    var desired = Math.max(verticalContentInset, Number(implicitHeight || 0) + verticalContentInset)
    var maxHeight = availableCardHeight > 0 ? availableCardHeight : desired
    if (cap !== undefined && Number(cap) > 0) maxHeight = Math.min(maxHeight, Number(cap))
    return Math.round(Math.min(desired, maxHeight))
  }

  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    var x = margin
    var y = margin
    if (barPos === "top") {
      x = screenW - contentWidth - margin
      y = barH + gap
    } else if (barPos === "bottom") {
      x = screenW - contentWidth - margin
      y = screenH - barH - contentHeight - gap
    } else if (barPos === "right") {
      x = screenW - barW - contentWidth - gap
      y = anchorItem.mapToItem(anchorWindow.contentItem, 0, 0).y
        + anchorItem.height / 2 - contentHeight / 2
    } else if (barPos === "left") {
      x = barW + gap
      y = anchorItem.mapToItem(anchorWindow.contentItem, 0, 0).y
        + anchorItem.height / 2 - contentHeight / 2
    } else {
      var point = anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
      x = point.x + anchorItem.width / 2 - contentWidth / 2
      y = barH + gap
    }
    x = Math.max(margin, Math.min(x, screenW - contentWidth - margin))
    y = Math.max(margin, Math.min(y, screenH - contentHeight - margin))
    return Qt.point(Math.round(x), Math.round(y))
  }

  screen: anchorWindow ? anchorWindow.screen : null
  visible: open || card.opacity > 0 || popoutSwitching
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "omaspot-keyboard-panel"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: open
    ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  anchors { top: true; bottom: true; left: true; right: true }

  onOpenChanged: {
    if (open) {
      focusPrimed = false
      focusTimer.restart()
      if (focusTarget) Qt.callLater(function() {
        if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
      })
      if (bar && bar.requestPopout) bar.requestPopout(owner || root)
    } else {
      focusTimer.stop()
      focusPrimed = false
      if (bar && bar.releasePopout) bar.releasePopout(owner || root)
    }
  }

  Timer {
    id: focusTimer
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.open
    acceptedButtons: Qt.AllButtons
    onClicked: {
      if (mouse.x >= card.x && mouse.x <= card.x + card.width
          && mouse.y >= card.y && mouse.y <= card.y + card.height) return
      if (root.owner && root.owner.close) root.owner.close()
      else root.open = false
    }
  }

  Rectangle {
    id: card
    x: root.cardOrigin.x
    y: root.cardOrigin.y
    width: root.contentWidth
    height: root.contentHeight
    color: Color.popups.background
    border.color: Color.popups.border
    border.width: Math.max(1, Style.space(2))
    property real padding: root.padding
    radius: Style.cornerRadius
    property real contentTopInset: border.width + root.padding
    property real contentRightInset: border.width + root.padding
    property real contentBottomInset: border.width + root.padding
    property real contentLeftInset: border.width + root.padding
    opacity: root.open || root.popoutSwitching ? 1 : 0

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
    }
  }
}
