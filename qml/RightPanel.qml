import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Switchable right panel: QUEUE and LYRICS. It is shown/hidden from Main
// and fed with data through properties (the queue) or through the context
// properties (LyricsView reads the lyrics directly).
//
// It is a single "floating island": the root is transparent and the whole
// rounded surface (with its subtle border and shadow) comes from `Panel`.
Item {
    id: panel

    property int tab: 0                 // 0 = cola, 1 = letras
    property var queueModel: null
    property int queueIndex: -1

    signal closeRequested()
    signal trackActivated(int index)
    signal trackContextRequested(var track, real x, real y)
    // Ask for the fullscreen lyrics (cinema mode) from the LYRICS tab.
    signal fullscreenLyricsRequested()

    implicitWidth: 360

    Panel {
        id: island
        anchors.fill: parent
        clipContent: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.s3
            spacing: Theme.s2

            // ---- header ------------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2

                // Pill tabs: capsules with a soft accent on the active
                // one, no underlines or hard lines.
                Repeater {
                    model: [ { t: 0, name: "Cola", icon: "queue" },
                             { t: 1, name: "Letra", icon: "lyrics" } ]
                    delegate: Item {
                        id: tabItem
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.pillH
                        readonly property bool on: panel.tab === modelData.t

                        HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rPill
                            color: tabItem.on ? Theme.alpha(Sys.accent, 0.16)
                                   : (tabHover.hovered ? Theme.hover(Sys.surface) : "transparent")
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        }

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 6
                            Glyph {
                                width: 14; height: 14
                                kind: tabItem.modelData.icon
                                color: tabItem.on ? Sys.accent : Sys.textDim
                            }
                            Text {
                                text: tabItem.modelData.name
                                color: tabItem.on ? Sys.text : Sys.textDim
                                font.pixelSize: Theme.tBase
                                font.weight: tabItem.on ? Font.DemiBold : Font.Medium
                            }
                        }

                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); panel.tab = tabItem.modelData.t } }
                    }
                }

                // Fullscreen lyrics (cinema mode): only in the LYRICS tab.
                // Round pill, like the close button.
                Rectangle {
                    Layout.preferredWidth: Theme.pillH
                    Layout.preferredHeight: Theme.pillH
                    radius: Theme.rPill
                    visible: panel.tab === 1
                    color: fsHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    HoverHandler { id: fsHover; cursorShape: Qt.PointingHandCursor }
                    Glyph {
                        anchors.centerIn: parent
                        width: 14; height: 14
                        kind: "expand"
                        color: fsHover.hovered ? Sys.accent : Sys.textDim
                    }
                    TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); panel.fullscreenLyricsRequested() } }
                }

                // Close: round pill, as tall as the tabs.
                Rectangle {
                    Layout.preferredWidth: Theme.pillH
                    Layout.preferredHeight: Theme.pillH
                    radius: Theme.rPill
                    color: closeHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                    Glyph {
                        anchors.centerIn: parent
                        width: 14; height: 14
                        kind: "chevron-right"
                        color: closeHover.hovered ? Sys.accent : Sys.textDim
                    }
                    TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); panel.closeRequested() } }
                }
            }

            // ---- content -----------------------------------------------
            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: panel.tab

                QueueView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    tracks: panel.queueModel
                    currentIndex: panel.queueIndex
                    onTrackActivated: (i) => panel.trackActivated(i)
                    onTrackContextRequested: (t, x, y) => panel.trackContextRequested(t, x, y)
                }

                LyricsView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // The edge fade has to blend with the island's real
                    // background, which is the `Panel` surface.
                    edgeColor: island.color
                }
            }
        }
    }
}
