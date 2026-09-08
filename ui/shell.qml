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
    property var trail: []
    property string historyFilter: "all"
    property string historySearch: ""
    property var transaction: ({})
    property bool revealShare: false
    readonly property bool mainPage: ["home", "history", "mints"].indexOf(page) >= 0
    readonly property var activity: (backend.state.history || []).filter(tx => {
        var direction = historyFilter === "all" || (historyFilter === "received" ? tx.direction === "Incoming" : tx.direction === "Outgoing")
        return direction && (tx.kind + " " + tx.status + " " + tx.amount).toLowerCase().indexOf(historySearch.toLowerCase()) >= 0
    })
    function sats(value) { return String(value || "0").replace(/\B(?=(\d{3})+(?!\d))/g, " ") }
    function titleFor(tx) { return (tx.kind || "Payment") + (tx.direction === "Incoming" ? " received" : " sent") }
    function dayFor(tx) { return tx && tx.timestamp ? new Date(tx.timestamp * 1000).toLocaleDateString() : "" }
    function go(destination) {
        if (backend.busy || backend.review) return
        if (destination === "scan") scanTarget = "payment"
        trail = trail.concat([page])
        page = destination
        backend.error = ""
    }
    function tab(destination) {
        if (backend.busy || backend.review) return
        trail = []
        page = destination
        backend.error = ""
    }
    function back() {
        if (backend.review) { backend.request("cancel_payment", {review_id: backend.reviewId}); return }
        if (backend.busy) return
        if (page === "share" || page === "complete") {
            backend.share = {}; backend.completion = {}; trail = []; page = "home"; return
        }
        page = trail.length ? trail[trail.length - 1] : "home"
        trail = trail.slice(0, -1)
    }
    onPageChanged: {
        contentScroll.contentItem.contentY = 0
        if (page !== "backup") backend.recoveryPhrase = ""
        if (page !== "share") { backend.share = {}; app.revealShare = false }
        if (page !== "scan") scanner.running = false
    }
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
        onShowResult: { app.revealShare = false; app.trail = []; app.page = "share" }
        onPaymentFinished: { app.trail = []; app.page = "complete" }
        onMintAdded: { app.trail = []; app.page = "home" }
        onReadyChanged: app.maybeOpen()
        onStateChanged: app.maybeOpen()
        onErrorChanged: if (backend.error) contentScroll.contentItem.contentY = 0
        onLocked: {
            app.page = "home"
            app.trail = []
            app.transaction = {}
            app.revealShare = false
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
                        if (app.scanTarget === "mint") {
                            app.mintUrl = result.text.trim(); app.page = "add_mint"
                        } else if (result.text.trim().startsWith("cashu")) {
                            app.receiveText = result.text; app.page = "receive_token"
                        } else { app.paymentText = result.text; app.page = "send" }
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
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
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
    component Entry: Ui.Button {
        id: entry
        property string heading: ""
        property string detail: ""
        property string trailing: "›"
        text: ""
        focusable: true
        Layout.fillWidth: true
        implicitHeight: entryContent.implicitHeight + Style.space(24)
        implicitWidth: Style.space(240)
        opacity: enabled ? 1 : 0.4
        Accessible.name: heading + ". " + detail + ". " + trailing
        RowLayout {
            id: entryContent
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(16)
            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(5)
                Label { text: entry.heading; font.bold: true; Layout.fillWidth: true }
                Label { visible: entry.detail !== ""; text: entry.detail; opacity: 0.6; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
            }
            Label { text: entry.trailing; font.pixelSize: Style.font.body; Layout.alignment: Qt.AlignVCenter }
        }
    }
    component MintPicker: Ui.Dropdown {
        Layout.fillWidth: true
        enabled: !backend.busy && !backend.review
        value: backend.state.selected || ""
        options: (backend.state.mints || []).map(mint => ({value: mint.url, label: mint.name + " · " + app.sats(mint.spendable) + " sats"}))
        onChanged: value => backend.request("select_mint", {url: value})
    }
    component DetailRow: RowLayout {
        property string heading: ""
        property string value: ""
        Layout.fillWidth: true
        Label { text: parent.heading; opacity: 0.6 }
        Label { text: parent.value; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight }
    }
    component ScanButtons: RowLayout {
        property string target: app.scanTarget
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
        Shortcut { sequence: "Escape"; onActivated: app.back() }
        Shortcut { sequence: "Alt+Left"; onActivated: app.back() }
        Shortcut { sequence: "Ctrl+1"; enabled: app.walletVisible; onActivated: app.tab("home") }
        Shortcut { sequence: "Ctrl+2"; enabled: app.walletVisible; onActivated: app.tab("history") }
        Shortcut { sequence: "Ctrl+3"; enabled: app.walletVisible; onActivated: app.tab("mints") }
        Shortcut { sequence: "Ctrl+Comma"; enabled: !backend.review; onActivated: app.go("settings") }

        Rectangle {
            id: surface
            anchors.fill: parent
            color: Color.background
        Controls.ScrollView {
            id: contentScroll
            anchors.fill: parent
            anchors.margins: Style.space(26)
            anchors.bottomMargin: navigation.visible ? navigation.height + Style.space(40) : Style.space(26)
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: Math.min(contentScroll.availableWidth, Style.space(460))
                x: (contentScroll.availableWidth - width) / 2
                spacing: Style.space(22)

                RowLayout {
                    Layout.fillWidth: true
                    Label { text: "CHAUMARCHY"; font.bold: true; font.letterSpacing: 1.5; Layout.fillWidth: true }
                    Ui.Button { text: "Scan"; visible: app.walletVisible && app.mainPage; enabled: !backend.busy; focusable: true; onClicked: app.go("scan") }
                    Ui.Button {
                        enabled: !backend.review && !backend.busy
                        visible: app.walletVisible
                        text: app.mainPage ? "Settings" : "← Back"
                        focusable: true
                        onClicked: app.mainPage ? app.go("settings") : app.back()
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
                Label { visible: backend.notice !== "" && app.page !== "complete"; text: backend.notice; Layout.fillWidth: true }
                Label { visible: scanner.running; text: "Scanning… Hold one QR code steady. Scanning stops after one minute."; Layout.fillWidth: true; opacity: 0.65 }
                Ui.Button { visible: scanner.running; text: "Cancel scan"; focusable: true; onClicked: scanner.running = false }

                ColumnLayout {
                    visible: !!backend.review
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: backend.review ? backend.review.kind : ""; font.pixelSize: Style.font.heading; font.bold: true }
                    Label { text: backend.review && backend.review.amount ? app.sats(backend.review.amount) + " sats" : "Reclaim unspent ecash"; font.pixelSize: Style.space(36); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Divider {}
                    DetailRow { heading: "Mint"; value: backend.review ? backend.review.mint : "" }
                    DetailRow { visible: !!backend.review && !!backend.review.fee; heading: "Maximum fee"; value: backend.review ? app.sats(backend.review.fee) + " sats" : "" }
                    DetailRow { visible: !!backend.review && !!backend.review.total; heading: "Maximum total"; value: backend.review ? app.sats(backend.review.total) + " sats" : "" }
                    Label { visible: !!backend.review && backend.review.receiving === true; text: "The mint may deduct an input fee. You will see the amount received after redemption."; Layout.fillWidth: true; opacity: 0.65 }
                    Action {
                        id: confirmButton
                        text: backend.busy ? "Processing…" : (!backend.review ? "Confirm" : backend.review.reclaim ? "Reclaim ecash" : backend.review.receiving ? "Receive ecash" : backend.review.kind === "Send ecash" ? "Create token" : "Pay invoice")
                        enabled: !backend.busy
                        Layout.fillWidth: true
                        onClicked: backend.request("confirm_payment", {review_id: backend.reviewId})
                    }
                    Ui.Button { text: "Cancel"; focusable: true; enabled: !backend.busy; Layout.alignment: Qt.AlignHCenter; onClicked: backend.request("cancel_payment", {review_id: backend.reviewId}) }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "home"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Item { Layout.preferredHeight: Style.space(10) }
                    Ui.Button { text: app.selectedMint.name + "  ⌄"; focusable: true; Layout.alignment: Qt.AlignHCenter; onClicked: app.go("mints") }
                    Label { text: app.sats(app.selectedMint.spendable); font.pixelSize: Style.space(54); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { text: "sats"; opacity: 0.55; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { visible: backend.state.restoring === true; text: "Recovering from your mints…"; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; opacity: 0.6 }
                    Label { visible: app.selectedMint.sync === "retrying"; text: "Mint unavailable. Balance may be out of date."; Layout.fillWidth: true; opacity: 0.6 }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        Action { text: "↓  Receive"; Layout.fillWidth: true; onClicked: app.go("receive") }
                        Action { text: "↑  Send"; Layout.fillWidth: true; onClicked: app.go("send") }
                    }
                    Entry { visible: !(backend.state.mints || []).length; heading: "Choose your first mint"; detail: "A mint issues and redeems your ecash."; onClicked: app.go("add_mint") }
                    Entry { visible: app.selectedMint.pending !== "0" || app.selectedMint.reserved !== "0"; heading: "Pending activity"; detail: app.sats(app.selectedMint.pending) + " pending · " + app.sats(app.selectedMint.reserved) + " reserved"; onClicked: app.tab("history") }
                    Divider {}
                    Label { text: "RECENT"; opacity: 0.55; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                    Label { visible: !(backend.state.history || []).length; text: "No payments yet"; opacity: 0.6; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Repeater {
                        model: (backend.state.history || []).slice(0, 3)
                        delegate: Entry {
                            required property var modelData
                            heading: (modelData.direction === "Incoming" ? "↓  " : "↑  ") + app.titleFor(modelData)
                            detail: app.dayFor(modelData) + " · " + modelData.status
                            trailing: (modelData.direction === "Incoming" ? "+" : "−") + app.sats(modelData.amount) + " sats"
                            onClicked: { app.transaction = Object.assign({mint: app.selectedMint.url}, modelData); app.go("transaction") }
                        }
                    }
                    Ui.Button { text: "View all activity  ›"; focusable: true; Layout.alignment: Qt.AlignHCenter; onClicked: app.tab("history") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "history"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    RowLayout { Layout.fillWidth: true; Label { text: "History"; font.pixelSize: Style.font.heading; font.bold: true; Layout.fillWidth: true } Ui.Button { text: "Refresh"; focusable: true; enabled: !backend.busy; onClicked: backend.request("sync") } }
                    MintPicker {}
                    Ui.TextField { Layout.fillWidth: true; placeholderText: "Search activity"; text: app.historySearch; onTextEdited: app.historySearch = text }
                    RowLayout {
                        Layout.fillWidth: true
                        Repeater { model: [{id:"all", name:"All"}, {id:"received", name:"Received"}, {id:"sent", name:"Sent"}]
                            delegate: Ui.Button { required property var modelData; Layout.fillWidth: true; text: modelData.name; selected: app.historyFilter === modelData.id; focusable: true; onClicked: app.historyFilter = modelData.id }
                        }
                    }
                    Label { visible: !app.activity.length; text: "No matching activity"; opacity: 0.6 }
                    Repeater {
                        model: app.activity
                        delegate: ColumnLayout {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            Label { visible: index === 0 || app.dayFor(modelData) !== app.dayFor(app.activity[index - 1]); text: app.dayFor(modelData); opacity: 0.55; font.pixelSize: Style.font.caption }
                            Entry {
                                heading: (modelData.direction === "Incoming" ? "↓  " : "↑  ") + app.titleFor(modelData)
                                detail: modelData.status
                                trailing: (modelData.direction === "Incoming" ? "+" : "−") + app.sats(modelData.amount) + " sats"
                                onClicked: { app.transaction = Object.assign({mint: app.selectedMint.url}, modelData); app.go("transaction") }
                            }
                        }
                    }
                    Label { text: "Showing up to 100 recent payments for this mint."; opacity: 0.5; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
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
                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            Label { text: modelData.amount ? app.sats(modelData.amount) + " sats · pending ecash" : "Pending ecash"; Layout.fillWidth: true }
                            RowLayout { Layout.fillWidth: true
                            Action { text: "Show token"; enabled: !backend.busy; Layout.fillWidth: true; onClicked: backend.request("show_pending_token", {operation_id: modelData.id}) }
                            Action { text: "Reclaim"; enabled: !backend.busy; Layout.fillWidth: true; onClicked: backend.request("reclaim_token", {operation_id: modelData.id}) }
                            }
                        }
                    }

                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "transaction"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: app.titleFor(app.transaction); font.bold: true; font.pixelSize: Style.font.heading }
                    Label { text: app.sats(app.transaction.amount) + " sats"; font.pixelSize: Style.space(38); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    DetailRow { heading: "Status"; value: app.transaction.status || "" }
                    DetailRow { heading: "Fee"; value: app.sats(app.transaction.fee) + " sats" }
                    DetailRow { heading: "Date"; value: app.transaction.timestamp ? new Date(app.transaction.timestamp * 1000).toLocaleString() : "" }
                    DetailRow { heading: "Mint"; value: app.transaction.mint || "" }
                    Divider {}
                    Label { text: "Transfer reference"; opacity: 0.6 }
                    Label { text: app.transaction.id || ""; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "send"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: "Send"; font.pixelSize: Style.font.heading; font.bold: true }
                    Ui.TextField { id: invoiceInput; Layout.fillWidth: true; placeholderText: "Paste a Lightning invoice"; text: app.paymentText; onTextEdited: app.paymentText = text; onAccepted: if (invoiceReview.enabled) invoiceReview.clicked() }
                    Action { id: invoiceReview; visible: app.paymentText.trim() !== ""; text: backend.busy ? "Preparing…" : "Review invoice"; enabled: !backend.busy && !!backend.state.selected; Layout.fillWidth: true; onClicked: backend.request("pay_invoice", {text: app.paymentText}) }
                    Entry { heading: "Scan a payment"; detail: "Read a QR from your screen, an image, or camera."; onClicked: app.go("scan") }
                    Entry { id: ecashChoice; heading: "Send ecash"; detail: "Create a token to share with someone."; onClicked: { app.amountText = ""; app.go("send_amount") } }
                    Entry { visible: !backend.state.selected; heading: "Choose a mint first"; onClicked: app.go("mints") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "receive"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: "Receive"; font.pixelSize: Style.font.heading; font.bold: true }
                    Entry { id: lightningChoice; heading: "Lightning"; detail: "Create an invoice to receive from another wallet."; onClicked: { app.receiveText = ""; app.go("receive_amount") } }
                    Entry { heading: "Ecash"; detail: "Redeem a Cashu token someone sent you."; onClicked: { app.receiveText = ""; app.go("receive_token") } }
                    Entry { heading: "Scan a token"; detail: "Read a QR from your screen, an image, or camera."; onClicked: app.go("scan") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && (app.page === "send_amount" || app.page === "receive_amount")
                    Layout.fillWidth: true
                    spacing: Style.space(24)
                    Label { text: app.page === "send_amount" ? "Send ecash" : "Receive Lightning"; font.pixelSize: Style.font.heading; font.bold: true }
                    MintPicker {}
                    Label { text: app.sats(app.selectedMint.spendable) + " sats available"; opacity: 0.6; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Item { Layout.preferredHeight: Style.space(16) }
                    Ui.TextField {
                        id: amountInput
                        Layout.fillWidth: true
                        placeholderText: "0"
                        horizontalAlignment: TextInput.AlignHCenter
                        font.pixelSize: Style.space(46)
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: RegularExpressionValidator { regularExpression: /[0-9]{0,16}/ }
                        text: app.page === "send_amount" ? app.amountText : app.receiveText
                        onTextEdited: { if (app.page === "send_amount") app.amountText = text; else app.receiveText = text }
                        onAccepted: if (amountContinue.enabled) amountContinue.clicked()
                    }
                    Label { text: "sats"; opacity: 0.55; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { text: app.page === "send_amount" ? "Review the amount and any fees before creating your token." : "Share the invoice with the person paying you."; opacity: 0.6; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Action {
                        id: amountContinue
                        text: backend.busy ? "Preparing…" : app.page === "send_amount" ? "Review ecash" : "Create invoice"
                        Layout.fillWidth: true
                        enabled: backend.unlocked && !backend.busy && !!backend.state.selected && /[1-9]/.test(app.page === "send_amount" ? app.amountText : app.receiveText)
                        onClicked: backend.request(app.page === "send_amount" ? "send_ecash" : "create_invoice", {amount: app.page === "send_amount" ? app.amountText : app.receiveText})
                    }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "receive_token"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: "Receive ecash"; font.pixelSize: Style.font.heading; font.bold: true }
                    Ui.TextField { Layout.fillWidth: true; placeholderText: "Paste a Cashu token"; text: app.receiveText; onTextEdited: app.receiveText = text }
                    Label { text: "The token is redeemed with its issuing mint. Add an unfamiliar mint before receiving its ecash."; Layout.fillWidth: true; opacity: 0.6 }
                    Action { text: backend.busy ? "Preparing…" : "Review token"; Layout.fillWidth: true; enabled: backend.unlocked && !backend.busy && app.receiveText.trim() !== ""; onClicked: backend.request("receive_token", {text: app.receiveText}) }
                    Ui.Button { text: "Scan instead"; focusable: true; onClicked: app.go("scan") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "scan"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: "Scan a QR code"; font.pixelSize: Style.font.heading; font.bold: true }
                    Label { text: app.scanTarget === "mint" ? "Scan a mint URL, then review it before adding." : "Lightning invoices and Cashu tokens are recognized automatically."; Layout.fillWidth: true; opacity: 0.6 }
                    ScanButtons {}
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "share"
                    Layout.fillWidth: true
                    spacing: Style.space(20)
                    Label { text: backend.share.token ? "Pending ecash" : "Lightning invoice"; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Image { source: backend.share.qr || ""; visible: source.toString() !== ""; Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: Math.min(280, contentScroll.availableWidth); Layout.preferredHeight: Layout.preferredWidth; fillMode: Image.PreserveAspectFit }
                    Label { text: app.sats(backend.share.amount) + " sats"; visible: !!backend.share.amount; font.pixelSize: Style.space(32); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { text: backend.share.token ? "Ready to share" : "Waiting for payment"; opacity: 0.6; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    DetailRow { heading: "Mint"; value: backend.share.mint || app.selectedMint.name }
                    DetailRow { visible: !!backend.share.expiry; heading: "Expires"; value: new Date((backend.share.expiry || 0) * 1000).toLocaleString() }
                    Label { visible: !!backend.share.token && !backend.share.qr; text: "Too large for one QR code. Copy the token to share it."; Layout.fillWidth: true }
                    Action {
                        text: clipboard.running ? "Copied · waiting for paste" : backend.share.token ? "Copy token" : "Copy invoice"
                        enabled: !clipboard.running
                        Layout.fillWidth: true
                        onClicked: { app.clipboardText = backend.share.token || backend.share.invoice || ""; clipboard.stdinEnabled = true; clipboard.running = true }
                    }
                    Ui.Button { text: app.revealShare ? "Hide text" : "Show full text"; focusable: true; Layout.alignment: Qt.AlignHCenter; onClicked: app.revealShare = !app.revealShare }
                    Controls.TextArea {
                        visible: app.revealShare
                        Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere
                        text: backend.share.token || backend.share.invoice || ""; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption
                        background: Rectangle { color: "transparent" }
                    }
                    Label { text: backend.share.token ? "Anyone holding this token can redeem it. Reopen or reclaim it from History." : "You can close this window. Your unlocked wallet keeps checking for payment."; opacity: 0.6; Layout.fillWidth: true }
                    Ui.Button { text: "Done"; focusable: true; Layout.alignment: Qt.AlignHCenter; onClicked: app.back() }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "complete"
                    Layout.fillWidth: true
                    spacing: Style.space(24)
                    Item { Layout.preferredHeight: Style.space(36) }
                    Label { text: "✓"; font.pixelSize: Style.space(42); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { text: backend.completion.paid ? "Payment sent" : backend.completion.reclaimed ? "Ecash reclaimed" : "Payment received"; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { text: app.sats(backend.completion.amount) + " sats"; font.pixelSize: Style.space(40); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Action { text: "Back to wallet"; Layout.fillWidth: true; onClicked: app.back() }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "mints"
                    Layout.fillWidth: true
                    spacing: Style.space(18)
                    Label { text: "Mints"; font.bold: true; font.pixelSize: Style.font.heading }
                    Repeater {
                        model: backend.state.mints || []
                        delegate: Entry {
                            required property var modelData
                            heading: modelData.name
                            detail: modelData.url + (modelData.sync === "retrying" ? " · unavailable" : "")
                            trailing: app.sats(modelData.spendable) + " sats" + (modelData.url === backend.state.selected ? " ✓" : "")
                            selected: modelData.url === backend.state.selected
                            enabled: !backend.busy
                            onClicked: { backend.request("select_mint", {url: modelData.url}); app.page = "home"; app.trail = [] }
                        }
                    }
                    Entry { heading: "+  Add a mint"; detail: "Choose a suggestion or use a mint URL."; onClicked: app.go("add_mint") }
                    Label { text: "Each mint holds a separate balance. Choose one to view its activity and make payments."; opacity: 0.6; Layout.fillWidth: true }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "add_mint"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: "Add a mint"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { text: "SUGGESTED"; opacity: 0.55; font.pixelSize: Style.font.caption }
                    Repeater {
                        model: app.suggestions
                        delegate: Entry { required property var modelData; heading: modelData.name; detail: modelData.url; trailing: app.mintUrl === modelData.url ? "✓" : "›"; selected: app.mintUrl === modelData.url; onClicked: app.mintUrl = modelData.url }
                    }
                    Ui.TextField { id: mintInput; Layout.fillWidth: true; placeholderText: "Or enter a mint URL"; text: app.mintUrl; onTextEdited: app.mintUrl = text }
                    Ui.Button { text: "Scan mint URL"; focusable: true; onClicked: { app.go("scan"); app.scanTarget = "mint" } }
                    Label { text: "Adding a mint means trusting its operator to redeem your ecash."; opacity: 0.6; Layout.fillWidth: true }
                    Action { id: addMintButton; text: backend.busy ? "Checking mint…" : "Trust and add mint"; enabled: backend.unlocked && !backend.busy && app.mintUrl.trim() !== ""; Layout.fillWidth: true; onClicked: backend.request("add_mint", {url: app.mintUrl}) }
                    Ui.Button { text: "View my mints"; focusable: true; onClicked: app.tab("mints") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "settings"
                    Layout.fillWidth: true
                    spacing: Style.space(18)
                    Label { text: "Settings"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { text: "WALLET"; opacity: 0.55; font.pixelSize: Style.font.caption }
                    Entry { heading: "Backup & recovery"; detail: "Recovery words and encrypted backups"; onClicked: app.go("backup") }
                    Entry { heading: "Security"; detail: backend.state.password_required ? "Password protection on" : "Password protection off"; onClicked: app.go("security") }
                    Entry { heading: "Mints"; detail: (backend.state.mints || []).length + " added"; onClicked: app.go("mints") }
                    Divider {}
                    Label { text: "Closing the window keeps your unlocked wallet monitoring payments."; opacity: 0.6; Layout.fillWidth: true }
                    Action { text: "Lock wallet"; visible: backend.state.password_required === true; enabled: backend.unlocked; Layout.fillWidth: true; onClicked: backend.lock() }
                    Ui.Button { text: "Quit Chaumarchy"; focusable: true; onClicked: Qt.quit() }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "security"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
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

                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "backup"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
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

                }

                Divider { visible: app.walletVisible && app.page === "settings" }
                Label {
                    visible: app.walletVisible && app.page === "settings"
                    text: backend.preview ? "Interface preview · wallet actions are disabled." : "Development build · validation in progress."
                    font.pixelSize: Style.font.caption
                    opacity: 0.55
                    Layout.fillWidth: true
                }
            }
        }
        RowLayout {
            id: navigation
            visible: app.walletVisible && app.mainPage && !backend.review
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottomMargin: Style.space(14)
            width: Math.min(parent.width - Style.space(52), Style.space(460))
            height: Style.space(42)
            spacing: Style.space(12)
            Repeater {
                model: [{id:"home", label:"Wallet"}, {id:"history", label:"History"}, {id:"mints", label:"Mints"}]
                delegate: Ui.Button { required property var modelData; text: modelData.label; selected: app.page === modelData.id; focusable: true; Layout.fillWidth: true; Layout.fillHeight: true; enabled: !backend.busy; onClicked: app.tab(modelData.id) }
            }
        }
        }
    }
}
