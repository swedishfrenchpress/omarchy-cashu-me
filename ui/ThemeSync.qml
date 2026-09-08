import QtQuick
import Quickshell.Io
import qs.Commons

// Watch the parent because Omarchy replaces the theme directory atomically.
// Font and user-shell overrides already have watchers in Commons.Style/Color.
QtObject {
    id: root
    property Timer debounce: Timer {
        interval: 180
        onTriggered: {
            Color.colorsFile.reload()
            Color.shellFile.reload()
            Style.scheduleRefresh()
        }
    }
    property Process watcher: Process {
        command: ["inotifywait", "--monitor", "--quiet", "--event",
                  "create,delete,moved_to,moved_from,close_write", Color.stateHome + "/omarchy/current"]
        running: true
        stdout: SplitParser { onRead: data => root.debounce.restart() }
        // Do not spin if the theme directory is absent or a watch fails.
        onExited: root.retry.restart()
    }
    property Timer retry: Timer {
        interval: 5000
        onTriggered: root.watcher.running = true
    }
}
