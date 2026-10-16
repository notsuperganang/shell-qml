import QtQuick
import qs.modules.common
import qs.services
import Quickshell
import Quickshell.Io

// Encrypted DNS (DoT via systemd-resolved) that gets past ISP DNS blocking.
// Backed by /usr/local/bin/dns-bypass; on/off run through a passwordless sudoers rule.
QuickToggleModel {
    id: root
    name: Translation.tr("Encrypted DNS")
    icon: "encrypted"
    tooltipText: Translation.tr("Bypass ISP DNS blocking (Cloudflare DNS-over-TLS)")
    available: false // until dns-bypass answers
    toggled: false

    mainAction: () => {
        const target = root.toggled ? "off" : "on";
        root.toggled = !root.toggled; // optimistic; statusProc corrects it
        setProc.command = ["sudo", "-n", "/usr/local/bin/dns-bypass", target];
        setProc.running = true;
    }

    Process {
        id: setProc
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                Quickshell.execDetached(["notify-send", Translation.tr("Encrypted DNS"),
                    Translation.tr("Couldn't switch it. Try <tt>sudo dns-bypass on</tt> in a terminal"), "-a", "Shell"]);
            statusProc.running = true;
        }
    }

    Process {
        id: statusProc
        running: true
        command: ["/usr/local/bin/dns-bypass", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const state = text.trim();
                root.available = state === "on" || state === "off";
                root.toggled = state === "on";
            }
        }
    }

    Timer { // also catch changes made from the terminal
        interval: 10000
        running: true
        repeat: true
        onTriggered: if (!setProc.running) statusProc.running = true
    }
}
