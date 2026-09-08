import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root
    readonly property bool preview: Quickshell.env("CHAUMARCHY_PREVIEW") === "1"
    property var state: ({unlocked: false, exists: false, mints: [], selected: null})
    readonly property bool unlocked: state.unlocked === true
    property bool ready: false
    property bool busy: false
    property int nextId: 1
    property string error: ""
    property bool restarting: false
    property string recoveryPhrase: ""
    property string notice: ""
    property var review: null
    property string reviewId: ""
    property var share: ({})
    signal showResult()
    signal locked()

    function request(method, fields) {
        if (!ready || busy || preview) return
        if (review && method !== "confirm_payment" && method !== "cancel_payment") return
        var message = Object.assign({id: nextId++, method: method}, fields || {})
        error = ""
        notice = ""
        busy = true
        worker.write(JSON.stringify(message) + "\n")
    }
    function lock() {
        if (preview) return
        state = {unlocked: false, exists: state.exists, mints: [], selected: null}
        busy = false
        ready = false
        error = ""
        recoveryPhrase = ""
        notice = ""
        review = null
        reviewId = ""
        share = {}
        locked()
        restarting = true
        worker.running = false
    }
    function consume(raw) {
        if (restarting) return
        try {
            var message = JSON.parse(raw)
            if (message.event === "state") {
                state = message.state
                ready = true
            }
            if (message.id !== undefined) busy = false
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
            if (message.result && message.result.paid) notice = "Lightning payment completed."
            if (message.result && message.result.received) notice = "Received " + message.result.amount + " sats."
            if (message.result && message.result.reclaimed) notice = "Reclaimed " + message.result.amount + " sats."
            if (message.result && message.result.cancelled) notice = "Payment cancelled."
            if (message.result && message.result.phrase) {
                recoveryPhrase = message.result.phrase
                phraseTimer.restart()
            }
            if (message.result && message.result.backup_saved) notice = "Encrypted backup saved."
            if (message.event === "fatal") ready = false
        } catch (_) {
            error = "Invalid response from the wallet worker."
            lock()
        }
    }
    property Process worker: Process {
        command: [Quickshell.env("CHAUMARCHY_BACKEND")]
        running: !root.preview && Quickshell.env("CHAUMARCHY_BACKEND") !== ""
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.consume(data) }
        // Never forward worker output to QML console logs.
        stderr: SplitParser { onRead: data => {} }
        onExited: {
            root.state = {unlocked: false, exists: root.state.exists, mints: [], selected: null}
            root.ready = false
            root.recoveryPhrase = ""
            root.review = null
            root.reviewId = ""
            root.share = {}
            root.busy = false
            root.locked()
            if (root.restarting) restartTimer.start()
            else if (!root.error) root.error = "Wallet worker stopped. Reopen Chaumarchy to retry."
        }
    }
    property Timer restartTimer: Timer {
        interval: 50
        onTriggered: { root.restarting = false; root.worker.running = true }
    }
    property Timer phraseTimer: Timer {
        interval: 60000
        onTriggered: root.recoveryPhrase = ""
    }
}
