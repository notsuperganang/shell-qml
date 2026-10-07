import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

// Bar chip listing the dev servers you're running (e.g. "3000 · 8000"); hover for open/kill actions.
MouseArea {
    id: root
    readonly property var servers: DevServers.servers
    // Keep the popup up while the pointer travels from the chip into it (they are separate windows)
    property bool popupHovered: false
    readonly property bool hovering: containsMouse || popupHovered
    onHoveringChanged: if (!hovering) closeDelay.restart()

    visible: servers.length > 0
    implicitWidth: chipRow.implicitWidth + 8
    implicitHeight: Appearance.sizes.barHeight
    hoverEnabled: true

    Timer {
        id: closeDelay
        interval: 100 // just enough to cross the gap between the bar and the popup
    }

    RowLayout {
        id: chipRow
        anchors.centerIn: parent
        spacing: 2

        MaterialSymbol {
            Layout.alignment: Qt.AlignVCenter
            fill: 1
            text: "electric_bolt"
            iconSize: Appearance.font.pixelSize.normal
            color: Appearance.colors.colOnLayer1
        }
        StyledText {
            Layout.alignment: Qt.AlignVCenter
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1
            text: root.servers.length <= 2 ? root.servers.map(s => s.port).join(" · ") : root.servers.length
        }
    }

    StyledPopup {
        hoverTarget: root
        active: root.hovering || closeDelay.running

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 6

            HoverHandler {
                onHoveredChanged: root.popupHovered = hovered
            }

            StyledPopupHeaderRow {
                icon: "dns"
                label: Translation.tr("Dev servers")
            }

            Repeater {
                model: root.servers
                delegate: ServerRow {
                    required property var modelData
                    port: modelData.port
                    title: modelData.hint ? `${modelData.name} · ${modelData.hint}` : modelData.name
                    subtitle: modelData.project
                    pid: modelData.pid
                }
            }

            Rectangle { // separator before system services
                visible: DevServers.services.length > 0
                Layout.fillWidth: true
                implicitHeight: 1
                color: Appearance.colors.colOutlineVariant
            }

            Repeater {
                model: DevServers.services
                delegate: ServerRow {
                    required property var modelData
                    port: modelData.port
                    title: modelData.name || Translation.tr("service")
                    subtitle: Translation.tr("system")
                }
            }
        }
    }

    component ServerRow: RowLayout {
        id: row
        property int port
        property string title
        property string subtitle
        property int pid: 0 // 0 = not ours, can't kill
        property bool armed: false // kill needs a second click
        spacing: 10

        StyledText {
            Layout.preferredWidth: 46
            font.family: Appearance.font.family.monospace
            font.weight: Font.DemiBold
            text: row.port
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 150
            spacing: 0
            StyledText {
                text: row.title
                font.pixelSize: Appearance.font.pixelSize.small
            }
            StyledText {
                text: row.subtitle
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
        }
        RippleButton {
            implicitWidth: 30
            implicitHeight: 30
            buttonRadius: Appearance.rounding.full
            onClicked: DevServers.open(row.port)
            contentItem: MaterialSymbol {
                horizontalAlignment: Text.AlignHCenter
                text: "open_in_new"
                iconSize: Appearance.font.pixelSize.large
            }
        }
        RippleButton {
            visible: row.pid > 0
            implicitWidth: row.armed ? confirmText.implicitWidth + 16 : 30
            implicitHeight: 30
            buttonRadius: Appearance.rounding.full
            colBackground: row.armed ? Appearance.colors.colErrorContainer : "transparent"
            onClicked: {
                if (row.armed) DevServers.kill(row.pid);
                row.armed = !row.armed;
                disarm.restart();
            }
            contentItem: Item {
                MaterialSymbol {
                    anchors.centerIn: parent
                    visible: !row.armed
                    text: "close"
                    iconSize: Appearance.font.pixelSize.large
                }
                StyledText {
                    id: confirmText
                    anchors.centerIn: parent
                    visible: row.armed
                    text: Translation.tr("Kill?")
                    color: Appearance.colors.colOnErrorContainer
                }
            }
            Timer {
                id: disarm
                interval: 3000
                onTriggered: row.armed = false
            }
        }
    }
}
