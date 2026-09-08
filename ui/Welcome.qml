import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

ColumnLayout {
    id: root
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
        property real reveal: 0
        NumberAnimation on reveal {
            from: 0; to: 1; duration: 1100
            easing.type: Easing.OutCubic
            running: root.visible
        }
        Repeater {
            model: 3
            Rectangle {
                required property int index
                width: Style.space(66); height: width; radius: width / 2
                x: (mark.width - width) / 2 + (index - 1) * Style.space(25) * mark.reveal
                y: (mark.height - height) / 2 + (1 - mark.reveal) * Style.space(20 + index * 8)
                color: "transparent"
                border.width: 1
                border.color: Color.foreground
                opacity: mark.reveal * (index === 1 ? 0.9 : 0.35)
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
    Ui.Button {
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
    Ui.Button {
        text: "Restore a wallet"
        Layout.alignment: Qt.AlignHCenter
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
