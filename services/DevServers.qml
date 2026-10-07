pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Listening TCP ports, split into the user's dev servers and other (system/root) services.
 * Polls `ss` every few seconds; cheap enough to run all the time.
 */
Singleton {
    id: root

    // [{ port, name, pid, project, hint }]
    property list<var> servers: []
    // [{ port, name }]: listeners we can't see the owner of (root/other users, e.g. postgres, docker-proxy)
    property list<var> services: []

    readonly property list<string> devProcesses: ["node", "bun", "deno", "php", "php-fpm", "python", "python3",
        "uvicorn", "gunicorn", "go", "java", "ruby", "rails", "dotnet", "cargo", "hugo", "air", "beam.smp"]
    // GUI apps that open random local ports
    readonly property list<string> ignoredProcesses: ["code", "brave", "Discord", "discord", "spotify", "Telegram",
        "obsidian", "kdeconnectd", "localsend", "zoom", "Postman", "postman"]
    readonly property var knownServices: ({ 3306: "mysql", 5432: "postgres", 6379: "redis", 27017: "mongodb" })
    readonly property string devRoot: `${Quickshell.env("HOME")}/Documents/dev/`

    function kill(pid) {
        Quickshell.execDetached(["kill", String(pid)]);
        refreshDelay.restart();
    }
    function open(port) {
        Qt.openUrlExternally(`http://localhost:${port}`);
    }

    // First real argument after the interpreter, e.g. "vite" for node .../.bin/vite, "artisan" for php artisan
    function hintFor(args) {
        const arg = args.slice(1).find(a => a && !a.startsWith("-") && !a.includes(":"));
        return arg ? arg.split("/").pop() : "";
    }
    function projectFor(cwd) {
        if (cwd.startsWith(devRoot)) return cwd.slice(devRoot.length);
        return cwd.replace(Quickshell.env("HOME"), "~");
    }

    function parse(text) {
        const seen = new Set();
        const servers = [];
        const services = [];
        for (const line of text.split("\n")) {
            if (!line) continue;
            const [portText, name, pid, cwd, argsText] = line.split("\t");
            const port = parseInt(portText);
            if (!port || seen.has(port)) continue; // IPv4 and IPv6 sockets share a port
            seen.add(port);
            if (!pid) {
                if (port < 10000) services.push({ port, name: knownServices[port] ?? "" });
                continue;
            }
            if (ignoredProcesses.includes(name)) continue;
            if (port >= 10000 && !devProcesses.includes(name)) continue;
            servers.push({ port, name, pid: parseInt(pid), project: projectFor(cwd ?? ""),
                hint: hintFor((argsText ?? "").split(" ")) });
        }
        root.servers = servers.sort((a, b) => a.port - b.port);
        root.services = services.sort((a, b) => a.port - b.port);
    }

    Process {
        id: proc
        command: ["bash", "-c", `
            ss -Hltnp | awk '{ print $4, $6 }' | while read -r local owner; do
                pid=$(sed -nE 's/^users:\\(\\("[^"]+",pid=([0-9]+).*/\\1/p' <<< "$owner")
                name=$(sed -nE 's/^users:\\(\\("([^"]+)".*/\\1/p' <<< "$owner")
                cwd= args=
                if [ -n "$pid" ]; then
                    cwd=$(readlink "/proc/$pid/cwd")
                    args=$(tr '\\0' ' ' < "/proc/$pid/cmdline")
                fi
                printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "\${local##*:}" "$name" "$pid" "$cwd" "$args"
            done`]
        stdout: StdioCollector {
            onStreamFinished: root.parse(text)
        }
    }

    Timer {
        interval: 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: proc.running = true
    }
    Timer { // pick up a killed server without waiting for the next poll
        id: refreshDelay
        interval: 500
        onTriggered: proc.running = true
    }
}
