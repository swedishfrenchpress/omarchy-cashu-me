import QtQuick
import qs.Commons

// An amount whose digits roll, after rareui's AnimatedCounter. Each digit is
// a wheel of faces 0…9,0 clipped to one line. When the value changes every
// wheel spins the short way in the direction the number moved, a place that
// appears fades in and rolls up from zero, and the columns that survive
// slide to make room. Leading and trailing marks (₿, $, " sats") stay put.
// Under reduced motion the faces snap.
Item {
    id: root
    property string text: ""
    property color color: Color.foreground
    // The page colour, for the fade at the top and bottom of each wheel.
    property color fade: Color.background
    property real fontSize: Style.font.body
    property bool reducedMotion: false
    property bool bold: false
    // Above zero, the font shrinks so the whole amount fits this width.
    property real maxWidth: 0

    readonly property real size: maxWidth > 0 && natural.advanceWidth > maxWidth ? fontSize * maxWidth / natural.advanceWidth : fontSize
    readonly property real line: Math.round(size * 1.3)
    readonly property int duration: 600
    property int dir: 1
    property string prefix: ""
    property string suffix: ""
    property bool settled: false
    property string previousDigits: ""

    implicitWidth: row.width
    implicitHeight: line
    Accessible.role: Accessible.StaticText
    Accessible.name: text

    TextMetrics { id: natural; font.family: Style.font.family; font.pixelSize: root.fontSize; font.bold: root.bold; text: root.text }
    TextMetrics { id: digitMetrics; font.family: Style.font.family; font.pixelSize: root.size; font.bold: root.bold; text: "0" }

    function mod(n, m) { return ((n % m) + m) % m }

    ListModel { id: cells }

    onTextChanged: apply()
    Component.onCompleted: { apply(); settled = true }

    function apply() {
        var head = text.match(/^[^0-9]*/)[0]
        var tail = text.match(/[^0-9]*$/)[0]
        var middle = text.slice(head.length, text.length - tail.length)
        var digits = middle.replace(/[^0-9]/g, "")
        // Compare as strings so amounts past 2^53 still order correctly.
        if (digits !== previousDigits) {
            var longer = Math.max(digits.length, previousDigits.length)
            dir = digits.padStart(longer, "0") >= previousDigits.padStart(longer, "0") ? 1 : -1
            previousDigits = digits
        }
        prefix = head
        suffix = tail
        var next = []
        for (var i = 0; i < middle.length; i++) {
            var char = middle.charAt(i)
            next.push({kind: char >= "0" && char <= "9" ? "digit" : "mark", face: char})
        }
        // Columns are matched from the right so a new place enters on the
        // left while the wheels already showing keep rolling in place.
        var keep = 0
        while (keep < next.length && keep < cells.count) {
            var incoming = next[next.length - 1 - keep]
            var existing = cells.get(cells.count - 1 - keep)
            if (incoming.kind !== existing.kind || (incoming.kind === "mark" && incoming.face !== existing.face)) break
            keep++
        }
        for (var k = 0; k < keep; k++) {
            var index = cells.count - 1 - k
            var cell = next[next.length - 1 - k]
            if (cells.get(index).face !== cell.face) cells.setProperty(index, "face", cell.face)
        }
        if (cells.count > keep) cells.remove(0, cells.count - keep)
        for (var j = next.length - keep - 1; j >= 0; j--) cells.insert(0, next[j])
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 0
        add: Transition {
            enabled: !root.reducedMotion
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: root.duration / 3 }
        }
        move: Transition {
            enabled: !root.reducedMotion
            NumberAnimation { property: "x"; duration: root.duration / 2; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.22, 1, 0.36, 1, 1, 1] }
        }
        Text {
            visible: root.prefix !== ""
            text: root.prefix
            color: root.color
            font.family: Style.font.family
            font.pixelSize: root.size
            font.bold: root.bold
            height: root.line
            verticalAlignment: Text.AlignVCenter
        }
        Repeater {
            model: cells
            delegate: Item {
                id: cell
                required property string kind
                required property string face
                readonly property int digit: kind === "digit" ? Number(face) : 0
                width: kind === "digit" ? digitMetrics.advanceWidth : mark.implicitWidth
                height: root.line
                Text {
                    id: mark
                    visible: cell.kind === "mark"
                    text: cell.face
                    color: root.color
                    font.family: Style.font.family
                    font.pixelSize: root.size
                    font.bold: root.bold
                    height: root.line
                    verticalAlignment: Text.AlignVCenter
                }
                Item {
                    id: wheel
                    visible: cell.kind === "digit"
                    anchors.fill: parent
                    clip: true
                    property real pos: 0
                    property real goal: 0
                    property bool live: false
                    Behavior on pos {
                        enabled: wheel.live && !root.reducedMotion
                        NumberAnimation { duration: root.duration; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.22, 1, 0.36, 1, 1, 1] }
                    }
                    function aim() {
                        if (root.reducedMotion) { goal = cell.digit; pos = cell.digit; return }
                        if (root.mod(goal, 10) !== cell.digit) {
                            // Aim from where the wheel is, so a fast typist
                            // never queues up a backlog of turns.
                            var at = pos
                            goal = root.dir < 0 ? at - root.mod(at - cell.digit, 10) : at + root.mod(cell.digit - at, 10)
                        }
                        pos = goal
                    }
                    Component.onCompleted: {
                        // A place that appears after first paint rolls up
                        // from zero; the initial render just shows its face.
                        var start = root.settled ? 0 : cell.digit
                        pos = start; goal = start
                        live = true
                        aim()
                    }
                    Connections { target: cell; function onDigitChanged() { wheel.aim() } }
                    Column {
                        y: -root.mod(wheel.pos, 10) * root.line
                        Repeater {
                            model: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
                            delegate: Text {
                                required property int modelData
                                text: modelData
                                color: root.color
                                font.family: Style.font.family
                                font.pixelSize: root.size
                                font.bold: root.bold
                                width: cell.width
                                height: root.line
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                    Rectangle {
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        height: root.line * 0.22
                        gradient: Gradient {
                            GradientStop { position: 0; color: root.fade }
                            GradientStop { position: 1; color: Qt.alpha(root.fade, 0) }
                        }
                    }
                    Rectangle {
                        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                        height: root.line * 0.22
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.alpha(root.fade, 0) }
                            GradientStop { position: 1; color: root.fade }
                        }
                    }
                }
            }
        }
        Text {
            visible: root.suffix !== ""
            text: root.suffix
            color: root.color
            font.family: Style.font.family
            font.pixelSize: root.size
            font.bold: root.bold
            height: root.line
            verticalAlignment: Text.AlignVCenter
        }
    }
}
