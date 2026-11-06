import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Barra de navegacion, copiada de la referencia (tryliner/desktop):
//
//   - 58 px de ancho, esquinas de 12, fondo "glass" y sin borde.
//   - Iconos de 26 px, SIN etiqueta, centrados, separados 20 px.
//   - El activo va a opacidad 1; el resto al 55 % (90 % al pasar el raton).
//   - Arriba Inicio / Buscar / Biblioteca. Abajo, separados, el resto y
//     Ajustes en ultimo lugar.
//
// La API publica (signals y propiedades) es la misma de siempre: Main no
// cambia.
Item {
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
    signal ytmlistContextRequested(var item, real x, real y)
    signal playlistContextRequested(var item, real x, real y)

    // ---- geometria (referencia: 58 px) --------------------------------
    readonly property int collapsedW: 58
    readonly property int expandedW: 236
    property bool expanded: false
    property real railWidth: expanded ? expandedW : collapsedW
    Behavior on railWidth {
        NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic }
    }

    // Iconos de la barra: tamano y aire, tal cual la referencia.
    readonly property int iconSize: 26
    readonly property int itemSize: 40
    readonly property int itemGap: 8

    function activate(id) {
        if (id === "liked")
            side.likedRequested()
        else if (id === "downloads")
            side.downloadsRequested()
        else if (id === "settings")
            side.settingsRequested()
        else
            side.navigate(id)
    }

    // Arriba: las tres secciones principales.
    readonly property var topItems: [
        { id: "home",    label: "Inicio",     icon: "home" },
        { id: "search",  label: "Buscar",     icon: "search" },
        { id: "library", label: "Biblioteca", icon: "library" }
    ]
    // Abajo: lo demas y Ajustes, en ultimo lugar (como la referencia).
    readonly property var bottomItems: [
        { id: "liked",     label: "Me gusta",  icon: "heart" },
        { id: "downloads", label: "Descargas", icon: "download" },
        { id: "settings",  label: "Ajustes",   icon: "gear" }
    ]

    Panel {
        anchors.fill: parent
        radius: 12
        // Solid: the rail is a floating island over the pages, so the
        // content must not show through it.
        color: Sys.surface
        borderWidth: 0

        ColumnLayout {
            anchors.fill: parent
            anchors.topMargin: 16
            anchors.bottomMargin: 16
            spacing: 0

            // Marca de la app arriba del todo (la referencia lleva el logo
            // en la barra de titulo; aqui no hay barra, asi que va aqui).
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                Layout.bottomMargin: Theme.s4
                LotusMark {
                    anchors.centerIn: parent
                    width: 24
                    height: 24
                    petalColor: Sys.accent
                    active: side.playing
                }
            }

            // ---- grupo de arriba ------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                spacing: side.itemGap

                Repeater {
                    model: side.topItems
                    delegate: SideNavButton {
                        required property var modelData
                        icon: modelData.icon
                        active: side.page === modelData.id
                        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); side.activate(modelData.id) }
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.fillHeight: true }

            // ---- grupo de abajo --------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                spacing: side.itemGap

                Repeater {
                    model: side.bottomItems
                    delegate: SideNavButton {
                        required property var modelData
                        icon: modelData.icon
                        active: side.page === modelData.id
                        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); side.activate(modelData.id) }
                    }
                }
            }
        }
    }

    // Un icono de la barra: 40x40, sin etiqueta ni caja; el activo va
    // blanco y el resto al 55 %. Se hunde un poco al pulsarlo.
    component SideNavButton: Item {
        id: btn

        property string icon: "home"
        property bool active: false
        signal activated()

        Layout.fillWidth: true
        Layout.preferredHeight: side.itemSize

        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }

        Glyph {
            anchors.centerIn: parent
            width: side.iconSize
            height: side.iconSize
            kind: btn.icon
            weight: btn.active ? 1.9 : 1.6
            color: Sys.text
            opacity: btn.active ? 1.0 : (hover.hovered ? 0.9 : 0.55)
            Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
        }

        scale: tap.pressed ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: 90 } }

        TapHandler { id: tap; onTapped: btn.activated() }
    }
}
