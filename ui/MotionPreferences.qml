import QtQuick
import QtCore
import Quickshell

QtObject {
    property alias reducedMotion: preferences.reducedMotion
    readonly property bool reduced: reducedMotion || Quickshell.env("CHAUMARCHY_REDUCED_MOTION") === "1"
    property Settings preferences: Settings {
        id: preferences
        location: "file://" + (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/chaumarchy/appearance.ini"
        category: "Motion"
        property bool reducedMotion: false
    }
}
