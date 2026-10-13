import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Rail de navegación. Reposo: una columna estrecha sólo con iconos (68 px).
// Al pasar el ratón se expande (232 px) y aparecen las etiquetas, las listas
// guardadas y la tarjeta "sonando ahora". Es el mismo conjunto de funciones
// que antes, pero en una superficie mucho más silenciosa: nada de cabeceras
// que compitan con el contenido.
Rectangle {
    id: side

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

    color: Sys.bg

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

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        spacing: 0

        // ---- identidad ------------------------------------------------
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            Layout.topMargin: 18
            Layout.bottomMargin: 14

            Rectangle {
                width: 30
                height: 30
                anchors.verticalCenter: parent.verticalCenter
                x: side.expanded ? 7 : (parent.width - width) / 2
                radius: Theme.rMd
                color: Sys.accentDim
                LotusMark {
                    anchors.centerIn: parent
                    width: 18
                    height: 17
                    petalColor: Sys.accent
                    active: side.playing
                }
            }
            ColumnLayout {
                visible: side.expanded
                anchors.left: parent.left
                anchors.leftMargin: 46
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                Text {
                    text: "Lotus Tune"
                    color: Sys.text
                    font.pixelSize: Theme.tLg
                    font.weight: Font.DemiBold
                }
                Text {
                    text: "minimal"
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    font.letterSpacing: 1.4
                    opacity: 0.7
                }
            }
        }

        // ---- navegación ----------------------------------------------
        Repeater {
            model: side.navItems
            delegate: Rectangle {
                required property var modelData
                id: navRow
                readonly property bool on: side.page === modelData.id

                Layout.fillWidth: true
                Layout.preferredHeight: 40
                Layout.topMargin: 2
                radius: Theme.rMd
                color: navRow.on ? Sys.accentDim
                                 : (navHover.hovered ? Theme.hover(Sys.bg) : "transparent")
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                HoverHandler { id: navHover; cursorShape: Qt.PointingHandCursor }

                // Filo de acento: marca la sección activa sin rellenar la fila.
                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: 15
                    radius: 2
                    color: Sys.accent
                    visible: navRow.on && side.expanded
                }

                Glyph {
                    width: 19
                    height: 19
                    anchors.verticalCenter: parent.verticalCenter
                    x: side.expanded ? 7 : (parent.width - width) / 2
                    kind: navRow.modelData.icon
                    color: navRow.on ? Sys.accent : Sys.textDim
                }
                Text {
                    visible: side.expanded
                    anchors.left: parent.left
                    anchors.leftMargin: 36
                    anchors.verticalCenter: parent.verticalCenter
                    text: navRow.modelData.label
                    color: navRow.on ? Sys.text : Sys.textDim
                    font.pixelSize: Theme.tBase
                    font.weight: navRow.on ? Font.DemiBold : Font.Medium
                }

                TapHandler { onTapped: side.activate(navRow.modelData.id) }
            }
        }

        // ---- Tus listas (sólo expandido) ------------------------------
        Text {
            visible: side.expanded
            Layout.leftMargin: 7
            Layout.topMargin: Theme.s5
            Layout.bottomMargin: Theme.s2
            text: "TUS LISTAS"
            color: Sys.textDim
            font.pixelSize: Theme.tXs
            font.weight: Font.DemiBold
            font.letterSpacing: 1.4
            opacity: 0.8
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
                spacing: 1

                Repeater {
                    model: catalog.ytmLibrary
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        id: ytmRow
                        Layout.fillWidth: true
                        height: 34
                        radius: Theme.rSm
                        color: listHover.hovered ? Theme.hover(Sys.bg) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                        HoverHandler { id: listHover; cursorShape: Qt.PointingHandCursor }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 10
                            Glyph {
                                Layout.preferredWidth: 14
                                Layout.preferredHeight: 14
                                Layout.alignment: Qt.AlignVCenter
                                kind: "list"
                                color: listHover.hovered ? Sys.accent : Sys.textDim
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
                                color: Sys.accent
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.RightButton)
                                    side.ytmlistContextRequested(modelData,
                                                                 mouse.scenePos.x,
                                                                 mouse.scenePos.y)
                                else
                                    side.ytmlistRequested(modelData.url || "",
                                                          modelData.name || "")
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
                        height: 34
                        radius: Theme.rSm
                        color: plHover.hovered ? Theme.hover(Sys.bg) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                        HoverHandler { id: plHover; cursorShape: Qt.PointingHandCursor }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 10
                            Glyph {
                                Layout.preferredWidth: 14
                                Layout.preferredHeight: 14
                                Layout.alignment: Qt.AlignVCenter
                                kind: "music"
                                color: plHover.hovered ? Sys.accent : Sys.textDim
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
                                if (mouse.button === Qt.RightButton)
                                    side.playlistContextRequested(modelData,
                                                                  mouse.scenePos.x,
                                                                  mouse.scenePos.y)
                                else
                                    side.playlistRequested(index)
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
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
            Layout.bottomMargin: Theme.s2
            height: 44
            radius: Theme.rMd
            color: nowHover.hovered ? Theme.hover(Sys.bg) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            HoverHandler { id: nowHover; cursorShape: Qt.PointingHandCursor }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 8
                spacing: 10

                Rectangle {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.rSm
                    color: Sys.surfaceAlt
                    clip: true
                    Image {
                        id: miniCover
                        anchors.fill: parent
                        source: side.trackThumb
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        visible: status === Image.Ready
                    }
                    LotusMark {
                        anchors.centerIn: parent
                        width: 16
                        height: 15
                        petalColor: Sys.accent
                        active: side.playing
                        visible: miniCover.status !== Image.Ready
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

            TapHandler { onTapped: side.nowPlayingRequested() }
        }

        // ---- ajustes --------------------------------------------------
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            Layout.bottomMargin: Theme.s3

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: side.expanded ? 0 : 2
                anchors.rightMargin: side.expanded ? 0 : 2
                radius: Theme.rMd
                color: setHover.hovered ? Theme.hover(Sys.bg) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            }
            HoverHandler { id: setHover; cursorShape: Qt.PointingHandCursor }

            Glyph {
                width: 18
                height: 18
                anchors.verticalCenter: parent.verticalCenter
                x: side.expanded ? 7 : (parent.width - width) / 2
                kind: "gear"
                color: setHover.hovered ? Sys.accent : Sys.textDim
            }
            RowLayout {
                visible: side.expanded
                anchors.left: parent.left
                anchors.leftMargin: 36
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    text: "Ajustes"
                    color: setHover.hovered ? Sys.text : Sys.textDim
                    font.pixelSize: Theme.tBase
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: "Ctrl+,"
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    opacity: 0.55
                }
            }
            TapHandler { onTapped: side.settingsRequested() }
        }
    }
}
