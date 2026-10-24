import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Bottom navigation bar (phone only). The desktop navigation rail folds
// into a horizontal tab bar: five fixed sections, icon over label, the
// active one highlighted with the accent pill. Flat, like every island:
// one transparent Panel, glyph + text, no extra layers.
//
// Inicio sits in the PHYSICAL middle slot (3rd of 5), it is the hero tab:
// bigger glyph and a soft accent halo when active. For the hero to be
// visually centred the two side halves must weigh the SAME (the width the
// hero cell claims does not move its centre: it stays at the exact middle
// of the bar). Order: Biblioteca, Buscar, INICIO, Me gusta, Descargas —
// `w` is the relative width each cell claims (all >= a 48 dp touch floor;
// `Layout.minimumWidth` protects it when the layout gets squeezed).
Item {
    id: bar

    // Current destination, already resolved ("library" vs "downloads")
    // by Main, exactly what the rail receives.
    property string page: "home"

    signal navigate(string page)
    signal likedRequested()
    signal downloadsRequested()

    // Low on purpose: content (20 px glyph + 10 px label + margins)
    // matches Theme.playerBarH so the two bars read as one bottom block.
    implicitHeight: 54

    function activate(id) {
        if (id === "liked")
            bar.likedRequested()
        else if (id === "downloads")
            bar.downloadsRequested()
        else
            bar.navigate(id)
    }

    // Fixed order with Inicio in the middle slot: its 1.4 relative width
    // (the hero) is balanced by the two 1.0 halves on each side, so the
    // hero lands EXACTLY centred: (1.0 + 1.0) + 1.4/2 over a total of
    // 5.4 = 50 %. The "duo" pair (Me gusta + Descargas) keeps the minimum
    // 48 dp touch floor but now weighs like a plain tab.
    readonly property var items: [
        { id: "library",   label: "Biblioteca", icon: "library",  w: 1.0, big: false, duo: false },
        { id: "search",    label: "Buscar",     icon: "search",   w: 1.0, big: false, duo: false },
        { id: "home",      label: "Inicio",     icon: "home",     w: 1.4, big: true,  duo: false },
        { id: "liked",     label: "Me gusta",   icon: "heart",    w: 1.0, big: false, duo: true },
        { id: "downloads", label: "Descargas",  icon: "download", w: 1.0, big: false, duo: true }
    ]

    Panel {
        anchors.fill: parent
        radius: Theme.rPanel
        color: "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.s1
            spacing: 0

            Repeater {
                model: bar.items
                delegate: Rectangle {
                    required property var modelData
                    required property int index

                    id: navCell

                    readonly property bool on: bar.page === modelData.id
                    // Inicio is the hero tab: a bigger glyph and, when
                    // active, a soft accent halo behind it.
                    readonly property bool big: modelData.big === true
                    // Right pair (Me gusta + Descargas): flag only guards
                    // the 48 dp minimum width, they now weigh like the
                    // left plain tabs so the hero's centre is exact.
                    readonly property bool duo: modelData.duo === true

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // Relative weights: the home cell claims ~1.4x of a
                    // plain tab, the duo ~0.8x (still >= 48 dp wide on a
                    // 360 dp screen). minimumWidth protects that touch
                    // floor when the layout gets squeezed.
                    Layout.preferredWidth: 100 * modelData.w
                    Layout.minimumWidth: navCell.duo ? 48 : 56
                    radius: Theme.rPill
                    color: navCell.on ? Sys.accentDim : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 3

                        // Glyph inside an Item so the halo can sit behind
                        // it without adding a slot to the column.
                        Item {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: Theme.s1
                            Layout.preferredWidth: navCell.big ? 28 : 20
                            Layout.preferredHeight: navCell.big ? 28 : 20

                            // Soft halo: the accent at a very low alpha,
                            // only for the active home tab. Keeps the
                            // "no extra layers" rule (one pill, no shadow
                            // effects), it just breathes a little more.
                            Rectangle {
                                visible: navCell.big
                                anchors.fill: parent
                                anchors.margins: navCell.big ? -3 : 0
                                radius: width / 2
                                color: Sys.accent
                                opacity: navCell.on ? 0.16 : 0.0
                                Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
                            }

                            Glyph {
                                anchors.centerIn: parent
                                width: navCell.big ? 26 : 20
                                height: navCell.big ? 26 : 20
                                kind: navCell.modelData.icon
                                // Inactive tabs stay clearly visible: the full
                                // text color at icon weight, the accent only
                                // marks the active one.
                                color: navCell.on ? Sys.accent : Sys.text
                                weight: navCell.on ? 1.9 : 1.5
                                opacity: navCell.on ? 1.0 : 0.82
                                // Slight lift for the active hero tab.
                                scale: navCell.on && navCell.big ? 1.08 : 1.0
                                Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                            }
                        }

                        Text {
                            text: navCell.modelData.label
                            color: navCell.on ? Sys.accent : Sys.text
                            opacity: navCell.on ? 1.0 : 0.68
                            // The hero tab label goes one step up the scale.
                            font.pixelSize: navCell.big ? Theme.tSm : Theme.tXs
                            font.weight: navCell.on ? Font.DemiBold : Font.Medium
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            horizontalAlignment: Text.AlignHCenter
                            Layout.alignment: Qt.AlignHCenter
                            Layout.maximumWidth: navCell.width - Theme.s2
                        }
                    }

                    TapHandler {
                        onTapped: {
                            if (typeof sfx !== 'undefined')
                                sfx.play('tap')
                            bar.activate(navCell.modelData.id)
                        }
                    }
                }
            }
        }
    }
}
