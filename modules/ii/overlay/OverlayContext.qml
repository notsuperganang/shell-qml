pragma Singleton
pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import qs
import qs.modules.common
import qs.modules.common.functions

Singleton {
    id: root
    
    signal requestCenter(string identifier)

    // Lives here, not in the widget: closing the overlay unloads its widgets, which would kill the dialog
    function pickFloatingImage() {
        GlobalStates.overlayOpen = false; // the overlay layer sits above all windows and would cover the dialog
        imagePicker.running = true;
    }

    Process {
        id: imagePicker
        command: ["kdialog", "--title", "Floating image", "--getopenfilename",
            FileUtils.trimFileProtocol(Directories.pictures), "*.png *.jpg *.jpeg *.gif *.webp *.avif|Images"]
        stdout: StdioCollector {
            onStreamFinished: {
                const path = text.trim();
                if (path.length > 0) // empty = dialog cancelled
                    Config.options.overlay.floatingImage.imageSource = "file://" + encodeURI(path);
            }
        }
        onExited: GlobalStates.overlayOpen = true // bring the overlay back once the dialog is done
    }

    readonly property list<var> availableWidgets: [
        { identifier: "crosshair", materialSymbol: "point_scan" },
        { identifier: "fpsLimiter", materialSymbol: "animation" },
        { identifier: "floatingImage", materialSymbol: "imagesmode" },
        { identifier: "recorder", materialSymbol: "screen_record" },
        { identifier: "resources", materialSymbol: "browse_activity" },
        { identifier: "notes", materialSymbol: "note_stack" },
        { identifier: "volumeMixer", materialSymbol: "volume_up" },
    ]
    
    readonly property bool hasPinnedWidgets: root.pinnedWidgetIdentifiers.length > 0

    property list<string> pinnedWidgetIdentifiers: []
    property list<var> clickableWidgets: []

    function pin(identifier: string, pin = true) {
        if (pin) {
            if (!root.pinnedWidgetIdentifiers.includes(identifier)) {
                root.pinnedWidgetIdentifiers.push(identifier)
            }
        } else {
            root.pinnedWidgetIdentifiers = root.pinnedWidgetIdentifiers.filter(id => id !== identifier)
        }
    }

    function registerClickableWidget(widget: var, clickable = true) {
        if (clickable) {
            if (!root.clickableWidgets.includes(widget)) {
                root.clickableWidgets.push(widget)
            }
        } else {
            root.clickableWidgets = root.clickableWidgets.filter(w => w !== widget)
        }
    }
}
