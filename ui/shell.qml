import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "ClockFormat.js" as ClockFormat
import "Motion.js" as Motion
import "AsciiField.js" as Field
import "AsciiArt.js" as Art
import "Bip39.js" as Bip39

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
        if (page !== "restore" && !restoreMode) { seedReset(); restoreMintList = []; restoreResults = {} }
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
    // An ecash send has no review step in the reference: Send on the amount
    // page creates the token. The worker still prepares and then confirms,
    // so the prepared review is confirmed the moment it arrives and never
    // shown; Lightning payments, receipts and reclaims keep their review.
    readonly property bool ecashAutoConfirm: !!backend.review && backend.review.kind === "Send ecash" && !backend.review.reclaim && !backend.review.receiving
    // The reference's History filter is by status, All / Pending / Completed,
    // not by direction; a failed payment shows only under All.
    readonly property var activity: (backend.state.history || []).filter(tx => {
        var status = String(tx.status || "").toLowerCase()
        var matches = historyFilter === "all" || (historyFilter === "pending" ? status === "pending" : status === "completed" || status === "paid")
        return matches && (app.titleFor(tx) + " " + tx.status + " " + tx.amount + " " + (tx.mint_name || "")).toLowerCase().indexOf(historySearch.toLowerCase()) >= 0
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
    // iOS system red for destructive rows, chosen the same way.
    readonly property color destructive: Color.background.hslLightness < 0.5 ? "#FF453A" : "#FF3B30"
    // iOS system orange for warnings and cautions, as the reference colours
    // "Never share these words" and its caution notices.
    readonly property color warning: Color.background.hslLightness < 0.5 ? "#FF9F0A" : "#FF9500"
    // One ephemeral toast at the top centre, like the reference's
    // ConfirmationToast: 2.2 s, then gone. Errors stay inline.
    function toast(message) { toastHost.message = message; toastHost.shown = true; toastTimer.restart() }
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
        if (conceptOpen) { conceptOpen = false; return }
        // The restore's final step is forward-only, as in the reference.
        if ((page === "restore" || restoreMode) && restoreStep === "progress") return
        // Back undoes the last step: mints → words → Welcome.
        if ((page === "restore" || restoreMode) && restoreStep === "mints") { restoreStep = "seed"; return }
        if (!walletVisible && restoreMode) { restoreMode = false; return }
        if (onboardingOpen) {
            if (onboardingStep === "mint" && firstMintQueue.length === 0) onboardingStep = "seed"
            else if (onboardingStep === "seed") onboardingStep = "welcome"
            return
        }
        if (page === "share" || page === "complete") {
            backend.share = {}; backend.completion = {}; trail = []; page = "home"; return
        }
        page = trail.length ? trail[trail.length - 1] : "home"
        trail = trail.slice(0, -1)
    }
    // Leaving a reveal page is what hides its secret; the pages carry no
    // Hide button of their own, since Back does the same.
    onPageChanged: {
        contentScroll.contentItem.contentY = 0
        if (page !== "recovery") backend.recoveryPhrase = ""
        if (page !== "key_reveal") { backend.revealedKey = ""; revealKeyPassword.clear() }
        if (page !== "recovery") revealPassword.clear()
        if (page !== "app_lock") appLockMode = ""
        if (page !== "add_mint") mintNotice = ""
        if (page !== "advanced_keys") { importingKey = false; importKeyText = "" }
        if (page === "receive" && app.privacy.auto_paste !== false && app.receiveText === "") { pasteTarget = "token"; pasteProbe.explicit = false; pasteProbe.running = false; pasteProbe.running = true }
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
    property string mintNotice: ""
    // The connect page's headline: "Add a mint first" when a payment stalled
    // for want of a mint, plain "Add mint" from the wallet home.
    property bool connectFromPayment: false
    function connectMint(fromPayment) { app.connectFromPayment = fromPayment === true; app.go("connect_mint") }
    function addMintByUrl() { app.mintUrl = ""; app.mintNotice = ""; app.go("add_mint") }
    // Adding a mint returns to the page that asked for one, as the reference's
    // sheet dismisses onto its opener.
    function finishAddMint() {
        var rest = app.trail.slice()
        var destination = "home"
        while (rest.length) {
            var previous = rest.pop()
            if (["add_mint", "connect_mint", "mint"].indexOf(previous) < 0) { destination = previous; break }
        }
        app.trail = rest
        app.page = destination
    }
    property string receiveMethod: "lightning"
    property var suggestions: []
    property bool restoreMode: false
    // ---- Onboarding, after cashubtc/wallet: Welcome → seed phrase → first
    // mint → wallet. `onboarding` holds the wallet back from view between
    // create and the handoff; it is never persisted, so an interrupted
    // onboarding simply opens the wallet next time (the phrase stays in
    // Settings → Backup).
    property bool onboardingOpen: false
    property string onboardingStep: "welcome"
    // Leaving the seed step hides the phrase at once.
    onOnboardingStepChanged: if (onboardingStep !== "seed") backend.recoveryPhrase = ""
    property bool conceptOpen: false
    property bool seedAcknowledged: false
    property var firstMintSelection: []
    property var firstMintCustom: []
    property string firstMintInput: ""
    property bool firstMintInputOpen: false
    property string firstMintNotice: ""
    property var firstMintQueue: []
    function resetOnboarding() {
        onboardingOpen = false; onboardingStep = "welcome"; conceptOpen = false; seedAcknowledged = false
        firstMintSelection = []; firstMintCustom = []; firstMintInput = ""; firstMintInputOpen = false; firstMintNotice = ""; firstMintQueue = []
    }
    function toggleSeedReveal() {
        if (backend.recoveryPhrase !== "") backend.recoveryPhrase = ""
        else backend.request("recovery_phrase", {password: ""})
    }
    function toggleFirstMint(url) {
        var picked = app.firstMintSelection.indexOf(url) >= 0
        app.firstMintSelection = picked ? app.firstMintSelection.filter(item => item !== url) : app.firstMintSelection.concat([url])
    }
    function normalizeMintUrl(piece) {
        var url = piece.trim()
        if (url === "") return ""
        if (!/^https?:\/\//i.test(url)) url = "https://" + url
        url = url.replace(/\/+$/, "")
        if (!/^https?:\/\/[^\s\/]+\.[^\s\/]+/i.test(url) && !/^http:\/\/(localhost|127\.0\.0\.1)/i.test(url)) return ""
        return url
    }
    // The custom URL becomes a selected row, as in the reference.
    function commitFirstMint() {
        if (app.firstMintInput.trim() === "") return true
        var url = app.normalizeMintUrl(app.firstMintInput)
        if (url === "") { app.firstMintNotice = "That doesn't look like a mint URL."; return false }
        var known = app.suggestions.concat(app.firstMintCustom.map(item => ({url: item}))).some(mint => mint.url.toLowerCase() === url.toLowerCase())
        if (known) { app.firstMintNotice = "That mint is already in the list."; return false }
        app.firstMintNotice = ""
        app.firstMintCustom = app.firstMintCustom.concat([url])
        app.firstMintSelection = app.firstMintSelection.concat([url])
        app.firstMintInput = ""
        app.firstMintInputOpen = false
        return true
    }
    // Adds the chosen mints one at a time, suggestions first in their own
    // order, then the custom URLs in entry order; the handoff follows the last.
    function continueFirstMint() {
        if (!app.commitFirstMint()) return
        var ordered = app.suggestions.map(mint => mint.url).concat(app.firstMintCustom).filter(url => app.firstMintSelection.indexOf(url) >= 0)
        if (ordered.length === 0) return
        app.firstMintNotice = ""
        app.firstMintQueue = ordered
        app.addNextFirstMint()
    }
    function addNextFirstMint() {
        if (app.firstMintQueue.length === 0) { app.finishOnboarding(); return }
        backend.request("add_mint", {url: app.firstMintQueue[0]})
    }
    // The closing beat: the terrain curtain sweeps over the last step, the
    // wallet mounts under full cover, and the curtain erodes to reveal it.
    // Reduced motion, or a hidden panel, flips the gate at once.
    function finishOnboarding() {
        if (motion.reduced || !app.presented) { app.completeGate(); return }
        handoff.begin()
    }
    function completeGate() {
        app.resetOnboarding()
        app.restoreMode = false; app.trail = []; app.page = "home"
        app.restoreStep = "seed"; app.seedReset(); app.restoreMintList = []; app.restoreResults = {}
        backend.recoveryPhrase = ""
    }
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
    // The mint page: an added mint or a suggestion, with what it reports.
    property string mintView: ""
    function openMint(url) { app.mintView = url; app.go("mint"); backend.request("mint_info", {url: url}) }
    function suggestionFor(url) { return app.suggestions.find(mint => mint.url === url) || ({}) }
    function contactLink(method, info) {
        var m = String(method).toLowerCase(), value = String(info).trim()
        if (/^https?:\/\//i.test(value)) return value
        if (m === "email") return "mailto:" + value
        if (m === "twitter" || m === "x") return "https://x.com/" + value.replace(/^@/, "")
        if (m === "telegram") return "https://t.me/" + value.replace(/^@/, "")
        return ""
    }
    function copyText(text, what) { app.clipboardText = text; clipboard.stdinEnabled = true; clipboard.running = true; if (what) app.toast("Copied " + what) }
    function shortKey(key) { return key && key.length > 20 ? key.slice(0, 10) + "…" + key.slice(-8) : (key || "") }
    function remaining(seconds) {
        var total = Math.max(0, Math.floor(seconds))
        if (total >= 3600) return Math.floor(total / 3600) + "h " + Math.floor((total % 3600) / 60) + "m"
        if (total >= 60) return Math.floor(total / 60) + "m " + (total % 60) + "s"
        return total + "s"
    }
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
    function pinnedHeight(implicit) { return Math.max(implicit, Math.min(contentScroll.availableHeight, Style.space(560)) - header.height - Style.space(app.compact ? 16 : 22)) }
    // ---- Restore flow
    property string restoreStep: "seed"
    // ---- Word-by-word seed entry, after cashubtc/wallet's SeedPhraseEntry:
    // twelve slots, the slot at seedIndex being the live field text, so a
    // valid but uncommitted last word arms the button with no extra state.
    // The wordlist check is local and per word; the BIP-39 checksum needs
    // all twelve and runs in the worker.
    property var seedWords: ["", "", "", "", "", "", "", "", "", "", "", ""]
    property int seedIndex: 0
    property bool seedReviewing: false
    property bool seedRejected: false
    property bool seedVerified: false
    property bool seedAutoCheck: false
    property var seedNotice: null
    readonly property string restoreWordsText: app.seedWords.filter(word => word !== "").join(" ")
    readonly property int restoreWordCount: app.seedWords.filter(word => word !== "").length
    readonly property bool seedComplete: app.seedWords.every(word => Bip39.contains(word))
    readonly property string seedDraft: app.seedWords[app.seedIndex]
    readonly property var seedCompletions: Bip39.completions(app.seedDraft, 3)
    function seedReset() { seedWords = ["", "", "", "", "", "", "", "", "", "", "", ""]; seedIndex = 0; seedReviewing = false; seedRejected = false; seedVerified = false; seedAutoCheck = false; seedNotice = null }
    function seedSet(slot, text) {
        var words = seedWords.slice(); words[slot] = text; seedWords = words
        seedReviewing = false; seedVerified = false
    }
    // Whitespace is the commit key: everything before it is a finished word
    // and the remainder stays in the field, so a multi-word paste into the
    // field behaves exactly like typing it.
    function seedTyped(text) {
        var lowered = text.toLowerCase()
        seedRejected = false
        if (!/\s/.test(lowered)) { seedSet(seedIndex, lowered); return "none" }
        var chunks = lowered.split(/\s+/)
        var outcome = "none"
        for (var i = 0; i < chunks.length; i++) {
            if (i === chunks.length - 1) { if (chunks[i] !== "") seedSet(seedIndex, chunks[i]) }
            else if (chunks[i] !== "") {
                seedSet(seedIndex, chunks[i])
                outcome = seedCommit()
                if (outcome === "rejected") return outcome
            }
        }
        return outcome
    }
    // An exact match wins outright and a unique prefix completes; anything
    // ambiguous is refused and stays in the field to be corrected.
    function seedCommit() {
        var candidate = seedDraft.trim().toLowerCase()
        if (candidate === "") return "ignored"
        var resolved
        if (Bip39.contains(candidate)) resolved = candidate
        else {
            var matches = Bip39.completions(candidate, 2)
            if (matches.length !== 1) { seedRejected = true; return "rejected" }
            resolved = matches[0]
        }
        seedSet(seedIndex, resolved)
        seedRejected = false
        var next = seedWords.indexOf("")
        if (next >= 0) { seedIndex = next; return "advanced" }
        return "completed"
    }
    function seedStepBack() {
        if (seedIndex === 0) return false
        seedIndex -= 1; seedReviewing = false; seedRejected = false
        return true
    }
    function seedJump(slot) { if (slot >= 0 && slot < 12) { seedIndex = slot; seedReviewing = false; seedRejected = false } }
    // Extra words past the twelfth are dropped: only 12-word phrases restore.
    function seedFill(pasted) {
        var tokens = pasted.toLowerCase().split(/\s+/).filter(token => token !== "")
        if (!tokens.some(token => Bip39.contains(token))) return "unusable"
        var kept = tokens.slice(0, 12)
        var words = []
        for (var i = 0; i < 12; i++) words.push(i < kept.length ? kept[i] : "")
        seedWords = words; seedReviewing = false; seedRejected = false; seedVerified = false
        if (kept.length < 12) { seedIndex = kept.length; return "partial" }
        var bad = words.findIndex(word => !Bip39.contains(word))
        if (bad >= 0) { seedIndex = bad; return "invalid" }
        seedIndex = 11
        return "filled"
    }
    function seedHandle(outcome) {
        if (outcome !== "ignored") seedNotice = null
        if (outcome === "completed") seedRunChecksum()
    }
    function seedRunChecksum() {
        if (!seedComplete || backend.busy) return
        seedAutoCheck = true
        backend.request("validate_phrase", {phrase: restoreWordsText})
    }
    function seedContinue() {
        if (seedVerified) { restoreStep = "mints"; return }
        seedAutoCheck = false
        backend.request("validate_phrase", {phrase: restoreWordsText})
    }
    property var restoreMintList: []
    property string restoreMintInput: ""
    property string restoreNotice: ""
    property var restoreResults: ({})
    property bool restoreReplacing: false
    function startRestore() { restoreStep = "seed"; seedReset(); restoreMintList = []; restoreMintInput = ""; restoreNotice = ""; restoreResults = {}; restoreReplacing = false }
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
        if (backend.state.exists) { replaceDialog.opened = true; return }
        app.restoreInstall()
    }
    function restoreInstall() {
        app.restoreResults = {}
        var urls = app.restoreMintList.map(mint => mint.url)
        backend.request("restore_phrase", {phrase: app.restoreWordsText, mint_urls: urls, password: ""})
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
    function finishRestore() {
        if (app.restoreMode) { app.finishOnboarding(); return }
        app.trail = []; app.page = "home"; app.restoreStep = "seed"; app.seedReset(); app.restoreMintList = []; app.restoreResults = {}
    }
    function pasteInto(target) { pasteTarget = target; pasteProbe.explicit = true; pasteProbe.running = false; pasteProbe.running = true }
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
    readonly property bool walletVisible: backend.preview || (backend.unlocked && !app.onboardingOpen)
    // Every screen before the wallet, plus the restore pages from Settings,
    // shares the onboarding frame: a stage over a pinned action chassis.
    readonly property bool preWallet: !app.walletVisible || (app.page === "restore" && !backend.review)
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
        onReviewChanged: if (app.ecashAutoConfirm) backend.request("confirm_payment", {review_id: backend.reviewId})
        onPaymentFinished: { app.trail = []; app.page = "complete" }
        onMintAdded: app.finishAddMint()
        onReadyChanged: {
            app.maybeOpen()
            if (backend.ready && app.restoreReplacing && !backend.state.exists) { app.restoreReplacing = false; app.restoreInstall() }
        }
        onStateChanged: app.maybeOpen()
        onErrorChanged: if (backend.error) contentScroll.contentItem.contentY = 0
        onNoticeChanged: if (backend.notice) { if (!app.onboardingOpen) app.toast(backend.notice); backend.notice = "" }
        // Clearing a submitted secret waits for the worker to accept it: a
        // rejected recovery phrase used to be wiped, forcing the user to retype
        // every word from paper.
        onSucceeded: method => {
            if (method === "unlock" || method === "create") password.clear()
            // The wallet exists from here on; the seed and first-mint steps
            // hold it back from view until the handoff.
            if (method === "create") { app.resetOnboarding(); app.onboardingOpen = true; app.onboardingStep = "seed" }
            if (method === "add_mint" && app.onboardingOpen && app.firstMintQueue.length > 0) { app.firstMintQueue = app.firstMintQueue.slice(1); app.addNextFirstMint() }
            // The checksum passed: after the twelfth word it only says so, and
            // Continue moves on; from Continue itself it moves on at once.
            if (method === "validate_phrase") { app.seedVerified = true; app.seedNotice = null; if (!app.seedAutoCheck) app.restoreStep = "mints" }
            if (method === "restore_phrase") { app.trail = []; app.page = "restore"; app.restoreStep = "progress"; app.restoreRunNext() }
            if (method === "delete_wallet") {
                // With the worker exiting, the restore waits for its restart
                // (see onReadyChanged); locked, the files are already gone.
                if (app.restoreReplacing) { app.restoreMode = true; if (!backend.restarting) { app.restoreReplacing = false; app.restoreInstall() } }
                else { app.trail = []; app.page = "home"; app.restoreMode = false }
            }
            if (method === "set_password" || method === "remove_password") { securityPassword.clear(); securityConfirmation.clear(); currentPassword.clear(); app.appLockMode = "" }
            if (method === "recovery_phrase") revealPassword.clear()
            if (method === "reveal_key") revealKeyPassword.clear()
            if (method === "import_key") { app.importKeyText = ""; app.importingKey = false }
            if (method === "remove_key") app.back()
            if (method === "remove_mint") { app.trail = []; app.page = "mints" }
            if (method === "make_qr") { if (app.page !== "qr") app.go("qr") }
            if (method === "locked_request") { if (app.page !== "qr") app.go("qr") }
        }
        onFailed: method => {
            if (method === "add_mint") app.firstMintQueue = []
            if (method === "restore_mint") {
                var current = app.restoreMintList.find(mint => (app.restoreResults[mint.url] || {}).status === "restoring")
                if (current) app.restoreResults = Object.assign({}, app.restoreResults, {[current.url]: {status: "failed", error: backend.error}})
            }
            if (method === "restore_phrase" && !backend.state.exists) app.restoreStep = "mints"
            // A checksum failure names no single word, so it hands the user
            // the whole phrase to look at rather than a banner.
            if (method === "validate_phrase") { backend.error = ""; app.seedReviewing = true; app.seedNotice = {title: "That's not a valid seed phrase.", message: "One of the words is probably mistyped. Tap any word below to fix it.", severity: "error"} }
        }
        onRestored: result => {
            app.restoreResults = Object.assign({}, app.restoreResults, {[result.mint]: {status: "done", recovered: result.recovered}})
            app.restoreRunNext()
        }
        onLocked: {
            handoff.finishImmediately()
            app.resetOnboarding()
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
            removeMintDialog.opened = false
            freshDialog.opened = false
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
                            app.receiveText = result.text; app.page = "receive"
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
        // Set by a Paste button, so a bad clipboard gets a toast; the
        // automatic paste on opening the receive page stays silent.
        property bool explicit: false
        onStarted: collected = ""
        stdout: SplitParser { onRead: data => pasteProbe.collected += data + " " }
        stderr: SplitParser { onRead: data => {} }
        onExited: (code, status) => {
            var text = pasteProbe.collected.trim()
            if (code !== 0) return
            if (app.pasteTarget === "token") { if (text.startsWith("cashu")) app.receiveText = text; else if (text !== "" && pasteProbe.explicit) app.toast("That doesn't look like a Cashu token") }
            else if (app.pasteTarget === "invoice") { if (text !== "") app.paymentText = text.replace(/^lightning:/i, "") }
            else if (app.pasteTarget === "mint") {
                // Empty and "held something, but not a mint URL" are different
                // mistakes with different fixes, so they read differently.
                if (text === "") app.mintNotice = "Clipboard is empty."
                else {
                    var found = ""
                    text.split(/[\s,;]+/).forEach(piece => { if (!found) found = app.normalizeMintUrl(piece.replace(/^["']|["']$/g, "")) })
                    if (found) { app.mintUrl = found; app.mintNotice = "" }
                    else app.mintNotice = "No mint URL in your clipboard. Copy the mint's address, then paste."
                }
            }
            else if (app.pasteTarget === "first_mint") { if (text !== "") app.firstMintInput = text.split(/\s+/)[0] }
            else if (app.pasteTarget === "lock") { if (text !== "") app.lockTo = text.split(/\s+/)[0] }
            else if (app.pasteTarget === "words") {
                var outcome = app.seedFill(text)
                if (outcome === "filled") { app.seedNotice = null; app.seedRunChecksum() }
                else if (outcome === "partial") app.seedNotice = {message: "Pasted " + app.restoreWordCount + (app.restoreWordCount === 1 ? " word" : " words") + ". Enter the rest.", severity: "caution"}
                else if (outcome === "invalid") app.seedNotice = {message: "Pasted 12 words, but word " + (app.seedIndex + 1) + " isn't in the list.", severity: "caution"}
                else app.seedNotice = {message: "Nothing in the clipboard looked like a seed phrase.", severity: "caution"}
            }
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
    // The kit has one button: bordered at rest, filled on hover, focus and
    // selection. A "secondary" action differs only in where it sits, never
    // in chrome, so it never reads as loose text.
    component Secondary: Button {
        focusable: true
        bordered: true
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
    // A mint's icon in a bordered square, the monogram of its name until
    // the icon loads or when the mint has none.
    component MintAvatar: Rectangle {
        id: avatar
        property string source: ""
        property string name: ""
        property int size: Style.space(36)
        width: size
        height: size
        radius: Style.cornerRadius
        clip: true
        color: Qt.alpha(Color.foreground, 0.07)
        border.width: 1
        border.color: Qt.alpha(Color.foreground, 0.25)
        Image { id: avatarImage; anchors.fill: parent; anchors.margins: 1; source: avatar.source; fillMode: Image.PreserveAspectCrop; asynchronous: true; smooth: true; visible: status === Image.Ready }
        Label { anchors.centerIn: parent; visible: !avatarImage.visible; text: avatar.name.trim().charAt(0).toUpperCase(); font.bold: true; font.pixelSize: Math.round(avatar.size * 0.45) }
    }
    component SquareIcon: IconButton {
        bordered: true
        implicitWidth: implicitHeight
        tooltipText: ""
    }
    // A key in groups of four, alternating weight, left-aligned, cut with an
    // ellipsis where the row runs out of room.
    component KeyText: Item {
        id: keyText
        property string key: ""
        property real size: Style.font.body
        readonly property var groups: key.match(/.{1,4}/g) || []
        readonly property int fit: Math.max(1, Math.floor((width - groupMetrics.advanceWidth) / groupMetrics.advanceWidth))
        readonly property bool truncated: groups.length > fit
        implicitHeight: keyRow.implicitHeight
        Layout.fillWidth: true
        Accessible.role: Accessible.StaticText
        Accessible.name: key
        TextMetrics { id: groupMetrics; font.family: Style.font.family; font.pixelSize: keyText.size; text: "0000 " }
        Row {
            id: keyRow
            spacing: 0
            Repeater {
                model: keyText.truncated ? keyText.groups.slice(0, keyText.fit) : keyText.groups
                delegate: Label { required property string modelData; required property int index; text: modelData + " "; opacity: index % 2 === 0 ? 1 : 0.5; font.pixelSize: keyText.size }
            }
            Label { visible: keyText.truncated; text: "…"; opacity: 0.5; font.pixelSize: keyText.size }
        }
    }
    // A text field with a paste button at its end, as the reference's
    // inputs carry a Paste action.
    component PasteField: RowLayout {
        id: pasteField
        property alias placeholderText: pasteInput.placeholderText
        property alias text: pasteInput.text
        property string target: ""
        signal edited(string text)
        signal accepted()
        Layout.fillWidth: true
        spacing: Style.space(8)
        Ui.TextField { id: pasteInput; Layout.fillWidth: true; onTextEdited: pasteField.edited(text); onAccepted: pasteField.accepted() }
        SquareIcon { iconText: "󰅍"; Accessible.name: "Paste from clipboard"; Layout.preferredHeight: pasteInput.implicitHeight; onClicked: app.pasteInto(pasteField.target) }
    }
    // The reference's NativeEmptyState: an illustration over a title over a
    // line of copy, centred, with an optional action. "full" is the
    // screen-sized form, "section" the in-list one. The illustration is
    // shaded ASCII art in the mono font (ui/AsciiArt.js, generated by
    // tools/ascii-art.py): a lit shape on a density ramp, the way classic
    // ASCII art draws. Nerd Font glyphs at any size, glyphs in a bordered
    // square, box-drawing line icons and small terrain-style sprites were
    // all tried and none read as a picture; shading is what does.
    component EmptyState: ColumnLayout {
        id: emptyState
        property string art: ""
        property string title: ""
        property string description: ""
        property string actionTitle: ""
        property bool section: false
        signal action()
        Layout.fillWidth: true
        Layout.preferredHeight: section ? implicitHeight + Style.space(64) : Math.max(implicitHeight, Style.space(300))
        spacing: 0
        Accessible.role: Accessible.StaticText
        Accessible.name: title + ". " + description
        Item { Layout.fillHeight: true }
        Label {
            visible: emptyState.art !== ""
            text: (Art.art[emptyState.art] || []).join("\n")
            opacity: 0.85
            font.pixelSize: emptyState.section ? Style.font.caption : Style.font.bodySmall
            lineHeight: 1.0
            Layout.alignment: Qt.AlignHCenter
            Accessible.ignored: true
        }
        Label { text: emptyState.title; font.bold: true; font.pixelSize: emptyState.section ? Style.font.title : Style.font.heading; Layout.fillWidth: true; Layout.topMargin: emptyState.art !== "" ? Style.space(emptyState.section ? 12 : 16) : 0; horizontalAlignment: Text.AlignHCenter }
        Label { visible: emptyState.description !== ""; text: emptyState.description; opacity: 0.55; font.pixelSize: emptyState.section ? Style.font.bodySmall : Style.font.body; Layout.fillWidth: true; Layout.topMargin: Style.space(4); horizontalAlignment: Text.AlignHCenter }
        Action { visible: emptyState.actionTitle !== ""; text: emptyState.actionTitle; Layout.topMargin: Style.space(emptyState.section ? 10 : 12); Layout.fillWidth: false; Layout.preferredWidth: Style.space(160); Layout.alignment: Qt.AlignHCenter; onClicked: emptyState.action() }
        Item { Layout.fillHeight: true }
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
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(10)
                KeyText { key: keyCard.pubkey }
                SquareIcon { iconText: "󰆏"; Accessible.name: "Copy this key"; enabled: keyCard.pubkey !== ""; onClicked: app.copyText(keyCard.pubkey, "key") }
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
        // A mint row shows its avatar instead of an icon.
        property string avatar: ""
        property string monogram: ""
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
            MintAvatar { visible: entry.monogram !== ""; source: entry.avatar; name: entry.monogram; Layout.alignment: Qt.AlignVCenter }
            Label { visible: entry.icon !== "" && entry.monogram === ""; text: entry.icon; color: entry.destructive ? app.destructive : entry.iconColor; font.pixelSize: Style.font.heading; opacity: entry.destructive || entry.iconColor !== Color.foreground ? 1 : 0.8; Layout.preferredWidth: Style.space(28); horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignVCenter }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                spacing: Style.space(5)
                Label { text: entry.heading; color: entry.destructive ? app.destructive : Color.foreground; font.bold: true; Layout.fillWidth: true; elide: Text.ElideMiddle; wrapMode: Text.NoWrap }
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
    // One onboarding step's stage. Steps stack in one frame and swap by a
    // quiet materialize (scale 0.96 → 1 with the fade, entering after the
    // tail of the exit), never a lateral push; reduced motion is a plain
    // fade. The chassis below never moves.
    component Stage: Item {
        id: stage
        property bool current: false
        default property alias content: stageColumn.data
        readonly property real contentHeight: stageColumn.implicitHeight
        anchors.fill: parent
        visible: opacity > 0
        opacity: current ? 1 : 0
        scale: current || motion.reduced ? 1 : 0.96
        transformOrigin: Item.Center
        Behavior on opacity {
            SequentialAnimation {
                PauseAnimation { duration: stage.current && !motion.reduced ? 100 : 0 }
                NumberAnimation { duration: motion.reduced ? Motion.gentle : (stage.current ? 280 : 180); easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
            }
        }
        Behavior on scale { enabled: !motion.reduced; NumberAnimation { duration: 280; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut } }
        ColumnLayout { id: stageColumn; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; spacing: Style.space(16) }
    }
    // Every step titles itself at the top of its stage, on the same line,
    // so the title stays put across the swap. The header rises 10 px into
    // place as its stage enters; exits only fade.
    component StepHeader: ColumnLayout {
        id: stepHeader
        property string title: ""
        property string subhead: ""
        property bool risen: true
        property bool shown: true
        Layout.fillWidth: true
        spacing: Style.space(8)
        transform: Translate {
            y: motion.reduced || stepHeader.risen || stepHeader.shown ? 0 : 10
            Behavior on y { enabled: stepHeader.risen; NumberAnimation { duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut } }
        }
        Label { text: stepHeader.title; font.bold: true; font.pixelSize: Style.font.displayLarge; lineHeight: 1.1; Layout.fillWidth: true }
        Label { visible: stepHeader.subhead !== ""; text: stepHeader.subhead; opacity: 0.65; lineHeight: 1.3; Layout.fillWidth: true }
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
            item.suspendDismissal = Qt.binding(() => imageDialog.visible || scanner.running || !!backend.review || deleteDialog.opened || replaceDialog.opened || removeKeyDialog.opened || removeMintDialog.opened)
            item.dismissed.connect(() => app.dismiss(false, true))
        }
    }
    FloatingWindow {
        id: window
        title: backend.preview ? "cashu.me — interface preview" : "cashu.me"
        visible: app.presented && !app.compact
        // Closing the window clears secrets exactly as hiding the panel does.
        onVisibleChanged: if (!visible && !app.compact) app.dismiss(true)
        // A phone's proportions, as the reference is a phone app: the
        // content column is 460 wide and the window opens about 2.2 times
        // as tall as that, as tall as the screen allows under the bar.
        implicitWidth: Style.space(460)
        implicitHeight: Math.min(Style.space(1000), (window.screen ? window.screen.height : 1080) - Style.bar.sizeHorizontal - Style.gapsOut * 4)
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
            visible: !app.preWallet
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
                    // Locked Ecash on the amount page: a lock beside the expand
                    // control, lit while a key is set, opening the key field.
                    IconButton {
                        visible: app.walletVisible && app.page === "send_amount"
                        iconText: app.lockTo !== "" ? "󰌾" : "󰍁"
                        selected: app.lockTo !== ""
                        Accessible.name: app.lockTo !== "" ? "Locked to a key. Change or remove the lock" : "Lock this ecash to a key"
                        enabled: !backend.busy
                        onClicked: { app.lockToOpen = !app.lockToOpen; if (!app.lockToOpen) amountInput.forceActiveFocus() }
                    }
                    IconButton {
                        iconText: app.compact ? "󰁜" : "󰁃"
                        Accessible.name: app.compact ? "Expand to window" : "Return to panel"
                        onClicked: app.present(app.compact)
                    }
                }

                Label { visible: backend.error !== ""; text: backend.error; color: Color.urgent; Layout.fillWidth: true }
                Label { visible: scanner.running; text: "Scanning… Hold one QR code steady. Scanning stops after one minute."; Layout.fillWidth: true; opacity: 0.65 }
                Secondary { visible: scanner.running; text: "Cancel scan"; onClicked: scanner.running = false }

                ColumnLayout {
                    visible: !!backend.review && !app.ecashAutoConfirm
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
                    id: homeColumn
                    visible: app.walletVisible && !backend.review && app.page === "home"
                    Layout.fillWidth: true
                    spacing: Style.space(app.compact ? 14 : 22)
                    // As many recent rows as fit between the RECENT label and
                    // the View all link without scrolling: more in a window,
                    // fewer in the panel, never fewer than one.
                    readonly property real rowStride: Style.space(56) + spacing
                    readonly property real freeHeight: contentScroll.availableHeight - homeColumn.y - recentLabel.y - recentLabel.height - spacing - viewAllLink.implicitHeight - spacing
                    readonly property int fitRows: Math.max(1, Math.min(20, Math.floor(freeHeight / rowStride)))
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
                    Entry { visible: app.totalPending > 0 || app.totalReserved > 0; heading: "Pending activity"; detail: app.amountLabel(app.totalPending) + " pending · " + app.amountLabel(app.totalReserved) + " reserved"; onClicked: app.tab("history") }
                    // The reference drops the RECENT header when there is
                    // nothing to label and centres its empty state instead.
                    readonly property bool hasHistory: (backend.state.history || []).length > 0
                    EmptyState { visible: app.mints.length === 0; art: "coin"; title: "Add a mint to get started"; description: "Mints custody your ecash. Add one to begin."; actionTitle: "Add mint"; onAction: app.connectMint(false) }
                    EmptyState { visible: app.mints.length > 0 && !parent.hasHistory; art: "clock"; title: "No Activity Yet"; description: "Your recent payments will show up here." }
                    Divider { visible: parent.hasHistory }
                    Label { id: recentLabel; visible: parent.hasHistory; text: "RECENT"; opacity: 0.55; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                    Repeater {
                        model: (backend.state.history || []).slice(0, homeColumn.fitRows)
                        delegate: ActivityRow {}
                    }
                    // The one borderless action on the page: a quiet link, not
                    // a third button under Receive and Send.
                    Button { id: viewAllLink; visible: parent.hasHistory; text: "View all activity  ›"; focusable: true; fontSize: Style.font.bodySmall; opacity: 0.7; Layout.alignment: Qt.AlignHCenter; onClicked: app.tab("history") }
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
                        Repeater { model: [{id:"all", name:"All"}, {id:"pending", name:"Pending"}, {id:"completed", name:"Completed"}]
                            delegate: Tab { required property var modelData; text: modelData.name; selected: app.historyFilter === modelData.id; onClicked: app.historyFilter = modelData.id }
                        }
                    }
                    EmptyState { visible: !app.activity.length && app.historySearch.trim() !== ""; art: "search"; title: "No Results"; description: "No activity matches “" + app.historySearch.trim() + "”." }
                    EmptyState { visible: !app.activity.length && app.historySearch.trim() === "" && app.historyFilter !== "all"; art: "filter"; title: "Nothing Here"; description: "No transactions match this filter." }
                    EmptyState { visible: !app.activity.length && app.historySearch.trim() === "" && app.historyFilter === "all"; art: "clock"; title: "No Activity Yet"; description: "Your first payment will show up here." }
                    Repeater {
                        model: app.activity
                        delegate: ActivityRow {}
                    }
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
                    readonly property string outcome: String(app.transaction.status || "").toLowerCase()
                    readonly property bool settled: outcome === "completed" || outcome === "paid"
                    // CDK's statuses, labelled as the reference labels them.
                    readonly property bool failed: outcome === "failed"
                    Label { text: app.titleFor(app.transaction); font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    // The reference's result mark: a filled tile with a check for
                    // a settled payment, a clock while pending, a cross when failed.
                    Label {
                        text: parent.settled ? "󰄬" : parent.failed ? "󰅖" : "󰔟"
                        color: parent.failed ? app.destructive : Color.foreground
                        opacity: parent.settled || parent.failed ? 1 : 0.6
                        font.pixelSize: Style.space(48)
                        font.bold: true
                        Layout.fillWidth: true
                        Layout.topMargin: Style.space(8)
                        horizontalAlignment: Text.AlignHCenter
                    }
                    AmountDisplay { amount: app.transaction.amount; emphasized: true; animated: false }
                    DetailRow { heading: "Status"; value: parent.settled ? (app.transaction.kind === "Lightning" ? "Paid" : "Claimed") : parent.failed ? "Failed" : "Pending" }
                    DetailRow { heading: "Date"; value: app.momentFor(app.transaction.timestamp) }
                    DetailRow { heading: "Mint"; value: app.transaction.mint_name || app.transaction.mint || "" }
                    DetailRow { visible: Number(app.transaction.fee || 0) > 0; heading: "Fee"; value: app.primaryAmount(app.transaction.fee) }
                    // Unclaimed ecash: the token can be shown and copied again,
                    // or taken back while nobody has redeemed it.
                    Action { visible: !!app.transaction.operation_id && !parent.settled; text: "Show token"; enabled: !backend.busy; onClicked: backend.request("show_pending_token", {operation_id: app.transaction.operation_id}) }
                    Secondary { visible: !!app.transaction.operation_id && !parent.settled; text: "Reclaim ecash"; enabled: !backend.busy; onClicked: backend.request("reclaim_token", {operation_id: app.transaction.operation_id}) }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "send"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: "Send"; font.pixelSize: Style.font.heading; font.bold: true }
                    // Without a mint there is nothing to send from; the reference
                    // shows this in place of the sheet's contents.
                    EmptyState { visible: app.mints.length === 0; section: true; art: "coin"; title: "No Mints Available"; description: "Add a mint to get started."; actionTitle: "Add mint"; onAction: app.connectMint(true) }
                    PasteField { visible: app.mints.length > 0; placeholderText: "Address, invoice, or Cashu Request"; target: "invoice"; text: app.paymentText; onEdited: text => app.paymentText = text; onAccepted: if (invoiceReview.enabled) invoiceReview.clicked() }
                    Action { id: invoiceReview; visible: app.mints.length > 0 && app.paymentText.trim() !== ""; text: backend.busy ? "Preparing…" : "Review invoice"; enabled: !backend.busy && !!backend.state.selected; Layout.fillWidth: true; onClicked: backend.request("pay_invoice", {text: app.paymentText}) }
                    Entry { visible: app.mints.length > 0; icon: "󰐲"; heading: "Scan"; detail: "Scan an invoice, address, or request"; onClicked: app.go("scan") }
                    Entry { id: ecashChoice; visible: app.mints.length > 0; icon: "󰄔"; heading: "Ecash"; detail: "Create a token to share with someone"; onClicked: { app.entryText = ""; app.lockTo = ""; app.lockToOpen = false; app.go("send_amount") } }
                }
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "receive"
                    Layout.fillWidth: true
                    spacing: Style.space(22)
                    Label { text: "Receive"; font.pixelSize: Style.font.heading; font.bold: true }
                    EmptyState { visible: app.mints.length === 0; section: true; art: "coin"; title: "No Mints Available"; description: "Add a mint to get started."; actionTitle: "Add mint"; onAction: app.connectMint(true) }
                    PasteField { visible: app.mints.length > 0; placeholderText: "Paste a Cashu token"; target: "token"; text: app.receiveText; onEdited: text => app.receiveText = text; onAccepted: if (receiveReview.enabled) receiveReview.clicked() }
                    Action { id: receiveReview; visible: app.mints.length > 0 && app.receiveText.trim() !== ""; text: backend.busy ? "Preparing…" : "Receive"; enabled: backend.unlocked && !backend.busy; onClicked: backend.request("receive_token", {text: app.receiveText}) }
                    Entry { visible: app.mints.length > 0; icon: "󰐲"; heading: "Scan"; detail: "Scan an ecash token"; onClicked: app.go("scan") }
                    Entry { id: lightningChoice; visible: app.mints.length > 0; icon: "󱐋"; heading: "Lightning"; detail: "Create an invoice to receive from another wallet"; onClicked: { app.entryText = ""; app.go("receive_amount") } }
                }
                ColumnLayout {
                    visible: app.walletVisible && (!backend.review || app.ecashAutoConfirm) && (app.page === "send_amount" || app.page === "receive_amount")
                    Layout.fillWidth: true
                    spacing: Style.space(24)
                    // The page owns keyboard focus and the amount is the only
                    // large thing on it: no box, no cursor, no helper copy.
                    // Layout.preferredHeight fills the panel so the button
                    // sits at the bottom and the amount floats between.
                    id: amountPage
                    Layout.preferredHeight: app.pinnedHeight(implicitHeight)
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
                    // Opened from the header's lock: the recipient's key, with the
                    // "Lock to my key" shortcut when Quick lock is on. A set lock
                    // shows as a caption under the amount.
                    Label { visible: app.page === "send_amount" && app.lockTo !== "" && !app.lockToOpen; text: "󰌾  Locked to " + (app.lockTo === app.locked.seed_key ? "your key" : app.shortKey(app.lockTo)); opacity: 0.6; font.pixelSize: Style.font.bodySmall; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    PasteField {
                        visible: app.page === "send_amount" && app.lockToOpen
                        placeholderText: "Recipient's public key (02… hex)"
                        target: "lock"
                        text: app.lockTo === app.locked.seed_key ? "" : app.lockTo
                        onEdited: text => app.lockTo = text.trim()
                        onAccepted: { app.lockToOpen = false; amountInput.forceActiveFocus() }
                    }
                    RowLayout {
                        visible: app.page === "send_amount" && app.lockToOpen
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        Tab { visible: app.locked.quick_lock === true && !!app.locked.seed_key; text: "Lock to my key"; selected: app.lockTo === app.locked.seed_key; onClicked: { app.lockTo = app.locked.seed_key; app.lockToOpen = false; amountInput.forceActiveFocus() } }
                        Tab { text: app.lockTo !== "" ? "Remove lock" : "Cancel"; onClicked: { app.lockTo = ""; app.lockToOpen = false; amountInput.forceActiveFocus() } }
                    }
                    Item { Layout.fillHeight: true }
                    Action {
                        id: amountContinue
                        text: backend.busy ? (app.ecashAutoConfirm ? "Creating…" : "Preparing…") : app.page === "send_amount" ? "Send" : "Request"
                        enabled: backend.unlocked && !backend.busy && !!backend.state.selected && app.entrySats > 0 && !app.entryOver
                        onClicked: backend.request(app.page === "send_amount" ? "send_ecash" : "create_invoice", app.page === "send_amount" ? {amount: String(app.entrySats), lock_to: app.lockTo} : {amount: String(app.entrySats)})
                    }
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
                    // the panel without scrolling.
                    spacing: Style.space(app.compact ? 12 : 20)
                    // After the reference: title, the code, the amount, an
                    // expiry countdown for an invoice, label/value rows, and
                    // Copy pinned to the bottom of the panel as a secondary
                    // action, never a primary one under the code.
                    Layout.preferredHeight: app.pinnedHeight(implicitHeight)
                    readonly property bool tokenClaimed: !!backend.share.token && !!backend.share.operation_id && !(backend.state.pending_sends || []).some(send => send.id === backend.share.operation_id)
                    readonly property double expiresIn: backend.share.expiry ? backend.share.expiry - app.now / 1000 : 0
                    Timer { running: app.page === "share" && !!backend.share.expiry; interval: 1000; repeat: true; triggeredOnStart: true; onTriggered: app.now = Date.now() }
                    Label { text: backend.share.token ? "Pending Ecash" : "Lightning Invoice"; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    // A long token animates through its NUT-16 frames; each new
                    // frame fades in over the last so the code never strobes.
                    Item {
                        id: shareQr
                        property var frames: backend.share.qr_frames || []
                        property int frame: 0
                        property string previous: ""
                        readonly property string current: frames.length > 0 ? frames[frame % frames.length] : (backend.share.qr || "")
                        visible: current !== ""
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: Math.min(app.compact ? 180 : 280, contentScroll.availableWidth)
                        Layout.preferredHeight: Layout.preferredWidth
                        onFramesChanged: { frame = 0; previous = "" }
                        onCurrentChanged: { ghost.opacity = 1; ghostFade.restart() }
                        property int speed: 1
                        readonly property var speeds: [{name: "fast", interval: 100}, {name: "medium", interval: 300}, {name: "slow", interval: 500}]
                        Image { anchors.fill: parent; source: shareQr.current; fillMode: Image.PreserveAspectFit; cache: true }
                        Image { id: ghost; anchors.fill: parent; source: shareQr.previous; fillMode: Image.PreserveAspectFit; opacity: 0; cache: true }
                        NumberAnimation { id: ghostFade; target: ghost; property: "opacity"; from: 1; to: 0; duration: motion.reduced ? 0 : 140; onStopped: shareQr.previous = shareQr.current }
                        Timer { running: shareQr.visible && shareQr.frames.length > 1 && app.page === "share"; interval: shareQr.speeds[shareQr.speed].interval; repeat: true; onTriggered: { shareQr.previous = shareQr.current; shareQr.frame = (shareQr.frame + 1) % shareQr.frames.length } }
                        TapHandler { enabled: shareQr.frames.length > 1; onTapped: { shareQr.speed = (shareQr.speed + 1) % shareQr.speeds.length; app.toast("Animation " + shareQr.speeds[shareQr.speed].name) } }
                        Accessible.role: Accessible.Button
                        Accessible.name: shareQr.frames.length > 1 ? "Animated QR code, " + shareQr.speeds[shareQr.speed].name + " speed. Tap to change the speed" : "QR code"
                    }
                    Label { visible: shareQr.frames.length > 1; text: "Animated code · " + shareQr.speeds[shareQr.speed].name + " · tap to change speed"; opacity: 0.5; font.pixelSize: Style.font.caption; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    AmountDisplay { visible: !!backend.share.amount; amount: backend.share.amount; size: Style.space(app.compact ? 28 : 32); animated: false }
                    Label { visible: !!backend.share.expiry; text: parent.expiresIn > 0 ? "󰔟  Expires in " + app.remaining(parent.expiresIn) : "Expired"; color: parent.expiresIn > 0 ? Color.foreground : app.destructive; opacity: parent.expiresIn > 0 ? 0.6 : 1; font.pixelSize: Style.font.caption; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { visible: parent.tokenClaimed; text: "󰄬  Claimed"; color: app.received; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    DetailRow { visible: !!backend.share.token && Number(backend.share.fee || 0) > 0; heading: "Fee"; value: app.primaryAmount(backend.share.fee) }
                    DetailRow { heading: "Unit"; value: "SAT" }
                    DetailRow { visible: app.fiatAvailable && !!backend.share.amount; heading: "Fiat"; value: app.fiatText(backend.share.amount) }
                    DetailRow { heading: "Mint"; value: (backend.share.mint ? app.mintName(backend.share.mint) : app.selectedMint.name) }
                    Item { Layout.fillHeight: true }
                    // The reference titles the invoice's button "Copy Invoice"
                    // and the token's plain "Copy", then Check Status below it.
                    Secondary {
                        text: backend.share.token ? "Copy" : "Copy Invoice"
                        enabled: !clipboard.running
                        onClicked: app.copyText(backend.share.token || backend.share.invoice || "", backend.share.token ? "ecash token" : "invoice")
                    }
                    // With "Check sent ecash" on, reconciliation asks the mint
                    // itself; the manual check exists only for the opted-out.
                    Secondary { visible: !!backend.share.token && !parent.tokenClaimed && app.privacy.check_sent === false; text: backend.busy ? "Checking…" : "Check Status"; enabled: !backend.busy; onClicked: backend.request("sync") }
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
                            avatar: modelData.icon_url || app.suggestionFor(modelData.url).icon_url || ""
                            monogram: modelData.name
                            heading: modelData.name
                            detail: (modelData.url === backend.state.selected ? "Default · " : "") + modelData.url.replace(/^https?:\/\//, "") + (modelData.sync === "retrying" ? " · unavailable" : "")
                            trailing: app.primaryAmount(modelData.spendable) + "  ›"
                            enabled: !backend.busy
                            onClicked: app.openMint(modelData.url)
                        }
                    }
                    Entry { icon: "󰐕"; heading: "Add mint"; onClicked: app.addMintByUrl() }
                    Footer { text: "Each mint holds a separate balance; the wallet shows their total. The default mint is used for new payments, and you can switch it when entering an amount." }
                }
                // The mint page, after the reference's MintDetailView: what the
                // mint reports about itself, then Add, Set as Default, or Remove.
                ColumnLayout {
                    id: mintPage
                    readonly property var added: app.mints.find(mint => mint.url === app.mintView) || null
                    readonly property var info: backend.mintInfo && backend.mintInfo.url === app.mintView ? backend.mintInfo : ({})
                    readonly property bool loading: backend.busy && backend.pendingMethod === "mint_info"
                    readonly property string displayName: info.name || (added ? added.name : "") || app.suggestionFor(app.mintView).name || app.mintView.replace(/^https?:\/\//, "")
                    readonly property bool isDefault: !!added && backend.state.selected === app.mintView
                    readonly property var nutLabels: ({"7": "Token state check", "8": "Lightning fee return", "9": "Restore from seed", "10": "Spending conditions", "11": "P2PK locking", "12": "DLEQ proofs", "14": "HTLCs", "20": "WebSocket updates"})
                    visible: app.walletVisible && !backend.review && app.page === "mint"
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(14)
                        MintAvatar { source: mintPage.info.icon_url || (mintPage.added ? mintPage.added.icon_url : "") || app.suggestionFor(app.mintView).icon_url || ""; name: mintPage.displayName; size: Style.space(56) }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            spacing: Style.space(4)
                            Label { text: mintPage.displayName; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                            Label { text: app.mintView.replace(/^https?:\/\//, ""); opacity: 0.6; font.pixelSize: Style.font.caption; Layout.fillWidth: true; elide: Text.ElideMiddle; wrapMode: Text.NoWrap }
                            Label { visible: mintPage.isDefault; text: "󰄬  Default mint"; color: app.received; font.pixelSize: Style.font.caption }
                        }
                    }
                    AmountDisplay { visible: !!mintPage.added; amount: mintPage.added ? mintPage.added.spendable : 0; size: Style.space(32); animated: false }
                    Footer { text: mintPage.loading ? "Checking…" : mintPage.info.url ? "Online" : backend.error ? "Unreachable · showing saved information." : "" }
                    Caption { visible: !!mintPage.info.description || !!mintPage.info.description_long; text: "ABOUT" }
                    Label { visible: !!mintPage.info.description; text: mintPage.info.description || ""; Layout.fillWidth: true }
                    Label { visible: !!mintPage.info.description_long; text: mintPage.info.description_long || ""; opacity: 0.65; Layout.fillWidth: true }
                    Caption { visible: !!mintPage.info.motd; text: "MESSAGE FROM THE MINT" }
                    Label { visible: !!mintPage.info.motd; text: mintPage.info.motd || ""; Layout.fillWidth: true }
                    Caption { visible: !!mintPage.info.nuts; text: "CAPABILITIES" }
                    Repeater {
                        model: mintPage.info.nuts || []
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.leftMargin: Style.space(12)
                            spacing: Style.space(12)
                            Label { text: modelData.supported ? "󰄬" : "󰅖"; color: modelData.supported ? app.received : Color.foreground; opacity: modelData.supported ? 1 : 0.35; Layout.preferredWidth: Style.space(20) }
                            Label { text: "NUT-" + (modelData.nut.length < 2 ? "0" : "") + modelData.nut; opacity: 0.55; font.pixelSize: Style.font.caption; Layout.preferredWidth: Style.space(56) }
                            Label { text: mintPage.nutLabels[modelData.nut] || ""; Layout.fillWidth: true }
                        }
                    }
                    Caption { visible: !!mintPage.info.url; text: "PAYMENT METHODS" }
                    DetailRow { visible: !!mintPage.info.url; heading: "󰁅  Receive"; value: (mintPage.info.receive_methods || []).join(" · ") || "None"; leading: true }
                    DetailRow { visible: !!mintPage.info.url; heading: "󰁝  Send"; value: (mintPage.info.send_methods || []).join(" · ") || "None"; leading: true }
                    Caption { visible: (mintPage.info.contact || []).length > 0; text: "CONTACT" }
                    Repeater {
                        model: mintPage.info.contact || []
                        delegate: Entry {
                            required property var modelData
                            icon: "󰆼"
                            heading: modelData.method.charAt(0).toUpperCase() + modelData.method.slice(1)
                            detail: modelData.info
                            trailing: app.contactLink(modelData.method, modelData.info) ? "󰏌" : ""
                            enabled: app.contactLink(modelData.method, modelData.info) !== ""
                            onClicked: Qt.openUrlExternally(app.contactLink(modelData.method, modelData.info))
                        }
                    }
                    Caption { visible: !!mintPage.info.version || !!mintPage.info.tos_url; text: "DETAILS" }
                    DetailRow { visible: !!mintPage.info.version; heading: "Software"; value: mintPage.info.version || ""; leading: true }
                    Entry { visible: !!mintPage.info.tos_url; icon: "󰈙"; heading: "Terms of service"; trailing: "󰏌"; onClicked: Qt.openUrlExternally(mintPage.info.tos_url) }
                    Footer { visible: !!mintPage.info.url; text: "Information reported by the mint." }
                    Footer { visible: !mintPage.added; text: "Mints are run by third parties; this wallet isn't affiliated with any of them. Only add a mint you trust." }
                    Action { visible: !mintPage.added; text: backend.busy && backend.pendingMethod === "add_mint" ? "Adding mint…" : "Add mint"; enabled: backend.unlocked && !backend.busy; onClicked: backend.request("add_mint", {url: app.mintView}) }
                    Action { visible: !!mintPage.added && !mintPage.isDefault; text: "Set as Default"; enabled: !backend.busy; onClicked: backend.request("select_mint", {url: app.mintView}) }
                    Entry { visible: !!mintPage.added; icon: "󰆴"; heading: "Remove mint"; trailing: ""; destructive: true; enabled: !backend.busy; onClicked: removeMintDialog.opened = true }
                }
                // ---- Add mint, after cashubtc/wallet's AddMintSheet: the URL
                // form alone, as the Mints tab opens it. Known mints live on
                // the connect page below, which the wallet home and a payment
                // without a mint open instead.
                ColumnLayout {
                    visible: app.walletVisible && !backend.review && app.page === "add_mint"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: app.trail.indexOf("connect_mint") >= 0 ? "Add by URL" : "Add mint"; font.bold: true; font.pixelSize: Style.font.heading }
                    // A persistent label, not a placeholder doing double duty.
                    Label { text: "Mint URL"; opacity: 0.6; font.pixelSize: Style.font.caption }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Ui.TextField { id: mintUrlField; Layout.fillWidth: true; placeholderText: "https://…"; text: app.mintUrl; onTextEdited: { app.mintUrl = text; app.mintNotice = "" } onAccepted: if (addMintButton.enabled) addMintButton.clicked() }
                        SquareIcon { visible: app.mintUrl !== ""; iconText: "󰅖"; Accessible.name: "Clear"; Layout.preferredHeight: mintUrlField.implicitHeight; enabled: !backend.busy; onClicked: { app.mintUrl = ""; app.mintNotice = "" } }
                    }
                    Footer { text: "Mints are run by third parties; this wallet isn't affiliated with any of them. Only add a mint you trust." }
                    Label { visible: app.mintNotice !== ""; text: app.mintNotice; opacity: 0.75; Layout.fillWidth: true }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        Secondary { text: "Paste"; enabled: !backend.busy; onClicked: app.pasteInto("mint") }
                        Action { id: addMintButton; text: backend.busy && backend.pendingMethod === "add_mint" ? "Adding mint…" : "Add mint"; enabled: backend.unlocked && !backend.busy && app.mintUrl.trim() !== ""; onClicked: backend.request("add_mint", {url: app.mintUrl.trim()}) }
                    }
                }
                // ---- Connect a mint, after the reference's ConnectMintSheet:
                // recognition over recall. The known mints the wallet doesn't
                // have yet add on tap; Add by URL opens the form above.
                ColumnLayout {
                    id: connectPage
                    readonly property var known: app.suggestions.filter(mint => !app.mints.some(added => added.url === mint.url))
                    visible: app.walletVisible && !backend.review && app.page === "connect_mint"
                    Layout.fillWidth: true
                    spacing: Style.space(16)
                    Label { text: app.connectFromPayment ? "Add a mint first" : "Add mint"; font.bold: true; font.pixelSize: Style.font.heading }
                    Label { text: "Mints issue the ecash you send and receive. Add one to get started."; opacity: 0.65; Layout.fillWidth: true }
                    // Not "Suggested": the form says this wallet isn't affiliated
                    // with any mint, and suggesting implies it is.
                    Caption { visible: connectPage.known.length > 0; text: "KNOWN MINTS" }
                    Repeater {
                        model: connectPage.known
                        delegate: Entry {
                            required property var modelData
                            avatar: modelData.icon_url || ""
                            monogram: modelData.name
                            heading: modelData.name
                            detail: modelData.url.replace(/^https?:\/\//, "")
                            trailing: "󰐕"
                            Accessible.name: "Add " + modelData.name
                            enabled: backend.unlocked && !backend.busy
                            onClicked: backend.request("add_mint", {url: modelData.url})
                        }
                    }
                    Label { visible: backend.busy && backend.pendingMethod === "add_mint"; text: "Adding mint…"; opacity: 0.6; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                    Button { text: "󰐕  Add by URL"; focusable: true; opacity: enabled ? 0.8 : 0.35; enabled: !backend.busy; Layout.alignment: Qt.AlignHCenter; onClicked: app.addMintByUrl() }
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
                    spacing: Style.space(16)
                    Label { text: "Backup Wallet"; font.bold: true; font.pixelSize: Style.font.heading; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { visible: !recoveryPage.revealed; text: "󰌆"; font.pixelSize: Style.space(44); opacity: 0.8; Layout.fillWidth: true; Layout.topMargin: Style.space(12); horizontalAlignment: Text.AlignHCenter }
                    Label { visible: !recoveryPage.revealed; text: "Your recovery phrase is the only way to restore your wallet. Keep it private and stored somewhere safe. Never share it with anyone."; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    Label { visible: !recoveryPage.revealed; text: "Anyone who sees these words can take your funds. Reveal them only when nobody is watching your screen, and write them down on paper rather than in a photo or a message."; opacity: 0.65; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
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
                    Action {
                        visible: recoveryPage.revealed
                        text: "Copy Recovery Phrase"
                        enabled: !clipboard.running
                        onClicked: app.copyText(backend.recoveryPhrase, "recovery phrase")
                    }
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
                    RowLayout {
                        visible: app.lightning.enabled === true && !!app.lightning.address
                        Layout.fillWidth: true
                        Layout.leftMargin: Style.space(12)
                        spacing: Style.space(12)
                        Label {
                            text: app.lightning.status === "error" ? "󰅙" : app.lightning.status === "connected" ? "󰄬" : "󰔟"
                            color: app.lightning.status === "error" ? app.destructive : app.lightning.status === "connected" ? app.received : Color.foreground
                            font.pixelSize: Style.font.heading
                            Layout.preferredWidth: Style.space(28)
                            horizontalAlignment: Text.AlignHCenter
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            spacing: Style.space(4)
                            Label { text: app.lightning.address || ""; font.bold: true; Layout.fillWidth: true; elide: Text.ElideMiddle; wrapMode: Text.NoWrap }
                            Label { text: app.lightning.status === "error" ? "Needs attention" : app.lightning.status === "connected" ? "Connected" : "Connecting"; opacity: 0.6; font.pixelSize: Style.font.caption }
                        }
                        SquareIcon { iconText: "󰆏"; Accessible.name: "Copy address"; onClicked: app.copyText(app.lightning.address, "Lightning address") }
                        SquareIcon { iconText: "󰐲"; Accessible.name: "Show QR code"; enabled: !backend.busy; onClicked: app.showQr("Lightning Address", app.lightning.address) }
                    }
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
                        statusColor: app.destructive
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
                    Action { visible: revealPage.revealed; text: "Copy Private Key"; enabled: !clipboard.running; onClicked: app.copyText(backend.revealedKey, "private key") }
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
                    // Copy alone; the back arrow is the way out, as on every explainer.
                    Action { text: "Copy"; enabled: !clipboard.running; onClicked: app.copyText(backend.qrView.qr_text || "", app.qrTitle.toLowerCase()) }
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
        // ---- Every screen before the wallet, after cashubtc/wallet's
        // onboarding: a live stage above a pinned action chassis, one frame
        // for Welcome, the seed phrase, the first mint, unlock and restore.
        // The chassis never moves between steps; only its labels change.
        // The ASCII terrain runs behind Welcome and morphs into a vault door
        // behind the restore words; every other step is open space.
        Item {
            id: onboarding
            // A phone-sized frame: in a tall window the chassis pins at
            // most this far down, like the wallet's own pinned pages,
            // rather than sinking to the bottom of a void.
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            // The same phone-width column as the wallet pages, so a
            // maximised window keeps the frame narrow rather than stretching
            // the chassis across the screen. Height caps at 1000 to match
            // the window's own proportions.
            width: Math.min(parent.width, Style.space(460))
            height: Math.min(parent.height, Style.space(1000))
            visible: app.preWallet
            readonly property real gutter: Style.space(app.compact ? 18 : 26)
            readonly property string step: {
                if (app.conceptOpen) return "concept"
                if (app.walletVisible) return "restore_" + app.restoreStep
                if (!backend.ready) return "starting"
                if (app.restoreMode) return "restore_" + app.restoreStep
                if (app.onboardingOpen) return app.onboardingStep
                if (backend.state.exists) return "unlock"
                return "welcome"
            }
            readonly property bool showsField: step === "welcome" || step === "restore_seed"
            readonly property bool canGoBack: ["seed", "mint", "concept", "restore_seed", "restore_mints"].indexOf(step) >= 0 && !(step === "mint" && app.firstMintQueue.length > 0)
            readonly property bool passwordRequired: backend.state.password_required !== false
            // First launch: the title settles, then the field fades in over
            // 0.9 s. Afterwards it fades with the step swap.
            property bool fieldEntered: false
            property int fieldFade: 900
            // Read from `step` itself: a derived property can still hold its
            // old value while this handler runs.
            onStepChanged: {
                if ((step === "welcome" || step === "restore_seed") && !fieldEntered) entrance.start()
                stageScroll.contentItem.contentY = 0
            }
            Component.onCompleted: if (step === "welcome" || step === "restore_seed") entrance.start()
            Timer { id: entrance; interval: motion.reduced ? 0 : 450; onTriggered: { onboarding.fieldEntered = true; settle.start() } }
            Timer { id: settle; interval: 950; onTriggered: onboarding.fieldFade = 280 }
            // The field's geometry: clear behind the tallest header of the
            // pair, then opaque, then a fade to a faint floor behind the
            // chassis. The vault sits in the space below the restore card.
            readonly property real headerClearance: band.y + band.height + Style.space(8) + welcomeHeader.implicitHeight
            readonly property real chassisInset: height - chassis.y
            readonly property var fieldLayout: Field.resolve(height, headerClearance, chassisInset, stageScroll.y + restoreSeedStage.contentHeight + Style.space(8))
            // Unset comes back null, not "", and Number(null) is 0: a frozen field.
            readonly property real staticTime: { var value = Quickshell.env("CASHU_ME_ASCII_STATIC_TIME"); return value ? Number(value) : NaN }
            readonly property bool fieldShown: showsField && fieldEntered && !fieldLayout.suppressed

            AsciiField {
                id: field
                anchors.fill: parent
                active: onboarding.showsField && onboarding.visible && app.presented && !onboarding.fieldLayout.suppressed && !app.conceptOpen
                reducedMotion: motion.reduced
                staticTime: onboarding.staticTime
                ink: Color.foreground
                dark: Color.background.hslLightness < 0.5
                fontFamily: Style.font.family
                mask: onboarding.fieldLayout
                vaultCenterY: onboarding.fieldLayout.vaultCenterY
                // Welcome's terrain deforms into the restore step's vault
                // door on the step swap, and back.
                vaultMix: onboarding.step === "restore_seed" ? 1 : 0
                Behavior on vaultMix { enabled: !motion.reduced && isNaN(onboarding.staticTime); NumberAnimation { duration: 280; easing.type: Easing.InOutQuad } }
                lensEnabled: !motion.reduced
                opacity: onboarding.fieldShown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: motion.reduced ? Motion.gentle : onboarding.fieldFade; easing.type: Easing.OutCubic } }
            }

            // The bar band: Back on the left where a step has one, the help
            // and expand controls on the right. Back keeps its slot and only
            // fades, so nothing shifts between steps.
            RowLayout {
                id: band
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: onboarding.gutter
                spacing: Style.space(6)
                IconButton {
                    iconText: "󰁍"
                    Accessible.name: "Back"
                    Accessible.ignored: !onboarding.canGoBack
                    enabled: onboarding.canGoBack && !backend.busy
                    opacity: onboarding.canGoBack ? (enabled ? 1 : 0.4) : 0
                    onClicked: app.back()
                }
                Item { Layout.fillWidth: true }
                IconButton {
                    visible: onboarding.step === "welcome" || onboarding.step === "starting"
                    iconText: "󰘥"
                    Accessible.name: "What is ecash?"
                    enabled: onboarding.step === "welcome"
                    onClicked: app.conceptOpen = true
                }
                IconButton {
                    iconText: app.compact ? "󰁜" : "󰁃"
                    Accessible.name: app.compact ? "Expand to window" : "Return to panel"
                    onClicked: app.present(app.compact)
                }
            }

            Controls.ScrollView {
                id: stageScroll
                anchors.top: band.bottom
                anchors.topMargin: Style.space(8)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: chassis.top
                anchors.leftMargin: onboarding.gutter
                anchors.rightMargin: onboarding.gutter
                anchors.bottomMargin: Style.space(12)
                contentWidth: availableWidth
                clip: true
                Item {
                    id: stack
                    width: stageScroll.availableWidth
                    readonly property real currentHeight: {
                        switch (onboarding.step) {
                        case "welcome": return welcomeStage.contentHeight
                        case "starting": return startingStage.contentHeight
                        case "seed": return seedStage.contentHeight
                        case "mint": return mintStage.contentHeight
                        case "concept": return conceptStage.contentHeight
                        case "unlock": return unlockStage.contentHeight
                        case "restore_seed": return restoreSeedStage.contentHeight
                        case "restore_mints": return restoreMintsStage.contentHeight
                        case "restore_progress": return restoreProgressStage.contentHeight
                        default: return 0
                        }
                    }
                    height: Math.max(stageScroll.availableHeight, currentHeight)

                    Stage {
                        id: startingStage
                        current: onboarding.step === "starting"
                        StepHeader { risen: startingStage.current; shown: startingStage.visible; title: "Starting cashu.me…" }
                    }
                    Stage {
                        id: welcomeStage
                        current: onboarding.step === "welcome"
                        StepHeader { id: welcomeHeader; risen: welcomeStage.current; shown: welcomeStage.visible; title: "Private cash.\nOn your desktop."; subhead: "An ecash wallet for Bitcoin and Lightning." }
                        Label { visible: !desktopLock.safeToUnlock; text: "Waiting for an unlocked Omarchy desktop."; opacity: 0.65; Layout.fillWidth: true }
                    }
                    // What is ecash?, the reference's concept sheet, as a step.
                    Stage {
                        id: conceptStage
                        current: onboarding.step === "concept"
                        StepHeader { risen: conceptStage.current; shown: conceptStage.visible; title: "Ecash is bearer cash for Bitcoin." }
                        Label { text: "Whoever holds it, owns it. Your balance stays on this device, hidden from everyone else."; opacity: 0.75; lineHeight: 1.3; Layout.fillWidth: true }
                        Label { text: "Mints hold the Bitcoin behind your ecash. You can use several at once."; opacity: 0.75; lineHeight: 1.3; Layout.fillWidth: true }
                        Label { text: "Send instantly. Cash out to Lightning anytime."; opacity: 0.75; lineHeight: 1.3; Layout.fillWidth: true }
                    }
                    // The seed phrase: a card that reveals on tap and hides on
                    // the next, the words in a numbered three-column grid.
                    // While hidden the words are never on screen at all; the
                    // worker only sends them when the card is opened.
                    Stage {
                        id: seedStage
                        current: onboarding.step === "seed"
                        StepHeader { risen: seedStage.current; shown: seedStage.visible; title: "Your seed phrase."; subhead: "Write these 12 words down in order. This is the only way to recover your wallet." }
                        Button {
                            id: seedCard
                            readonly property bool revealed: backend.recoveryPhrase !== ""
                            readonly property var words: revealed ? backend.recoveryPhrase.split(" ") : []
                            text: ""
                            focusable: true
                            background: Qt.alpha(Color.foreground, 0.07)
                            Layout.fillWidth: true
                            Layout.topMargin: Style.space(8)
                            implicitHeight: seedGrid.implicitHeight + Style.space(40)
                            Accessible.name: revealed ? "Hide seed phrase" : "Reveal seed phrase"
                            onClicked: app.toggleSeedReveal()
                            // Keeps the words up while they are being copied
                            // down; the worker's own one-minute limit resumes
                            // once the card is closed or the step is left.
                            Timer { running: seedStage.current && seedCard.revealed; interval: 30000; repeat: true; onTriggered: backend.phraseTimer.restart() }
                            GridLayout {
                                id: seedGrid
                                anchors.fill: parent
                                anchors.margins: Style.space(20)
                                columns: 3
                                rowSpacing: Style.space(12)
                                columnSpacing: Style.space(12)
                                opacity: seedCard.revealed ? 1 : 0.18
                                Repeater {
                                    model: 12
                                    delegate: RowLayout {
                                        required property int index
                                        spacing: Style.space(6)
                                        Layout.fillWidth: true
                                        Label { text: (index + 1 < 10 ? "0" : "") + (index + 1); opacity: 0.45; font.pixelSize: Style.font.caption; Layout.preferredWidth: Style.space(18); horizontalAlignment: Text.AlignRight }
                                        Label { text: seedCard.revealed ? (seedCard.words[index] || "") : "••••••"; font.bold: seedCard.revealed; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                                    }
                                }
                            }
                            ColumnLayout {
                                visible: !seedCard.revealed
                                anchors.centerIn: parent
                                spacing: Style.space(4)
                                Label { text: "󰈈"; font.pixelSize: Style.font.iconLarge; opacity: 0.8; Layout.alignment: Qt.AlignHCenter }
                                Label { text: "Tap to reveal"; opacity: 0.7; font.pixelSize: Style.font.bodySmall; Layout.alignment: Qt.AlignHCenter }
                            }
                        }
                        Button { text: "󰆏  Copy"; focusable: true; opacity: enabled ? 0.8 : 0.35; enabled: seedCard.revealed && !clipboard.running; Layout.alignment: Qt.AlignHCenter; onClicked: app.copyText(backend.recoveryPhrase, "recovery phrase") }
                    }
                    // Pick your first mint: the suggested mints as rows that
                    // toggle, a URL of your own as a further row, and Skip.
                    Stage {
                        id: mintStage
                        current: onboarding.step === "mint"
                        StepHeader { risen: mintStage.current; shown: mintStage.visible; title: "Pick your first mint."; subhead: "Mints issue your ecash and redeem it for Bitcoin. Add more anytime in Settings." }
                        Repeater {
                            model: app.suggestions.concat(app.firstMintCustom.map(url => ({url: url, name: url.replace(/^https?:\/\//, ""), icon_url: ""})))
                            delegate: Entry {
                                required property var modelData
                                readonly property bool picked: app.firstMintSelection.indexOf(modelData.url) >= 0
                                avatar: modelData.icon_url || ""
                                monogram: modelData.name
                                heading: modelData.name
                                detail: modelData.url.replace(/^https?:\/\//, "")
                                trailing: picked ? "󰗠" : "󰄰"
                                Accessible.role: Accessible.CheckBox
                                Accessible.checked: picked
                                enabled: app.firstMintQueue.length === 0 && !backend.busy
                                onClicked: app.toggleFirstMint(modelData.url)
                            }
                        }
                        Button { visible: !app.firstMintInputOpen; text: "󰐕  Add by URL"; focusable: true; opacity: 0.8; enabled: app.firstMintQueue.length === 0; Layout.alignment: Qt.AlignHCenter; onClicked: { app.firstMintInputOpen = true; firstMintField.forceActiveFocus() } }
                        RowLayout {
                            visible: app.firstMintInputOpen
                            Layout.fillWidth: true
                            spacing: Style.space(8)
                            Ui.TextField { id: firstMintField; Layout.fillWidth: true; placeholderText: "mint.example.com"; text: app.firstMintInput; enabled: app.firstMintQueue.length === 0; onTextEdited: app.firstMintInput = text; onAccepted: app.commitFirstMint() }
                            SquareIcon { iconText: app.firstMintInput.trim() === "" ? "󰅍" : "󰁔"; Accessible.name: app.firstMintInput.trim() === "" ? "Paste from clipboard" : "Add mint"; Layout.preferredHeight: firstMintField.implicitHeight; enabled: app.firstMintQueue.length === 0; onClicked: app.firstMintInput.trim() === "" ? app.pasteInto("first_mint") : app.commitFirstMint() }
                        }
                        Label { visible: app.firstMintNotice !== ""; text: app.firstMintNotice; opacity: 0.75; Layout.fillWidth: true }
                        Label { visible: app.firstMintQueue.length > 0; text: "Connecting to " + (app.firstMintQueue[0] || "").replace(/^https?:\/\//, "") + "…"; opacity: 0.6; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                    }
                    Stage {
                        id: unlockStage
                        current: onboarding.step === "unlock"
                        StepHeader { risen: unlockStage.current; shown: unlockStage.visible; title: onboarding.passwordRequired ? "Unlock your wallet." : "Welcome back."; subhead: onboarding.passwordRequired ? "Enter your wallet password to open it." : "" }
                        Label { visible: !desktopLock.safeToUnlock; text: "Waiting for an unlocked Omarchy desktop."; opacity: 0.65; Layout.fillWidth: true }
                        // The way out when the password is gone. Funds live at
                        // the mints, so the wallet on this computer can be replaced.
                        Label { visible: onboarding.passwordRequired; text: "Forgot your password?"; font.bold: true; Layout.topMargin: Style.space(8) }
                        Footer { visible: onboarding.passwordRequired; text: "Your funds are safe. They live at your mints, not on this computer. Restore with your recovery phrase to set up this wallet again with a new password. Without the phrase, a fresh wallet starts from zero." }
                        Button { visible: onboarding.passwordRequired; text: "Start a fresh wallet"; focusable: true; opacity: enabled ? 0.8 : 0.35; enabled: backend.ready && !backend.busy; onClicked: freshDialog.opened = true }
                    }
                    // ---- Restore, in three steps after cashubtc/wallet: the
                    // words, the mints to recover from, then each mint's result.
                    // From onboarding it installs a new wallet; from Settings it
                    // replaces the current one after a confirmation. Desktop
                    // liberty: the words go into one field rather than twelve.
                    Stage {
                        id: restoreSeedStage
                        current: onboarding.step === "restore_seed"
                        // Word-by-word entry is keyboard-driven, so the field
                        // takes focus on arrival, the one step that does.
                        onCurrentChanged: if (current) Qt.callLater(() => seedField.forceActiveFocus())
                        StepHeader { risen: restoreSeedStage.current; shown: restoreSeedStage.visible; title: "Restore wallet."; subhead: "Enter your 12 words, one at a time." }
                        // The reference's word-by-word entry: a rail of twelve
                        // ticks that scrubs, one card holding the current word
                        // over up to two empty ghost cards, and a chip row that
                        // is the paste link while nothing is entered, then up
                        // to three completions while typing. Cards are opaque:
                        // the vault door runs behind this step.
                        RowLayout {
                            visible: !app.seedReviewing
                            Layout.fillWidth: true
                            Layout.topMargin: Style.space(24)
                            spacing: Style.space(16)
                            Item {
                                id: seedRail
                                readonly property int slot: 10
                                Layout.preferredWidth: Style.space(24)
                                Layout.preferredHeight: slot * 12
                                Layout.alignment: Qt.AlignTop
                                Accessible.role: Accessible.Slider
                                Accessible.name: "Seed word progress, word " + (app.seedIndex + 1) + " of 12"
                                Repeater {
                                    model: 12
                                    delegate: Rectangle {
                                        required property int index
                                        readonly property bool current: index === app.seedIndex
                                        readonly property bool settled: !current && app.seedWords[index] !== ""
                                        x: (seedRail.width - width) / 2
                                        y: index * seedRail.slot + (seedRail.slot - height) / 2
                                        width: 2
                                        height: current ? seedRail.slot : 3
                                        radius: 1
                                        color: app.seedComplete ? app.received : Color.foreground
                                        opacity: current ? 1 : settled ? 0.6 : 0.25
                                        Behavior on height { enabled: !motion.reduced; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                        Behavior on y { enabled: !motion.reduced; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                    }
                                }
                                // The rail scrubs: press and drag runs through the
                                // words live; a tap jumps.
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -Style.space(10)
                                    function slotAt(y) { return Math.max(0, Math.min(11, Math.floor((y - Style.space(10)) / seedRail.slot))) }
                                    onPressed: mouse => app.seedJump(slotAt(mouse.y))
                                    onPositionChanged: mouse => { if (pressed) app.seedJump(slotAt(mouse.y)) }
                                    onReleased: seedField.forceActiveFocus()
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(10)
                                Item {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Style.space(14)
                                    implicitHeight: seedEntryCard.implicitHeight
                                    Repeater {
                                        model: Math.min(2, 11 - app.seedIndex)
                                        delegate: Rectangle {
                                            required property int index
                                            width: parent.width
                                            height: seedEntryCard.implicitHeight
                                            y: -Style.space(7) * (index + 1)
                                            z: -1 - index
                                            scale: 1 - 0.04 * (index + 1)
                                            transformOrigin: Item.Top
                                            radius: Style.cornerRadius
                                            color: surface.color
                                            border.width: 1
                                            border.color: Qt.alpha(Color.foreground, index === 0 ? 0.22 : 0.12)
                                        }
                                    }
                                    Rectangle {
                                        id: seedEntryCard
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        implicitHeight: seedRow.implicitHeight + Style.space(24)
                                        radius: Style.cornerRadius
                                        color: Qt.tint(surface.color, Qt.alpha(Color.foreground, 0.07))
                                        border.width: 1
                                        border.color: app.seedRejected ? Color.urgent : Qt.alpha(Color.foreground, 0.25)
                                        RowLayout {
                                            id: seedRow
                                            anchors.fill: parent
                                            anchors.margins: Style.space(12)
                                            spacing: Style.space(12)
                                            Label { text: app.seedIndex + 1; opacity: 0.45; font.pixelSize: Style.font.title; Layout.preferredWidth: Style.space(24); horizontalAlignment: Text.AlignRight }
                                            Ui.TextField {
                                                id: seedField
                                                Layout.fillWidth: true
                                                placeholderText: "word " + (app.seedIndex + 1)
                                                font.pixelSize: Style.font.heading
                                                horizontalPadding: 0
                                                verticalPadding: Style.space(4)
                                                background: Item {}
                                                inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                                                Accessible.name: "Word " + (app.seedIndex + 1) + " of 12"
                                                onTextEdited: app.seedHandle(app.seedTyped(text))
                                                onAccepted: app.seedHandle(app.seedCommit())
                                                // Backspace on an empty field steps back a word.
                                                Keys.onPressed: event => { if (event.key === Qt.Key_Backspace && text === "" && app.seedStepBack()) event.accepted = true }
                                                Connections {
                                                    target: app
                                                    function onSeedIndexChanged() { seedField.text = app.seedDraft }
                                                    function onSeedWordsChanged() { if (seedField.text !== app.seedDraft) seedField.text = app.seedDraft }
                                                }
                                            }
                                        }
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: Style.space(34)
                                    spacing: Style.space(8)
                                    Button { visible: app.restoreWordCount === 0 && app.seedDraft === ""; text: "󰅍  Paste seed phrase"; bordered: true; focusable: true; background: surface.color; onClicked: app.pasteInto("words") }
                                    Repeater {
                                        model: app.seedDraft !== "" ? app.seedCompletions : []
                                        delegate: Button { required property string modelData; text: modelData; bordered: true; background: surface.color; onClicked: { app.seedSet(app.seedIndex, modelData); app.seedHandle(app.seedCommit()); seedField.forceActiveFocus() } }
                                    }
                                    Item { Layout.fillWidth: true }
                                }
                                Label {
                                    readonly property string message: app.seedNotice ? app.seedNotice.message : app.seedRejected ? "Not a seed word. Check the spelling." : (app.seedComplete && app.seedVerified ? "All 12 words verified." : "")
                                    visible: message !== ""
                                    text: message
                                    color: app.seedNotice && app.seedNotice.severity === "error" || app.seedRejected ? app.destructive : app.seedNotice ? app.warning : (app.seedComplete && app.seedVerified ? app.received : Color.foreground)
                                    opacity: 1
                                    font.pixelSize: Style.font.caption
                                    Layout.fillWidth: true
                                }
                            }
                        }
                        // A checksum failure names no single word, so the card
                        // gives way to all twelve, each tappable back into the field.
                        ColumnLayout {
                            visible: app.seedReviewing
                            Layout.fillWidth: true
                            Layout.topMargin: Style.space(8)
                            spacing: Style.space(12)
                            Label { text: app.seedNotice ? (app.seedNotice.title || "") : ""; visible: text !== ""; color: app.destructive; font.bold: true; Layout.fillWidth: true }
                            Label { text: app.seedNotice ? app.seedNotice.message : ""; visible: text !== ""; opacity: 0.75; Layout.fillWidth: true }
                            GridLayout {
                                Layout.fillWidth: true
                                columns: 3
                                rowSpacing: Style.space(8)
                                columnSpacing: Style.space(8)
                                Repeater {
                                    model: 12
                                    delegate: Button {
                                        required property int index
                                        text: (index + 1 < 10 ? "0" : "") + (index + 1) + "  " + (app.seedWords[index] || "…")
                                        bordered: true
                                        focusable: true
                                        leftAlign: true
                                        background: surface.color
                                        Layout.fillWidth: true
                                        Accessible.name: "Word " + (index + 1) + ", " + app.seedWords[index]
                                        onClicked: { app.seedJump(index); Qt.callLater(() => seedField.forceActiveFocus()) }
                                    }
                                }
                            }
                        }
                    }
                    Stage {
                        id: restoreMintsStage
                        current: onboarding.step === "restore_mints"
                        StepHeader { risen: restoreMintsStage.current; shown: restoreMintsStage.visible; title: "Add your mints."; subhead: "Your seed phrase doesn't record which mints you used. Add the mints you used before to recover funds from them." }
                        Ui.TextField { id: restoreMintField; Layout.fillWidth: true; Layout.topMargin: Style.space(8); placeholderText: "mint.example.com"; text: app.restoreMintInput; onTextEdited: app.restoreMintInput = text; onAccepted: app.stageRestoreMint(app.restoreMintInput) }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(12)
                            Tab { text: "󰐕  Add"; enabled: app.restoreMintInput.trim() !== ""; opacity: enabled ? 1 : 0.4; onClicked: app.stageRestoreMint(app.restoreMintInput) }
                            Tab { text: "󰅍  Paste"; Accessible.name: "Paste mint URLs from clipboard"; onClicked: app.pasteInto("mints") }
                        }
                        // The list is empty far more often than not, and the
                        // disabled primary never says why.
                        Label { visible: app.restoreMintList.length === 0; text: "Add the mints you used before, then restore."; opacity: 0.6; Layout.fillWidth: true; Layout.topMargin: Style.space(8); horizontalAlignment: Text.AlignHCenter }
                        Label { visible: app.restoreNotice !== ""; text: app.restoreNotice; opacity: 0.75; Layout.fillWidth: true }
                        Repeater {
                            model: onboarding.step === "restore_mints" ? app.restoreMintList : []
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
                    }
                    Stage {
                        id: restoreProgressStage
                        current: onboarding.step === "restore_progress"
                        StepHeader { risen: restoreProgressStage.current; shown: restoreProgressStage.visible; title: "Restoring wallet."; subhead: !restorePage.allSettled ? "Checking your mints…" : restorePage.recoveredTotal > 0 ? "Here's what we restored." : "No funds on these mints. If you used others, restore again from Settings with those." }
                        Label { visible: restorePage.recoveredTotal > 0; text: "󰄬  Recovered: " + app.amountLabel(restorePage.recoveredTotal); color: app.received; Layout.fillWidth: true }
                        Repeater {
                            model: onboarding.step === "restore_progress" ? app.restoreMintList : []
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
                    }
                }
            }
            QtObject {
                id: restorePage
                readonly property int mintCount: app.restoreMintList.length
                readonly property bool allSettled: app.restoreMintList.length > 0 && app.restoreMintList.every(mint => ["done", "failed"].indexOf((app.restoreResults[mint.url] || {}).status) >= 0)
                readonly property double recoveredTotal: app.restoreMintList.reduce((sum, mint) => sum + Number((app.restoreResults[mint.url] || {}).recovered || 0), 0)
            }

            // The chassis: an accessory that argues for the primary directly
            // above it (the seed acknowledgement, the password), the primary,
            // and one second row that is the secondary, the text link, or
            // reserved space, so the primary sits on the same line on every
            // step.
            ColumnLayout {
                id: chassis
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: onboarding.gutter
                anchors.rightMargin: onboarding.gutter
                anchors.bottomMargin: Style.space(app.compact ? 14 : 26)
                spacing: Style.space(12)
                readonly property string primaryText: {
                    switch (onboarding.step) {
                    case "welcome": return backend.busy && backend.pendingMethod === "create" ? "Creating your wallet…" : "Create Wallet"
                    case "seed": return "I've Saved My Seed Phrase"
                    case "mint": return app.firstMintQueue.length > 0 ? "Adding…" : "Continue"
                    case "concept": return "Got it"
                    case "unlock": return backend.busy ? "Opening…" : (onboarding.passwordRequired ? "Unlock" : "Open wallet")
                    case "restore_seed": return backend.busy && backend.pendingMethod === "validate_phrase" ? "Checking…" : "Continue"
                    case "restore_mints": return restorePage.mintCount === 0 ? "Restore" : "Restore from " + restorePage.mintCount + (restorePage.mintCount === 1 ? " mint" : " mints")
                    case "restore_progress": return "Continue"
                    default: return ""
                    }
                }
                readonly property bool primaryEnabled: {
                    if (backend.busy) return false
                    switch (onboarding.step) {
                    case "welcome": return backend.ready && desktopLock.safeToUnlock
                    case "seed": return app.seedAcknowledged
                    case "mint": return app.firstMintSelection.length > 0 || app.firstMintInput.trim() !== ""
                    case "concept": return true
                    case "unlock": return backend.ready && desktopLock.safeToUnlock && (!onboarding.passwordRequired || password.text.length > 0)
                    case "restore_seed": return backend.ready && app.seedComplete
                    case "restore_mints": return restorePage.mintCount > 0
                    case "restore_progress": return restorePage.allSettled
                    default: return false
                    }
                }
                function primary() {
                    switch (onboarding.step) {
                    case "welcome": if (app.onboardingOpen) app.onboardingStep = "seed"; else backend.request("create"); break
                    case "seed": app.onboardingStep = "mint"; break
                    case "mint": app.continueFirstMint(); break
                    case "concept": app.conceptOpen = false; break
                    case "unlock": backend.request("unlock", {password: password.text}); break
                    case "restore_seed": app.seedContinue(); break
                    case "restore_mints": app.beginRestore(); break
                    case "restore_progress": app.finishRestore(); break
                    }
                }
                readonly property string secondaryText: onboarding.step === "welcome" ? "Restore Wallet" : (onboarding.step === "unlock" && onboarding.passwordRequired ? "Restore with recovery phrase" : "")
                readonly property string tertiaryText: onboarding.step === "mint" ? "Skip for now" : ""
                function secondary() { app.startRestore(); app.restoreMode = true }

                Label { visible: backend.error !== ""; text: backend.error; color: Color.urgent; Layout.fillWidth: true }
                // The seed acknowledgement, with the warning it answers.
                ColumnLayout {
                    visible: onboarding.step === "seed"
                    Layout.fillWidth: true
                    spacing: Style.space(10)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(12)
                        Label { text: "󰀦"; color: app.warning; font.pixelSize: Style.font.heading; Layout.preferredWidth: Style.space(24); horizontalAlignment: Text.AlignHCenter }
                        Label { text: "Never share these words with anyone."; color: app.warning; Layout.fillWidth: true }
                    }
                    Button {
                        id: seedAcknowledge
                        text: ""
                        focusable: true
                        Layout.fillWidth: true
                        implicitHeight: ackRow.implicitHeight + Style.space(12)
                        Accessible.role: Accessible.CheckBox
                        Accessible.checked: app.seedAcknowledged
                        Accessible.name: "I've written down my seed phrase and stored it safely."
                        onClicked: app.seedAcknowledged = !app.seedAcknowledged
                        RowLayout {
                            id: ackRow
                            anchors.fill: parent
                            anchors.margins: Style.space(6)
                            spacing: Style.space(12)
                            Label { text: app.seedAcknowledged ? "󰗠" : "󰄰"; font.pixelSize: Style.font.heading; opacity: app.seedAcknowledged ? 1 : 0.6; Layout.preferredWidth: Style.space(24); horizontalAlignment: Text.AlignHCenter }
                            Label { text: "I've written down my seed phrase and stored it safely."; opacity: 0.75; Layout.fillWidth: true }
                        }
                    }
                }
                Ui.TextField {
                    id: password
                    visible: onboarding.step === "unlock" && onboarding.passwordRequired
                    password: true
                    placeholderText: "Wallet password"
                    Layout.fillWidth: true
                    onAccepted: if (chassisPrimary.enabled) chassisPrimary.clicked()
                }
                Action {
                    id: chassisPrimary
                    text: chassis.primaryText
                    visible: chassis.primaryText !== ""
                    enabled: chassis.primaryEnabled
                    Layout.minimumHeight: Style.space(42)
                    onClicked: if (enabled) chassis.primary()
                }
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(42)
                    Secondary {
                        id: chassisSecondary
                        anchors.fill: parent
                        visible: chassis.secondaryText !== ""
                        text: chassis.secondaryText
                        enabled: backend.ready && !backend.busy
                        onClicked: chassis.secondary()
                    }
                    Button {
                        id: chassisTertiary
                        anchors.fill: parent
                        visible: chassis.tertiaryText !== ""
                        text: chassis.tertiaryText
                        focusable: true
                        enabled: !backend.busy && app.firstMintQueue.length === 0
                        opacity: enabled ? 0.8 : 0.35
                        onClicked: app.finishOnboarding()
                    }
                }
            }
        }
        // ---- The handoff: the terrain sweeps down over the last onboarding
        // step, the wallet mounts beneath it at full cover, and the curtain
        // erodes level by level until the ₿ peaks are the last thing over
        // the balance. Nothing translates and no edge travels after the
        // sweep; the motion is the field's own.
        Item {
            id: handoff
            anchors.fill: parent
            visible: false
            z: 15
            property real sweep: 0
            property real erosion: 0
            function begin() {
                if (visible) return
                sweep = 0; erosion = 0; visible = true
                run.start()
            }
            // Runs the gate flip if it hasn't happened and drops the overlay
            // with no animation, so a lock mid-sweep never strands the user.
            function finishImmediately() {
                if (!visible) return
                run.stop()
                visible = false
                if (app.onboardingOpen || app.restoreMode) app.completeGate()
            }
            MouseArea { anchors.fill: parent }
            AsciiField {
                id: curtain
                anchors.fill: parent
                curtain: true
                active: handoff.visible && app.presented
                staticTime: onboarding.staticTime
                ink: Color.foreground
                dark: Color.background.hslLightness < 0.5
                fontFamily: Style.font.family
                scrim: surface.color
                sweep: handoff.sweep
                erosion: handoff.erosion
            }
            SequentialAnimation {
                id: run
                NumberAnimation { target: handoff; property: "sweep"; from: 0; to: 1; duration: 450; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.easeOut }
                ScriptAction { script: app.completeGate() }
                PauseAnimation { duration: 30 }
                ScriptAction { script: if (isNaN(onboarding.staticTime)) curtain.pressAt(handoff.width / 2, handoff.height / 2) }
                PauseAnimation { duration: 270 }
                ParallelAnimation {
                    // Linear on purpose: every stage of the exit carries its
                    // own smoothstep; easing the driver too would stall it.
                    NumberAnimation { target: handoff; property: "erosion"; from: 0; to: 1; duration: 1000 }
                    SequentialAnimation {
                        PauseAnimation { duration: 10 }
                        ScriptAction { script: curtain.releaseLens() }
                    }
                }
                ScriptAction { script: handoff.visible = false }
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
        Item {
            id: toastHost
            property string message: ""
            property bool shown: false
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: toastCard.width
            height: toastCard.height + Style.space(14)
            z: 20
            Rectangle {
                id: toastCard
                y: toastHost.shown ? Style.space(14) : -height
                opacity: toastHost.shown ? 1 : 0
                width: toastLabel.implicitWidth + Style.space(36)
                height: toastLabel.implicitHeight + Style.space(20)
                radius: Style.cornerRadius
                color: Color.popups.background
                border.width: 1
                border.color: Color.popups.border
                Behavior on y { enabled: !motion.reduced; NumberAnimation { duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.22, 1, 0.36, 1, 1, 1] } }
                Behavior on opacity { enabled: !motion.reduced; NumberAnimation { duration: 140 } }
                Label { id: toastLabel; anchors.centerIn: parent; text: toastHost.message; font.bold: true; color: Color.popups.text; wrapMode: Text.NoWrap }
                Accessible.role: Accessible.Notification
                Accessible.name: toastHost.message
            }
            Timer { id: toastTimer; interval: 2200; onTriggered: toastHost.shown = false }
        }
        Ui.ConfirmDialog {
            id: freshDialog
            anchors.fill: parent
            z: 10
            message: "Start a fresh wallet?\n\nThe wallet on this computer will be removed. Any ecash it holds can only be recovered with its recovery phrase. This cannot be undone."
            confirmText: "Start fresh"
            onCanceled: opened = false
            onConfirmed: { opened = false; backend.request("delete_wallet") }
        }
        Ui.ConfirmDialog {
            id: removeMintDialog
            anchors.fill: parent
            z: 10
            message: "Remove mint?\n\nRemove " + mintPage.displayName + " from your wallet? Any unspent ecash on this mint will need to be restored from your seed phrase."
            confirmText: "Remove"
            onCanceled: opened = false
            onConfirmed: { opened = false; backend.request("remove_mint", {url: app.mintView}) }
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
