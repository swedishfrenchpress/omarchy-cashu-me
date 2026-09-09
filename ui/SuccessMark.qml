import QtQuick
import qs.Commons
import "Motion.js" as Motion

Text {
    id: root
    property bool reducedMotion: false
    property bool presented: true
    property string receipt: ""
    property string shownReceipt: ""
    property real reveal: 1
    function acknowledge() {
        if (!visible || !presented || !receipt || receipt === "{}" || receipt === shownReceipt) return
        shownReceipt = receipt
        reveal = 0
        settle.restart()
    }
    onVisibleChanged: acknowledge()
    onPresentedChanged: acknowledge()
    onReceiptChanged: { if (receipt === "{}") shownReceipt = ""; acknowledge() }
    text: "✓"
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.space(42)
    horizontalAlignment: Text.AlignHCenter
    opacity: reveal
    scale: reducedMotion ? 1 : 0.95 + 0.05 * reveal
    NumberAnimation {
        id: settle
        target: root
        property: "reveal"
        to: 1
        duration: root.reducedMotion ? Motion.gentle : Motion.reveal
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Motion.easeOut
    }
}
