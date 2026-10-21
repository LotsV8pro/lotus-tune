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
    readonly property int collapsedW: 76
    readonly property int expandedW: 236
    // El rail NO se despliega al pasar el ratón: se queda siempre en la
    // columna estrecha de iconos, sin que el contenido de la página baile
    // de ancho al mover el ratón por encima. Las listas viven en
    // Biblioteca.
    property bool expanded: false
    // La altura de esta propiedad la lee Main.qml para reservar el ancho.
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

                    // Todas las entradas caben en la columna estrecha (icono
                    // con su etiqueta debajo), así no hay nada escondido:
                    // con el rail fijo no hay «desplegar» donde buscar.
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

            // Hueco flexible: el rail queda sólo con la navegación.
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}
