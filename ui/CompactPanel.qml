import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui as Ui
import "Motion.js" as Motion

PanelWindow {
    id: root
    property bool open: false
    property bool animate: false
    property bool reducedMotion: false
    property bool privacyHidden: false
    property real anchorX: -1
    readonly property real progress: card.opacity
    readonly property real visualScale: reducedMotion ? 1 : 0.97 + 0.03 * card.opacity
    visible: !privacyHidden && (open || card.opacity > 0)
    property string outputName: ""
    property bool suspendDismissal: false
    property alias body: holder
    signal dismissed()
    screen: Quickshell.screens.find(s => s.name === outputName) || Quickshell.screens[0] || null
    anchors { top: true; right: true }
    margins { top: Style.bar.sizeHorizontal + Style.gapsOut; right: Style.gapsOut }
    implicitWidth: Math.min(Style.space(400), screen ? screen.width - Style.gapsOut * 2 : 400)
    implicitHeight: Math.min(Style.space(590), screen ? screen.height - margins.top - Style.gapsOut : 590)
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "chaumarchy-panel"
    WlrLayershell.layer: WlrLayer.Overlay
    // Release all input immediately, even while the visual exit is finishing.
    WlrLayershell.keyboardFocus: open && !privacyHidden ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    mask: Region { width: root.open ? root.width : 0; height: root.open ? root.height : 0 }
    HyprlandFocusGrab {
        active: root.open && root.visible && !root.suspendDismissal
        windows: [root]
        onCleared: if (root.open && !root.suspendDismissal) root.dismissed()
    }
    Ui.BorderSurface {
        id: card
        anchors.fill: parent
        color: Color.popups.background
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius
        padding: 0
        opacity: root.open ? 1 : 0
        Behavior on opacity {
            enabled: root.animate && !root.privacyHidden
            NumberAnimation {
                duration: root.reducedMotion ? Motion.gentle : (root.open ? Motion.panelEnter : Motion.panelExit)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Motion.easeOut
            }
        }
        transform: Scale {
            // Coordinates supplied by the bar button, relative to this card.
            origin.x: root.anchorX < 0 || !root.screen ? card.width : Math.max(0, Math.min(card.width, root.anchorX - (root.screen.width - root.margins.right - root.width)))
            origin.y: 0
            xScale: root.visualScale
            yScale: xScale
        }
        Item {
            id: holder
            anchors.fill: parent
            anchors.topMargin: card.contentTopInset
            anchors.rightMargin: card.contentRightInset
            anchors.bottomMargin: card.contentBottomInset
            anchors.leftMargin: card.contentLeftInset
            clip: true
        }
    }
}
