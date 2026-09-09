import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
    id: root
    moduleName: "chaumarchy.wallet"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "󰖄"
        tooltipText: "Chaumarchy · Cashu wallet"
        onPressed: buttonCode => {
            if (launch.running) return
            if (root.bar && root.bar.activePopout) root.bar.activePopout.close()
            // One null check for both uses: dereferencing contentItem after
            // guarding screen.name aborted the handler and the button did
            // nothing at all.
            var host = root.QsWindow.window
            var output = host ? host.screen.name : ""
            var originX = host ? Math.round(button.mapToItem(host.contentItem, button.width / 2, 0).x) : -1
            launch.command = [Quickshell.env("HOME") + "/.local/bin/chaumarchy",
                              buttonCode === Qt.RightButton ? "--window" : "--toggle", output, String(originX)]
            launch.running = true
        }
    }
    // This plugin only opens the wallet. Keys and payments stay in its own process.
    Process { id: launch }
}
