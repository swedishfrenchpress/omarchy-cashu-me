import QtQuick
import Quickshell

// Reduced motion is no longer a wallet setting, matching the reference
// wallet, which defers to the system. Omarchy has no such system switch, so
// the environment variable is the one remaining way to ask for it.
QtObject {
    readonly property bool reduced: Quickshell.env("CASHU_ME_REDUCED_MOTION") === "1"
}
