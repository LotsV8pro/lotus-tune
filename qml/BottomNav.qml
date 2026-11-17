import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Bottom navigation bar (phone only). The desktop navigation rail folds
// into a horizontal tab bar: five fixed sections, icon over label, the
// active one highlighted with the accent pill. Flat, like every island:
// one transparent Panel, glyph + text, no extra layers.
//
// Inicio is the hero tab: the app's lotus mark and a soft accent halo.
// Order: Biblioteca, Buscar, Inicio, Me gusta, Descargas. Downloads opens
// the "Descargadas" tab of LibraryPage. `w` is the relative
// width each cell claims; `Layout.minimumWidth` keeps the touch floor when
// the layout gets squeezed.
Item {
    id: bar

    // Current destination, already resolved ("library" vs "downloads")
    // by Main, exactly what the rail receives.
    property string page: "home"

    signal navigate(string page)
    signal likedRequested()

    // Height: one comfortable touch row (glyph + label + margins). On the
    // phone it grows a step so the labels are not glued to the edge.
    implicitHeight: Theme.touch ? 60 : 54

    // Readable accent: the raw accent comes from the wallpaper and can be
    // as dark as #1a1a1a, which made the active tab invisible.
    readonly property color _acc: Theme.accentOn(Sys.accent, Sys.bg)
    readonly property color _quiet: Theme.mix(Sys.bg, Sys.text, 0.74)
    readonly property color _label: Theme.tDim(Sys.bg, Sys.text)

    function activate(id) {
        if (id === "liked")
            bar.likedRequested()
        else
            bar.navigate(id)
    }

    // Five equal cells. Inicio keeps the lotus mark, the bigger glyph and
    // halo of the hero tab; every cell stays above the 48 dp touch floor.
    readonly property var items: [
        { id: "library",   label: qsTr("Biblioteca"), icon: "library",   w: 1.0, big: false },
        { id: "search",    label: qsTr("Buscar"),     icon: "search",    w: 1.0, big: false },
        { id: "home",      label: qsTr("Inicio"),     icon: "logo",      w: 1.0, big: true },
        { id: "liked",     label: qsTr("Me gusta"),   icon: "heart",     w: 1.0, big: false },
        { id: "downloads", label: qsTr("Descargas"),  icon: "download",  w: 1.0, big: false }
    ]

    // Same island as the desktop rail (Sidebar.qml): a faint light wash
    // over the dynamic background, radius 12, no edge. On the phone it is
    // the only nav surface, so it needs the same body the rail has.
    Panel {
        anchors.fill: parent
        radius: 12
        antialiasing: true
        // Solid: the tab bar floats over the pages (and over the artist
        // page), so the content must not show through it.
        color: Sys.surface
        borderWidth: 0

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

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // Five equal cells, each above the 48 dp touch floor.
                    Layout.preferredWidth: 100 * modelData.w
                    Layout.minimumWidth: 56
                    radius: Theme.rPill
                    antialiasing: true
                    // Active = a soft accent tint (16 %) plus the accent
                    // itself on the glyph/label (5.7:1 on the tint). Inactive
                    // = quiet grey, readable but clearly "off".
                    color: navCell.on ? Theme.alpha(bar._acc, 0.16)
                                      : (navHold.pressed ? Theme.sHigh(Sys.bg, Sys.text)
                                                         : "transparent")
                    scale: navHold.pressed ? 0.96 : 1
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    HoverHandler { id: navHold; cursorShape: Qt.PointingHandCursor }

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
                                antialiasing: true
                                color: bar._acc
                                opacity: navCell.on ? 0.20 : 0.0
                                Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
                            }

                            LotusMark {
                                anchors.centerIn: parent
                                visible: navCell.modelData.icon === "logo"
                                width: 24
                                height: 24
                                petalColor: navCell.on ? bar._acc : bar._quiet
                            }
                            Glyph {
                                anchors.centerIn: parent
                                visible: navCell.modelData.icon !== "logo"
                                width: navCell.big ? 26 : 20
                                height: navCell.big ? 26 : 20
                                kind: navCell.modelData.icon
                                // Inactive tabs stay clearly visible: the full
                                // text color at icon weight, the accent only
                                // marks the active one.
                                color: navCell.on ? bar._acc : bar._quiet
                                weight: navCell.on ? 1.9 : 1.5
                                opacity: 1.0
                                // Slight lift for the active hero tab.
                                scale: navCell.on && navCell.big ? 1.08 : 1.0
                                Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                            }
                        }

                        Text {
                            text: navCell.modelData.label
                            color: navCell.on ? bar._acc : bar._label
                            opacity: 1.0
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

                    // MouseArea, not TapHandler: on the phone build the
                    // TapHandler never fired with touch and the tab bar
                    // was dead (the rest of the app, all MouseArea,
                    // answered fine).
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
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
