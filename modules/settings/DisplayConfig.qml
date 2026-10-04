pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ContentPage {
    id: page
    forceWidth: true
    baseWidth: 720

    // The profile being edited (a working copy; nothing is written until Apply/Save).
    property string selectedName: ""
    property var draft: null
    property string savedJson: ""
    property int selectedIndex: 0
    property bool renaming: false
    readonly property bool dirty: page.draft !== null && JSON.stringify(page.draft) !== page.savedJson
    readonly property var selectedMonitor: page.draft?.monitors[page.selectedIndex] ?? null
    readonly property var selectedDetected: page.selectedMonitor ? Displays.detectedFor(page.selectedMonitor.output) : null
    readonly property bool isActive: page.selectedName !== "" && page.selectedName === Displays.data?.active

    function loadProfile(name) {
        const p = Displays.profileByName(name);
        page.renaming = false;
        if (!p) {
            page.selectedName = "";
            page.draft = null;
            page.savedJson = "";
            return;
        }
        page.selectedName = name;
        page.draft = Displays.withConnectedMonitors(p);
        page.savedJson = JSON.stringify(page.draft);
        page.selectedIndex = Math.max(0, Math.min(page.selectedIndex, page.draft.monitors.length - 1));
    }

    function syncFromService() {
        if (Displays.pending || page.dirty) return;
        let name = page.selectedName;
        if (!name || !Displays.profileByName(name))
            name = Displays.data?.active || (Displays.profileNames()[0] ?? "");
        page.loadProfile(name);
    }

    function mutate(fn) {
        const d = Displays.clone(page.draft);
        fn(d);
        page.draft = d;
    }

    function setField(field, value) {
        page.mutate(d => {
            d.monitors[page.selectedIndex][field] = value;
        });
    }

    // Monitors that take part in the arrangement (enabled and not mirroring).
    function arranged(monitors) {
        return monitors.filter(m => m.enabled && !m.mirror);
    }

    // Shift everything so the arrangement starts at 0,0.
    function normalise(d) {
        const list = page.arranged(d.monitors);
        if (list.length === 0) return;
        const minX = Math.min(...list.map(m => m.x));
        const minY = Math.min(...list.map(m => m.y));
        for (const m of d.monitors) {
            m.x = Math.round(m.x - minX);
            m.y = Math.round(m.y - minY);
        }
    }

    function overlaps(a, as, b, bs) {
        return a.x < b.x + bs.w && a.x + as.w > b.x && a.y < b.y + bs.h && a.y + as.h > b.y;
    }

    // Snap a dragged monitor to the edges of the others (like Windows' "Rearrange displays")
    // and push it out of any overlap.
    function snap(d, index, x, y) {
        const me = d.monitors[index];
        const ms = Displays.logicalSize(me);
        const others = d.monitors.filter((m, i) => i !== index && m.enabled && !m.mirror);
        const threshold = Math.max(ms.w, ms.h) * 0.12;
        let bestX = x, bestY = y, dX = threshold, dY = threshold;
        for (const o of others) {
            const os = Displays.logicalSize(o);
            for (const cx of [o.x - ms.w, o.x + os.w, o.x, o.x + os.w - ms.w, o.x + (os.w - ms.w) / 2]) {
                if (Math.abs(cx - x) < dX) { dX = Math.abs(cx - x); bestX = cx; }
            }
            for (const cy of [o.y - ms.h, o.y + os.h, o.y, o.y + os.h - ms.h, o.y + (os.h - ms.h) / 2]) {
                if (Math.abs(cy - y) < dY) { dY = Math.abs(cy - y); bestY = cy; }
            }
        }
        let pos = { x: bestX, y: bestY };
        for (const o of others) {
            const os = Displays.logicalSize(o);
            if (!page.overlaps(pos, ms, o, os)) continue;
            const moves = [
                { x: o.x - ms.w, y: pos.y },
                { x: o.x + os.w, y: pos.y },
                { x: pos.x, y: o.y - ms.h },
                { x: pos.x, y: o.y + os.h }
            ];
            moves.sort((a, b) => (Math.abs(a.x - pos.x) + Math.abs(a.y - pos.y)) - (Math.abs(b.x - pos.x) + Math.abs(b.y - pos.y)));
            pos = moves[0];
        }
        return { x: Math.round(pos.x), y: Math.round(pos.y) };
    }

    function workspaceRule(n) {
        return (page.draft?.workspaces ?? []).find(w => w.workspace === n) ?? null;
    }

    Component.onCompleted: {
        Displays.refreshDetected();
        page.syncFromService();
    }

    Connections {
        target: Displays
        function onDataChanged() { page.syncFromService(); }
        function onDetectedChanged() {
            if (page.draft && !page.dirty) page.loadProfile(page.selectedName);
            else if (!page.draft) page.syncFromService();
        }
        function onApplied() { page.loadProfile(Displays.data?.active ?? page.selectedName); }
        function onReverted() { page.loadProfile(page.selectedName); }
    }

    // ---------- confirmation banner ----------

    NoticeBox {
        visible: Displays.pending
        Layout.fillWidth: true
        materialIcon: "timer"
        text: Translation.tr("Keep these display settings? Reverting in %1 s.").arg(Displays.countdown)

        RowLayout {
            Layout.alignment: Qt.AlignRight
            RippleButtonWithIcon {
                materialIcon: "undo"
                mainText: Translation.tr("Revert")
                onClicked: Displays.revert()
            }
            RippleButtonWithIcon {
                materialIcon: "check"
                mainText: Translation.tr("Keep changes")
                onClicked: Displays.keep()
            }
        }
    }

    NoticeBox {
        visible: Displays.profilesFileMissing && !Displays.pending
        Layout.fillWidth: true
        materialIcon: "info"
        text: Translation.tr("No display profiles yet. Create one from the current layout to get started.")

        RippleButtonWithIcon {
            Layout.alignment: Qt.AlignRight
            materialIcon: "add"
            mainText: Translation.tr("Create from current layout")
            onClicked: {
                Displays.upsertProfile(Displays.profileFromCurrent(Translation.tr("Default")));
                page.loadProfile(Translation.tr("Default"));
            }
        }
    }

    // ---------- profiles ----------

    ContentSection {
        visible: Displays.data !== null
        icon: "view_quilt"
        title: Translation.tr("Profile")

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // Controls below are rebuilt whenever what they show changes: Qt's ComboBox and
            // ConfigSwitch drop their bindings once clicked, and these are shared across
            // profiles/displays.
            Repeater {
                model: page.renaming ? [] : [`${page.selectedName}|${Displays.data?.active}|${Displays.profileNames().join("|")}`]
                delegate: StyledComboBox {
                    objectName: "profileCombo"
                    Layout.fillWidth: true
                    enabled: !Displays.pending
                    buttonIcon: "desktop_windows"
                    textRole: "displayName"
                    model: Displays.profileNames().map(n => ({
                        displayName: n === Displays.data?.active ? `${n}  •  ${Translation.tr("active")}` : n,
                        value: n
                    }))
                    currentIndex: Math.max(0, model.findIndex(item => item.value === page.selectedName))
                    onActivated: index => page.loadProfile(model[index].value)
                }
            }

            MaterialTextField {
                id: renameField
                visible: page.renaming
                Layout.fillWidth: true
                placeholderText: Translation.tr("Profile name")
                onAccepted: renameButton.clicked()
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6
            enabled: !Displays.pending

            RippleButtonWithIcon {
                materialIcon: "add"
                mainText: Translation.tr("New from current")
                onClicked: {
                    const name = Displays.uniqueName(Translation.tr("New profile"));
                    Displays.upsertProfile(Displays.profileFromCurrent(name));
                    page.loadProfile(name);
                }
            }
            RippleButtonWithIcon {
                materialIcon: "content_copy"
                mainText: Translation.tr("Duplicate")
                enabled: page.draft !== null
                onClicked: {
                    const copy = Displays.clone(page.draft);
                    copy.name = Displays.uniqueName(`${page.selectedName} copy`);
                    Displays.upsertProfile(copy);
                    page.loadProfile(copy.name);
                }
            }
            RippleButtonWithIcon {
                id: renameButton
                materialIcon: page.renaming ? "check" : "edit"
                mainText: page.renaming ? Translation.tr("Save name") : Translation.tr("Rename")
                enabled: page.draft !== null
                onClicked: {
                    if (!page.renaming) {
                        renameField.text = page.selectedName;
                        page.renaming = true;
                        renameField.forceActiveFocus();
                        return;
                    }
                    const name = renameField.text.trim();
                    page.renaming = false;
                    if (!name || name === page.selectedName) return;
                    if (Displays.profileNames().includes(name)) return;
                    const saved = Displays.clone(Displays.profileByName(page.selectedName));
                    saved.name = name;
                    const old = page.selectedName;
                    page.selectedName = name;
                    Displays.upsertProfile(saved, old);
                    page.loadProfile(name);
                }
            }
            RippleButtonWithIcon {
                materialIcon: "delete"
                mainText: Translation.tr("Delete")
                enabled: page.draft !== null && !page.isActive && Displays.profileNames().length > 1
                onClicked: {
                    const name = page.selectedName;
                    page.selectedName = "";
                    Displays.deleteProfile(name);
                }
            }
        }
    }

    // ---------- arrangement ----------

    ContentSection {
        visible: page.draft !== null
        icon: "monitor"
        title: Translation.tr("Arrangement")

        Rectangle {
            id: canvas
            Layout.fillWidth: true
            implicitHeight: 280
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer2
            clip: true

            readonly property real pad: 28
            readonly property var tiles: (page.draft?.monitors ?? []).map((m, i) => ({ m: m, i: i })).filter(t => t.m.enabled && !t.m.mirror)
            readonly property var bounds: {
                if (canvas.tiles.length === 0) return { x: 0, y: 0, w: 1, h: 1 };
                let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
                for (const t of canvas.tiles) {
                    const s = Displays.logicalSize(t.m);
                    x1 = Math.min(x1, t.m.x); y1 = Math.min(y1, t.m.y);
                    x2 = Math.max(x2, t.m.x + s.w); y2 = Math.max(y2, t.m.y + s.h);
                }
                return { x: x1, y: y1, w: Math.max(1, x2 - x1), h: Math.max(1, y2 - y1) };
            }
            readonly property real k: Math.min((canvas.width - 2 * canvas.pad) / canvas.bounds.w, (canvas.height - 2 * canvas.pad) / canvas.bounds.h)
            readonly property real offX: (canvas.width - canvas.bounds.w * canvas.k) / 2
            readonly property real offY: (canvas.height - canvas.bounds.h * canvas.k) / 2

            StyledText {
                visible: canvas.tiles.length === 0
                anchors.centerIn: parent
                color: Appearance.colors.colSubtext
                text: Translation.tr("No enabled displays in this profile")
            }

            Repeater {
                model: canvas.tiles
                delegate: Rectangle {
                    id: tile
                    required property var modelData
                    readonly property var size: Displays.logicalSize(tile.modelData.m)
                    readonly property bool selected: page.selectedIndex === tile.modelData.i
                    readonly property bool connected: Displays.detectedFor(tile.modelData.m.output) !== null
                    property real dx: 0
                    property real dy: 0

                    x: canvas.offX + (tile.modelData.m.x - canvas.bounds.x) * canvas.k + tile.dx
                    y: canvas.offY + (tile.modelData.m.y - canvas.bounds.y) * canvas.k + tile.dy
                    z: dragArea.pressed ? 2 : (tile.selected ? 1 : 0)
                    width: tile.size.w * canvas.k
                    height: tile.size.h * canvas.k
                    radius: Appearance.rounding.small
                    color: tile.selected ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer3
                    opacity: tile.connected ? 1 : 0.55
                    border.width: 2
                    border.color: tile.selected ? Appearance.colors.colPrimary : Appearance.colors.colOutlineVariant

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: parent.width - 12
                        spacing: 2
                        StyledText {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.normal
                            text: tile.modelData.m.label ?? Displays.labelFor(tile.modelData.m.output)
                        }
                        StyledText {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                            text: tile.connected ? Displays.modeLabel(tile.modelData.m.mode) : Translation.tr("Not connected")
                        }
                    }

                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        enabled: !Displays.pending
                        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property point start
                        onPressed: mouse => {
                            page.selectedIndex = tile.modelData.i;
                            dragArea.start = mapToItem(canvas, mouse.x, mouse.y);
                        }
                        onPositionChanged: mouse => {
                            const p = mapToItem(canvas, mouse.x, mouse.y);
                            tile.dx = p.x - dragArea.start.x;
                            tile.dy = p.y - dragArea.start.y;
                        }
                        onReleased: {
                            const moved = Math.abs(tile.dx) + Math.abs(tile.dy) > 3;
                            const nx = tile.modelData.m.x + tile.dx / canvas.k;
                            const ny = tile.modelData.m.y + tile.dy / canvas.k;
                            tile.dx = 0;
                            tile.dy = 0;
                            if (!moved) return;
                            page.mutate(d => {
                                const pos = page.snap(d, tile.modelData.i, nx, ny);
                                d.monitors[tile.modelData.i].x = pos.x;
                                d.monitors[tile.modelData.i].y = pos.y;
                                page.normalise(d);
                            });
                        }
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("Drag displays to arrange them; they snap to each other's edges. Click one to edit it below. Mirrored and disabled displays are not shown.")
        }

        // Pick displays that aren't on the canvas (disabled / mirroring)
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: (page.draft?.monitors ?? []).map((m, i) => ({ m: m, i: i }))
                delegate: RippleButtonWithIcon {
                    required property var modelData
                    toggled: page.selectedIndex === modelData.i
                    materialIcon: !modelData.m.enabled ? "desktop_access_disabled" : (modelData.m.mirror ? "screen_share" : "desktop_windows")
                    mainText: modelData.m.label ?? Displays.labelFor(modelData.m.output)
                    onClicked: page.selectedIndex = modelData.i
                }
            }
        }
    }

    // ---------- selected display ----------

    ContentSection {
        visible: page.selectedMonitor !== null
        icon: "display_settings"
        title: page.selectedMonitor ? (page.selectedMonitor.label ?? Displays.labelFor(page.selectedMonitor.output)) : ""

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: {
                const m = page.selectedMonitor;
                if (!m) return "";
                const where = page.selectedDetected ? Translation.tr("connected as %1").arg(page.selectedDetected.name) : Translation.tr("not connected");
                return `${m.output}  ·  ${where}  ·  ${Translation.tr("position")} ${m.x}, ${m.y}`;
            }
        }

        Repeater {
            model: page.selectedMonitor ? [`${page.selectedIndex}|${JSON.stringify(page.selectedMonitor)}|${(page.selectedDetected?.modes ?? []).length}|${Displays.detected.length}`] : []
            delegate: ColumnLayout {
                Layout.fillWidth: true
                spacing: 8
                enabled: !Displays.pending

                ConfigSwitch {
                    objectName: "enabledSwitch"
                    buttonIcon: "power_settings_new"
                    text: Translation.tr("Enabled")
                    checked: page.selectedMonitor?.enabled ?? false
                    onCheckedChanged: {
                        if (page.selectedMonitor && checked !== page.selectedMonitor.enabled)
                            page.setField("enabled", checked);
                    }
                }

                ContentSubsection {
                    visible: page.selectedMonitor?.enabled ?? false
                    title: Translation.tr("Resolution & refresh rate")

                    StyledComboBox {
                        objectName: "modeCombo"
                        Layout.fillWidth: true
                        buttonIcon: "aspect_ratio"
                        textRole: "displayName"
                        model: {
                            const m = page.selectedMonitor;
                            if (!m) return [];
                            const modes = page.selectedDetected?.modes ?? [];
                            const list = modes.some(x => Displays.sameMode(x, m.mode)) ? modes : [m.mode, ...modes];
                            return list.map(x => ({ displayName: Displays.modeLabel(x), value: x }));
                        }
                        currentIndex: Math.max(0, model.findIndex(item => Displays.sameMode(item.value, page.selectedMonitor?.mode)))
                        onActivated: index => {
                            const mode = model[index].value;
                            page.mutate(d => {
                                const m = d.monitors[page.selectedIndex];
                                m.mode = mode;
                                if (!Displays.validScales(mode).some(s => Math.abs(s - m.scale) < 0.001)) m.scale = 1;
                            });
                        }
                    }
                }

                ContentSubsection {
                    visible: page.selectedMonitor?.enabled ?? false
                    title: Translation.tr("Scale")
                    tooltip: Translation.tr("Only scales that divide this resolution into whole pixels are offered.")

                    ConfigSelectionArray {
                        currentValue: page.selectedMonitor ? Displays.validScales(page.selectedMonitor.mode).find(s => Math.abs(s - page.selectedMonitor.scale) < 0.001) ?? null : null
                        options: page.selectedMonitor ? Displays.validScales(page.selectedMonitor.mode).map(s => ({
                            displayName: `${Math.round(s * 100)}%`,
                            value: s
                        })) : []
                        onSelected: newValue => page.setField("scale", newValue)
                    }
                }

                ContentSubsection {
                    visible: page.selectedMonitor?.enabled ?? false
                    title: Translation.tr("Rotation")

                    ConfigSelectionArray {
                        currentValue: page.selectedMonitor?.transform ?? 0
                        options: [0, 1, 2, 3].map(t => ({ displayName: Translation.tr(Displays.transformNames[t]), value: t }))
                        onSelected: newValue => page.setField("transform", newValue)
                    }
                }

                ContentSubsection {
                    visible: page.selectedMonitor?.enabled ?? false
                    title: Translation.tr("Mirror")
                    tooltip: Translation.tr("Show the same picture as another display (e.g. for presentations).")

                    StyledComboBox {
                        Layout.fillWidth: true
                        buttonIcon: "screen_share"
                        textRole: "displayName"
                        model: [{ displayName: Translation.tr("Don't mirror"), value: "" }].concat(
                            Displays.detected
                                .filter(d => !page.selectedMonitor || !Displays.outputMatches(page.selectedMonitor.output, d))
                                .map(d => ({ displayName: Translation.tr("Mirror %1 (%2)").arg(d.label).arg(d.name), value: d.name })))
                        currentIndex: Math.max(0, model.findIndex(item => item.value === (page.selectedMonitor?.mirror ?? "")))
                        onActivated: index => page.setField("mirror", model[index].value)
                    }
                }
            }
        }
    }

    // ---------- workspaces ----------

    ContentSection {
        visible: page.draft !== null
        icon: "workspaces"
        title: Translation.tr("Workspaces")

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: Translation.tr("Pin workspaces to a display. The star marks the workspace a display shows first.")
        }

        Repeater {
            model: page.draft ? Array.from({ length: 10 }, (_, i) => ({ number: i + 1, rule: page.workspaceRule(i + 1) })) : []
            delegate: RowLayout {
                id: wsRow
                required property var modelData
                readonly property int number: wsRow.modelData.number
                readonly property var rule: wsRow.modelData.rule
                Layout.fillWidth: true
                enabled: !Displays.pending
                spacing: 8

                StyledText {
                    Layout.preferredWidth: 110
                    text: Translation.tr("Workspace %1").arg(wsRow.number)
                }

                StyledComboBox {
                    Layout.fillWidth: true
                    buttonIcon: "desktop_windows"
                    textRole: "displayName"
                    model: [{ displayName: Translation.tr("Any display"), value: "" }].concat(
                        (page.draft?.monitors ?? []).map(m => ({ displayName: m.label ?? Displays.labelFor(m.output), value: m.output })))
                    currentIndex: Math.max(0, model.findIndex(item => item.value === (wsRow.rule?.output ?? "")))
                    onActivated: index => {
                        const output = model[index].value;
                        page.mutate(d => {
                            d.workspaces = d.workspaces ?? [];
                            const w = d.workspaces.find(x => x.workspace === wsRow.number);
                            if (!output) d.workspaces = d.workspaces.filter(x => x.workspace !== wsRow.number);
                            else if (w) { w.output = output; w.default = false; }
                            else d.workspaces.push({ workspace: wsRow.number, output: output, default: false });
                        });
                    }
                }

                RippleButton {
                    implicitWidth: 40
                    implicitHeight: 40
                    buttonRadius: Appearance.rounding.full
                    enabled: wsRow.rule !== null
                    toggled: wsRow.rule?.default ?? false
                    onClicked: page.mutate(d => {
                        const w = d.workspaces.find(x => x.workspace === wsRow.number);
                        if (!w) return;
                        const makeDefault = !w.default;
                        for (const x of d.workspaces) if (x.output === w.output) x.default = false;
                        w.default = makeDefault;
                    })
                    contentItem: MaterialSymbol {
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: "star"
                        fill: wsRow.rule?.default ? 1 : 0
                        iconSize: Appearance.font.pixelSize.larger
                        color: wsRow.rule?.default ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
                        opacity: wsRow.rule ? 1 : 0.35
                    }
                }
            }
        }
    }

    // ---------- actions ----------

    RowLayout {
        visible: page.draft !== null && !Displays.pending
        Layout.fillWidth: true
        spacing: 8

        StyledText {
            Layout.fillWidth: true
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            text: page.dirty ? Translation.tr("Unsaved changes") : (page.isActive ? Translation.tr("This profile is active") : "")
        }
        RippleButtonWithIcon {
            materialIcon: "undo"
            mainText: Translation.tr("Discard")
            enabled: page.dirty
            onClicked: page.loadProfile(page.selectedName)
        }
        RippleButtonWithIcon {
            materialIcon: "save"
            mainText: Translation.tr("Save")
            enabled: page.dirty
            onClicked: {
                Displays.upsertProfile(page.draft);
                page.savedJson = JSON.stringify(page.draft);
            }
        }
        RippleButtonWithIcon {
            materialIcon: "check_circle"
            mainText: page.isActive ? Translation.tr("Apply") : Translation.tr("Apply & activate")
            onClicked: Displays.apply(page.draft)
        }
    }
}
