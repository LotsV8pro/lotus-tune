import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Per page top bar. It is ONE floating island: all the content lives
// inside a rounded `Panel` with a soft shadow, the same brick the rest of
// the interface uses. Back (if it applies), the page title and two
// discreet actions (launcher and settings). No subtitle and no separators:
// the hierarchy comes from the air.
Rectangle {
    id: top

    property string title: ""
    property string subtitle: ""   // kept for compatibility; it is not painted
    property bool showBack: false

    signal backRequested()
    signal launcherRequested()
    signal settingsRequested()

    color: "transparent"

    // Island: the surface comes from `Panel` itself, but in the current
    // flat language the bar sits straight on the background (no box, no
    // edge).
    Panel {
        anchors.fill: parent
        color: "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.s4
            anchors.rightMargin: Theme.s3
            spacing: Theme.s2

            // Back: only when the page is a child of another. Round
            // button.
            Rectangle {
                visible: top.showBack
                Layout.alignment: Qt.AlignVCenter
                width: Theme.rowThin
                height: Theme.rowThin
                radius: width / 2
                color: backHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
                Glyph {
                    anchors.centerIn: parent
                    width: 16; height: 16
                    kind: "chevron-left"
                    color: Sys.text
                }
                TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.backRequested() } }
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                text: top.title
                color: Sys.text
                font.pixelSize: Theme.tLg
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Item { Layout.fillWidth: true }

            // Launcher: a quiet action, not a bordered field. Round
            // button.
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: Theme.rowThin
                height: Theme.rowThin
                radius: width / 2
                color: launcherHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                HoverHandler { id: launcherHover; cursorShape: Qt.PointingHandCursor }
                Glyph {
                    anchors.centerIn: parent
                    width: 17; height: 17
                    kind: "search"
                    color: launcherHover.hovered ? Sys.text : Sys.textDim
                }
                TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.launcherRequested() } }
            }

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: Theme.rowThin
                height: Theme.rowThin
                radius: width / 2
                color: gearHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                HoverHandler { id: gearHover; cursorShape: Qt.PointingHandCursor }
                Glyph {
                    anchors.centerIn: parent
                    width: 17; height: 17
                    kind: "gear"
                    color: gearHover.hovered ? Sys.text : Sys.textDim
                }
                TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.settingsRequested() } }
            }
        }
    }
}
