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
            var output = root.QsWindow.window ? root.QsWindow.window.screen.name : ""
            launch.command = [Quickshell.env("HOME") + "/.local/bin/chaumarchy",
                              buttonCode === Qt.RightButton ? "--window" : "--toggle", output]
            launch.running = true
        }
    }
    // This plugin only opens the wallet. Keys and payments stay in its own process.
    Process { id: launch }
}
