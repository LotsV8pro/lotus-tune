import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Navigation rail. Folded (primary state): a narrow column with the main
// sections, icon + short label.
//
// The whole rail lives on ONE floating island (`Panel`): the window
// background shows around it and the component only paints transparent
// content on top. Same public API as before; only the painting changed.
Item {
    id: side

    // Active rail destination: usually the current page, but Main resolves
    // it to "downloads" when the Library page shows the local source (so
    // "Downloads" lights up instead of "Library").
    property string page: "home"
    property string trackTitle: ""
    property string trackArtist: ""
    property string trackThumb: ""
    property bool playing: false
    property string engineStatus: ""

    signal navigate(string page)
    signal settingsRequested()
    signal nowPlayingRequested()
    signal likedRequested()
    signal downloadsRequested()
    signal playlistRequested(int index)
    signal ytmlistRequested(string url, string name)
    // Right click on a list: context menu (x/y in window coordinates).
    signal ytmlistContextRequested(var item, real x, real y)
    signal playlistContextRequested(var item, real x, real y)

    // ---- rail geometry ------------------------------------------------
    readonly property int collapsedW: 76
    readonly property int expandedW: 236
    // The rail does NOT expand on hover: it stays in the narrow column of
    // icons, so the page content never changes width as the mouse moves
    // over it. The lists live in the Library.
    property bool expanded: false
    // Main.qml reads this property to reserve the width.
    property real railWidth: expanded ? expandedW : collapsedW
    Behavior on railWidth {
        NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic }
    }

    function activate(id) {
        if (id === "liked")
            side.likedRequested()
        else if (id === "downloads")
            side.downloadsRequested()
        else
            side.navigate(id)
    }

    // ---- sections ------------------------------------------------------
    readonly property var navItems: [
        { id: "home",      label: "Inicio",     icon: "home" },
        { id: "search",    label: "Buscar",     icon: "search" },
        { id: "library",   label: "Biblioteca", icon: "library" },
        { id: "liked",     label: "Me gusta",   icon: "heart" },
        { id: "downloads", label: "Descargas",  icon: "download" }
    ]

    // Flat, like the reference repo: the rail sits straight on the
    // background (no box); the hierarchy is marked by the highlight of the
    // active section.
    Panel {
        anchors.fill: parent
        radius: Theme.rPanel
        color: "transparent"

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.s2
            spacing: 0

            // Brand: the five-petal lotus marks the app at the top of the
            // rail (it came back: the old header used to carry it).
            LotusMark {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.s1
                petalColor: Sys.accent
                active: side.playing
            }

            // Small spacer under the brand, and the navigation follows.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.s2
            }

            // ---- navigation ------------------------------------------------
            // Icon + label under it, for every section.
            Repeater {
                model: side.navItems
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    id: navRow
                    // `page` already comes resolved to a concrete
                    // destination (Main decides between "library" and
                    // "downloads" depending on the active source/tab).
                    readonly property bool on: side.page === modelData.id
                    readonly property bool primary: index < 3

                    // Every entry fits in the narrow column (icon with its
                    // label below), so nothing is hidden: with a fixed rail
                    // there is no "expand" to look for.
                    visible: true
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.rowCompact
                    Layout.topMargin: !side.expanded ? Theme.s1
                                      : (index === 3 ? Theme.s4 : Theme.s2)
                    radius: Theme.rPill
                    color: navRow.on ? Sys.accentDim
                                     : (navHover.hovered ? Theme.hover(Sys.surface) : "transparent")
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    HoverHandler { id: navHover; cursorShape: Qt.PointingHandCursor }

                    Glyph {
                        id: navGlyph
                        width: 19
                        height: 19
                        kind: navRow.modelData.icon
                        color: navRow.on ? Sys.accent
                                         : (navHover.hovered ? Sys.text : Sys.textDim)
                        weight: navRow.on ? 1.9 : 1.6
                        x: side.expanded ? 12 : (parent.width - width) / 2
                        y: side.expanded ? (parent.height - height) / 2
                                         : (parent.height - height) / 2 - 7
                        Behavior on x { NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic } }
                        Behavior on y { NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic } }
                    }

                    Text {
                        id: navLabel
                        text: navRow.modelData.label
                        color: navRow.on ? Sys.text : Sys.textDim
                        font.pixelSize: side.expanded ? Theme.tBase : Theme.tXs
                        font.weight: navRow.on ? Font.DemiBold : Font.Medium
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        horizontalAlignment: side.expanded ? Text.AlignLeft : Text.AlignHCenter
                        width: side.expanded ? parent.width - 46 : parent.width
                        x: side.expanded ? 40 : 0
                        y: side.expanded ? (parent.height - height) / 2
                                         : navGlyph.y + navGlyph.height + 3
                        Behavior on x { NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic } }
                        Behavior on y { NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic } }
                    }

                    TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); side.activate(navRow.modelData.id) } }
                }
            }

            // Flexible spacer: the rail keeps only the navigation.
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}
