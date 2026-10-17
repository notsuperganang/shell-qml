pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Pinned clipboard snippets (name, NIK, links, ...) that never expire, unlike cliphist history.
 * Stored as [{label, text}] in a private file (mode 600) outside any git repo; editing it by hand
 * (e.g. to set labels) is picked up live. Only shown in the clipboard view while searching.
 */
Singleton {
    id: root
    readonly property string filePath: Directories.clipboardPinsPath
    property list<var> pins: []

    function isPinned(text) {
        return pins.some(p => p.text === text);
    }

    // Pin a cliphist entry ("<id>\t<preview>"): the preview is truncated, so decode the full text first
    function pinCliphistEntry(entry) {
        decodeProc.entry = entry;
        decodeProc.running = true;
    }

    function add(text) {
        text = text.replace(/\n+$/, "");
        if (!text.trim() || isPinned(text)) return;
        const label = text.split("\n")[0].slice(0, 60);
        root.pins = [...root.pins, { "label": label, "text": text }];
        save();
    }

    function remove(text) {
        root.pins = root.pins.filter(p => p.text !== text);
        save();
    }

    function copy(text) {
        Quickshell.execDetached(["wl-copy", "--", text]);
    }

    function save() {
        pinsFile.setText(JSON.stringify(root.pins, null, 2));
    }

    function fuzzyQuery(search) {
        if (!search.trim()) return root.pins;
        const targets = root.pins.map(p => ({ "key": Fuzzy.prepare(`${p.label} ${p.text}`), "pin": p }));
        return Fuzzy.go(search, targets, { "key": "key" }).map(r => r.obj.pin);
    }

    Process {
        id: decodeProc
        property string entry: ""
        command: ["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(decodeProc.entry)}' | cliphist decode`]
        stdout: StdioCollector {
            onStreamFinished: root.add(text)
        }
    }

    FileView {
        id: pinsFile
        path: Qt.resolvedUrl(root.filePath)
        watchChanges: true
        onFileChanged: reload()
        onSaved: Quickshell.execDetached(["chmod", "600", root.filePath]) // NIK, address, ... stay private
        onLoaded: {
            try {
                const data = JSON.parse(pinsFile.text());
                root.pins = Array.isArray(data) ? data.filter(p => typeof p?.text === "string")
                    .map(p => ({ "label": p.label || p.text.split("\n")[0].slice(0, 60), "text": p.text })) : [];
            } catch (e) {
                console.log("[ClipboardPins] Can't parse", root.filePath, e);
            }
        }
        onLoadFailed: error => {
            if (error == FileViewError.FileNotFound) root.pins = [];
        }
    }
}
