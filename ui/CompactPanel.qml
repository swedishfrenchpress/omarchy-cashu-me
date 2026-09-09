import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui as Ui

PanelWindow {
    id: root
    visible: false
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
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    HyprlandFocusGrab {
        active: root.visible && !root.suspendDismissal
        windows: [root]
        onCleared: if (root.visible && !root.suspendDismissal) root.dismissed()
    }
    Ui.BorderSurface {
        id: card
        anchors.fill: parent
        color: Color.popups.background
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius
        padding: 0
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
