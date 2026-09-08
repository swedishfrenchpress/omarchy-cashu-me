import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

ShellRoot {
    id: app
    property string page: "home"
    property string paymentText: ""
    property string amountText: ""
    property string mintUrl: ""
    property string receiveMethod: "lightning"
    ThemeSync {}

    IpcHandler {
        target: "wallet"
        function show(): void { window.visible = true }
        function hide(): void { window.visible = false }
        function quit(): void { Qt.quit() }
        function status(): string {
            return JSON.stringify({mode: "interface-preview", visible: window.visible,
                page: app.page, background: Color.background.toString(),
                foreground: Color.foreground.toString(), font: Style.font.family})
        }
    }

    component Label: Text {
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
    }
    component Action: Ui.Button {
        focusable: true
        bordered: true
        Layout.minimumHeight: Style.space(38)
    }
    component Divider: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Color.foreground
        opacity: 0.15
    }

    FloatingWindow {
        id: window
        title: "Chaumarchy — interface preview"
        visible: true
        implicitWidth: Style.space(460)
        implicitHeight: Style.space(620)
        minimumSize: Qt.size(340, 420)
        color: Color.background

        Shortcut { sequence: "Ctrl+Q"; onActivated: Qt.quit() }
        Shortcut { sequence: "Escape"; onActivated: app.page = "home" }
        Shortcut { sequence: "Ctrl+Comma"; onActivated: app.page = "settings" }

        Controls.ScrollView {
            anchors.fill: parent
            anchors.margins: Style.space(26)
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: parent.width
                spacing: Style.space(22)

                RowLayout {
                    Layout.fillWidth: true
                    Label { text: "CHAUMARCHY"; font.bold: true; font.letterSpacing: 1.5; Layout.fillWidth: true }
                    Ui.Button {
                        text: app.page === "home" ? "Settings" : "Back"
                        focusable: true
                        onClicked: app.page = app.page === "home" ? "settings" : "home"
                    }
                }

                ColumnLayout {
                    visible: app.page === "home"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: "No mint selected"; opacity: 0.6 }
                    RowLayout {
                        spacing: Style.space(10)
                        Label { text: "0"; font.pixelSize: Style.space(60) }
                        Label { text: "sats"; opacity: 0.6; Layout.alignment: Qt.AlignBaseline }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        Action { text: "↑  Send"; Layout.fillWidth: true; onClicked: app.page = "send" }
                        Action { text: "↓  Receive"; Layout.fillWidth: true; onClicked: app.page = "receive" }
                    }
                    Divider {}
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "History"; font.bold: true; Layout.fillWidth: true }
                        Label { text: "0 payments"; opacity: 0.5; font.pixelSize: Style.font.caption }
                    }
                    Item { Layout.preferredHeight: Style.space(24) }
                    Label { text: "Your payments will appear here."; opacity: 0.55; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Item { Layout.preferredHeight: Style.space(36) }
                }

                ColumnLayout {
                    visible: app.page === "send"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: "Send"; font.pixelSize: Style.font.heading; font.bold: true }
                    Label { text: "Paste a Lightning invoice, or choose an amount to share as ecash."; opacity: 0.65; Layout.fillWidth: true }
                    Ui.TextField {
                        Layout.fillWidth: true
                        placeholderText: "Lightning invoice"
                        text: app.paymentText
                        onTextEdited: app.paymentText = text
                    }
                    Ui.TextField {
                        Layout.fillWidth: true
                        placeholderText: "Amount in sats"
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: RegularExpressionValidator { regularExpression: /[0-9]{0,12}/ }
                        text: app.amountText
                        onTextEdited: app.amountText = text
                    }
                    Label { text: "QR input"; font.bold: true }
                    RowLayout {
                        Layout.fillWidth: true
                        Action { text: "Screen"; enabled: false; Layout.fillWidth: true }
                        Action { text: "Image"; enabled: false; Layout.fillWidth: true }
                        Action { text: "Camera"; enabled: false; Layout.fillWidth: true }
                    }
                    Action { text: "Review payment"; enabled: false; Layout.fillWidth: true }
                }

                ColumnLayout {
                    visible: app.page === "receive"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: "Receive"; font.pixelSize: Style.font.heading; font.bold: true }
                    Ui.Dropdown {
                        Layout.fillWidth: true
                        value: app.receiveMethod
                        options: [{value: "lightning", label: "Lightning invoice"}, {value: "ecash", label: "Cashu token"}]
                        onChanged: value => app.receiveMethod = value
                    }
                    Ui.TextField {
                        Layout.fillWidth: true
                        placeholderText: app.receiveMethod === "lightning" ? "Amount in sats" : "Paste Cashu token"
                    }
                    Label {
                        text: app.receiveMethod === "lightning" ? "Create an invoice to pay from another Lightning wallet." : "Redeem a token with its issuing mint."
                        opacity: 0.65
                        Layout.fillWidth: true
                    }
                    Action { text: app.receiveMethod === "lightning" ? "Create invoice" : "Review token"; enabled: false; Layout.fillWidth: true }
                }

                ColumnLayout {
                    visible: app.page === "settings"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: "Settings"; font.pixelSize: Style.font.heading; font.bold: true }
                    Label { text: "Mints"; font.bold: true }
                    Ui.TextField {
                        Layout.fillWidth: true
                        placeholderText: "https://mint.example.com"
                        text: app.mintUrl
                        onTextEdited: app.mintUrl = text
                    }
                    Action { text: "Add mint"; enabled: false; Layout.fillWidth: true }
                    Divider {}
                    Label { text: "Backup & recovery"; font.bold: true }
                    Action { text: "Recovery phrase"; enabled: false; Layout.fillWidth: true }
                    RowLayout {
                        Layout.fillWidth: true
                        Action { text: "Export backup"; enabled: false; Layout.fillWidth: true }
                        Action { text: "Restore"; enabled: false; Layout.fillWidth: true }
                    }
                    Divider {}
                    Label { text: "Closing the window keeps Chaumarchy running. Open it again with the launcher."; opacity: 0.65; Layout.fillWidth: true }
                    Action { text: "Quit Chaumarchy"; Layout.fillWidth: true; onClicked: Qt.quit() }
                }

                Divider {}
                Label {
                    text: "Interface preview · payments and QR scanning are not connected yet."
                    font.pixelSize: Style.font.caption
                    opacity: 0.55
                    Layout.fillWidth: true
                }
            }
        }
    }
}
