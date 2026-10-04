pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions

/**
 * Display profiles for Hyprland.
 *
 * Profiles live in ~/.config/hypr/displays/profiles.json (the GUI's source of truth).
 * Applying a profile regenerates ~/.config/hypr/monitors.lua and workspaces.lua, reloads
 * Hyprland, and waits for confirmation; without it the previous files are restored.
 */
Singleton {
    id: root

    // QS_DISPLAYS_HYPR_DIR points the service at a scratch copy of the hypr config (for testing).
    readonly property string hyprDir: Quickshell.env("QS_DISPLAYS_HYPR_DIR") || FileUtils.trimFileProtocol(`${Directories.config}/hypr`)
    readonly property string profilesPath: `${root.hyprDir}/displays/profiles.json`
    readonly property string monitorsPath: `${root.hyprDir}/monitors.lua`
    readonly property string workspacesPath: `${root.hyprDir}/workspaces.lua`

    readonly property int confirmSeconds: 15
    readonly property var scaleCandidates: [1, 1.2, 1.25, 1.333333, 1.5, 1.6, 1.666667, 1.75, 2, 2.4, 2.5, 3]
    readonly property var transformNames: ["Normal", "90°", "180°", "270°", "Flipped", "Flipped 90°", "Flipped 180°", "Flipped 270°"]

    // Monitors reported by `hyprctl monitors all -j`, normalised (see refreshDetected()).
    property var detected: []
    // Parsed profiles.json: { version, active, profiles: [...] }. null until loaded.
    property var data: null
    property bool profilesFileMissing: false

    // Apply/confirm state
    property bool pending: false
    property int countdown: 0
    property string pendingProfileName: ""
    property var pendingProfile: null
    property string backupMonitors: ""
    property string backupWorkspaces: ""

    signal applied()
    signal reverted()

    // ---------- monitor identity & helpers ----------

    function isInternal(name) {
        return /^(eDP|LVDS|DSI)-/.test(name);
    }

    // Stable id used in profiles and generated Lua: built-in panels by connector name
    // (the lid bind disables eDP-2 by name), everything else by description so it
    // follows the monitor to any port.
    function outputIdFor(mon) {
        return root.isInternal(mon.name) ? mon.name : `desc:${mon.description}`;
    }

    function outputMatches(output, mon) {
        if (!output || !mon) return false;
        if (output === mon.name) return true;
        if (output.startsWith("desc:"))
            return mon.description.startsWith(output.slice(5).trim());
        return false;
    }

    function detectedFor(output) {
        return root.detected.find(m => root.outputMatches(output, m)) ?? null;
    }

    function labelFor(output) {
        const d = root.detectedFor(output);
        if (d) return d.label;
        return output.startsWith("desc:") ? output.slice(5) : output;
    }

    // "2560x1440@165" -> {w, h, r}
    function parseMode(mode) {
        const m = /^(\d+)x(\d+)(?:@([\d.]+))?/.exec(mode ?? "");
        if (!m) return null;
        return { w: parseInt(m[1]), h: parseInt(m[2]), r: m[3] ? parseFloat(m[3]) : 0 };
    }

    // Hyprland reports "2560x1440@165.00Hz"; store "2560x1440@165" (or @59.95 when fractional).
    function normaliseMode(mode) {
        const p = root.parseMode(mode);
        if (!p) return mode;
        const r = Math.abs(p.r - Math.round(p.r)) < 0.01 ? Math.round(p.r) : p.r.toFixed(2);
        return `${p.w}x${p.h}@${r}`;
    }

    function modeLabel(mode) {
        const p = root.parseMode(mode);
        if (!p) return mode;
        const r = Math.abs(p.r - Math.round(p.r)) < 0.01 ? Math.round(p.r) : p.r.toFixed(2);
        return `${p.w} × ${p.h} @ ${r} Hz`;
    }

    function sameMode(a, b) {
        const pa = root.parseMode(a), pb = root.parseMode(b);
        return !!pa && !!pb && pa.w === pb.w && pa.h === pb.h && Math.abs(pa.r - pb.r) < 0.6;
    }

    // Scales that divide the mode into whole logical pixels (Hyprland rejects/adjusts others).
    function validScales(mode) {
        const p = root.parseMode(mode);
        if (!p) return [1];
        const ok = root.scaleCandidates.filter(s => {
            const lw = p.w / s, lh = p.h / s;
            return Math.abs(lw - Math.round(lw)) < 0.02 && Math.abs(lh - Math.round(lh)) < 0.02;
        });
        return ok.length > 0 ? ok : [1];
    }

    function fmtNumber(n) {
        return String(Math.round(n * 1000000) / 1000000);
    }

    // Logical (scaled, rotated) size of a profile monitor entry.
    function logicalSize(entry) {
        const p = root.parseMode(entry.mode) ?? { w: 1920, h: 1080 };
        const rotated = entry.transform % 2 === 1;
        const s = entry.scale > 0 ? entry.scale : 1;
        return {
            w: Math.round((rotated ? p.h : p.w) / s),
            h: Math.round((rotated ? p.w : p.h) / s)
        };
    }

    // ---------- profiles ----------

    function clone(obj) {
        return JSON.parse(JSON.stringify(obj));
    }

    function profileNames() {
        return (root.data?.profiles ?? []).map(p => p.name);
    }

    function profileByName(name) {
        return (root.data?.profiles ?? []).find(p => p.name === name) ?? null;
    }

    // A profile describing what Hyprland is showing right now. Built-in panels count as
    // enabled even when currently off: that is usually the lid bind, not a layout choice.
    function profileFromCurrent(name) {
        const monitors = root.detected.map(d => ({
            output: d.output,
            label: d.label,
            enabled: root.isInternal(d.name) ? true : !d.disabled,
            mode: d.currentMode,
            x: d.x,
            y: d.y,
            scale: Math.round(d.scale * 1000000) / 1000000,
            transform: d.transform,
            mirror: d.mirrorOf
        }));
        return { name: name, monitors: monitors, workspaces: [] };
    }

    // Add connected monitors that a profile doesn't mention yet (placed to the right).
    function withConnectedMonitors(profile) {
        const p = root.clone(profile);
        for (const d of root.detected) {
            if (p.monitors.some(m => root.outputMatches(m.output, d))) continue;
            let right = 0;
            for (const m of p.monitors) {
                if (!m.enabled) continue;
                right = Math.max(right, m.x + root.logicalSize(m).w);
            }
            p.monitors.push({
                output: d.output, label: d.label, enabled: true,
                mode: d.modes[0] ?? d.currentMode, x: right, y: 0, scale: 1, transform: 0, mirror: ""
            });
        }
        return p;
    }

    function uniqueName(base) {
        const names = root.profileNames();
        if (!names.includes(base)) return base;
        let i = 2;
        while (names.includes(`${base} ${i}`)) i++;
        return `${base} ${i}`;
    }

    function saveProfiles() {
        if (!root.data) return;
        root.data = root.clone(root.data); // notify bindings
        profilesFile.setText(JSON.stringify(root.data, null, 2) + "\n");
        root.profilesFileMissing = false;
    }

    function upsertProfile(profile, oldName) {
        if (!root.data) root.data = { version: 1, active: profile.name, profiles: [] };
        const list = root.data.profiles;
        const idx = list.findIndex(p => p.name === (oldName ?? profile.name));
        if (idx >= 0) list[idx] = root.clone(profile);
        else list.push(root.clone(profile));
        if (oldName && root.data.active === oldName) root.data.active = profile.name;
        root.saveProfiles();
    }

    function deleteProfile(name) {
        if (!root.data) return;
        root.data.profiles = root.data.profiles.filter(p => p.name !== name);
        if (root.data.active === name) root.data.active = root.data.profiles[0]?.name ?? "";
        root.saveProfiles();
    }

    // ---------- Lua generation ----------

    function luaString(s) {
        return `"${String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
    }

    function generateMonitorsLua(profile) {
        let out = `-- Generated by the Quickshell "Display" settings page (profile: ${root.luaString(profile.name)}).\n`;
        out += "-- Do not edit by hand: it is overwritten on the next apply.\n";
        out += "-- Profiles live in ~/.config/hypr/displays/profiles.json.\n\n";
        const lidAware = profile.monitors.some(m => m.enabled && root.isInternal(m.output));
        if (lidAware) out += root.lidPrelude;
        for (const m of profile.monitors) {
            out += `-- ${m.label ?? root.labelFor(m.output)}\n`;
            if (m.enabled && lidAware && root.isInternal(m.output)) {
                out += "if docked_with_lid_closed then\n";
                out += `    hl.monitor({ output = ${root.luaString(m.output)}, disabled = true })\n`;
                out += "else\n    ";
                out += root.monitorLine(m);
                out += "end\n";
                continue;
            }
            if (!m.enabled) {
                out += `hl.monitor({ output = ${root.luaString(m.output)}, disabled = true })\n`;
                continue;
            }
            out += root.monitorLine(m);
        }
        return out;
    }

    function monitorLine(m) {
        const fields = [
            `output = ${root.luaString(m.output)}`,
            `mode = ${root.luaString(m.mode)}`,
            `position = ${root.luaString(`${Math.round(m.x)}x${Math.round(m.y)}`)}`,
            `scale = ${root.luaString(root.fmtNumber(m.scale))}`
        ];
        if (m.transform) fields.push(`transform = ${m.transform}`);
        if (m.mirror) fields.push(`mirror = ${root.luaString(m.mirror)}`);
        return `hl.monitor({ ${fields.join(", ")} })\n`;
    }

    // The lid bind only reacts to lid *events*, so any reload (including autoreload on save)
    // with the lid closed would turn the built-in panel back on behind it. Only when an
    // external display is connected, so a lone laptop never ends up with no screen.
    readonly property string lidPrelude: `local function lid_closed()
    for _, name in ipairs({ "LID0", "LID", "LID1" }) do
        local f = io.open("/proc/acpi/button/lid/" .. name .. "/state")
        if f then
            local state = f:read("*a") or ""
            f:close()
            return state:find("closed") ~= nil
        end
    end
    return false
end

local function external_connected()
    for _, m in pairs(hl.get_monitors()) do
        if not (m.name:match("^eDP%-") or m.name:match("^LVDS%-") or m.name:match("^DSI%-")) then
            return true
        end
    end
    return false
end

local docked_with_lid_closed = lid_closed() and external_connected()

`

    function generateWorkspacesLua(profile) {
        let out = `-- Generated by the Quickshell "Display" settings page (profile: ${root.luaString(profile.name)}).\n`;
        out += "-- Do not edit by hand: it is overwritten on the next apply.\n\n";
        const rules = (profile.workspaces ?? []).slice().sort((a, b) => a.workspace - b.workspace);
        for (const w of rules) {
            if (!w.output) continue;
            const def = w.default ? ", default = true" : "";
            out += `hl.workspace_rule({ workspace = ${root.luaString(w.workspace)}, monitor = ${root.luaString(w.output)}${def} })\n`;
        }
        return out;
    }

    // ---------- apply / keep / revert ----------

    function apply(profile) {
        if (root.pending) return;
        root.backupMonitors = monitorsFile.text();
        root.backupWorkspaces = workspacesFile.text();
        root.pendingProfile = root.clone(profile);
        root.pendingProfileName = profile.name;
        monitorsFile.setText(root.generateMonitorsLua(profile));
        workspacesFile.setText(root.generateWorkspacesLua(profile));
        reloadProc.running = true;
        root.countdown = root.confirmSeconds;
        root.pending = true;
        confirmTimer.restart();
    }

    function keep() {
        if (!root.pending) return;
        confirmTimer.stop();
        root.pending = false;
        if (!root.data) root.data = { version: 1, active: "", profiles: [] };
        root.upsertProfile(root.pendingProfile);
        root.data.active = root.pendingProfileName;
        root.saveProfiles();
        root.applied();
    }

    function revert() {
        if (!root.pending) return;
        confirmTimer.stop();
        root.pending = false;
        monitorsFile.setText(root.backupMonitors);
        workspacesFile.setText(root.backupWorkspaces);
        reloadProc.running = true;
        root.reverted();
    }

    function refreshDetected() {
        monitorsProc.running = true;
    }

    Timer {
        id: confirmTimer
        interval: 1000
        repeat: true
        onTriggered: {
            root.countdown -= 1;
            if (root.countdown <= 0) root.revert();
        }
    }

    Process {
        id: reloadProc
        command: ["hyprctl", "reload"]
        onExited: refreshTimer.restart()
    }

    // Monitors take a moment to settle after a reload
    Timer {
        id: refreshTimer
        interval: 800
        onTriggered: root.refreshDetected()
    }

    Process {
        id: monitorsProc
        command: ["hyprctl", "monitors", "all", "-j"]
        stdout: StdioCollector {
            id: monitorsCollector
            onStreamFinished: {
                try {
                    const raw = JSON.parse(monitorsCollector.text);
                    root.detected = raw.map(m => {
                        const modes = [];
                        for (const mode of m.availableModes ?? []) {
                            const n = root.normaliseMode(mode);
                            if (!modes.includes(n)) modes.push(n);
                        }
                        return {
                            name: m.name,
                            description: m.description,
                            label: root.isInternal(m.name) ? `Layar laptop (${m.name})` : `${m.make} ${m.model}`.trim(),
                            output: root.outputIdFor(m),
                            disabled: m.disabled,
                            modes: modes,
                            currentMode: root.normaliseMode(`${m.width}x${m.height}@${m.refreshRate}`),
                            x: m.x,
                            y: m.y,
                            scale: m.scale,
                            transform: m.transform,
                            mirrorOf: m.mirrorOf && m.mirrorOf !== "none" ? m.mirrorOf : ""
                        };
                    });
                } catch (e) {
                    console.error("[Displays] Failed to parse hyprctl monitors:", e);
                }
            }
        }
    }

    FileView {
        id: profilesFile
        path: root.profilesPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.data = JSON.parse(profilesFile.text());
                root.profilesFileMissing = false;
            } catch (e) {
                console.error("[Displays] Invalid profiles.json:", e);
            }
        }
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) root.profilesFileMissing = true;
        }
    }

    FileView {
        id: monitorsFile
        path: root.monitorsPath
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
    }

    FileView {
        id: workspacesFile
        path: root.workspacesPath
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
    }

    Component.onCompleted: root.refreshDetected()
}
