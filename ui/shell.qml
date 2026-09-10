import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "ClockFormat.js" as ClockFormat

ShellRoot {
    id: app
    property bool compact: Quickshell.env("CHAUMARCHY_WINDOW") !== "1" && Quickshell.env("CHAUMARCHY_PREVIEW") !== "1"
    property bool presentationMotion: Quickshell.env("CHAUMARCHY_ANIMATE") === "1"
    property real anchorX: Number(Quickshell.env("CHAUMARCHY_ANCHOR_X") || "-1")
    MotionPreferences { id: motion }
    property bool presented: true
    property string outputName: Quickshell.env("CHAUMARCHY_SCREEN") || ""
    property double dismissedAt: 0
    // Secrets never survive hiding. Navigation and a prepared payment do: the
    // panel is dismissed casually and reopened from the bar, and a review must
    // stay reviewable across that.
    function clearSecrets() {
        backend.recoveryPhrase = ""
        revealShare = false
        receiveText = ""
        clipboardText = ""
        password.clear()
        securityPassword.clear()
        securityConfirmation.clear()
        currentPassword.clear()
        backupPassword.clear()
        backupConfirmation.clear()
        restorePassword.clear()
        restoreWords.clear()
        restoreMints.clear()
    }
    function dismiss(immediate, outside) {
        if (immediate === true) presentationMotion = false
        presented = false
        clearSecrets()
        scanner.running = false
        dismissedAt = outside === true ? Date.now() : 0
    }
    function present(asWindow, animate) {
        presentationMotion = animate === true
        compact = !asWindow
        presented = true
    }
    property string page: "home"
    property var trail: []
    property string historyFilter: "all"
    property string historySearch: ""
    property var transaction: ({})
    property bool revealShare: false
    readonly property bool mainPage: ["home", "history", "mints"].indexOf(page) >= 0
    readonly property var activity: (backend.state.history || []).filter(tx => {
        var direction = historyFilter === "all" || (historyFilter === "received" ? tx.direction === "Incoming" : tx.direction === "Outgoing")
        return direction && (app.titleFor(tx) + " " + tx.status + " " + tx.amount + " " + (tx.mint_name || "")).toLowerCase().indexOf(historySearch.toLowerCase()) >= 0
    })
    // A space groups digits at one full monospace character's width in
    // Style.font.family, which reads as a much bigger gap between thousands
    // than a comma does at the same pixel size.
    function sats(value) { return String(value || "0").replace(/\B(?=(\d{3})+(?!\d))/g, ",") }
    // Display-only preferences (Settings → Display). Neither changes any
    // amount actually held or sent; every mint call stays in sats.
    readonly property bool bitcoinSymbol: !!(backend.state.display && backend.state.display.bitcoin_symbol)
    readonly property string fiatCurrency: (backend.state.display && backend.state.display.fiat_currency) || ""
    function setDisplay(useBitcoinSymbol, currency) { backend.request("set_display", {bitcoin_symbol: useBitcoinSymbol, fiat_currency: currency || ""}) }
    function currencyInfo(code) { return (backend.state.currencies || []).find(currency => currency.code === code) }
    // BIP-177 style: "₿21,000" instead of "21,000 sats". Applies everywhere
    // an amount is shown; the underlying value is always the same sats.
    function amountLabel(value) { return app.bitcoinSymbol ? "₿" + app.sats(value) : app.sats(value) + " sats" }
    // Once a local currency is enabled and its rate is known, every amount
    // shows both units: the primary one large, the other small and muted.
    // Tapping the home balance swaps which unit is primary, everywhere.
    property string balanceUnit: "bitcoin"
    onFiatCurrencyChanged: if (fiatCurrency === "") balanceUnit = "bitcoin"
    function cycleBalanceUnit() { if (app.fiatCurrency) app.balanceUnit = app.balanceUnit === "bitcoin" ? "fiat" : "bitcoin" }
    readonly property bool fiatAvailable: app.fiatCurrency !== "" && !!backend.state.exchange_rate && backend.state.exchange_rate.currency === app.fiatCurrency
    readonly property bool showingFiat: app.balanceUnit === "fiat" && app.fiatAvailable
    function fiatText(value) {
        var info = app.currencyInfo(app.fiatCurrency)
        var symbol = info ? info.symbol : ""
        var rate = backend.state.exchange_rate ? Number(backend.state.exchange_rate.rate) : 0
        var decimals = (app.fiatCurrency === "JPY" || app.fiatCurrency === "KRW") ? 0 : 2
        var exact = Number(value || 0) * rate / 100000000
        var converted = exact.toFixed(decimals)
        // A few sats round to nothing; "<$0.01" says there is a real amount.
        if (exact > 0 && Number(converted) === 0) return "<" + symbol + (decimals ? "0." + "0".repeat(decimals - 1) + "1" : "1")
        var pieces = converted.split(".")
        pieces[0] = app.sats(pieces[0])
        return symbol + pieces.join(".")
    }
    function primaryAmount(value) { return app.showingFiat ? app.fiatText(value) : app.amountLabel(value) }
    function secondaryAmount(value) { return app.showingFiat ? app.amountLabel(value) : app.fiatText(value) }
    readonly property string homeValue: app.primaryAmount(app.totalSpendable)
    readonly property string homeUnit: app.showingFiat ? app.fiatCurrency : (app.bitcoinSymbol ? "" : "sats")
    // iOS system green, the light and dark variants, chosen by the theme's
    // background. Omarchy themes have no green token of their own.
    readonly property color received: Color.background.hslLightness < 0.5 ? "#30D158" : "#34C759"
    // The worker identifies a mint by URL; people know it by name.
    function mintName(url) {
        var mint = app.mints.find(mint => mint.url === url)
        return mint ? mint.name : (url || "")
    }
    function titleFor(tx) {
        var lightning = tx.kind === "Lightning"
        return (tx.kind || "Payment") + (tx.direction === "Incoming" ? " received" : lightning ? " paid" : " sent")
    }
    // Dates follow the Omarchy clock format in shell.json, without the year.
    property var clockSettings: ({})
    readonly property string dateFormat: ClockFormat.dateFormat(clockSettings.format || ClockFormat.defaultFormat, clockSettings.formatAlt || ClockFormat.defaultAltFormat)
    readonly property string timeFormat: ClockFormat.timeFormat(clockSettings.format || ClockFormat.defaultFormat)
    function momentFor(seconds) { return seconds ? ClockFormat.format(new Date(seconds * 1000), dateFormat + " " + timeFormat) : "" }
    // Activity rows show the time for today's payments and the date otherwise.
    function whenFor(tx) {
        if (!tx || !tx.timestamp) return ""
        var when = new Date(tx.timestamp * 1000)
        return when.toDateString() === new Date().toDateString() ? ClockFormat.format(when, timeFormat) : ClockFormat.format(when, dateFormat)
    }
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
    // The amount being typed, in whichever unit the balance currently shows.
    // What is sent is always entrySats; a fiat figure is converted at the
    // current rate and the exact sats show beneath it.
    property string entryText: ""
    readonly property bool fiatEntry: app.showingFiat
    readonly property int fiatDecimals: (app.fiatCurrency === "JPY" || app.fiatCurrency === "KRW") ? 0 : 2
    readonly property real rate: backend.state.exchange_rate ? Number(backend.state.exchange_rate.rate) : 0
    readonly property double entrySats: app.fiatEntry ? Math.round(Number(app.entryText || 0) * 100000000 / app.rate) : Number(app.entryText || 0)
    readonly property bool entryOver: app.page === "send_amount" && app.entrySats > Number(app.selectedMint.spendable || 0)
    readonly property string entryDisplay: {
        if (!app.fiatEntry) return app.amountLabel(app.entryText || "0")
        var info = app.currencyInfo(app.fiatCurrency)
        var pieces = (app.entryText || "0").split(".")
        return (info ? info.symbol : "") + app.sats(pieces[0] || "0") + (pieces.length > 1 ? "." + pieces[1] : "")
    }
    function normalizeEntry(text) {
        var clean = text.replace(app.fiatEntry ? /[^0-9.]/g : /[^0-9]/g, "")
        if (app.fiatEntry) {
            var dot = clean.indexOf(".")
            if (dot >= 0) clean = clean.slice(0, dot + 1) + clean.slice(dot + 1).replace(/\./g, "").slice(0, app.fiatDecimals)
            if (app.fiatDecimals === 0) clean = clean.replace(/\./g, "")
        }
        return clean.replace(/^0+(?=\d)/, "").slice(0, 20)
    }
    // Swapping the unit keeps the sats constant and rewrites the typed text.
    function swapEntryUnit() {
        if (!app.fiatAvailable) return
        var current = app.entrySats
        app.cycleBalanceUnit()
        if (current <= 0) { app.entryText = ""; return }
        app.entryText = app.fiatEntry ? String(Number((current * app.rate / 100000000).toFixed(app.fiatDecimals))) : String(current)
    }
    function cycleMint() {
        var index = app.mints.findIndex(mint => mint.url === backend.state.selected)
        if (app.mints.length > 1) backend.request("select_mint", {url: app.mints[(index + 1) % app.mints.length].url})
    }
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
    property bool copyCancelled: false
    // Re-evaluated while a review is open so an expired quote is visible: the
    // worker pauses its state pushes for the whole 300 s review window.
    property double now: Date.now()
    readonly property bool reviewExpired: !!backend.review && !!backend.review.expiry && backend.review.expiry * 1000 < app.now
    readonly property bool walletVisible: backend.preview || backend.unlocked
    readonly property var selectedMint: {
        var mints = backend.state.mints || []
        return mints.find(mint => mint.url === backend.state.selected) || {name: "No mint selected", spendable: "0", pending: "0", reserved: "0"}
    }
    readonly property var mints: backend.state.mints || []
    function total(field) { return app.mints.reduce((sum, mint) => sum + Number(mint[field] || 0), 0) }
    readonly property double totalSpendable: total("spendable")
    readonly property double totalPending: total("pending")
    readonly property double totalReserved: total("reserved")
    readonly property var unavailableMints: app.mints.filter(mint => mint.sync === "retrying")
    FileView {
        path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
        watchChanges: true
        printErrors: false
        function apply() { try { app.clockSettings = ClockFormat.clockSettings(JSON.parse(text())) } catch (_) { app.clockSettings = {} } }
        onLoaded: apply()
        onFileChanged: reload()
        onLoadFailed: app.clockSettings = {}
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
        // Clearing a submitted secret waits for the worker to accept it: a
        // rejected recovery phrase used to be wiped, forcing the user to retype
        // every word from paper.
        onSucceeded: method => {
            if (method === "unlock" || method === "create") password.clear()
            if (method === "restore_phrase") { restoreWords.clear(); restoreMints.clear() }
            if (method === "restore_backup") restorePassword.clear()
            if (method === "export_backup") { backupPassword.clear(); backupConfirmation.clear() }
            if (method === "set_password") { securityPassword.clear(); securityConfirmation.clear() }
            if (method === "remove_password") currentPassword.clear()
        }
        onLocked: {
            app.page = "home"
            app.trail = []
            app.transaction = {}
            app.automaticOpenAttempted = false
            app.paymentText = ""
            app.entryText = ""
            app.clearSecrets()
            scanner.running = false
            app.copyCancelled = true
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
        // wl-copy holds the selection until it is pasted once. A non-zero exit
        // means the copy never happened, which was previously indistinguishable
        // from success and left the user pasting an empty clipboard.
        onExited: (code, status) => {
            app.clipboardText = ""
            if (code !== 0 && !app.copyCancelled) backend.error = "Could not copy. Check that wl-copy is available, or use Show full text."
            app.copyCancelled = false
        }
    }
    Timer { running: !!backend.review; interval: 1000; repeat: true; onTriggered: app.now = Date.now() }
    FileDialog {
        id: importDialog
        title: "Choose a Chaumarchy backup"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Chaumarchy backup (*.backup)", "All files (*)"]
        onAccepted: app.restorePath = decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, ""))
    }

    IpcHandler {
        target: "wallet"
        function show(): void { app.present(false) }
        function expand(): void { app.present(true) }
        function toggle(screenName: string): void {
            if (app.presented && app.compact && app.outputName === screenName) { app.dismiss(); return }
            // A click on the bar can also dismiss the compositor focus grab.
            if (!app.presented && Date.now() - app.dismissedAt < 200) return
            app.outputName = screenName
            app.present(false, true)
        }
        function toggleAt(screenName: string, originX: int): void {
            app.anchorX = originX
            toggle(screenName)
        }
        function hide(): void { app.dismiss() }
        function quit(): void { Qt.quit() }
        function status(): string {
            return JSON.stringify({mode: backend.preview ? "interface-preview" : "wallet", visible: app.presented, presentation: app.compact ? "panel" : "window",
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
    component Button: MotionButton { reducedMotion: motion.reduced }
    // Every full-size button fills its layout and takes an equal share of a
    // row. Qt sizes fill items from their text before sharing the rest, so
    // without a common preferred width "Receive" and "Send" ended up unequal.
    component Action: Button {
        focusable: true
        bordered: true
        opacity: enabled ? 1 : 0.4
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.minimumHeight: Style.space(38)
    }
    component Secondary: Button {
        focusable: true
        opacity: enabled ? 1 : 0.4
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.minimumHeight: Style.space(38)
    }
    component Tab: Button {
        focusable: true
        Layout.fillWidth: true
        Layout.preferredWidth: 1
    }
    // One payment in a list: a circled arrow, the type over the time, and the
    // amount in the primary unit over its conversion. Incoming amounts are
    // green; nothing in the row is bold.
    component ActivityRow: Button {
        id: activityRow
        required property var modelData
        readonly property bool incoming: modelData.direction === "Incoming"
        text: ""
        focusable: true
        Layout.fillWidth: true
        implicitHeight: activityContent.implicitHeight + Style.space(20)
        implicitWidth: Style.space(240)
        Accessible.name: app.titleFor(modelData) + ". " + app.whenFor(modelData) + ". " + (incoming ? "plus " : "") + app.primaryAmount(modelData.amount)
        onClicked: { app.transaction = modelData; app.go("transaction") }
        RowLayout {
            id: activityContent
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(14)
            Rectangle {
                Layout.preferredWidth: Style.space(36)
                Layout.preferredHeight: Style.space(36)
                radius: width / 2
                color: Qt.alpha(Color.foreground, 0.12)
                Text {
                    anchors.centerIn: parent
                    text: activityRow.incoming ? "󰁅" : "󰁝"
                    color: Color.foreground
                    opacity: 0.7
                    font.family: Style.font.family
                    font.pixelSize: Style.font.icon
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(3)
                Label { text: app.titleFor(activityRow.modelData); Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                Label { text: app.whenFor(activityRow.modelData); opacity: 0.55; font.pixelSize: Style.font.caption }
            }
            ColumnLayout {
                spacing: Style.space(3)
                Label {
                    text: (activityRow.incoming ? "+" : "") + app.primaryAmount(activityRow.modelData.amount)
                    color: activityRow.incoming ? app.received : Color.foreground
                    Layout.alignment: Qt.AlignRight
                }
                Label { visible: app.fiatAvailable; text: app.secondaryAmount(activityRow.modelData.amount); opacity: 0.55; font.pixelSize: Style.font.caption; Layout.alignment: Qt.AlignRight }
            }
        }
    }
    // A large amount with its conversion beneath, for the balance, a payment
    // detail and a completed payment.
    component AmountDisplay: ColumnLayout {
        id: display
        property var amount: 0
        property bool emphasized: false
        property int size: Style.space(38)
        // Rolling digits suit a value that changes in place, like the
        // balance. A record being opened, like a payment detail, is static.
        property bool animated: true
        Layout.fillWidth: true
        spacing: Style.space(4)
        Label { visible: !display.animated; text: app.primaryAmount(display.amount); font.bold: display.emphasized; font.pixelSize: display.size; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
        AnimatedAmount {
            visible: display.animated
            text: app.primaryAmount(display.amount)
            bold: display.emphasized
            fontSize: display.size
            fade: surface.color
            reducedMotion: motion.reduced
            maxWidth: display.width
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
        }
        Label { visible: app.fiatAvailable; text: app.secondaryAmount(display.amount); opacity: 0.55; font.pixelSize: Style.font.body; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
    }
    component IconButton: Button {
        text: ""
        focusable: true
        tooltipText: Accessible.name
        opacity: enabled ? 1 : 0.4
    }
    component Divider: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Color.foreground
        opacity: 0.15
    }
    component Entry: Button {
        id: entry
        property string heading: ""
        property string detail: ""
        property string trailing: "›"
        // Opt-in slot for "this is the active one" among a set of entries
        // (the selected mint, say). It occupies constant width and only its
        // opacity changes, so switching selection never reflows the row the
        // way editing `trailing`'s text used to.
        property bool showsActiveMark: false
        text: ""
        focusable: true
        Layout.fillWidth: true
        implicitHeight: entryContent.implicitHeight + Style.space(24)
        implicitWidth: Style.space(240)
        opacity: enabled ? 1 : 0.4
        Accessible.name: heading + ". " + detail + ". " + trailing + (showsActiveMark && selected ? ". Selected" : "")
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
            Label {
                visible: entry.showsActiveMark
                text: "✓"
                color: Color.accent
                font.bold: true
                font.pixelSize: Style.font.body
                Layout.alignment: Qt.AlignVCenter
                opacity: entry.selected ? 1 : 0
            }
        }
    }
    component DetailRow: RowLayout {
        property string heading: ""
        property string value: ""
        // Leading rows keep the value beside its heading on the left instead
        // of pushing it to the far edge.
        property bool leading: false
        Layout.fillWidth: true
        spacing: Style.space(12)
        Label { text: parent.heading; opacity: 0.6 }
        Label { text: parent.value; Layout.fillWidth: true; horizontalAlignment: parent.leading ? Text.AlignLeft : Text.AlignRight }
    }
    component ScanButtons: RowLayout {
        property string target: app.scanTarget
        Layout.fillWidth: true
        enabled: backend.unlocked && !backend.busy && !scanner.running
        Action { text: "Screen QR"; Layout.fillWidth: true; onClicked: { app.scanTarget = parent.target; app.scan("screen") } }
        Action { text: "Image"; Layout.fillWidth: true; onClicked: { app.scanTarget = parent.target; imageDialog.open() } }
        Action { text: "Camera"; Layout.fillWidth: true; onClicked: { app.scanTarget = parent.target; app.scan("camera") } }
    }

    Loader {
        id: panelLoader
        active: Quickshell.env("QT_QPA_PLATFORM") !== "offscreen"
        source: "CompactPanel.qml"
        onLoaded: {
            item.open = Qt.binding(() => app.presented && app.compact)
            item.animate = Qt.binding(() => app.presentationMotion && app.compact)
            item.reducedMotion = Qt.binding(() => motion.reduced)
            item.privacyHidden = Qt.binding(() => !backend.preview && !desktopLock.safeToUnlock)
            item.anchorX = Qt.binding(() => app.anchorX)
            item.outputName = Qt.binding(() => app.outputName)
            // A review holds reserved funds. Require an explicit confirm or
            // cancel rather than hiding it on a stray click outside the panel.
            item.suspendDismissal = Qt.binding(() => exportDialog.visible || importDialog.visible || imageDialog.visible || scanner.running || !!backend.review)
            item.dismissed.connect(() => app.dismiss(false, true))
        }
    }
    FloatingWindow {
        id: window
        title: backend.preview ? "Chaumarchy — interface preview" : "Chaumarchy"
        visible: app.presented && !app.compact
        // Closing the window clears secrets exactly as hiding the panel does.
        onVisibleChanged: if (!visible && !app.compact) app.dismiss(true)
        implicitWidth: Style.space(460)
        implicitHeight: Style.space(620)
        minimumSize: Qt.size(340, 420)
        color: Color.background

        Rectangle {
            id: surface
            parent: app.compact && panelLoader.item ? panelLoader.item.body : window.contentItem
            anchors.fill: parent
            color: app.compact ? Color.popups.background : Color.background
            Shortcut { sequence: "Ctrl+Q"; onActivated: Qt.quit() }
            Shortcut { sequence: "Escape"; onActivated: backend.review ? app.back() : (app.compact ? app.dismiss(true) : app.back()) }
            Shortcut { sequence: "Alt+Left"; onActivated: app.back() }
            Shortcut { sequence: "Ctrl+1"; enabled: app.walletVisible; onActivated: app.tab("home") }
            Shortcut { sequence: "Ctrl+2"; enabled: app.walletVisible; onActivated: app.tab("history") }
            Shortcut { sequence: "Ctrl+3"; enabled: app.walletVisible; onActivated: app.tab("mints") }
            Shortcut { sequence: "Ctrl+Comma"; enabled: !backend.review; onActivated: app.go("settings") }
        Controls.ScrollView {
            id: contentScroll
            anchors.fill: parent
            anchors.margins: Style.space(app.compact ? 18 : 26)
            anchors.bottomMargin: navigation.visible ? navigation.height + Style.space(40) : Style.space(26)
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: Math.min(contentScroll.availableWidth, Style.space(460))
                x: (contentScroll.availableWidth - width) / 2
                spacing: Style.space(app.compact ? 16 : 22)

                RowLayout {
                    id: header
                    Layout.fillWidth: true
                    spacing: Style.space(6)
                    // Back/Scan/Settings stay in the layout at a constant width
                    // whenever the wallet is visible, and only fade in or out of
                    // relevance per page. Toggling `visible` instead removed
                    // this icon's width from the row, which shifted the
                    // CHAUMARCHY wordmark sideways every time you navigated.
                    IconButton {
                        visible: app.walletVisible
                        enabled: !app.mainPage && !backend.review && !backend.busy
                        opacity: app.mainPage ? 0 : (enabled ? 1 : 0.4)
                        Accessible.ignored: app.mainPage
                        iconText: "󰁍"
                        Accessible.name: "Back"
                        onClicked: app.back()
                    }
                    Label { text: "CHAUMARCHY"; font.bold: true; font.letterSpacing: 1.5; Layout.fillWidth: true }
                    IconButton {
                        visible: app.walletVisible
                        enabled: app.mainPage && !backend.busy
                        opacity: app.mainPage ? (enabled ? 1 : 0.4) : 0
                        Accessible.ignored: !app.mainPage
                        iconText: "󰐲"
                        Accessible.name: "Scan a QR code"
                        onClicked: app.go("scan")
                    }
                    IconButton {
                        visible: app.walletVisible
                        enabled: app.mainPage && !backend.review && !backend.busy
                        opacity: app.mainPage ? (enabled ? 1 : 0.4) : 0
                        Accessible.ignored: !app.mainPage
                        iconText: "󰒓"
                        Accessible.name: "Settings"
                        onClicked: app.go("settings")
                    }
                    IconButton {
                        iconText: app.compact ? "󰁜" : "󰁃"
                        Accessible.name: app.compact ? "Expand to window" : "Return to panel"
                        onClicked: app.present(app.compact)
                    }
                }

                Welcome {
                    id: welcome
                    reducedMotion: motion.reduced
                    presented: app.presented
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
                        onClicked: backend.request("unlock", {password: password.text})
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
                    Secondary { text: "Choose a backup file"; onClicked: importDialog.open() }
                    Secondary { text: "Use recovery words"; onClicked: app.phraseRestore = !app.phraseRestore }
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
                        }
                    }
                    Secondary { text: "Back"; onClicked: app.restoreMode = false }
                }
                Label { visible: backend.error !== ""; text: backend.error; color: Color.urgent; Layout.fillWidth: true }
                Label { visible: backend.notice !== "" && app.page !== "complete"; text: backend.notice; Layout.fillWidth: true }
                Label { visible: scanner.running; text: "Scanning… Hold one QR code steady. Scanning stops after one minute."; Layout.fillWidth: true; opacity: 0.65 }
                Secondary { visible: scanner.running; text: "Cancel scan"; onClicked: scanner.running = false }

                ColumnLayout {
                    visible: !!backend.review
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: backend.review ? backend.review.kind : ""; font.pixelSize: Style.font.heading; font.bold: true }
                    Label { text: backend.review && backend.review.amount ? app.amountLabel(backend.review.amount) : "Reclaim unspent ecash"; font.pixelSize: Style.space(36); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Divider {}
                    DetailRow { heading: "Mint"; value: backend.review ? app.mintName(backend.review.mint) : "" }
                    DetailRow { visible: !!backend.review && !!backend.review.fee; heading: "Maximum fee"; value: backend.review ? app.amountLabel(backend.review.fee) : "" }
                    DetailRow { visible: !!backend.review && !!backend.review.total; heading: "Maximum total"; value: backend.review ? app.amountLabel(backend.review.total) : "" }
                    DetailRow { visible: !!backend.review && !!backend.review.expiry; heading: "Quote expires"; value: backend.review && backend.review.expiry ? app.momentFor(backend.review.expiry) : "" }
                    Label { visible: !!backend.review && backend.review.receiving === true; text: "The mint may deduct an input fee. You will see the amount received after redemption."; Layout.fillWidth: true; opacity: 0.65 }
                    Label { visible: app.reviewExpired; text: "This quote has expired. Cancel it and create the payment again."; Layout.fillWidth: true; opacity: 0.8 }
                    Action {
                        id: confirmButton
                        text: backend.busy ? "Processing…" : (!backend.review ? "Confirm" : backend.review.reclaim ? "Reclaim ecash" : backend.review.receiving ? "Receive ecash" : backend.review.kind === "Send ecash" ? "Create token" : "Pay invoice")
                        enabled: !backend.busy && !app.reviewExpired
                        Layout.fillWidth: true
                        onClicked: backend.request("confirm_payment", {review_id: backend.reviewId})
                    }
                    Secondary { text: "Cancel"; enabled: !backend.busy; onClicked: backend.request("cancel_payment", {review_id: backend.reviewId}) }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "home"
                    Layout.fillWidth: true
                    spacing: Style.space(app.compact ? 14 : 22)
                    Item { Layout.preferredHeight: Style.space(app.compact ? 12 : 26) }
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: balanceColumn.implicitHeight
                        Accessible.role: Accessible.Button
                        Accessible.name: "Balance, " + app.homeValue + " " + (app.homeUnit || (app.bitcoinSymbol ? "bitcoin" : "sats")) + (app.fiatCurrency ? ". Tap to switch between bitcoin and " + app.fiatCurrency + "." : "")
                        TapHandler { enabled: !!app.fiatCurrency; onTapped: app.cycleBalanceUnit() }
                        // The unit and the tap hint are accessible-only (see
                        // Accessible.name above): the ₿/$ already in the
                        // amount says enough without a caption line.
                        AmountDisplay { id: balanceColumn; anchors.fill: parent; amount: app.totalSpendable; emphasized: true; size: Style.space(app.compact ? 46 : 54) }
                    }
                    Label { visible: backend.state.restoring === true; text: "Recovering from your mints…"; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; opacity: 0.6 }
                    Label { visible: app.unavailableMints.length > 0; text: (app.unavailableMints.length === 1 ? app.unavailableMints[0].name + " is unavailable." : app.unavailableMints.length + " mints are unavailable.") + " Balance may be out of date."; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; opacity: 0.6 }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        Action { text: "Receive"; onClicked: app.go("receive") }
                        Action { text: "Send"; onClicked: app.go("send") }
                    }
                    Entry { visible: !(backend.state.mints || []).length; heading: "Choose your first mint"; detail: "A mint issues and redeems your ecash."; onClicked: app.go("add_mint") }
                    Entry { visible: app.totalPending > 0 || app.totalReserved > 0; heading: "Pending activity"; detail: app.amountLabel(app.totalPending) + " pending · " + app.amountLabel(app.totalReserved) + " reserved"; onClicked: app.tab("history") }
                    Divider {}
                    Label { text: "RECENT"; opacity: 0.55; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                    Label { visible: !(backend.state.history || []).length; text: "No payments yet"; opacity: 0.6; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Repeater {
                        model: (backend.state.history || []).slice(0, 3)
                        delegate: ActivityRow {}
                    }
                    Secondary { text: "View all activity  ›"; onClicked: app.tab("history") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "history"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "History"; font.pixelSize: Style.font.heading; font.bold: true; Layout.fillWidth: true }
                        IconButton { iconText: "󰑐"; iconSpinning: backend.busy; tooltipText: ""; Accessible.name: "Refresh"; enabled: !backend.busy; onClicked: backend.request("sync") }
                    }
                    Ui.TextField { Layout.fillWidth: true; placeholderText: "Search activity"; text: app.historySearch; onTextEdited: app.historySearch = text }
                    RowLayout {
                        Layout.fillWidth: true
                        Repeater { model: [{id:"all", name:"All"}, {id:"received", name:"Received"}, {id:"sent", name:"Sent"}]
                            delegate: Tab { required property var modelData; text: modelData.name; selected: app.historyFilter === modelData.id; onClicked: app.historyFilter = modelData.id }
                        }
                    }
                    Label { visible: !app.activity.length; text: "No matching activity"; opacity: 0.6 }
                    Repeater {
                        model: app.activity
                        delegate: ActivityRow {}
                    }
                    Label { text: "Showing up to 100 recent payments across your mints."; opacity: 0.5; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                    Label { visible: (backend.state.pending_invoices || []).length > 0; text: "Pending invoices"; font.bold: true }
                    Repeater {
                        model: backend.state.pending_invoices || []
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            Label { text: app.amountLabel(modelData.amount) + " · " + (modelData.expiry * 1000 < Date.now() ? "expired" : "awaiting payment") + (app.mints.length > 1 && modelData.mint_name ? " · " + modelData.mint_name : ""); Layout.fillWidth: true }
                            Action { text: "Show"; Layout.fillWidth: false; Layout.preferredWidth: -1; enabled: !backend.busy; onClicked: backend.request("show_invoice", {operation_id: modelData.id}) }
                        }
                    }
                    Label { visible: (backend.state.pending_sends || []).length > 0; text: "Unclaimed ecash"; font.bold: true }
                    Repeater {
                        model: backend.state.pending_sends || []
                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            Label { text: (modelData.amount ? app.amountLabel(modelData.amount) + " · pending ecash" : "Pending ecash") + (app.mints.length > 1 && modelData.mint_name ? " · " + modelData.mint_name : ""); Layout.fillWidth: true }
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
                    AmountDisplay { amount: app.transaction.amount; emphasized: true; animated: false }
                    DetailRow { heading: "Status"; value: app.transaction.status || "" }
                    DetailRow { heading: "Fee"; value: app.amountLabel(app.transaction.fee) }
                    DetailRow { heading: "Date"; value: app.momentFor(app.transaction.timestamp) }
                    DetailRow { heading: "Mint"; value: app.transaction.mint_name || app.transaction.mint || "" }
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
                    Entry { id: ecashChoice; heading: "Send ecash"; detail: "Create a token to share with someone."; onClicked: { app.entryText = ""; app.go("send_amount") } }
                    Entry { visible: !backend.state.selected; heading: "Choose a mint first"; onClicked: app.go("mints") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "receive"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: "Receive"; font.pixelSize: Style.font.heading; font.bold: true }
                    Entry { id: lightningChoice; heading: "Lightning"; detail: "Create an invoice to receive from another wallet."; onClicked: { app.entryText = ""; app.go("receive_amount") } }
                    Entry { heading: "Ecash"; detail: "Redeem a Cashu token someone sent you."; onClicked: { app.receiveText = ""; app.go("receive_token") } }
                    Entry { heading: "Scan a token"; detail: "Read a QR from your screen, an image, or camera."; onClicked: app.go("scan") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && (app.page === "send_amount" || app.page === "receive_amount")
                    Layout.fillWidth: true
                    spacing: Style.space(24)
                    // The page owns keyboard focus and the amount is the only
                    // large thing on it: no box, no cursor, no helper copy.
                    // Layout.preferredHeight fills the panel so the button
                    // sits at the bottom and the amount floats between.
                    id: amountPage
                    Layout.preferredHeight: Math.max(implicitHeight, contentScroll.availableHeight - header.height - parent.spacing)
                    onVisibleChanged: if (visible) amountInput.forceActiveFocus()
                    Label { text: app.page === "send_amount" ? "Send ecash" : "Receive Lightning"; font.pixelSize: Style.font.heading; font.bold: true }
                    Button {
                        visible: app.mints.length > 1
                        text: app.selectedMint.name + " · " + app.amountLabel(app.selectedMint.spendable) + " available"
                        iconText: "󰅀"
                        focusable: true
                        enabled: !backend.busy
                        opacity: 0.7
                        Layout.alignment: Qt.AlignHCenter
                        Accessible.name: text + ". Tap to switch mint"
                        onClicked: { app.cycleMint(); amountInput.forceActiveFocus() }
                    }
                    Label { visible: app.mints.length <= 1; text: app.amountLabel(app.selectedMint.spendable) + " available"; opacity: 0.55; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Item { Layout.fillHeight: true }
                    TextInput {
                        id: amountInput
                        // Invisible: it only collects keystrokes for the big
                        // amount below, which is the thing that renders.
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 1
                        opacity: 0
                        activeFocusOnTab: true
                        inputMethodHints: Qt.ImhFormattedNumbersOnly
                        text: app.entryText
                        onTextEdited: { var clean = app.normalizeEntry(text); app.entryText = clean; if (text !== clean) text = clean }
                        onAccepted: if (amountContinue.enabled) amountContinue.clicked()
                        Accessible.name: "Amount"
                    }
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: bigAmount.implicitHeight
                        Accessible.role: Accessible.Button
                        Accessible.name: "Amount " + app.entryDisplay + (app.fiatAvailable ? ". Tap to switch unit" : "")
                        TapHandler { onTapped: { app.swapEntryUnit(); amountInput.forceActiveFocus() } }
                        AnimatedAmount {
                            id: bigAmount
                            anchors.fill: parent
                            text: app.entryDisplay
                            fontSize: Style.space(app.compact ? 52 : 60)
                            fade: surface.color
                            reducedMotion: motion.reduced
                            maxWidth: parent.width
                            color: app.entryOver ? Color.urgent : Color.foreground
                            opacity: app.entryText === "" ? 0.35 : 1
                            Behavior on opacity { enabled: !motion.reduced; NumberAnimation { duration: 150 } }
                        }
                    }
                    Label {
                        visible: app.fiatAvailable
                        text: app.fiatEntry ? app.amountLabel(app.entrySats) : "≈ " + app.fiatText(app.entrySats)
                        opacity: 0.55
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Item { Layout.fillHeight: true }
                    Action {
                        id: amountContinue
                        text: backend.busy ? "Preparing…" : app.page === "send_amount" ? "Send" : "Request"
                        enabled: backend.unlocked && !backend.busy && !!backend.state.selected && app.entrySats > 0 && !app.entryOver
                        onClicked: backend.request(app.page === "send_amount" ? "send_ecash" : "create_invoice", {amount: String(app.entrySats)})
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
                    Secondary { text: "Scan instead"; onClicked: app.go("scan") }
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
                    // Shown in the unit the amount was typed in, with the
                    // other beneath, so a dollar request still reads as one.
                    AmountDisplay { visible: !!backend.share.amount; amount: backend.share.amount; size: Style.space(32); animated: false }
                    Label { text: backend.share.token ? "Ready to share" : "Waiting for payment"; opacity: 0.6; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    DetailRow { heading: "Mint"; value: backend.share.mint ? app.mintName(backend.share.mint) : app.selectedMint.name; leading: true }
                    DetailRow { visible: !!backend.share.expiry; heading: "Expires"; value: app.momentFor(backend.share.expiry); leading: true }
                    Label { visible: !!backend.share.token && !backend.share.qr; text: "Too large for one QR code. Copy the token to share it."; Layout.fillWidth: true }
                    Action {
                        text: clipboard.running ? "Copied · waiting for paste" : backend.share.token ? "Copy token" : "Copy invoice"
                        enabled: !clipboard.running
                        Layout.fillWidth: true
                        onClicked: { app.clipboardText = backend.share.token || backend.share.invoice || ""; clipboard.stdinEnabled = true; clipboard.running = true }
                    }
                    Secondary { text: app.revealShare ? "Hide text" : "Show full text"; onClicked: app.revealShare = !app.revealShare }
                    Controls.TextArea {
                        visible: app.revealShare
                        Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere
                        text: backend.share.token || backend.share.invoice || ""; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption
                        background: Rectangle { color: "transparent" }
                    }
                    Label { text: backend.share.token ? "Anyone holding this token can redeem it. Reopen or reclaim it from History." : "You can close this window. Your unlocked wallet keeps checking for payment."; opacity: 0.6; Layout.fillWidth: true }
                    Secondary { text: "Done"; onClicked: app.back() }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "complete"
                    Layout.fillWidth: true
                    spacing: Style.space(24)
                    Item { Layout.preferredHeight: Style.space(36) }
                    SuccessMark {
                        Layout.fillWidth: true
                        reducedMotion: motion.reduced
                        presented: app.presented
                        receipt: JSON.stringify(backend.completion)
                    }
                    Label { text: backend.completion.paid ? "Payment sent" : backend.completion.reclaimed ? "Ecash reclaimed" : "Payment received"; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    AmountDisplay { amount: backend.completion.amount; emphasized: true; size: Style.space(40); animated: false }
                    Action { text: "Back to wallet"; onClicked: app.back() }
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
                            trailing: app.amountLabel(modelData.spendable)
                            showsActiveMark: true
                            selected: modelData.url === backend.state.selected
                            enabled: !backend.busy
                            onClicked: backend.request("select_mint", {url: modelData.url})
                        }
                    }
                    Entry { heading: "+  Add a mint"; detail: "Choose a suggestion or use a mint URL."; onClicked: app.go("add_mint") }
                    Label { text: "Each mint holds a separate balance; the wallet shows their total. The checked mint is used for new payments, and you can switch it when entering an amount."; opacity: 0.6; Layout.fillWidth: true }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "add_mint"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: "Add a mint"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { text: "SUGGESTED"; opacity: 0.55; font.pixelSize: Style.font.caption }
                    Repeater {
                        model: app.suggestions
                        delegate: Entry { required property var modelData; heading: modelData.name; detail: modelData.url; showsActiveMark: true; selected: app.mintUrl === modelData.url; onClicked: app.mintUrl = modelData.url }
                    }
                    Ui.TextField { id: mintInput; Layout.fillWidth: true; placeholderText: "Or enter a mint URL"; text: app.mintUrl; onTextEdited: app.mintUrl = text }
                    Secondary { text: "Scan mint URL"; onClicked: { app.go("scan"); app.scanTarget = "mint" } }
                    Label { text: "Adding a mint means trusting its operator to redeem your ecash."; opacity: 0.6; Layout.fillWidth: true }
                    Action { id: addMintButton; text: backend.busy ? "Checking mint…" : "Trust and add mint"; enabled: backend.unlocked && !backend.busy && app.mintUrl.trim() !== ""; Layout.fillWidth: true; onClicked: backend.request("add_mint", {url: app.mintUrl}) }
                    Secondary { text: "View my mints"; onClicked: app.tab("mints") }
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
                    Entry {
                        heading: "Display"
                        detail: (app.bitcoinSymbol ? "₿ symbol" : "Sats") + (app.fiatCurrency ? " · " + app.fiatCurrency : " · No local currency")
                        onClicked: app.go("display")
                    }
                    Entry {
                        heading: "Reduce motion"
                        detail: "Gentle fades without movement"
                        trailing: motion.reduced ? "On" : "Off"
                        onClicked: motion.reducedMotion = !motion.reducedMotion
                    }
                    Divider {}
                    Label { text: "Closing the window keeps your unlocked wallet monitoring payments."; opacity: 0.6; Layout.fillWidth: true }
                    Action { text: "Lock wallet"; visible: backend.state.password_required === true; enabled: backend.unlocked && !backend.busy && !backend.review; Layout.fillWidth: true; onClicked: backend.lock() }
                    Secondary { text: "Quit Chaumarchy"; onClicked: Qt.quit() }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "display"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: "Display"; font.bold: true; font.pixelSize: Style.font.heading }
                    Entry {
                        heading: "Bitcoin symbol"
                        detail: "Show ₿21,000 instead of 21,000 sats"
                        trailing: app.bitcoinSymbol ? "On" : "Off"
                        onClicked: app.setDisplay(!app.bitcoinSymbol, app.fiatCurrency)
                    }
                    Divider {}
                    Label { text: "LOCAL CURRENCY"; opacity: 0.55; font.pixelSize: Style.font.caption }
                    Label { text: "Show an approximate value in a local currency. This never changes what a mint holds or sends; sats stay the real amount, and the rate is only an estimate."; opacity: 0.6; Layout.fillWidth: true }
                    Entry {
                        heading: "Off"
                        detail: "Show only sats"
                        showsActiveMark: true
                        selected: app.fiatCurrency === ""
                        onClicked: app.setDisplay(app.bitcoinSymbol, "")
                    }
                    Repeater {
                        model: backend.state.currencies || []
                        delegate: Entry {
                            required property var modelData
                            heading: modelData.flag + "  " + modelData.code + "  " + modelData.symbol
                            detail: modelData.name
                            showsActiveMark: true
                            selected: app.fiatCurrency === modelData.code
                            onClicked: app.setDisplay(app.bitcoinSymbol, modelData.code)
                        }
                    }
                    Label { visible: app.fiatCurrency !== "" && !backend.state.exchange_rate; text: "Fetching the exchange rate…"; opacity: 0.6; Layout.fillWidth: true }
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
                    Label {
                        visible: !backend.state.password_required
                        text: "If someone copies your wallet folder, this password is the only thing protecting it. Several random words make a far stronger passphrase than a short complicated one."
                        opacity: 0.65; Layout.fillWidth: true
                    }
                    Ui.TextField { id: securityPassword; visible: !backend.state.password_required; password: true; placeholderText: "New passphrase (12+ characters)"; Layout.fillWidth: true }
                    Ui.TextField { id: securityConfirmation; visible: !backend.state.password_required; password: true; placeholderText: "Repeat password"; Layout.fillWidth: true }
                    Action {
                        id: enablePasswordButton
                        visible: !backend.state.password_required
                        text: "Enable password"
                        Layout.fillWidth: true
                        enabled: backend.unlocked && !backend.busy && securityPassword.text.length >= 12 && securityPassword.text === securityConfirmation.text
                        onClicked: backend.request("set_password", {password: securityPassword.text})
                    }
                    Label { visible: !backend.state.password_required && securityConfirmation.text.length > 0 && securityPassword.text !== securityConfirmation.text; text: "Passwords do not match."; Layout.fillWidth: true; opacity: 0.65 }
                    Ui.TextField { id: currentPassword; visible: backend.state.password_required === true; password: true; placeholderText: "Current password to remove protection"; Layout.fillWidth: true }
                    Action {
                        visible: backend.state.password_required === true
                        text: "Remove password"
                        Layout.fillWidth: true
                        enabled: backend.unlocked && !backend.busy && currentPassword.text.length > 0
                        onClicked: backend.request("remove_password", {password: currentPassword.text})
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
                    Secondary { visible: backend.recoveryPhrase !== ""; text: "Hide phrase"; onClicked: backend.recoveryPhrase = "" }
                    Label { text: "A backup travels, so it is the file most likely to be copied. Several random words make a far stronger passphrase than a short complicated one."; opacity: 0.65; Layout.fillWidth: true }
                    Ui.TextField { id: backupPassword; password: true; placeholderText: "Backup passphrase (12+ characters)"; Layout.fillWidth: true }
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
                delegate: Tab { required property var modelData; text: modelData.label; selected: app.page === modelData.id; Layout.fillHeight: true; enabled: !backend.busy; onClicked: app.tab(modelData.id) }
            }
        }
        }
    }
}
