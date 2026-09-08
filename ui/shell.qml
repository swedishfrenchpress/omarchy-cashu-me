import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtQuick.Dialogs
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
    property var suggestions: []
    property string restorePath: ""
    property bool phraseRestore: false
    property bool restoreMode: false
    property bool automaticOpenAttempted: false
    property string receiveText: ""
    property string scanTarget: "send"
    property string clipboardText: ""
    readonly property bool walletVisible: backend.preview || backend.unlocked
    readonly property var selectedMint: {
        var mints = backend.state.mints || []
        return mints.find(mint => mint.url === backend.state.selected) || {name: "No mint selected", spendable: "0", pending: "0", reserved: "0"}
    }
    ThemeSync {}
    WalletBackend {
        id: backend
        onShowResult: app.page = "share"
        onReadyChanged: app.maybeOpen()
        onStateChanged: app.maybeOpen()
        onLocked: {
            app.page = "home"
            app.automaticOpenAttempted = false
            app.paymentText = ""
            app.amountText = ""
            password.clear()
            securityPassword.clear()
            securityConfirmation.clear()
            currentPassword.clear()
            backupPassword.clear()
            backupConfirmation.clear()
            restorePassword.clear()
            restoreWords.clear()
            restoreMints.clear()
            app.receiveText = ""
            app.clipboardText = ""
            scanner.running = false
            clipboard.running = false
            exportDialog.close()
            importDialog.close()
            imageDialog.close()
        }
    }
    DesktopLock {
        id: desktopLock
        enabled: !backend.preview
        onLocked: if (backend.unlocked || backend.busy) backend.lock()
        onSafeToUnlockChanged: app.maybeOpen()
    }
    function maybeOpen() {
        // Read the state directly: derived QML bindings may still hold the old
        // unlocked value while onStateChanged is being delivered.
        if (backend.preview || !backend.ready || backend.busy || backend.state.unlocked === true || !desktopLock.safeToUnlock) return
        if (!backend.state.exists || backend.state.password_required !== false || app.automaticOpenAttempted || backend.error) return
        app.automaticOpenAttempted = true
        backend.request("unlock")
    }
    FileView {
        path: Qt.resolvedUrl("suggested-mints.json").toString().replace("file://", "")
        onLoaded: { try { app.suggestions = JSON.parse(text()) } catch (_) { app.suggestions = [] } }
    }
    FileDialog {
        id: exportDialog
        title: "Save encrypted wallet backup"
        fileMode: FileDialog.SaveFile
        nameFilters: ["Chaumarchy backup (*.backup)"]
        defaultSuffix: "backup"
        onAccepted: {
            backend.request("export_backup", {path: decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, "")), password: backupPassword.text})
            backupPassword.clear()
            backupConfirmation.clear()
        }
    }
    FileDialog {
        id: imageDialog
        title: "Open a QR image"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp *.bmp)"]
        onAccepted: app.scan("image", decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, "")))
    }
    function scan(mode, path) {
        if (scanner.running || !backend.unlocked) return
        backend.error = ""
        scanner.command = [Quickshell.env("CHAUMARCHY_SCANNER"), mode].concat(path ? [path] : [])
        scanner.running = true
    }
    Process {
        id: scanner
        stdout: SplitParser {
            onRead: data => {
                try {
                    var result = JSON.parse(data)
                    if (result.error) backend.error = result.error
                    else if (backend.unlocked) {
                        if (app.scanTarget === "send") app.paymentText = result.text
                        else { app.receiveMethod = "ecash"; app.receiveText = result.text }
                    }
                } catch (_) { backend.error = "Could not decode the scanned result." }
            }
        }
        stderr: SplitParser { onRead: data => {} }
    }
    Process {
        id: clipboard
        command: ["wl-copy", "--foreground", "--sensitive", "--paste-once", "--type", "text/plain"]
        stdinEnabled: true
        onStarted: { write(app.clipboardText); stdinEnabled = false; app.clipboardText = "" }
    }
    FileDialog {
        id: importDialog
        title: "Choose a Chaumarchy backup"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Chaumarchy backup (*.backup)", "All files (*)"]
        onAccepted: app.restorePath = decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, ""))
    }

    IpcHandler {
        target: "wallet"
        function show(): void { window.visible = true }
        function hide(): void { window.visible = false }
        function quit(): void { Qt.quit() }
        function status(): string {
            return JSON.stringify({mode: backend.preview ? "interface-preview" : "wallet", visible: window.visible,
                unlocked: backend.unlocked,
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
        opacity: enabled ? 1 : 0.4
        Layout.minimumHeight: Style.space(38)
    }
    component Divider: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Color.foreground
        opacity: 0.15
    }
    component ScanButtons: RowLayout {
        property string target: "send"
        Layout.fillWidth: true
        enabled: backend.unlocked && !backend.busy && !scanner.running
        Action { text: "Screen QR"; Layout.fillWidth: true; onClicked: { app.scanTarget = parent.target; app.scan("screen") } }
        Action { text: "Image"; Layout.fillWidth: true; onClicked: { app.scanTarget = parent.target; imageDialog.open() } }
        Action { text: "Camera"; Layout.fillWidth: true; onClicked: { app.scanTarget = parent.target; app.scan("camera") } }
    }

    FloatingWindow {
        id: window
        title: backend.preview ? "Chaumarchy — interface preview" : "Chaumarchy"
        visible: true
        implicitWidth: Style.space(460)
        implicitHeight: Style.space(620)
        minimumSize: Qt.size(340, 420)
        color: Color.background

        Shortcut { sequence: "Ctrl+Q"; onActivated: Qt.quit() }
        Shortcut { sequence: "Escape"; onActivated: { if (backend.review) backend.request("cancel_payment", {review_id: backend.reviewId}); else app.page = "home" } }
        Shortcut { sequence: "Ctrl+Comma"; enabled: !backend.review; onActivated: app.page = "settings" }

        Controls.ScrollView {
            id: contentScroll
            anchors.fill: parent
            anchors.margins: Style.space(26)
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: Math.min(contentScroll.availableWidth, Style.space(460))
                x: (contentScroll.availableWidth - width) / 2
                spacing: Style.space(22)

                RowLayout {
                    Layout.fillWidth: true
                    Label { text: "CHAUMARCHY"; font.bold: true; font.letterSpacing: 1.5; Layout.fillWidth: true }
                    Ui.Button {
                        enabled: !backend.review
                        visible: app.walletVisible
                        text: app.page === "home" ? "Settings" : "Back"
                        focusable: true
                        onClicked: app.page = app.page === "home" ? "settings" : "home"
                    }
                }

                Welcome {
                    id: welcome
                    visible: backend.ready && !app.walletVisible && !backend.state.exists && !app.restoreMode
                    Layout.fillWidth: true
                    Layout.topMargin: Math.max(0, (contentScroll.availableHeight - implicitHeight - Style.space(80)) / 2)
                    ready: backend.ready && desktopLock.safeToUnlock
                    busy: backend.busy
                    onCreateRequested: backend.request("create")
                    onRestoreRequested: app.restoreMode = true
                }
                ColumnLayout {
                    visible: !app.walletVisible && backend.state.exists
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: backend.state.password_required === false ? "Welcome back" : "Unlock your wallet"; font.bold: true; font.pixelSize: Style.font.heading }
                    Ui.TextField {
                        id: password
                        visible: backend.state.password_required !== false
                        password: true
                        placeholderText: "Wallet password"
                        Layout.fillWidth: true
                        onAccepted: if (unlockButton.enabled) unlockButton.clicked()
                    }
                    Action {
                        id: unlockButton
                        text: backend.busy ? "Opening…" : (backend.state.password_required === false ? "Open wallet" : "Unlock")
                        Layout.fillWidth: true
                        enabled: backend.ready && !backend.busy && desktopLock.safeToUnlock
                            && (backend.state.password_required === false || password.text.length > 0)
                        onClicked: { backend.request("unlock", {password: password.text}); password.clear() }
                    }
                }
                Label { visible: !app.walletVisible && !desktopLock.safeToUnlock; text: "Waiting for an unlocked Omarchy desktop."; opacity: 0.65; Layout.fillWidth: true }
                Label { visible: !app.walletVisible && !backend.ready && !backend.error; text: "Starting Chaumarchy…"; opacity: 0.65; Layout.fillWidth: true }
                ColumnLayout {
                    visible: !app.walletVisible && !backend.state.exists && app.restoreMode
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: "Bring your wallet home"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { text: "Restore your encrypted backup or use your recovery words and mint URLs."; opacity: 0.65; Layout.fillWidth: true }
                    Ui.Button { text: "Choose a backup file"; focusable: true; onClicked: importDialog.open() }
                    Ui.Button { text: "Use recovery words"; focusable: true; onClicked: app.phraseRestore = !app.phraseRestore }
                    Controls.TextArea {
                        id: restoreWords
                        visible: app.phraseRestore && !backend.state.exists
                        Layout.fillWidth: true
                        placeholderText: "Recovery words, in order"
                        wrapMode: TextEdit.Wrap
                        color: Color.foreground
                        placeholderTextColor: Qt.alpha(Color.foreground, 0.5)
                        font.family: Style.font.family
                        background: Rectangle { color: "transparent"; border.color: Qt.alpha(Color.foreground, 0.25) }
                    }
                    Controls.TextArea {
                        id: restoreMints
                        visible: app.phraseRestore && !backend.state.exists
                        Layout.fillWidth: true
                        placeholderText: "Your mint URLs, one per line"
                        wrapMode: TextEdit.Wrap
                        color: Color.foreground
                        placeholderTextColor: Qt.alpha(Color.foreground, 0.5)
                        font.family: Style.font.family
                        background: Rectangle { color: "transparent"; border.color: Qt.alpha(Color.foreground, 0.25) }
                    }
                    Action {
                        visible: app.phraseRestore && !backend.state.exists
                        text: "Recover wallet"
                        Layout.fillWidth: true
                        enabled: backend.ready && !backend.busy && desktopLock.safeToUnlock && restoreWords.text.trim() !== "" && restoreMints.text.trim() !== ""
                        onClicked: {
                            backend.request("restore_phrase", {phrase: restoreWords.text.trim().replace(/\s+/g, " "), mint_urls: restoreMints.text.trim().split(/\s+/)})
                            restoreWords.clear(); restoreMints.clear()
                        }
                    }
                    Label { visible: app.phraseRestore && !backend.state.exists; text: "Use your original mint URLs. Recovery scans those mints for unspent ecash; it cannot recover your full history or every pending operation. Stop using the old wallet before recovery."; Layout.fillWidth: true; opacity: 0.65 }
                    Label { visible: app.restorePath !== "" && !backend.state.exists; text: app.restorePath; opacity: 0.65; Layout.fillWidth: true }
                    Ui.TextField { id: restorePassword; visible: app.restorePath !== "" && !backend.state.exists; password: true; placeholderText: "Backup password"; Layout.fillWidth: true }
                    Action {
                        visible: app.restorePath !== "" && !backend.state.exists
                        text: "Restore wallet"
                        Layout.fillWidth: true
                        enabled: backend.ready && !backend.busy && desktopLock.safeToUnlock && restorePassword.text.length > 0
                        onClicked: {
                            backend.request("restore_backup", {path: app.restorePath, backup_password: restorePassword.text})
                            restorePassword.clear()
                        }
                    }
                    Ui.Button { text: "Back"; focusable: true; onClicked: app.restoreMode = false }
                }
                Label { visible: backend.error !== ""; text: backend.error; color: Color.urgent; Layout.fillWidth: true }
                Label { visible: backend.notice !== ""; text: backend.notice; Layout.fillWidth: true }
                Label { visible: scanner.running; text: "Scanning… Hold one QR code steady. Scanning stops after one minute."; Layout.fillWidth: true; opacity: 0.65 }
                Ui.Button { visible: scanner.running; text: "Cancel scan"; focusable: true; onClicked: scanner.running = false }

                ColumnLayout {
                    visible: !!backend.review
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: backend.review ? backend.review.kind : ""; font.bold: true }
                    Label { text: backend.review ? backend.review.mint : ""; Layout.fillWidth: true; opacity: 0.65 }
                    Label { text: backend.review && backend.review.amount ? backend.review.amount + " sats" : "Reclaim this unspent transfer?"; font.pixelSize: Style.font.heading }
                    Label { visible: !!backend.review && !!backend.review.fee; text: backend.review ? "Maximum fees: " + backend.review.fee + " sats" : ""; Layout.fillWidth: true }
                    Label { visible: !!backend.review && !!backend.review.total; text: backend.review ? "Maximum debit: " + backend.review.total + " sats" : ""; font.bold: true }
                    Label { visible: !!backend.review && backend.review.receiving === true; text: "The issuing mint may deduct an input fee. The actual credited amount appears after redemption."; Layout.fillWidth: true; opacity: 0.65 }
                    RowLayout {
                        Layout.fillWidth: true
                        Action { text: "Cancel"; enabled: !backend.busy; Layout.fillWidth: true; onClicked: backend.request("cancel_payment", {review_id: backend.reviewId}) }
                        Action { text: backend.busy ? "Processing…" : "Confirm"; enabled: !backend.busy; Layout.fillWidth: true; onClicked: backend.request("confirm_payment", {review_id: backend.reviewId}) }
                    }
                }

                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "home"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Ui.Dropdown {
                        visible: (backend.state.mints || []).length > 0
                        Layout.fillWidth: true
                        value: backend.state.selected || ""
                        options: (backend.state.mints || []).map(mint => ({value: mint.url, label: mint.name}))
                        onChanged: value => backend.request("select_mint", {url: value})
                    }
                    Label { visible: !(backend.state.mints || []).length; text: "Your wallet is ready. Choose a mint to start using ecash."; Layout.fillWidth: true; opacity: 0.6 }
                    Action { visible: !(backend.state.mints || []).length; text: "Choose a mint"; Layout.fillWidth: true; onClicked: app.page = "settings" }
                    Label { visible: backend.state.restoring === true; text: "Recovering from your mints… Spending becomes available after recovery completes. Unreachable mints are retried in the background."; Layout.fillWidth: true; opacity: 0.65 }
                    Label { visible: app.selectedMint.sync === "retrying"; text: "Mint sync needs another attempt. Displayed balances may be out of date."; Layout.fillWidth: true; opacity: 0.65 }
                    RowLayout {
                        spacing: Style.space(10)
                        Label { text: app.selectedMint.spendable; font.pixelSize: Style.space(60) }
                        Label { text: "sats"; opacity: 0.6; Layout.alignment: Qt.AlignBaseline }
                    }
                    Label {
                        visible: app.selectedMint.pending !== "0" || app.selectedMint.reserved !== "0"
                        text: app.selectedMint.pending + " pending · " + app.selectedMint.reserved + " reserved"
                        opacity: 0.6
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
                        Ui.Button { text: "Refresh"; enabled: backend.unlocked && !backend.busy; focusable: true; onClicked: backend.request("sync") }
                    }
                    Item { Layout.preferredHeight: Style.space(24) }
                    Label { visible: !(backend.state.history || []).length; text: "Your payments will appear here."; opacity: 0.55; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Repeater {
                        model: backend.state.history || []
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            ColumnLayout {
                                Layout.fillWidth: true
                                Label { text: modelData.kind + " · " + modelData.status }
                                Label { text: new Date(modelData.timestamp * 1000).toLocaleString(); opacity: 0.55; font.pixelSize: Style.font.caption }
                            }
                            Label { text: (modelData.direction === "Incoming" ? "+" : "−") + modelData.amount + " sats" }
                        }
                    }
                    Label { visible: (backend.state.pending_invoices || []).length > 0; text: "Pending invoices"; font.bold: true }
                    Repeater {
                        model: backend.state.pending_invoices || []
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            Label { text: modelData.amount + " sats · " + (modelData.expiry * 1000 < Date.now() ? "expired" : "awaiting payment"); Layout.fillWidth: true }
                            Action { text: "Show"; enabled: !backend.busy; onClicked: backend.request("show_invoice", {operation_id: modelData.id}) }
                        }
                    }
                    Label { visible: (backend.state.pending_sends || []).length > 0; text: "Unclaimed ecash"; font.bold: true }
                    Repeater {
                        model: backend.state.pending_sends || []
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            Action { text: "Show token"; enabled: !backend.busy; Layout.fillWidth: true; onClicked: backend.request("show_pending_token", {operation_id: modelData.id}) }
                            Action { text: "Reclaim"; enabled: !backend.busy; Layout.fillWidth: true; onClicked: backend.request("reclaim_token", {operation_id: modelData.id}) }
                        }
                    }
                    Item { Layout.preferredHeight: Style.space(36) }
                }

                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "send"
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
                    ScanButtons { target: "send" }
                    Action {
                        text: backend.busy ? "Preparing…" : "Review payment"
                        enabled: backend.unlocked && !backend.busy && (app.paymentText.length > 0 || app.amountText.length > 0)
                        Layout.fillWidth: true
                        onClicked: backend.request(app.paymentText.trim() ? "pay_invoice" : "send_ecash", {text: app.paymentText, amount: app.amountText})
                    }
                }

                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "receive"
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
                        text: app.receiveText
                        onTextEdited: app.receiveText = text
                    }
                    Label {
                        text: app.receiveMethod === "lightning" ? "Create an invoice to pay from another Lightning wallet." : "Redeem a token with its issuing mint."
                        opacity: 0.65
                        Layout.fillWidth: true
                    }
                    ScanButtons { target: "receive"; visible: app.receiveMethod === "ecash" }
                    Action {
                        text: backend.busy ? "Preparing…" : (app.receiveMethod === "lightning" ? "Create invoice" : "Review token")
                        enabled: backend.unlocked && !backend.busy && app.receiveText.length > 0
                        Layout.fillWidth: true
                        onClicked: backend.request(app.receiveMethod === "lightning" ? "create_invoice" : "receive_token", {text: app.receiveText, amount: app.receiveText})
                    }
                }

                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "share"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: backend.share.token ? "Share ecash" : "Lightning invoice"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { visible: !!backend.share.expiry; text: "Expires " + new Date((backend.share.expiry || 0) * 1000).toLocaleString(); Layout.fillWidth: true; opacity: 0.65 }
                    Label { visible: !!backend.share.token && !backend.share.qr; text: "This token is too large for one QR code. Use Copy to share it."; Layout.fillWidth: true }
                    Image { source: backend.share.qr || ""; visible: source.toString() !== ""; Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: Math.min(300, window.width - 64); Layout.preferredHeight: Layout.preferredWidth; fillMode: Image.PreserveAspectFit }
                    Controls.TextArea {
                        Layout.fillWidth: true
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.WrapAnywhere
                        text: backend.share.token || backend.share.invoice || ""
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        background: Rectangle { color: "transparent" }
                    }
                    Action {
                        text: "Copy"
                        enabled: !clipboard.running
                        Layout.fillWidth: true
                        onClicked: {
                            app.clipboardText = backend.share.token || backend.share.invoice || ""
                            clipboard.stdinEnabled = true
                            clipboard.running = true
                        }
                    }
                    Label { text: backend.share.token ? "Anyone with this token can redeem it. You can reopen unclaimed tokens from History." : "Payment will be checked in the background while your wallet is unlocked."; opacity: 0.65; Layout.fillWidth: true }
                    Action { text: "Done"; Layout.fillWidth: true; onClicked: { backend.share = {}; app.page = "home" } }
                }

                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "settings"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: "Settings"; font.pixelSize: Style.font.heading; font.bold: true }
                    Label { text: "Mints"; font.bold: true }
                    Ui.Dropdown {
                        Layout.fillWidth: true
                        value: ""
                        options: [{value: "", label: "Choose a suggested mint…"}].concat(app.suggestions.map(mint => ({value: mint.url, label: mint.name})))
                        onChanged: value => app.mintUrl = value
                    }
                    Ui.TextField {
                        Layout.fillWidth: true
                        placeholderText: "https://mint.example.com"
                        text: app.mintUrl
                        onTextEdited: app.mintUrl = text
                    }
                    Label { text: "Adding a mint means trusting its operator to redeem your ecash."; opacity: 0.6; Layout.fillWidth: true }
                    Action {
                        text: backend.busy ? "Checking mint…" : "Trust and add mint"
                        enabled: backend.unlocked && !backend.busy && app.mintUrl.length > 0
                        Layout.fillWidth: true
                        onClicked: backend.request("add_mint", {url: app.mintUrl})
                    }
                    Divider {}
                    Label { text: "Security"; font.bold: true }
                    Label {
                        text: backend.state.password_required ? "Password protection is on. Your wallet locks with the desktop."
                            : "Password protection is optional. Without it, anyone using your desktop account can open this wallet."
                        opacity: 0.65; Layout.fillWidth: true
                    }
                    Ui.TextField { id: securityPassword; visible: !backend.state.password_required; password: true; placeholderText: "New password (12+ characters)"; Layout.fillWidth: true }
                    Ui.TextField { id: securityConfirmation; visible: !backend.state.password_required; password: true; placeholderText: "Repeat password"; Layout.fillWidth: true }
                    Action {
                        id: enablePasswordButton
                        visible: !backend.state.password_required
                        text: "Enable password"
                        Layout.fillWidth: true
                        enabled: backend.unlocked && !backend.busy && securityPassword.text.length >= 12 && securityPassword.text === securityConfirmation.text
                        onClicked: { backend.request("set_password", {password: securityPassword.text}); securityPassword.clear(); securityConfirmation.clear() }
                    }
                    Label { visible: !backend.state.password_required && securityConfirmation.text.length > 0 && securityPassword.text !== securityConfirmation.text; text: "Passwords do not match."; Layout.fillWidth: true; opacity: 0.65 }
                    Ui.TextField { id: currentPassword; visible: backend.state.password_required === true; password: true; placeholderText: "Current password to remove protection"; Layout.fillWidth: true }
                    Action {
                        visible: backend.state.password_required === true
                        text: "Remove password"
                        Layout.fillWidth: true
                        enabled: backend.unlocked && !backend.busy && currentPassword.text.length > 0
                        onClicked: { backend.request("remove_password", {password: currentPassword.text}); currentPassword.clear() }
                    }
                    Divider {}
                    Label { text: "Backup & recovery"; font.bold: true }
                    Action { text: "Show recovery phrase"; enabled: backend.unlocked && !backend.busy; Layout.fillWidth: true; onClicked: backend.request("recovery_phrase") }
                    Label { visible: backend.recoveryPhrase !== ""; text: backend.recoveryPhrase; Layout.fillWidth: true; font.bold: true }
                    Label { visible: backend.recoveryPhrase !== ""; text: (backend.state.mints || []).map(mint => mint.url).join("\n"); Layout.fillWidth: true }
                    Label { visible: backend.recoveryPhrase !== ""; text: "Write these words down privately, together with your mint URLs. This view hides after one minute. A phrase does not restore your full history."; opacity: 0.65; Layout.fillWidth: true }
                    Ui.Button { visible: backend.recoveryPhrase !== ""; text: "Hide phrase"; focusable: true; onClicked: backend.recoveryPhrase = "" }
                    Ui.TextField { id: backupPassword; password: true; placeholderText: "Backup password (12+ characters)"; Layout.fillWidth: true }
                    Ui.TextField { id: backupConfirmation; password: true; placeholderText: "Repeat backup password"; Layout.fillWidth: true }
                    Action {
                        text: "Export encrypted backup"
                        enabled: backend.unlocked && !backend.busy && backupPassword.text.length >= 12 && backupPassword.text === backupConfirmation.text
                        Layout.fillWidth: true
                        onClicked: exportDialog.open()
                    }
                    Label { text: "Full backup restore is available when setting up a new wallet. It never overwrites an existing wallet."; opacity: 0.65; Layout.fillWidth: true }
                    Divider {}
                    Label { text: "Closing the window keeps Chaumarchy running. Open it again with the launcher."; opacity: 0.65; Layout.fillWidth: true }
                    Action { text: "Lock wallet"; visible: backend.state.password_required === true; enabled: backend.unlocked; Layout.fillWidth: true; onClicked: backend.lock() }
                    Action { text: "Quit Chaumarchy"; Layout.fillWidth: true; onClicked: Qt.quit() }
                }

                Divider {}
                Label {
                    visible: app.walletVisible
                    text: backend.preview ? "Interface preview · wallet actions are disabled." : "Development build · validation in progress."
                    font.pixelSize: Style.font.caption
                    opacity: 0.55
                    Layout.fillWidth: true
                }
            }
        }
    }
}
