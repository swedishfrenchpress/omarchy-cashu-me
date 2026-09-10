import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Motion.js" as Motion

ColumnLayout {
    id: root
    property bool reducedMotion: false
    property bool presented: true
    property bool revealed: false
    function revealOnce() { if (visible && presented) revealed = true }
    onVisibleChanged: revealOnce()
    onPresentedChanged: revealOnce()
    Component.onCompleted: Qt.callLater(revealOnce)
    property bool ready: false
    property bool busy: false
    property alias createAction: createButton
    signal createRequested()
    signal restoreRequested()
    spacing: Style.space(24)

    Item { Layout.preferredHeight: Style.space(20) }
    Item {
        id: mark
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(116)
        Repeater {
            model: 3
            Rectangle {
                required property int index
                id: ring
                property bool shown: false
                property real reveal: shown ? 1 : 0
                Timer { interval: index * Motion.stagger + 1; running: root.revealed; onTriggered: ring.shown = true }
                Behavior on reveal {
                    NumberAnimation {
                        duration: root.reducedMotion ? Motion.gentle : Motion.reveal
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Motion.easeOut
                    }
                }
                width: Style.space(66); height: width; radius: width / 2
                x: (mark.width - width) / 2 + (index - 1) * Style.space(25)
                y: (mark.height - height) / 2
                transform: Translate {
                    x: root.reducedMotion ? 0 : (1 - ring.reveal) * (1 - index) * Style.space(25)
                    y: root.reducedMotion ? 0 : (1 - ring.reveal) * Style.space(8)
                }
                color: "transparent"
                border.width: 1
                border.color: Color.foreground
                opacity: ring.reveal * (index === 1 ? 0.9 : 0.35)
            }
        }
    }
    Text {
        text: "Cash, at home."
        Layout.fillWidth: true
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.space(30)
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
    Text {
        text: "Your Cashu wallet for Omarchy. Send and receive bitcoin as digital cash, through a mint you choose."
        Layout.fillWidth: true
        color: Color.foreground
        opacity: 0.7
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        lineHeight: 1.3
    }
    Text {
        text: "No account. Your wallet lives on this device."
        Layout.fillWidth: true
        color: Color.foreground
        opacity: 0.5
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
    Item { Layout.preferredHeight: Style.space(8) }
    MotionButton {
        reducedMotion: root.reducedMotion
        id: createButton
        objectName: "createWalletButton"
        Layout.fillWidth: true
        Layout.minimumHeight: Style.space(42)
        text: root.busy ? "Creating your wallet…" : "Create wallet"
        focusable: true
        bordered: true
        enabled: root.ready && !root.busy
        opacity: enabled ? 1 : 0.4
        onClicked: if (enabled) root.createRequested()
    }
    MotionButton {
        reducedMotion: root.reducedMotion
        text: "Restore a wallet"
        Layout.fillWidth: true
        Layout.minimumHeight: Style.space(42)
        focusable: true
        enabled: !root.busy
        onClicked: root.restoreRequested()
    }
    Text {
        text: "Add a password whenever you like in Security."
        Layout.fillWidth: true
        color: Color.foreground
        opacity: 0.45
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
}
