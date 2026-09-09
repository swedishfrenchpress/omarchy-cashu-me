import QtQuick
import qs.Ui as Ui
import "Motion.js" as Motion

// Keep Omarchy's actual input/focus/paint behavior. Observe presses passively;
// this handler never dispatches an action or takes the button's exclusive grab.
Ui.Button {
    id: root
    property bool reducedMotion: false
    readonly property bool pointerPressed: press.pressed
    scale: pointerPressed && enabled && !reducedMotion ? 0.98 : 1
    Behavior on scale {
        enabled: !root.reducedMotion
        NumberAnimation {
            duration: root.pointerPressed ? Motion.press : Motion.release
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Motion.easeOut
        }
    }
    TapHandler {
        id: press
        acceptedButtons: Qt.LeftButton
        gesturePolicy: TapHandler.DragThreshold
    }
}
