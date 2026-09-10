import QtQuick
import QtCore
import Quickshell

QtObject {
    property alias reducedMotion: preferences.reducedMotion
    readonly property bool reduced: reducedMotion || Quickshell.env("CASHU_ME_REDUCED_MOTION") === "1"
    property Settings preferences: Settings {
        id: preferences
        location: "file://" + (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/cashu-me/appearance.ini"
        category: "Motion"
        property bool reducedMotion: false
    }
}
