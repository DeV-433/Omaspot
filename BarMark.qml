import QtQuick
import qs.Commons
import qs.Commons as Commons

// Omaspot's bar mark: "the spot". A dot you broadcast from.
//
//   on       solid spot inside a ring, with a ripple running from the spot
//            out to the ring; each connected device is a bead riding the ring
//            (up to three)
//   busy     solid spot breathing, ring at half strength: starting/stopping
//   off      a hollow spot and nothing else: asleep
//   blocked  hollow spot with a slash: create_ap is not installed
//
// The bar draws this at about 12px, so the still silhouette carries the state
// (filled + ring = on, hollow = off) and motion only adds life on top.
//
// The root is a fixed transparent Rectangle so the bar measures the mark by
// its box, not by the moving parts; otherwise the icon would rescale as the
// ripple grows. Motion runs only while on or busy, and stops entirely when
// animations are turned off (Style.duration returns 0).
Rectangle {
  id: mark

  property string mode: "off"
  property int clients: 0
  property color ink: Commons.Color.foreground

  readonly property bool animate: Style.duration(1000) > 0
  readonly property real unit: width / 24
  readonly property bool isOn: mode === "on"
  readonly property bool lit: mode === "on" || mode === "busy"
  readonly property int beads: isOn ? Math.min(clients, 3) : 0
  readonly property real ringSize: width * 0.9
  readonly property real stroke: Math.max(1, unit * 2.4)
  readonly property real spotSize: width * 0.42

  // 0..1 progress of the ripple, and the beads' angle in degrees.
  property real phase: 0.5
  property real orbit: 0

  color: "transparent"

  NumberAnimation on phase {
    from: 0
    to: 1
    duration: 2200
    loops: Animation.Infinite
    running: mark.isOn && mark.animate && mark.visible
  }
  NumberAnimation on orbit {
    from: 0
    to: 360
    duration: 8000
    loops: Animation.Infinite
    running: mark.beads > 0 && mark.animate && mark.visible
  }

  // The ring: the broadcast range. Absent when off, so off reads as empty.
  Rectangle {
    visible: mark.lit
    anchors.centerIn: parent
    width: mark.ringSize
    height: width
    radius: width / 2
    color: "transparent"
    border.width: mark.stroke
    border.color: mark.ink
    opacity: mark.isOn ? 1 : 0.45
  }

  // The ripple: leaves the spot and fades as it reaches the ring.
  Rectangle {
    visible: mark.isOn && mark.animate
    anchors.centerIn: parent
    width: mark.spotSize + (mark.ringSize - mark.spotSize) * mark.phase
    height: width
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1, mark.unit * 1.8)
    border.color: mark.ink
    opacity: 0.75 * (1 - mark.phase)
  }

  // The spot: solid when lit, hollow (and a touch larger, so it does not
  // vanish at bar size) when off.
  Rectangle {
    anchors.centerIn: parent
    width: mark.lit ? mark.spotSize : mark.width * 0.5
    height: width
    radius: width / 2
    color: mark.lit ? mark.ink : "transparent"
    border.width: mark.lit ? 0 : mark.stroke
    border.color: mark.ink

    SequentialAnimation on scale {
      running: mark.mode === "busy" && mark.animate && mark.visible
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: 1; to: 0.62; duration: 560; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.62; to: 1; duration: 560; easing.type: Easing.InOutSine }
    }
  }

  // Not installed: a slash across the sleeping spot.
  Rectangle {
    visible: mark.mode === "blocked"
    anchors.centerIn: parent
    width: mark.stroke
    height: mark.width * 0.78
    radius: width / 2
    rotation: 45
    color: mark.ink
  }

  // One bead per connected device, riding the ring and evenly spaced.
  Repeater {
    model: mark.beads
    Rectangle {
      required property int index
      readonly property real angle: (mark.orbit + index * 360 / Math.max(1, mark.beads) - 45) * Math.PI / 180
      readonly property real reach: (mark.ringSize - mark.stroke) / 2
      width: Math.max(2, mark.unit * 6)
      height: width
      radius: width / 2
      color: mark.ink
      // A thin cut-out in the bar colour so a bead reads apart from the ring.
      border.width: Math.max(1, mark.unit * 1.2)
      border.color: Commons.Color.bar ? Commons.Color.bar.background : Commons.Color.background
      x: mark.width / 2 + Math.cos(angle) * reach - width / 2
      y: mark.height / 2 + Math.sin(angle) * reach - height / 2
    }
  }
}
