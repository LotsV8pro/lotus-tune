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
            // Same gutter as the page content (almost edge to edge on the
            // phone, 24 dp on the desktop).
            anchors.leftMargin: Theme.touch ? Theme.s3 : Theme.s4
            anchors.rightMargin: Theme.touch ? Theme.s2 : Theme.s3
            spacing: Theme.s2

            // Back: only when the page is a child of another. Round
            // button.
            Rectangle {
                visible: top.showBack
                Layout.alignment: Qt.AlignVCenter
                width: Theme.rowThin
                height: Theme.rowThin
                radius: width / 2
                antialiasing: true
                color: backHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
                Glyph {
                    anchors.centerIn: parent
                    width: 16; height: 16
                    kind: "chevron-left"
                    color: Sys.text
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.backRequested() }
                }
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                text: top.title
                color: Sys.text
                font.pixelSize: Theme.touch ? Theme.tXl : Theme.tLg
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
                antialiasing: true
                color: launcherHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                HoverHandler { id: launcherHover; cursorShape: Qt.PointingHandCursor }
                Glyph {
                    anchors.centerIn: parent
                    width: 17; height: 17
                    kind: "search"
                    // Touch has no hover: the icon cannot be "off"
                    // (textDim on the dark surface was unreadable).
                    color: (launcherHover.hovered || Theme.touch) ? Sys.text : Theme.tDim(Sys.bg, Sys.text)
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.launcherRequested() }
                }
            }

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: Theme.rowThin
                height: Theme.rowThin
                radius: width / 2
                antialiasing: true
                color: gearHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                HoverHandler { id: gearHover; cursorShape: Qt.PointingHandCursor }
                Glyph {
                    anchors.centerIn: parent
                    width: 17; height: 17
                    kind: "gear"
                    color: (gearHover.hovered || Theme.touch) ? Sys.text : Theme.tDim(Sys.bg, Sys.text)
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.settingsRequested() }
                }
            }
        }
    }
}
