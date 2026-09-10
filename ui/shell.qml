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
    property bool compact: Quickshell.env("CASHU_ME_WINDOW") !== "1" && Quickshell.env("CASHU_ME_PREVIEW") !== "1"
    property bool presentationMotion: Quickshell.env("CASHU_ME_ANIMATE") === "1"
    property real anchorX: Number(Quickshell.env("CASHU_ME_ANCHOR_X") || "-1")
    MotionPreferences { id: motion }
    property bool presented: true
    property string outputName: Quickshell.env("CASHU_ME_SCREEN") || ""
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
        revealPassword.clear()
        revealKeyPassword.clear()
        backend.revealedKey = ""
        importKeyText = ""
        appLockMode = ""
        if (page !== "restore" && !restoreMode) { restoreWordsText = ""; restoreMintList = []; restoreResults = {} }
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
        // The restore's final step is forward-only, as in the reference.
        if ((page === "restore" || restoreMode) && restoreStep === "progress") return
        if (!walletVisible && restoreMode) { restoreMode = false; return }
        if (page === "share" || page === "complete") {
            backend.share = {}; backend.completion = {}; trail = []; page = "home"; return
        }
        page = trail.length ? trail[trail.length - 1] : "home"
        trail = trail.slice(0, -1)
    }
    onPageChanged: {
        contentScroll.contentItem.contentY = 0
        if (page !== "recovery") backend.recoveryPhrase = ""
        if (page !== "key_reveal") { backend.revealedKey = ""; revealKeyPassword.clear() }
        if (page !== "recovery") revealPassword.clear()
        if (page !== "app_lock") appLockMode = ""
        if (page !== "advanced_keys") { importingKey = false; importKeyText = "" }
        if (page === "receive_token" && app.privacy.auto_paste !== false && app.receiveText === "") { pasteTarget = "token"; pasteProbe.running = false; pasteProbe.running = true }
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
    property bool restoreMode: false
    // Settings state that lives in the interface. Everything the worker
    // persists is read from backend.state; these are the pieces mid-edit.
    property string appLockMode: ""
    property bool importingKey: false
    property string importKeyText: ""
    property string deviceKeyId: ""
    property string revealKeyId: ""
    property string revealTitle: "Your Key"
    property string qrTitle: ""
    property string lockTo: ""
    property bool lockToOpen: false
    readonly property var privacy: backend.state.privacy || ({check_incoming: true, repeat_checks: true, check_sent: true, auto_paste: true})
    readonly property var lightning: backend.state.lightning || ({enabled: false, auto_claim: true, status: "off"})
    readonly property var locked: backend.state.locked || ({seed_key: "", quick_lock: false, device_keys: []})
    readonly property var deviceKeys: app.locked.device_keys || []
    readonly property var deviceKey: app.deviceKeys.find(key => key.id === app.deviceKeyId) || ({})
    function setPrivacy(patch) {
        var next = Object.assign({}, app.privacy, patch)
        backend.request("set_privacy", {check_incoming: next.check_incoming !== false, repeat_checks: next.repeat_checks !== false, check_sent: next.check_sent !== false, auto_paste: next.auto_paste !== false})
    }
    function setLightning(patch) {
        var next = Object.assign({}, app.lightning, patch)
        backend.request("set_lightning", {enabled: next.enabled === true, auto_claim: next.auto_claim !== false, url: next.mint || ""})
    }
    function nextMintAfter(url) {
        var index = app.mints.findIndex(mint => mint.url === url)
        return app.mints.length ? app.mints[(index + 1) % app.mints.length].url : ""
    }
    function showQr(title, text) { app.qrTitle = title; backend.request("make_qr", {text: text}) }
    function copyText(text) { app.clipboardText = text; clipboard.stdinEnabled = true; clipboard.running = true }
    function shortKey(key) { return key && key.length > 20 ? key.slice(0, 10) + "…" + key.slice(-8) : (key || "") }
    function ago(seconds) {
        if (!seconds) return ""
        var elapsed = Math.max(0, Math.floor(Date.now() / 1000 - seconds))
        if (elapsed < 60) return "just now"
        if (elapsed < 3600) return Math.floor(elapsed / 60) + "m ago"
        if (elapsed < 86400) return Math.floor(elapsed / 3600) + "h ago"
        return Math.floor(elapsed / 86400) + "d ago"
    }
    // A page that pins its action to the bottom of the panel: fills the
    // panel, but never stretches a tall window into a void.
    function pinnedHeight(implicit) { return Math.max(implicit, Math.min(contentScroll.availableHeight, Style.space(620)) - header.height - Style.space(app.compact ? 16 : 22)) }
    // ---- Restore flow
    property string restoreStep: "seed"
    property string restoreWordsText: ""
    readonly property int restoreWordCount: app.restoreWordsText.trim() === "" ? 0 : app.restoreWordsText.trim().split(/\s+/).length
    property var restoreMintList: []
    property string restoreMintInput: ""
    property string restoreNotice: ""
    property var restoreResults: ({})
    property bool restoreReplacing: false
    function startRestore() { restoreStep = "seed"; restoreWordsText = ""; restoreMintList = []; restoreMintInput = ""; restoreNotice = ""; restoreResults = {}; restoreReplacing = false }
    function stageRestoreMint(input) {
        var added = 0, skipped = 0
        input.split(/[\s,]+/).forEach(piece => {
            var url = piece.trim()
            if (url === "") return
            if (!/^https?:\/\//i.test(url)) url = "https://" + url
            url = url.replace(/\/+$/, "")
            if (!/^https?:\/\/[^\s\/]+\.[^\s\/]+/i.test(url) && !/^http:\/\/(localhost|127\.0\.0\.1)/i.test(url)) { skipped++; return }
            if (app.restoreMintList.some(mint => mint.url.toLowerCase() === url.toLowerCase())) { skipped++; return }
            app.restoreMintList = app.restoreMintList.concat([{url: url}])
            added++
        })
        app.restoreMintInput = ""
        app.restoreNotice = added === 0 ? (skipped > 0 ? "That doesn't look like a mint URL, or it is already in the list." : "") : ""
    }
    function beginRestore() {
        app.restoreNotice = ""
        if (app.walletVisible) { replaceDialog.opened = true; return }
        app.restoreInstall()
    }
    function restoreInstall() {
        app.restoreResults = {}
        var urls = app.restoreMintList.map(mint => mint.url)
        backend.request("restore_phrase", {phrase: app.restoreWordsText.trim().replace(/\s+/g, " "), mint_urls: urls, password: ""})
    }
    function restoreRunNext() {
        var next = app.restoreMintList.find(mint => !app.restoreResults[mint.url] || app.restoreResults[mint.url].status === "pending")
        if (!next) return
        app.restoreResults = Object.assign({}, app.restoreResults, {[next.url]: {status: "restoring"}})
        backend.request("restore_mint", {url: next.url})
    }
    function retryRestoreMint(url) {
        app.restoreResults = Object.assign({}, app.restoreResults, {[url]: {status: "pending"}})
        app.restoreRunNext()
    }
    function finishRestore() { app.restoreMode = false; app.trail = []; app.page = "home"; app.restoreStep = "seed"; app.restoreWordsText = ""; app.restoreMintList = []; app.restoreResults = {} }
    function pasteInto(target) { pasteTarget = target; pasteProbe.running = false; pasteProbe.running = true }
    property string pasteTarget: ""
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
            if (method === "validate_phrase") app.restoreStep = "mints"
            if (method === "restore_phrase") { app.trail = []; app.page = "restore"; app.restoreStep = "progress"; app.restoreRunNext() }
            if (method === "delete_wallet") {
                if (app.restoreReplacing) { app.restoreReplacing = false; app.restoreMode = true; app.restoreInstall() }
                else { app.trail = []; app.page = "home"; app.restoreMode = false }
            }
            if (method === "set_password" || method === "remove_password") { securityPassword.clear(); securityConfirmation.clear(); currentPassword.clear(); app.appLockMode = "" }
            if (method === "recovery_phrase") revealPassword.clear()
            if (method === "reveal_key") revealKeyPassword.clear()
            if (method === "import_key") { app.importKeyText = ""; app.importingKey = false }
            if (method === "remove_key") app.back()
            if (method === "make_qr") { if (app.page !== "qr") app.go("qr") }
            if (method === "locked_request") { if (app.page !== "qr") app.go("qr") }
        }
        onFailed: method => {
            if (method === "restore_mint") {
                var current = app.restoreMintList.find(mint => (app.restoreResults[mint.url] || {}).status === "restoring")
                if (current) app.restoreResults = Object.assign({}, app.restoreResults, {[current.url]: {status: "failed", error: backend.error}})
            }
            if (method === "restore_phrase" && !backend.state.exists) app.restoreStep = "mints"
        }
        onRestored: result => {
            app.restoreResults = Object.assign({}, app.restoreResults, {[result.mint]: {status: "done", recovered: result.recovered}})
            app.restoreRunNext()
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
            imageDialog.close()
            deleteDialog.opened = false
            replaceDialog.opened = false
            removeKeyDialog.opened = false
            app.restoreReplacing = false
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
        id: imageDialog
        title: "Open a QR image"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp *.bmp)"]
        onAccepted: app.scan("image", decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, "")))
    }
    function scan(mode, path) {
        if (scanner.running || !backend.unlocked) return
        backend.error = ""
        scanner.command = [Quickshell.env("CASHU_ME_SCANNER"), mode].concat(path ? [path] : [])
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
    // Reads the Wayland clipboard once, for auto-paste on the receive page
    // and the Paste actions on the restore page. wl-paste is the same tool
    // the copy path relies on.
    Process {
        id: pasteProbe
        command: ["wl-paste", "--no-newline", "--type", "text/plain"]
        property string collected: ""
        onStarted: collected = ""
        stdout: SplitParser { onRead: data => pasteProbe.collected += data + " " }
        stderr: SplitParser { onRead: data => {} }
        onExited: (code, status) => {
            var text = pasteProbe.collected.trim()
            if (code !== 0) return
            if (app.pasteTarget === "token") { if (text.startsWith("cashu") && app.receiveText === "") app.receiveText = text }
            else if (app.pasteTarget === "words") { if (text.split(/\s+/).length === 12) app.restoreWordsText = text; else app.restoreNotice = "Nothing in the clipboard looked like a seed phrase." }
            else if (app.pasteTarget === "mints") { if (text === "") app.restoreNotice = "Clipboard is empty."; else app.stageRestoreMint(text) }
            app.pasteTarget = ""
        }
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
    // One of a mutually exclusive set, with the chrome of the kit's own
    // Ui.ButtonGroup chips: bordered, and `selected` paints the chosen one.
    // ButtonGroup itself sizes chips to their text, so the equal-width
    // layout stays ours.
    component Tab: Button {
        focusable: true
        bordered: true
        Layout.fillWidth: true
        Layout.preferredWidth: 1
    }
    // One payment in a list: an arrow on a square tile, the type over the time, and the
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
                // Omarchy's own corner radius, so the tile matches the
                // buttons around it rather than reading as an iOS circle.
                radius: Style.cornerRadius
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
                Label { text: app.whenFor(activityRow.modelData); opacity: 0.55; font.pixelSize: Style.font.bodySmall }
            }
            ColumnLayout {
                spacing: Style.space(3)
                Label {
                    text: (activityRow.incoming ? "+" : "") + app.primaryAmount(activityRow.modelData.amount)
                    color: activityRow.incoming ? app.received : Color.foreground
                    Layout.alignment: Qt.AlignRight
                }
                Label { visible: app.fiatAvailable; text: app.secondaryAmount(activityRow.modelData.amount); opacity: 0.55; font.pixelSize: Style.font.bodySmall; Layout.alignment: Qt.AlignRight }
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
        // The conversion scales with the number above it, about two fifths
        // of its size as in cashubtc/wallet, never below the title size.
        Label { visible: app.fiatAvailable; text: app.secondaryAmount(display.amount); opacity: 0.55; font.pixelSize: Math.max(Style.font.title, Math.round(display.size * 0.4)); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
    }
    component IconButton: Button {
        text: ""
        focusable: true
        tooltipText: Accessible.name
        opacity: enabled ? 1 : 0.4
    }
    component Caption: Label { opacity: 0.55; font.pixelSize: Style.font.caption; font.letterSpacing: 1; Layout.topMargin: Style.space(6) }
    component Footer: Label { opacity: 0.6; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
    // A row whose whole surface flips a setting, with the kit's own switch
    // at the end, the way the reference's toggle rows work.
    component ToggleRow: Button {
        id: toggleRow
        property string icon: ""
        property string heading: ""
        property string detail: ""
        property bool checked: false
        property bool busy: false
        signal toggled()
        text: ""
        focusable: true
        Layout.fillWidth: true
        implicitHeight: toggleContent.implicitHeight + Style.space(24)
        implicitWidth: Style.space(240)
        opacity: enabled ? 1 : 0.4
        Accessible.role: Accessible.CheckBox
        Accessible.name: heading + ". " + detail
        Accessible.checked: checked
        onClicked: if (!busy) toggled()
        RowLayout {
            id: toggleContent
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(14)
            Label { visible: toggleRow.icon !== ""; text: toggleRow.icon; font.pixelSize: Style.font.heading; opacity: 0.8; Layout.preferredWidth: Style.space(28); horizontalAlignment: Text.AlignHCenter }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(5)
                Label { text: toggleRow.heading; font.bold: true; Layout.fillWidth: true }
                Label { visible: toggleRow.detail !== ""; text: toggleRow.detail; opacity: 0.6; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
            }
            Ui.ToggleSwitch { checked: toggleRow.checked; busy: toggleRow.busy; interactive: false; Layout.alignment: Qt.AlignVCenter }
        }
    }
    // A key with its status, tap-to-copy public key, and two actions, as
    // in the reference's KeyCard.
    component KeyCard: Rectangle {
        id: keyCard
        property string title: ""
        property string status: ""
        property color statusColor: Color.foreground
        property string pubkey: ""
        property string revealLabel: "Reveal key"
        signal showQr()
        signal reveal()
        Layout.fillWidth: true
        implicitHeight: keyContent.implicitHeight + Style.space(28)
        radius: Style.cornerRadius
        color: Qt.alpha(Color.foreground, 0.07)
        ColumnLayout {
            id: keyContent
            anchors.fill: parent
            anchors.margins: Style.space(14)
            spacing: Style.space(10)
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(12)
                Label { text: "󰌆"; font.pixelSize: Style.font.heading; opacity: 0.8 }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(3)
                    Label { text: keyCard.title; font.bold: true }
                    Label { visible: keyCard.status !== ""; text: keyCard.status; color: keyCard.statusColor; opacity: keyCard.statusColor === Color.foreground ? 0.6 : 0.9; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                }
            }
            Secondary {
                text: clipboard.running ? "Copied · waiting for paste" : app.shortKey(keyCard.pubkey) + "   󰆏"
                Accessible.name: "Copy this key"
                enabled: keyCard.pubkey !== "" && !clipboard.running
                onClicked: app.copyText(keyCard.pubkey)
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(12)
                Tab { text: "󰐲  Show QR"; enabled: keyCard.pubkey !== "" && !backend.busy; onClicked: keyCard.showQr() }
                Tab { text: "󰈈  " + keyCard.revealLabel; enabled: keyCard.pubkey !== "" && !backend.busy; onClicked: keyCard.reveal() }
            }
        }
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
        property string icon: ""
        property color iconColor: Color.foreground
        property bool destructive: false
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
            Label { visible: entry.icon !== ""; text: entry.icon; color: entry.destructive ? Color.urgent : entry.iconColor; font.pixelSize: Style.font.heading; opacity: entry.destructive || entry.iconColor !== Color.foreground ? 1 : 0.8; Layout.preferredWidth: Style.space(28); horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignVCenter }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(5)
                Label { text: entry.heading; color: entry.destructive ? Color.urgent : Color.foreground; font.bold: true; Layout.fillWidth: true; elide: Text.ElideMiddle; wrapMode: Text.NoWrap }
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
            item.suspendDismissal = Qt.binding(() => imageDialog.visible || scanner.running || !!backend.review || deleteDialog.opened || replaceDialog.opened || removeKeyDialog.opened)
            item.dismissed.connect(() => app.dismiss(false, true))
        }
    }
    FloatingWindow {
        id: window
        title: backend.preview ? "cashu.me — interface preview" : "cashu.me"
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
                    // No wordmark, as in cashubtc/wallet: the back arrow on the
                    // left, Scan, Settings and the expand control on the right.
                    // Back/Scan/Settings stay in the layout at a constant width
                    // whenever the wallet is visible, and only fade in or out of
                    // relevance per page. Toggling `visible` instead removed
                    // this icon's width from the row and shifted its neighbours.
                    // The left slot is Settings on the three main pages and
                    // Back everywhere else, as in cashubtc/wallet's toolbar.
                    // A review has Cancel as its only way back, so it is empty.
                    IconButton {
                        visible: app.walletVisible
                        enabled: !backend.review && !backend.busy
                        opacity: backend.review ? 0 : (enabled ? 1 : 0.4)
                        Accessible.ignored: !!backend.review
                        iconText: app.mainPage ? "󰒓" : "󰁍"
                        Accessible.name: app.mainPage ? "Settings" : "Back"
                        onClicked: app.mainPage ? app.go("settings") : app.back()
                    }
                    Item { Layout.fillWidth: true }
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
                    onRestoreRequested: { app.startRestore(); app.restoreMode = true }
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
                Label { visible: !app.walletVisible && !backend.ready && !backend.error; text: "Starting cashu.me…"; opacity: 0.65; Layout.fillWidth: true }
                // ---- Restore, in three steps after cashubtc/wallet: the words,
                // the mints to recover from, then each mint's result. From
                // onboarding it installs a new wallet; from Settings it
                // replaces the current one after a confirmation. Desktop
                // liberty: the words go into one field rather than twelve.
                ColumnLayout {
                    id: restorePage
                    readonly property bool onboarding: !app.walletVisible
                    readonly property int mintCount: app.restoreMintList.length
                    readonly property bool allSettled: app.restoreMintList.length > 0 && app.restoreMintList.every(mint => ["done", "failed"].indexOf((app.restoreResults[mint.url] || {}).status) >= 0)
                    readonly property double recoveredTotal: app.restoreMintList.reduce((sum, mint) => sum + Number((app.restoreResults[mint.url] || {}).recovered || 0), 0)
                    visible: !backend.review && ((app.walletVisible && app.page === "restore") || (!app.walletVisible && !backend.state.exists && app.restoreMode))
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    // Step 1: seed
                    Label { visible: app.restoreStep === "seed"; text: "Restore Wallet"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { visible: app.restoreStep === "seed"; text: "Enter your 12 words in order."; opacity: 0.65; Layout.fillWidth: true }
                    Controls.TextArea {
                        id: restoreWords
                        visible: app.restoreStep === "seed"
                        Layout.fillWidth: true
                        placeholderText: "Recovery words, separated by spaces"
                        wrapMode: TextEdit.Wrap
                        color: Color.foreground
                        placeholderTextColor: Qt.alpha(Color.foreground, 0.5)
                        font.family: Style.font.family
                        text: app.restoreWordsText
                        onTextChanged: if (text !== app.restoreWordsText) app.restoreWordsText = text
                        background: Rectangle { color: "transparent"; radius: Style.cornerRadius; border.color: Qt.alpha(Color.foreground, 0.25) }
                    }
                    Label { visible: app.restoreStep === "seed"; text: app.restoreWordCount + " of 12 words"; opacity: 0.55; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                    Secondary { visible: app.restoreStep === "seed"; text: "Paste seed phrase"; onClicked: app.pasteInto("words") }
                    Action { visible: app.restoreStep === "seed"; text: backend.busy ? "Checking…" : "Next"; enabled: backend.ready && !backend.busy && app.restoreWordCount === 12; onClicked: backend.request("validate_phrase", {phrase: app.restoreWordsText.trim().replace(/\s+/g, " ")}) }
                    Secondary { visible: app.restoreStep === "seed" && restorePage.onboarding; text: "Back"; onClicked: app.restoreMode = false }
                    // Step 2: mints
                    Label { visible: app.restoreStep === "mints"; text: "Restore Funds"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { visible: app.restoreStep === "mints"; text: "Add the mints you used before to recover funds from this seed."; opacity: 0.65; Layout.fillWidth: true }
                    Ui.TextField { id: restoreMintField; visible: app.restoreStep === "mints"; Layout.fillWidth: true; placeholderText: "mint.example.com"; text: app.restoreMintInput; onTextEdited: app.restoreMintInput = text; onAccepted: app.stageRestoreMint(app.restoreMintInput) }
                    RowLayout {
                        visible: app.restoreStep === "mints"
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        Tab { text: "Add"; enabled: app.restoreMintInput.trim() !== ""; onClicked: app.stageRestoreMint(app.restoreMintInput) }
                        Tab { text: "Paste"; onClicked: app.pasteInto("mints") }
                    }
                    Label { visible: app.restoreStep === "mints" && app.restoreNotice !== ""; text: app.restoreNotice; opacity: 0.75; Layout.fillWidth: true }
                    Repeater {
                        model: app.restoreStep === "mints" ? app.restoreMintList : []
                        delegate: Entry {
                            required property var modelData
                            icon: "󰭎"
                            heading: modelData.url.replace(/^https?:\/\//, "")
                            detail: modelData.url
                            trailing: "󰅖"
                            Accessible.name: "Remove mint " + modelData.url
                            onClicked: app.restoreMintList = app.restoreMintList.filter(mint => mint.url !== modelData.url)
                        }
                    }
                    Action {
                        visible: app.restoreStep === "mints"
                        text: restorePage.mintCount === 0 ? "Restore" : "Restore from " + restorePage.mintCount + (restorePage.mintCount === 1 ? " mint" : " mints")
                        enabled: restorePage.mintCount > 0 && !backend.busy
                        onClicked: app.beginRestore()
                    }
                    Secondary { visible: app.restoreStep === "mints"; text: "Back to seed phrase"; enabled: !backend.busy; onClicked: app.restoreStep = "seed" }
                    // Step 3: progress
                    Label { visible: app.restoreStep === "progress"; text: restorePage.allSettled ? "Restore Complete" : "Restoring…"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { visible: app.restoreStep === "progress"; text: !restorePage.allSettled ? "Recovering funds from your mints…" : restorePage.recoveredTotal > 0 ? "Here's what we recovered." : "No funds found on these mints."; opacity: 0.65; Layout.fillWidth: true }
                    Label { visible: app.restoreStep === "progress" && restorePage.recoveredTotal > 0; text: "󰄬  Recovered: " + app.amountLabel(restorePage.recoveredTotal); color: app.received; Layout.fillWidth: true }
                    Repeater {
                        model: app.restoreStep === "progress" ? app.restoreMintList : []
                        delegate: Entry {
                            required property var modelData
                            readonly property var result: app.restoreResults[modelData.url] || {status: "pending"}
                            icon: result.status === "done" ? (Number(result.recovered || 0) > 0 ? "󰄬" : "󰍶") : result.status === "failed" ? "󰅙" : "󰔟"
                            iconColor: result.status === "done" && Number(result.recovered || 0) > 0 ? app.received : result.status === "failed" ? Color.urgent : Color.foreground
                            heading: app.mintName(modelData.url) !== modelData.url ? app.mintName(modelData.url) : modelData.url.replace(/^https?:\/\//, "")
                            detail: result.status === "failed" ? (result.error || "Could not restore this mint.") : modelData.url
                            trailing: result.status === "done" ? app.amountLabel(result.recovered || 0) : result.status === "failed" ? "Retry" : result.status === "restoring" ? "Restoring…" : "Waiting"
                            enabled: result.status === "failed" && !backend.busy
                            onClicked: app.retryRestoreMint(modelData.url)
                        }
                    }
                    Action { visible: app.restoreStep === "progress"; text: "Continue"; enabled: restorePage.allSettled && !backend.busy; onClicked: app.finishRestore() }
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
                    AmountDisplay { visible: !!backend.review && !!backend.review.amount; amount: backend.review ? backend.review.amount : 0; size: Style.space(36); animated: false }
                    Label { visible: !!backend.review && !backend.review.amount; text: "Reclaim unspent ecash"; font.pixelSize: Style.space(24); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Divider {}
                    DetailRow { heading: "Mint"; value: backend.review ? app.mintName(backend.review.mint) : "" }
                    DetailRow { visible: !!backend.review && !!backend.review.locked_to; heading: "Locked to"; value: backend.review && backend.review.locked_to ? (backend.review.locked_to === app.locked.seed_key ? "Your key" : backend.review.receiving ? backend.review.locked_to : app.shortKey(backend.review.locked_to)) : "" }
                    // A zero fee is noise, and the total is the amount plus
                    // that fee, which the reader can add. Only a real fee shows.
                    DetailRow { visible: !!backend.review && Number(backend.review.fee || 0) > 0; heading: "Maximum fee"; value: backend.review ? app.primaryAmount(backend.review.fee) : "" }
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
                    Entry { id: ecashChoice; heading: "Send ecash"; detail: "Create a token to share with someone."; onClicked: { app.entryText = ""; app.lockTo = ""; app.lockToOpen = false; app.go("send_amount") } }
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
                    Action {
                        visible: app.mints.length > 1
                        text: app.selectedMint.name + " · " + app.amountLabel(app.selectedMint.spendable) + " available"
                        iconText: "󰅀"
                        enabled: !backend.busy
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
                        font.pixelSize: Math.round(bigAmount.fontSize * 0.4)
                        opacity: 0.55
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                    }
                    // Locked Ecash: lock this token to a key. The quick shortcut
                    // fills in the wallet's own key, as the reference's send
                    // drawer does when "Quick lock to my key" is on.
                    RowLayout {
                        visible: app.page === "send_amount"
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        Tab { visible: app.locked.quick_lock === true && !!app.locked.seed_key; text: "󰌾  Lock to my key"; selected: app.lockTo !== "" && app.lockTo === app.locked.seed_key; onClicked: { app.lockTo = app.lockTo === app.locked.seed_key ? "" : app.locked.seed_key; app.lockToOpen = false; amountInput.forceActiveFocus() } }
                        Tab { text: app.lockTo !== "" && app.lockTo !== app.locked.seed_key ? "󰌾  Locked to " + app.shortKey(app.lockTo) : "󰌾  Lock to a key"; selected: app.lockToOpen; onClicked: { app.lockToOpen = !app.lockToOpen; if (!app.lockToOpen) amountInput.forceActiveFocus() } }
                    }
                    Ui.TextField {
                        visible: app.page === "send_amount" && app.lockToOpen
                        Layout.fillWidth: true
                        placeholderText: "Recipient's public key (02… hex)"
                        text: app.lockTo === app.locked.seed_key ? "" : app.lockTo
                        onTextEdited: app.lockTo = text.trim()
                        onAccepted: { app.lockToOpen = false; amountInput.forceActiveFocus() }
                    }
                    Item { Layout.fillHeight: true }
                    Action {
                        id: amountContinue
                        text: backend.busy ? "Preparing…" : app.page === "send_amount" ? "Send" : "Request"
                        enabled: backend.unlocked && !backend.busy && !!backend.state.selected && app.entrySats > 0 && !app.entryOver
                        onClicked: backend.request(app.page === "send_amount" ? "send_ecash" : "create_invoice", app.page === "send_amount" ? {amount: String(app.entrySats), lock_to: app.lockTo} : {amount: String(app.entrySats)})
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
                    // Sized so the QR, amount, mint and copy button all fit
                    // the panel without scrolling; only the notes and Done
                    // sit below the fold.
                    spacing: Style.space(app.compact ? 12 : 20)
                    Label { text: backend.share.token ? "Pending ecash" : "Lightning invoice"; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Image { source: backend.share.qr || ""; visible: source.toString() !== ""; Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: Math.min(app.compact ? 180 : 280, contentScroll.availableWidth); Layout.preferredHeight: Layout.preferredWidth; fillMode: Image.PreserveAspectFit }
                    // Shown in the unit the amount was typed in, with the
                    // other beneath, so a dollar request still reads as one.
                    AmountDisplay { visible: !!backend.share.amount; amount: backend.share.amount; size: Style.space(app.compact ? 28 : 32); animated: false }
                    Label { text: backend.share.token ? "Ready to share" : "Waiting for payment"; opacity: 0.6; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { visible: !!backend.share.token && !backend.share.qr; text: "Too large for one QR code. Copy the token to share it."; Layout.fillWidth: true }
                    Action {
                        text: clipboard.running ? "Copied · waiting for paste" : backend.share.token ? "Copy token" : "Copy invoice"
                        enabled: !clipboard.running
                        Layout.fillWidth: true
                        onClicked: { app.clipboardText = backend.share.token || backend.share.invoice || ""; clipboard.stdinEnabled = true; clipboard.running = true }
                    }
                    DetailRow { heading: "Mint"; value: backend.share.mint ? app.mintName(backend.share.mint) : app.selectedMint.name; leading: true }
                    DetailRow { visible: !!backend.share.expiry; heading: "Expires"; value: app.momentFor(backend.share.expiry); leading: true }
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
                // ---- Settings, after cashubtc/wallet's Settings screen, minus
                // Nostr. Pages, not sheets; confirmations use Omarchy's own
                // dialog. The "How locking works" explainer is a row rather
                // than a toolbar icon.
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "settings"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    Label { text: "Settings"; font.bold: true; font.pixelSize: Style.font.heading }
                    Caption { text: "DISPLAY" }
                    Entry { icon: "󰓅"; heading: "Currency"; trailing: (app.fiatCurrency || "Off") + "  ›"; onClicked: app.go("currency") }
                    ToggleRow { icon: "󰠓"; heading: "Use ₿ symbol"; checked: app.bitcoinSymbol; onToggled: app.setDisplay(!app.bitcoinSymbol, app.fiatCurrency) }
                    Caption { text: "BACKUP & SECURITY" }
                    Entry { icon: "󰌆"; heading: "Backup & Restore"; onClicked: app.go("backup") }
                    Entry { icon: "󰒃"; heading: "App Lock"; onClicked: app.go("app_lock") }
                    Caption { text: "PAYMENTS" }
                    Entry { icon: "󱐋"; heading: "Lightning"; onClicked: app.go("lightning") }
                    Entry { icon: "󰌾"; heading: "Locked Ecash"; onClicked: app.go("locked") }
                    Caption { text: "PRIVACY" }
                    Entry { icon: "󰈉"; heading: "Privacy"; onClicked: app.go("privacy") }
                    Caption { text: "ABOUT" }
                    Entry { icon: "󰖟"; heading: "Learn about Cashu"; trailing: "󰏌"; onClicked: Qt.openUrlExternally("https://cashu.space") }
                    Entry { icon: "󰈙"; heading: "Protocol Specs (NUTs)"; trailing: "󰏌"; onClicked: Qt.openUrlExternally("https://github.com/cashubtc/nuts") }
                    Caption { text: "DANGER" }
                    Entry { icon: "󰆴"; heading: "Delete Wallet"; trailing: ""; destructive: true; enabled: !backend.busy; onClicked: deleteDialog.opened = true }
                    Label {
                        text: "cashu.me" + (backend.state.version ? " · " + backend.state.version : "") + (backend.preview ? " · interface preview" : "")
                        font.pixelSize: Style.font.caption
                        opacity: 0.45
                        Layout.fillWidth: true
                        Layout.topMargin: Style.space(12)
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
                // ---- Display → Currency
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "currency"
                    Layout.fillWidth: true
                    spacing: Style.space(12)
                    Label { text: "Currency"; font.bold: true; font.pixelSize: Style.font.heading }
                    Entry {
                        icon: "󰠓"
                        heading: "Off"
                        detail: "Sats only"
                        showsActiveMark: true
                        selected: app.fiatCurrency === ""
                        onClicked: app.setDisplay(app.bitcoinSymbol, "")
                    }
                    Repeater {
                        model: backend.state.currencies || []
                        delegate: Entry {
                            required property var modelData
                            icon: modelData.flag
                            heading: modelData.code
                            detail: modelData.name
                            showsActiveMark: true
                            selected: app.fiatCurrency === modelData.code
                            onClicked: app.setDisplay(app.bitcoinSymbol, modelData.code)
                        }
                    }
                    Divider { visible: app.fiatCurrency !== "" }
                    RowLayout {
                        visible: app.fiatCurrency !== ""
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(2)
                            Label { text: "BTC Price"; opacity: 0.55; font.pixelSize: Style.font.caption }
                            Label { text: app.fiatAvailable ? app.fiatText(100000000) : "Loading…"; font.pixelSize: Style.font.title }
                        }
                        Label {
                            visible: app.fiatAvailable && !!backend.state.exchange_rate.fetched_at
                            text: "Updated " + app.ago(backend.state.exchange_rate ? backend.state.exchange_rate.fetched_at : 0)
                            opacity: 0.55
                            font.pixelSize: Style.font.caption
                        }
                        IconButton { iconText: "󰑐"; iconSpinning: backend.busy && backend.pendingMethod === "refresh_rate"; tooltipText: ""; Accessible.name: "Refresh price"; enabled: !backend.busy; onClicked: backend.request("refresh_rate") }
                    }
                }
                // ---- Backup & Restore
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "backup"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    Label { text: "Backup & Restore"; font.bold: true; font.pixelSize: Style.font.heading }
                    Entry { icon: "󰌆"; heading: "Backup seed phrase"; detail: "View and copy your 12 recovery words."; enabled: backend.unlocked && !backend.busy; onClicked: app.go("recovery") }
                    Entry { icon: "󰑙"; heading: "Restore"; detail: "Restore a wallet and recover funds from mints."; enabled: backend.unlocked && !backend.busy; onClicked: { app.startRestore(); app.go("restore") } }
                }
                // ---- Backup seed phrase. Takes the whole page: a warning and
                // one reveal action first, then the numbered words with the
                // mint URLs a restore also needs. With App Lock on, revealing
                // asks for the password again. The worker hides the phrase
                // after one minute; leaving the page hides it at once.
                ColumnLayout {
                    id: recoveryPage
                    readonly property bool revealed: backend.recoveryPhrase !== ""
                    readonly property var words: backend.recoveryPhrase.trim().split(/\s+/).filter(word => word !== "")
                    visible: app.walletVisible && !backend.review && app.page === "recovery"
                    Layout.fillWidth: true
                    Layout.preferredHeight: app.pinnedHeight(implicitHeight)
                    spacing: Style.space(16)
                    Label { text: "Backup Wallet"; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Item { visible: !recoveryPage.revealed; Layout.fillHeight: true }
                    Label { visible: !recoveryPage.revealed; text: "󰌆"; font.pixelSize: Style.space(44); opacity: 0.8; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { visible: !recoveryPage.revealed; text: "Your recovery phrase is the only way to restore your wallet. Keep it private and stored somewhere safe. Never share it with anyone."; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { visible: !recoveryPage.revealed; text: "Anyone who sees these words can take your funds. Reveal them only when nobody is watching your screen, and write them down on paper rather than in a photo or a message."; opacity: 0.65; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Item { visible: !recoveryPage.revealed; Layout.fillHeight: true }
                    Ui.TextField { id: revealPassword; visible: !recoveryPage.revealed && backend.state.password_required === true; password: true; placeholderText: "Wallet password"; Layout.fillWidth: true; onAccepted: if (revealButton.enabled) revealButton.clicked() }
                    Action {
                        id: revealButton
                        visible: !recoveryPage.revealed
                        text: backend.busy ? "Revealing…" : "Reveal Recovery Phrase"
                        enabled: backend.unlocked && !backend.busy && (backend.state.password_required !== true || revealPassword.text.length > 0)
                        onClicked: backend.request("recovery_phrase", {password: revealPassword.text})
                    }
                    Label { visible: recoveryPage.revealed; text: "Write down these words in order and store them somewhere safe. Do not share them with anyone."; opacity: 0.65; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    GridLayout {
                        visible: recoveryPage.revealed
                        Layout.fillWidth: true
                        columns: 3
                        columnSpacing: Style.space(8)
                        rowSpacing: Style.space(8)
                        Repeater {
                            model: recoveryPage.words
                            delegate: Rectangle {
                                required property string modelData
                                required property int index
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1
                                implicitHeight: Style.space(44)
                                radius: Style.cornerRadius
                                color: Qt.alpha(Color.foreground, 0.07)
                                Accessible.role: Accessible.StaticText
                                Accessible.name: "Word " + (index + 1) + ", " + modelData
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Style.space(10)
                                    anchors.rightMargin: Style.space(6)
                                    spacing: Style.space(6)
                                    Label { text: (index + 1) + "."; opacity: 0.5; font.pixelSize: Style.font.caption }
                                    Label { text: modelData; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                                }
                            }
                        }
                    }
                    Caption { visible: recoveryPage.revealed; text: "MINTS" }
                    Label { visible: recoveryPage.revealed; text: "A restore also needs your mint URLs. Keep these with the words."; opacity: 0.65; Layout.fillWidth: true }
                    Repeater {
                        model: recoveryPage.revealed ? app.mints : []
                        delegate: Label { required property var modelData; text: modelData.url; Layout.fillWidth: true; wrapMode: Text.WrapAnywhere }
                    }
                    Label { visible: recoveryPage.revealed; text: "A phrase does not restore your full history. This page hides after one minute."; opacity: 0.5; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                    Item { visible: recoveryPage.revealed; Layout.fillHeight: true }
                    Action {
                        visible: recoveryPage.revealed
                        text: clipboard.running ? "Copied · waiting for paste" : "Copy Recovery Phrase"
                        enabled: !clipboard.running
                        onClicked: app.copyText(backend.recoveryPhrase)
                    }
                    Secondary { visible: recoveryPage.revealed; text: "Hide phrase"; onClicked: backend.recoveryPhrase = "" }
                }
                // ---- App Lock: the reference's one toggle, with a password in
                // place of Face ID. Turning it on asks for a new password here
                // on the page; turning it off asks for the current one.
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "app_lock"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    Label { text: "App Lock"; font.bold: true; font.pixelSize: Style.font.heading }
                    ToggleRow {
                        icon: "󰒃"
                        heading: "Require a password"
                        detail: "Ask for your password when opening the wallet."
                        checked: backend.state.password_required === true || app.appLockMode === "enable"
                        enabled: !backend.busy
                        onToggled: app.appLockMode = backend.state.password_required === true ? (app.appLockMode === "disable" ? "" : "disable") : (app.appLockMode === "enable" ? "" : "enable")
                    }
                    Ui.TextField { id: securityPassword; visible: app.appLockMode === "enable"; password: true; placeholderText: "New password (12+ characters)"; Layout.fillWidth: true }
                    Ui.TextField { id: securityConfirmation; visible: app.appLockMode === "enable"; password: true; placeholderText: "Repeat password"; Layout.fillWidth: true; onAccepted: if (enablePasswordButton.enabled) enablePasswordButton.clicked() }
                    Label { visible: app.appLockMode === "enable" && securityConfirmation.text.length > 0 && securityPassword.text !== securityConfirmation.text; text: "Passwords do not match."; opacity: 0.65; Layout.fillWidth: true }
                    Action {
                        id: enablePasswordButton
                        visible: app.appLockMode === "enable"
                        text: backend.busy ? "Turning on…" : "Turn on App Lock"
                        enabled: backend.unlocked && !backend.busy && securityPassword.text.length >= 12 && securityPassword.text === securityConfirmation.text
                        onClicked: backend.request("set_password", {password: securityPassword.text})
                    }
                    Ui.TextField { id: currentPassword; visible: app.appLockMode === "disable"; password: true; placeholderText: "Current password"; Layout.fillWidth: true; onAccepted: if (disablePasswordButton.enabled) disablePasswordButton.clicked() }
                    Action {
                        id: disablePasswordButton
                        visible: app.appLockMode === "disable"
                        text: backend.busy ? "Turning off…" : "Turn off App Lock"
                        enabled: backend.unlocked && !backend.busy && currentPassword.text.length > 0
                        onClicked: backend.request("remove_password", {password: currentPassword.text})
                    }
                    Footer { text: backend.state.password_required === true ? "Your wallet locks with the desktop and asks for this password to open. Several random words make a far stronger password than a short complicated one." : "Without App Lock, anyone using your desktop account can open this wallet. If someone copies your wallet folder, a password is the only thing protecting it." }
                    Footer { text: "Your seed phrase and private keys always require your password to reveal while App Lock is on." }
                }
                // ---- Payments → Lightning: an npub.cash Lightning address.
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "lightning"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    Label { text: "Lightning"; font.bold: true; font.pixelSize: Style.font.heading }
                    Caption { text: "LIGHTNING ADDRESS" }
                    ToggleRow {
                        icon: "󱐋"
                        heading: "Enable Lightning Address"
                        checked: app.lightning.enabled === true
                        enabled: !backend.busy && (app.lightning.enabled === true || app.mints.length > 0)
                        busy: backend.busy && backend.pendingMethod === "set_lightning"
                        onToggled: app.setLightning({enabled: !app.lightning.enabled})
                    }
                    Entry {
                        visible: app.lightning.enabled === true && !!app.lightning.address
                        icon: app.lightning.status === "error" ? "󰅙" : app.lightning.status === "connected" ? "󰄬" : "󰔟"
                        iconColor: app.lightning.status === "error" ? Color.urgent : app.lightning.status === "connected" ? app.received : Color.foreground
                        heading: app.lightning.address || ""
                        detail: app.lightning.status === "error" ? "Needs attention" : app.lightning.status === "connected" ? "Connected" : "Connecting"
                        trailing: "󰐲"
                        onClicked: app.showQr("Lightning Address", app.lightning.address)
                    }
                    Secondary { visible: app.lightning.enabled === true && !!app.lightning.address; text: clipboard.running ? "Copied · waiting for paste" : "Copy address"; enabled: !clipboard.running; onClicked: app.copyText(app.lightning.address) }
                    Footer { visible: app.lightning.enabled !== true; text: app.mints.length > 0 ? "Receive Lightning payments to your wallet using a Lightning address." : "Add a mint first to use a Lightning address." }
                    Label { visible: app.lightning.status === "error"; text: app.lightning.error || "Wallet not fully initialized. Try setup again to finish your Lightning address."; color: Color.urgent; Layout.fillWidth: true }
                    Action { visible: app.lightning.status === "error"; text: backend.busy ? "Setting up…" : "Try setup again"; enabled: !backend.busy; onClicked: app.setLightning({}) }
                    Footer { visible: app.lightning.status === "connecting"; text: "Setting up Lightning address…" }
                    Caption { visible: app.lightning.status === "connected"; text: "PREFERENCES" }
                    ToggleRow { visible: app.lightning.status === "connected"; icon: "󰁝"; heading: "Auto-claim payments"; checked: app.lightning.auto_claim === true; enabled: !backend.busy; onToggled: app.setLightning({auto_claim: !app.lightning.auto_claim}) }
                    Entry {
                        visible: app.lightning.status === "connected" && app.mints.length > 0
                        icon: "󰭎"
                        heading: "Receiving mint"
                        trailing: (app.lightning.mint ? app.mintName(app.lightning.mint) : "Select a mint") + (app.mints.length > 1 ? "  ›" : "")
                        enabled: !backend.busy && app.mints.length > 1
                        Accessible.name: "Receiving mint: " + (app.lightning.mint ? app.mintName(app.lightning.mint) : "none") + ". Choose which mint claims incoming Lightning payments"
                        onClicked: app.setLightning({mint: app.nextMintAfter(app.lightning.mint)})
                    }
                    Footer { visible: app.lightning.status === "connected"; text: "Incoming payments are minted as ecash at your chosen mint." }
                    Entry {
                        visible: app.lightning.enabled === true
                        icon: backend.busy && backend.pendingMethod === "check_lightning" ? "󰔟" : "󰑐"
                        heading: "Check for payments"
                        detail: app.lightning.last_checked ? "Last checked " + app.ago(app.lightning.last_checked) : "Not checked yet"
                        trailing: ""
                        enabled: !backend.busy && app.privacy.check_incoming !== false
                        onClicked: backend.request("check_lightning")
                    }
                    Footer { visible: app.lightning.enabled === true && app.privacy.check_incoming === false; text: "To check for payments, allow incoming invoice checks in Privacy settings." }
                }
                // ---- Payments → Locked Ecash (P2PK)
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "locked"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    Label { text: "Locked Ecash"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { text: "Lock ecash to a key so only its holder can claim it — even if the token is intercepted in transit."; opacity: 0.65; Layout.fillWidth: true }
                    Caption { text: "YOUR KEY" }
                    KeyCard {
                        visible: !!app.locked.seed_key
                        title: "Your key"
                        status: "Backed up by your seed phrase"
                        pubkey: app.locked.seed_key || ""
                        onShowQr: app.showQr("Your Key", app.locked.seed_key)
                        onReveal: { app.revealKeyId = ""; app.revealTitle = "Your Key"; app.go("key_reveal") }
                        revealLabel: "Reveal key"
                    }
                    Footer { visible: !app.locked.seed_key; text: "Your key appears once your wallet finishes setting up." }
                    Footer { visible: !!app.locked.seed_key; text: "Show your QR or share this key, and anyone can send you locked ecash. The key comes from your seed phrase, so only you can claim it." }
                    Caption { text: "WHEN SENDING" }
                    ToggleRow { icon: "󰌾"; heading: "Quick lock to my key"; detail: "Show a “Lock to my key” shortcut when sending ecash."; checked: app.locked.quick_lock === true; enabled: !backend.busy; onToggled: backend.request("set_quick_lock", {enabled: !app.locked.quick_lock}) }
                    Entry { icon: "󰇘"; heading: "Advanced keys"; detail: app.deviceKeys.length === 0 ? "Add a key that lives only on this device" : app.deviceKeys.length === 1 ? "1 device key" : app.deviceKeys.length + " device keys"; onClicked: app.go("advanced_keys") }
                    Entry { icon: "󰋽"; heading: "How locking works"; onClicked: app.go("locked_help") }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "locked_help"
                    Layout.fillWidth: true
                    spacing: Style.space(18)
                    Label { text: "Locked ecash"; font.bold: true; font.pixelSize: Style.font.heading }
                    Repeater {
                        model: [
                            {icon: "󰍁", text: "Ecash is bearer cash. Whoever holds a token can spend it — like a banknote."},
                            {icon: "󰌾", text: "Locking ties a token to a key. Even if it's intercepted in transit, only the key's holder can claim it."},
                            {icon: "󰌆", text: "Your key comes from your seed phrase, so it's backed up automatically. Share your key or QR, and anyone can send you locked ecash."},
                            {icon: "󰒊", text: "When you send, you can lock ecash to someone else's key so only they can claim it."}
                        ]
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Style.space(14)
                            Label { text: modelData.icon; font.pixelSize: Style.font.heading; opacity: 0.8; Layout.alignment: Qt.AlignTop }
                            Label { text: modelData.text; Layout.fillWidth: true }
                        }
                    }
                    Action { text: "Got it"; onClicked: app.back() }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "advanced_keys"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    Label { text: "Advanced Keys"; font.bold: true; font.pixelSize: Style.font.heading }
                    Entry { icon: "󰐕"; heading: "Generate a key"; trailing: ""; enabled: !backend.busy; onClicked: backend.request("generate_key") }
                    Entry { icon: "󰇚"; heading: "Import a key"; trailing: app.importingKey ? "" : "›"; enabled: !backend.busy; onClicked: app.importingKey = !app.importingKey }
                    Label { visible: app.importingKey; text: "Paste a private key (nsec) to add it. You'll be able to claim ecash locked to it."; opacity: 0.65; Layout.fillWidth: true }
                    Ui.TextField { id: importKeyField; visible: app.importingKey; password: true; placeholderText: "nsec1…"; Layout.fillWidth: true; text: app.importKeyText; onTextEdited: app.importKeyText = text; onAccepted: if (importKeyButton.enabled) importKeyButton.clicked() }
                    Action { id: importKeyButton; visible: app.importingKey; text: backend.busy ? "Importing…" : "Import key"; enabled: !backend.busy && app.importKeyText.trim() !== ""; onClicked: backend.request("import_key", {text: app.importKeyText.trim()}) }
                    Footer { visible: app.deviceKeys.length === 0; text: "Device-only keys are stored on this device, not in your seed backup. If you lose this device, ecash locked to them is gone — keep amounts small." }
                    Caption { visible: app.deviceKeys.length > 0; text: "DEVICE KEYS" }
                    Repeater {
                        model: app.deviceKeys
                        delegate: Entry {
                            required property var modelData
                            icon: "󰌆"
                            heading: modelData.nickname || app.shortKey(modelData.pubkey)
                            detail: "Device only" + (modelData.used_count === 1 ? " · Used once" : modelData.used_count > 1 ? " · Used " + modelData.used_count + " times" : "")
                            onClicked: { app.deviceKeyId = modelData.id; app.go("device_key") }
                        }
                    }
                    Footer { visible: app.deviceKeys.length > 0; text: "These keys aren't in your seed backup. Back up each one, or keep amounts small." }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "device_key"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    Label { text: app.deviceKey.nickname || "Device key"; font.bold: true; font.pixelSize: Style.font.heading }
                    KeyCard {
                        title: app.deviceKey.nickname || "Device key"
                        status: "On this device only — not in your seed backup"
                        statusColor: Color.urgent
                        pubkey: app.deviceKey.pubkey || ""
                        revealLabel: "Back up key"
                        onShowQr: app.showQr("Key", app.deviceKey.pubkey)
                        onReveal: { app.revealKeyId = app.deviceKey.id; app.revealTitle = "Back up key"; app.go("key_reveal") }
                    }
                    Caption { text: "NAME" }
                    Ui.TextField {
                        id: keyNameField
                        Layout.fillWidth: true
                        placeholderText: "Add a name"
                        text: app.deviceKey.nickname || ""
                        onEditingFinished: if (text !== (app.deviceKey.nickname || "")) backend.request("rename_key", {key_id: app.deviceKey.id, nickname: text})
                    }
                    Entry { icon: "󰆴"; heading: "Remove Key"; trailing: ""; destructive: true; enabled: !backend.busy; onClicked: removeKeyDialog.opened = true }
                    Footer { text: "Ecash locked to this key can only be claimed with it. Removing it can't be undone — back it up first if you might still receive to it." }
                }
                // ---- A private key, revealed on request. With App Lock on the
                // password is asked for first, as for the seed phrase.
                ColumnLayout {
                    id: revealPage
                    readonly property bool revealed: backend.revealedKey !== ""
                    visible: app.walletVisible && !backend.review && app.page === "key_reveal"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: app.revealTitle; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { text: "Anyone with this key can claim ecash locked to it. Never share it."; opacity: 0.65; Layout.fillWidth: true }
                    Ui.TextField { id: revealKeyPassword; visible: !revealPage.revealed && backend.state.password_required === true; password: true; placeholderText: "Wallet password"; Layout.fillWidth: true; onAccepted: if (revealKeyButton.enabled) revealKeyButton.clicked() }
                    Action {
                        id: revealKeyButton
                        visible: !revealPage.revealed
                        text: backend.busy ? "Revealing…" : "Reveal Private Key"
                        enabled: !backend.busy && (backend.state.password_required !== true || revealKeyPassword.text.length > 0)
                        onClicked: backend.request("reveal_key", {key_id: app.revealKeyId, password: revealKeyPassword.text})
                    }
                    Rectangle {
                        visible: revealPage.revealed
                        Layout.fillWidth: true
                        implicitHeight: revealedText.implicitHeight + Style.space(24)
                        radius: Style.cornerRadius
                        color: Qt.alpha(Color.foreground, 0.07)
                        Label { id: revealedText; anchors.fill: parent; anchors.margins: Style.space(12); text: backend.revealedKey; font.pixelSize: Style.font.caption; wrapMode: Text.WrapAnywhere; Accessible.name: "Private key, " + backend.revealedKey }
                    }
                    Action { visible: revealPage.revealed; text: clipboard.running ? "Copied · waiting for paste" : "Copy Private Key"; enabled: !clipboard.running; onClicked: app.copyText(backend.revealedKey) }
                    Secondary { visible: revealPage.revealed; text: "Hide key"; onClicked: backend.revealedKey = "" }
                    Footer { visible: revealPage.revealed; text: "This page hides the key after one minute." }
                }
                // ---- A QR for any text: the Lightning address or a key.
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "qr"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: app.qrTitle; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Image { source: backend.qrView.qr || ""; visible: source.toString() !== ""; Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: Math.min(app.compact ? 220 : 280, contentScroll.availableWidth); Layout.preferredHeight: Layout.preferredWidth; fillMode: Image.PreserveAspectFit }
                    Label { text: backend.qrView.qr_text || ""; font.pixelSize: Style.font.caption; opacity: 0.8; Layout.fillWidth: true; wrapMode: Text.WrapAnywhere; horizontalAlignment: Text.AlignHCenter }
                    Action { text: clipboard.running ? "Copied · waiting for paste" : "Copy"; enabled: !clipboard.running; onClicked: app.copyText(backend.qrView.qr_text || "") }
                    Secondary { text: "Done"; onClicked: app.back() }
                }
                // ---- Privacy
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "privacy"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    Label { text: "Privacy"; font.bold: true; font.pixelSize: Style.font.heading }
                    ToggleRow { heading: "Check incoming invoices"; detail: "Checks for incoming payments while the app is open, contacting the mint each time. Off, the wallet doesn't check on its own."; checked: app.privacy.check_incoming !== false; enabled: !backend.busy; onToggled: app.setPrivacy({check_incoming: !app.privacy.check_incoming}) }
                    ToggleRow { heading: "Repeat checks on a timer"; detail: "Every half minute while the app is open, each check contacting the mint. Off, the wallet checks only once when it opens."; checked: app.privacy.repeat_checks !== false; enabled: !backend.busy && app.privacy.check_incoming !== false; onToggled: app.setPrivacy({repeat_checks: !app.privacy.repeat_checks}) }
                    ToggleRow { heading: "Check sent ecash"; detail: "Asks the mint whether sent ecash was claimed, while the app is open. Off, the wallet stays quiet and you check manually instead."; checked: app.privacy.check_sent !== false; enabled: !backend.busy; onToggled: app.setPrivacy({check_sent: !app.privacy.check_sent}) }
                    ToggleRow { heading: "Paste ecash automatically"; detail: "Reads a Cashu token from the clipboard when the receive page opens."; checked: app.privacy.auto_paste !== false; enabled: !backend.busy; onToggled: app.setPrivacy({auto_paste: !app.privacy.auto_paste}) }
                    Footer { text: "Checks contact the mint over the network — more checks mean faster updates, fewer give the mint less to see." }
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
        // Confirmations use Omarchy's own dialog, the desktop counterpart of
        // the reference's confirmation sheets.
        Ui.ConfirmDialog {
            id: deleteDialog
            anchors.fill: parent
            z: 10
            message: "Delete wallet?\n\nThis deletes the wallet from this device. Make sure you have backed up your seed phrase before continuing. This cannot be undone."
            confirmText: "Delete"
            onCanceled: opened = false
            onConfirmed: { opened = false; backend.request("delete_wallet") }
        }
        Ui.ConfirmDialog {
            id: replaceDialog
            anchors.fill: parent
            z: 10
            message: "Replace this wallet?\n\nRestoring installs the wallet for the words you entered in place of the current one. Make sure the current wallet's seed phrase is backed up first. This cannot be undone."
            confirmText: "Replace"
            onCanceled: opened = false
            onConfirmed: { opened = false; app.restoreReplacing = true; backend.request("delete_wallet") }
        }
        Ui.ConfirmDialog {
            id: removeKeyDialog
            anchors.fill: parent
            z: 10
            message: "Remove this key?\n\nEcash locked to this key can only be claimed with it. This cannot be undone."
            confirmText: "Remove Key"
            onCanceled: opened = false
            onConfirmed: { opened = false; backend.request("remove_key", {key_id: app.deviceKeyId}) }
        }
        }
    }
}
