import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Reusable context menu (right click), in Sonora's style: a list of entries
// with an icon, an optional check mark, separators and dimmed/disabled
// entries. It opens at the requested point (`at`, in window coordinates) and
// is clipped to the margins. Every entry carries its own `action()` (a JS
// function); pressing it closes the menu and runs it.
//
// It is "dumb": it knows nothing about the app. Main hands it the built
// `items` and listens to `closed`.
Item {
    id: menu

    // [{ label, icon, enabled, checked, danger, separator, action }]
    property var items: []
    property point at: Qt.point(0, 0)
    property bool open: false

    signal closed()

    readonly property int menuW: 252
    readonly property int pad: 6
    readonly property real idealH: col.implicitHeight + 2 * pad

    visible: open
    z: 96

    // Closes the menu by telling the owner (Main), which is the one in
    // charge of `open` through its binding. NOTE: do not assign
    // `open = false` here, that would break the binding and the menu could
    // only be opened ONCE.
    function dismiss() {
        if (!open)
            return
        closed()
    }

    // Layer that catches any click outside the panel to close it.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: menu.dismiss()
        onWheel: (w) => { w.accepted = true }
    }

    // Floating island: `Panel` provides the rounded corners, the subtle
    // border and the soft shadow; inside goes the list, which scrolls if it
    // does not fit.
    Panel {
        id: island
        width: menu.menuW
        height: Math.min(menu.idealH, Math.max(0, menu.height - Theme.s4))
        x: Math.max(Theme.s2, Math.min(menu.at.x, menu.width - width - Theme.s2))
        y: Math.max(Theme.s2, Math.min(menu.at.y, menu.height - height - Theme.s2))
        radius: Theme.rLg
        clipContent: true
        opacity: menu.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

        Flickable {
            id: flick
            anchors.fill: parent
            anchors.margins: menu.pad
            contentWidth: width
            contentHeight: col.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ColumnLayout {
                id: col
                width: flick.width
                spacing: 2

                Repeater {
                    model: menu.items

                    delegate: Item {
                        id: cell
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: modelData.separator === true ? Theme.s3 : Theme.rowThin

                        // Soft separator: instead of a hard line, a barely
                        // perceptible band that only gives air.
                        Rectangle {
                            visible: modelData.separator === true
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Theme.s3
                            anchors.rightMargin: Theme.s3
                            height: 1
                            color: Theme.alpha(Sys.text, 0.05)
                        }

                        Rectangle {
                            id: row
                            visible: modelData.separator !== true
                            anchors.fill: parent
                            // Every entry is a pill: a capsule with a soft
                            // accent on hover.
                            radius: Theme.rPill
                            readonly property bool can: modelData.enabled !== false
                            readonly property bool on: hov.hovered && row.can
                            color: row.on ? Theme.alpha(Sys.accent, 0.12) : "transparent"
                            // The accent marks hover/checked rows; in the
                            // current palette it is dark (#983e45) and it
                            // disappears over the dark surface, so the
                            // accent-tinted glyphs take the lightened copy
                            // (theme.js) and stay readable on any palette.
                            readonly property color hi: Theme.accentText(Sys.accent)

                            HoverHandler {
                                id: hov
                                enabled: row.can
                                cursorShape: Qt.PointingHandCursor
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s2
                                anchors.rightMargin: Theme.s2
                                spacing: Theme.s2

                                Glyph {
                                    Layout.preferredWidth: 15
                                    Layout.preferredHeight: 15
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: (modelData.icon || "").length > 0
                                    kind: modelData.icon || "music"
                                    color: !row.can ? Sys.textDim
                                           : (modelData.danger === true ? Sys.danger
                                              : (modelData.checked === true || row.on
                                                 ? row.hi : Sys.text))
                                }

                                Text {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignVCenter
                                    text: modelData.label || ""
                                    color: !row.can ? Sys.textDim
                                           : (modelData.danger === true ? Sys.danger
                                              : (row.on ? row.hi : Sys.text))
                                    font.pixelSize: Theme.tBase
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    opacity: row.can ? 1 : 0.65
                                }

                                Glyph {
                                    Layout.preferredWidth: 13
                                    Layout.preferredHeight: 13
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: modelData.checked === true
                                    kind: "check"
                                    color: row.hi
                                }
                            }

                            TapHandler {
                                enabled: row.can
                                onTapped: {
                                    if (typeof sfx !== 'undefined') sfx.play('tap')
                                    const act = cell.modelData.action
                                    menu.dismiss()
                                    if (typeof act === "function")
                                        act()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
