pragma ComponentBehavior: Bound

import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell

Item {
    id: root
    property real padding: 4
    implicitWidth: QsWindow?.window?.screen.width * 0.7 ?? 0
    implicitHeight: QsWindow?.window?.screen.height * 0.7 ?? 0

    property string query: ""

    ToolbarTextField {
        id: searchField
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        implicitWidth: 360
        implicitHeight: 40
        placeholderText: Translation.tr("Search keybinds (e.g. screenshot, workspace, shift)")
        onTextChanged: root.query = text
    }

    // Called each time the cheatsheet opens: start with an empty, focused search field.
    function resetSearch() {
        searchField.text = "";
        Qt.callLater(() => searchField.forceActiveFocus());
    }

    StyledFlickable {
        id: flickable
        clip: true
        anchors {
            top: searchField.bottom
            topMargin: 12
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        anchors.margins: Appearance.rounding.small
        contentHeight: height
        contentWidth: flow.implicitWidth
        Flow {
            id: flow
            height: flickable.height
            flow: Flow.TopToBottom
            spacing: 10
            Repeater {
                model: [...HyprlandKeybinds.keybindCategories, ""]
                delegate: CheatsheetKeybindsCategory {
                    required property var modelData
                    categoryName: modelData
                    searchQuery: root.query
                }
            }
        }
    }

    ScrollEdgeFade {
        target: flickable
        vertical: false
        color: Appearance.colors.colLayer0Base
    }
}
