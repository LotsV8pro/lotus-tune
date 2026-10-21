import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Rail de navegación. Plegado (estado primario): una columna estrecha con las
// tres secciones principales, icono + etiqueta corta. Al pasar el ratón se
// expande y aparecen las entradas secundarias, las listas y "sonando ahora".
//
// Todo el rail vive sobre UNA sola isla flotante (`Panel`): el fondo de la
// ventana asoma alrededor y el componente sólo pinta contenido transparente
// encima. Misma API pública que antes; sólo cambia cómo se pinta.
Item {
    id: side

    // Destino activo del rail: normalmente la página actual, pero Main lo
    // resuelve a "downloads" cuando la página Biblioteca está mostrando la
    // fuente local (para que se ilumine "Descargas" y no "Biblioteca").
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
    // Clic derecho sobre una lista: menú contextual (x/y en ventana).
    signal ytmlistContextRequested(var item, real x, real y)
    signal playlistContextRequested(var item, real x, real y)

    // ---- geometría del rail -------------------------------------------
    readonly property int collapsedW: 68
    readonly property int expandedW: 236
    property bool expanded: false
    // La altura de esta propiedad la lee Main.qml para reservar el ancho.
    property real railWidth: expanded ? expandedW : collapsedW
    Behavior on railWidth {
        NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic }
    }

    HoverHandler {
        id: railHover
        onHoveredChanged: side.expanded = railHover.hovered
    }

    function activate(id) {
        if (id === "liked")
            side.likedRequested()
        else if (id === "downloads")
            side.downloadsRequested()
        else
            side.navigate(id)
    }

    // ---- secciones -----------------------------------------------------
    readonly property var navItems: [
        { id: "home",      label: "Inicio",     icon: "home" },
        { id: "search",    label: "Buscar",     icon: "search" },
        { id: "library",   label: "Biblioteca", icon: "library" },
        { id: "liked",     label: "Me gusta",   icon: "heart" },
        { id: "downloads", label: "Descargas",  icon: "download" }
    ]

    // Plano, al estilo del repo de referencia: el rail va directo sobre el
    // fondo (sin caja); la jerarquía la marca el resaltado de la sección activa.
    Panel {
        anchors.fill: parent
        radius: Theme.rPanel
        color: "transparent"

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.s2
            spacing: 0

            // Aire superior: sustituye a la vieja cabecera de marca.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.s2
            }

            // ---- navegación ----------------------------------------------
            // Plegado: sólo las tres secciones principales (icono + etiqueta).
            // Expandido: se añaden "Me gusta" y "Descargas" con más aire.
            Repeater {
                model: side.navItems
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    id: navRow
                    // `page` ya viene resuelto a un destino concreto (Main decide
                    // si toca "library" o "downloads" según la fuente/tab activas).
                    readonly property bool on: side.page === modelData.id
                    readonly property bool primary: index < 3

                    // La entrada activa se marca con una PÍLDORA (cápsula) y se
                    // mantiene visible aunque el rail esté plegado: así "Descargas"
                    // o "Me gusta" siguen iluminadas sin tener que desplegar.
                    visible: side.expanded || navRow.primary || navRow.on
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

            // ---- Tus listas (sólo expandido) ------------------------------
            // Sin líneas: la jerarquía la marca el aire, no un separador.
            Text {
                visible: side.expanded
                Layout.leftMargin: Theme.s1
                Layout.topMargin: Theme.s3
                Layout.bottomMargin: Theme.s1
                text: "TUS LISTAS"
                color: Sys.textDim
                font.pixelSize: Theme.tXs
                font.weight: Font.DemiBold
                font.letterSpacing: 1.4
                opacity: 0.75
            }

            Flickable {
                visible: side.expanded
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentHeight: listsCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: listsCol
                    width: parent.width
                    spacing: Theme.s1

                    Repeater {
                        model: catalog.ytmLibrary
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            id: ytmRow
                            Layout.fillWidth: true
                            height: Theme.rowThin
                            radius: Theme.rMd
                            color: listHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                            HoverHandler { id: listHover; cursorShape: Qt.PointingHandCursor }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s2
                                anchors.rightMargin: Theme.s2
                                spacing: 10
                                Glyph {
                                    Layout.preferredWidth: 14
                                    Layout.preferredHeight: 14
                                    Layout.alignment: Qt.AlignVCenter
                                    kind: "list"
                                    color: listHover.hovered ? Sys.text : Sys.textDim
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.name || "Sin nombre"
                                    color: listHover.hovered ? Sys.text : Sys.textDim
                                    font.pixelSize: Theme.tMd
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                Glyph {
                                    Layout.preferredWidth: 12
                                    Layout.preferredHeight: 12
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: modelData.owned === true
                                    kind: "user"
                                    color: Sys.textDim
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: (mouse) => {
                                    if (typeof sfx !== 'undefined') sfx.play('tap')
                                    if (mouse.button === Qt.RightButton) {
                                        const p = mapToItem(null, mouse.x, mouse.y)
                                        side.ytmlistContextRequested(modelData, p.x, p.y)
                                    } else {
                                        side.ytmlistRequested(modelData.url || "",
                                                              modelData.name || "")
                                    }
                                }
                            }
                        }
                    }

                    Repeater {
                        model: catalog.playlists
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            id: plRow
                            Layout.fillWidth: true
                            height: Theme.rowThin
                            radius: Theme.rMd
                            color: plHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                            HoverHandler { id: plHover; cursorShape: Qt.PointingHandCursor }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s2
                                anchors.rightMargin: Theme.s2
                                spacing: 10
                                Glyph {
                                    Layout.preferredWidth: 14
                                    Layout.preferredHeight: 14
                                    Layout.alignment: Qt.AlignVCenter
                                    kind: "music"
                                    color: plHover.hovered ? Sys.text : Sys.textDim
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.name || "Sin nombre"
                                    color: plHover.hovered ? Sys.text : Sys.textDim
                                    font.pixelSize: Theme.tMd
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: (mouse) => {
                                    if (typeof sfx !== 'undefined') sfx.play('tap')
                                    if (mouse.button === Qt.RightButton) {
                                        const p = mapToItem(null, mouse.x, mouse.y)
                                        side.playlistContextRequested(modelData, p.x, p.y)
                                    } else {
                                        side.playlistRequested(index)
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.s1
                        Layout.topMargin: Theme.s2
                        visible: catalog.playlists.length === 0
                                 && catalog.ytmLibrary.length === 0
                        text: "Aún no hay listas."
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                        opacity: 0.7
                    }
                }
            }

            // Hueco flexible cuando el rail está plegado.
            Item {
                visible: !side.expanded
                Layout.fillWidth: true
                Layout.fillHeight: true
            }

            // ---- sonando ahora (sólo expandido) ---------------------------
            Rectangle {
                visible: side.expanded
                Layout.fillWidth: true
                Layout.topMargin: Theme.s2
                Layout.bottomMargin: Theme.s1
                height: 44
                radius: Theme.rMd
                color: nowHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                HoverHandler { id: nowHover; cursorShape: Qt.PointingHandCursor }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 4
                    anchors.rightMargin: Theme.s2
                    spacing: 10

                    Rectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        Layout.alignment: Qt.AlignVCenter
                        radius: Theme.rSm
                        color: Sys.surfaceAlt
                        clip: true
                        RoundedArt {
                            id: miniCover
                            anchors.fill: parent
                            source: side.trackThumb
                            radiusSpec: Theme.rSm
                        }
                        LotusMark {
                            anchors.centerIn: parent
                            width: 16
                            height: 15
                            petalColor: Sys.accent
                            visible: !miniCover.ready
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: side.trackTitle.length ? side.trackTitle : "Nada en cola"
                            color: side.trackTitle.length ? Sys.text : Sys.textDim
                            font.pixelSize: Theme.tMd
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        Text {
                            Layout.fillWidth: true
                            text: side.trackArtist.length ? side.trackArtist : "—"
                            color: Sys.textDim
                            font.pixelSize: Theme.tXs
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }
                }

                TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); side.nowPlayingRequested() } }
            }

            // ---- ajustes (sólo expandido) ---------------------------------
            Item {
                visible: side.expanded
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                Layout.bottomMargin: Theme.s2

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.rMd
                    color: setHover.hovered ? Theme.hover(Sys.surface) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }
                HoverHandler { id: setHover; cursorShape: Qt.PointingHandCursor }

                Glyph {
                    width: 18
                    height: 18
                    anchors.verticalCenter: parent.verticalCenter
                    x: 10
                    kind: "gear"
                    color: setHover.hovered ? Sys.text : Sys.textDim
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 36
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Ajustes"
                    color: setHover.hovered ? Sys.text : Sys.textDim
                    font.pixelSize: Theme.tBase
                }
                TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); side.settingsRequested() } }
            }
        }
    }
}
