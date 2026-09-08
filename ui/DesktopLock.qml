import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root
    property bool enabled: true
    property bool safeToUnlock: false
    signal locked()
    // This Omarchy version exposes lock state through its shell IPC.
    // Treat an unreachable shell as unknown/locked, never as unlocked.
    property Process probe: Process {
        command: ["quickshell", "ipc", "-p", (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell",
                  "call", "--", "lock", "isLocked"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.safeToUnlock = text.trim() === "false"
                if (!root.safeToUnlock) root.locked()
            }
        }
        onStarted: deadline.restart()
        onExited: (code, status) => {
            deadline.stop()
            if (code !== 0) { root.safeToUnlock = false; root.locked() }
        }
    }
    property Timer poll: Timer {
        interval: 1000
        repeat: true
        running: root.enabled
        triggeredOnStart: true
        onTriggered: if (!probe.running) probe.running = true
    }
    property Timer deadline: Timer {
        interval: 2000
        onTriggered: {
            root.safeToUnlock = false
            root.locked()
            probe.running = false
        }
    }
}
