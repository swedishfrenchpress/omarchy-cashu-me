import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root
    readonly property bool preview: Quickshell.env("CASHU_ME_PREVIEW") === "1"
    property var state: ({unlocked: false, exists: false, mints: [], selected: null})
    readonly property bool unlocked: state.unlocked === true
    property bool ready: false
    property bool busy: false
    property int nextId: 1
    property int pendingId: 0
    property string pendingMethod: ""
    property int restartAttempts: 0
    property string error: ""
    property bool restarting: false
    property string recoveryPhrase: ""
    property string notice: ""
    property var review: null
    property string reviewId: ""
    property var share: ({})
    property var completion: ({})
    signal paymentFinished()
    signal mintAdded()
    signal showResult()
    signal locked()
    // Emitted only once the worker has accepted a request, so callers can clear
    // the secret they submitted without discarding it on a recoverable failure.
    signal succeeded(string method)
    // The request the worker refused, once its error is set.
    signal failed(string method)
    // One mint's restore result, for the restore page's per-mint rows.
    signal restored(var result)
    // A QR the interface asked for (make_qr, or a key's own request).
    signal qrReady(var result)
    property var qrView: ({})
    // What a mint reports about itself, for the mint page.
    property var mintInfo: ({})
    // A private key shown on request. Cleared with the recovery phrase.
    property string revealedKey: ""

    function request(method, fields) {
        if (!ready || busy || preview) return
        if (review && method !== "confirm_payment" && method !== "cancel_payment") return
        var message = Object.assign({id: nextId++, method: method}, fields || {})
        error = ""
        notice = ""
        busy = true
        pendingId = message.id
        pendingMethod = method
        worker.write(JSON.stringify(message) + "\n")
    }
    function lock() {
        if (preview) return
        state = {unlocked: false, exists: state.exists, password_required: state.password_required, mints: [], selected: null}
        busy = false
        pendingId = 0
        pendingMethod = ""
        ready = false
        error = ""
        recoveryPhrase = ""
        revealedKey = ""
        qrView = {}
        mintInfo = {}
        notice = ""
        review = null
        reviewId = ""
        share = {}
        completion = {}
        locked()
        restarting = true
        // Clear the interface at once, but ask the worker to stop rather than
        // signalling it: a kill during confirm would abandon a payment in
        // flight. The worker finishes its current mint call, releases any
        // reservation it holds, and exits.
        if (worker.running) {
            worker.write(JSON.stringify({id: nextId++, method: "lock"}) + "\n")
            lockTimer.restart()
        } else {
            restarting = false
        }
    }
    function consume(raw) {
        if (restarting) return
        try {
            var message = JSON.parse(raw)
            var finished = ""
            if (message.event === "state") {
                state = message.state
                ready = true
                restartAttempts = 0
                if (share.invoice && share.mint) {
                    var issued = (state.issued_invoices || []).find(quote => quote.id === share.quote_id && quote.mint === share.mint)
                    if (issued) {
                        completion = {received: true, amount: issued.amount}
                        share = {}
                        paymentFinished()
                    }
                }
            }
            // Resolve only the outstanding request. The worker also emits
            // {"id":null} for input it could not parse, which is a reply to
            // nothing and must never release a live request.
            var refused = ""
            if (message.id !== undefined && message.id !== null && message.id === pendingId) {
                busy = false
                finished = message.error ? "" : pendingMethod
                refused = message.error ? pendingMethod : ""
                pendingId = 0
                pendingMethod = ""
            }
            if (message.review_done) { review = null; reviewId = "" }
            if (message.error) error = message.error
            if (message.result && message.result.review) {
                review = message.result.review
                reviewId = message.result.review_id
            }
            if (message.result && (message.result.token || message.result.invoice)) {
                share = message.result
                showResult()
            }
            if (message.result && (message.result.paid || message.result.received || message.result.reclaimed)) {
                completion = message.result
                paymentFinished()
            }
            if (message.result && message.result.paid) notice = "Lightning payment completed."
            if (message.result && message.result.received) notice = "Received " + message.result.amount + " sats."
            if (message.result && message.result.reclaimed) notice = "Reclaimed " + message.result.amount + " sats."
            if (message.result && message.result.cancelled) notice = "Payment cancelled"
            if (message.result && message.result.phrase) {
                recoveryPhrase = message.result.phrase
                phraseTimer.restart()
            }
            if (message.result && message.result.nsec) {
                revealedKey = message.result.nsec
                phraseTimer.restart()
            }
            if (message.result && message.result.recovered !== undefined) restored(message.result)
            if (message.result && message.result.qr_text) { qrView = message.result; qrReady(message.result) }
            if (message.result && message.result.mint_info) mintInfo = message.result.mint_info
            // A delete with a session open ends the worker; come back locked
            // and wallet-less rather than treating the exit as a crash.
            if (message.result && message.result.worker_exits) { restarting = true; lockTimer.restart() }
            if (message.result && message.result.mint_added) { notice = "Mint added"; mintAdded() }
            if (message.event === "fatal") ready = false
            if (finished !== "") succeeded(finished)
            if (refused !== "") failed(refused)
        } catch (_) {
            lock()
            error = "Invalid response from the wallet worker."
        }
    }
    property Process worker: Process {
        command: [Quickshell.env("CASHU_ME_BACKEND")]
        running: !root.preview && Quickshell.env("CASHU_ME_BACKEND") !== ""
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.consume(data) }
        // Never forward worker output to QML console logs.
        stderr: SplitParser { onRead: data => {} }
        onExited: {
            root.lockTimer.stop()
            root.state = {unlocked: false, exists: root.state.exists, password_required: root.state.password_required, mints: [], selected: null}
            root.ready = false
            root.recoveryPhrase = ""
            root.revealedKey = ""
            root.qrView = {}
            root.mintInfo = {}
            root.review = null
            root.reviewId = ""
            root.share = {}
            root.completion = {}
            root.busy = false
            root.pendingId = 0
            root.pendingMethod = ""
            root.locked()
            if (root.restarting) restartTimer.start()
            else if (root.restartAttempts < 3) {
                // An unexpected stop used to leave the interface permanently
                // inert. Come back locked instead; the user reopens the wallet.
                root.restartAttempts++
                root.restarting = true
                root.error = "The wallet worker stopped unexpectedly and was restarted. Open your wallet again."
                restartTimer.start()
            }
            else if (!root.error) root.error = "Wallet worker stopped repeatedly. Reopen cashu.me to retry."
        }
    }
    property Timer restartTimer: Timer {
        interval: 50
        onTriggered: { root.restarting = false; root.worker.running = true }
    }
    property Timer lockTimer: Timer {
        // Longer than the worker's own 90 s confirm bound, so a payment already
        // in flight records its outcome before the worker is forced down.
        interval: 120000
        onTriggered: if (root.worker.running) root.worker.running = false
    }
    property Timer phraseTimer: Timer {
        interval: 60000
        onTriggered: { root.recoveryPhrase = ""; root.revealedKey = "" }
    }
}
