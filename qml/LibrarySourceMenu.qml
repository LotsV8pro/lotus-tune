import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Desplegable de fuentes de la Biblioteca.
//
// Disparador con la fuente actual (icono + nombre + estado) y panel que se
// despliega en línea con TODAS las fuentes de audio disponibles, incluida la
// entrada «Local / Descargas». Cada entrada muestra nombre, estado
// (Lista/Bloqueada), nº de listas y una tira con las portadas de sus listas.
//
// Nunca se reproduce nada aquí: al elegir una fuente solo se emite `selected`
// (la página cambia el contenido de debajo) o `toggled` (abrir/cerrar).
ColumnLayout {
    id: root

    property string currentId: "ytm"
    property var entries: []      // [{ id, name, status, note, count, thumbs }]
    property bool open: false

    signal selected(string id)
    signal toggled(bool open)

    spacing: Theme.s2

    readonly property var currentEntry: {
        for (var i = 0; i < entries.length; i++)
            if (entries[i].id === currentId)
                return entries[i]
        return null
    }

    function iconFor(id) {
        if (id === "local") return "download"
        if (id === "ytm") return "music"
        if (id === "soundcloud") return "radio"
        if (id === "spotify" || id === "tidal") return "disc"
        return "grid"
    }
    function statusText(e) { return e && e.status === "ready" ? "Lista" : "Bloqueada" }
    function countText(e) {
        if (!e) return ""
        const n = e.count || 0
        if (n <= 0) return ""
        return e.id === "local" ? (n + " pistas") : (n + " listas")
    }
    function metaText(e) {
        if (!e) return ""
        const s = statusText(e)
        const c = countText(e)
        return c ? (s + " · " + c) : s
    }

    // ---- disparador ----------------------------------------------------
    Rectangle {
        id: trigger
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.rowCompact
        radius: Theme.rMd
        color: root.open ? Sys.surface
                         : (trigMa.containsMouse ? Theme.hover(Sys.bg) : "transparent")
        border.width: root.open ? 1 : 0
        border.color: Sys.borderSubtle
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.s3
            anchors.rightMargin: Theme.s3
            spacing: Theme.s3

            Rectangle {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                radius: Theme.rMd
                color: Sys.accentDim
                Glyph {
                    anchors.centerIn: parent
                    width: 15
                    height: 15
                    kind: root.iconFor(root.currentId)
                    color: Sys.accent
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    Layout.fillWidth: true
                    text: "FUENTE DE LA BIBLIOTECA"
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    font.letterSpacing: 1.2
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                Text {
                    Layout.fillWidth: true
                    text: root.currentEntry ? root.currentEntry.name : String(root.currentId)
                    color: Sys.text
                    font.pixelSize: Theme.tLg
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }

            Text {
                text: root.metaText(root.currentEntry)
                color: (root.currentEntry && root.currentEntry.status !== "ready")
                       ? Sys.textDim : Sys.accent
                font.pixelSize: Theme.tSm
                font.weight: Font.Medium
            }

            Glyph {
                width: 16
                height: 16
                kind: "chevron-down"
                rotation: root.open ? 180 : 0
                color: (root.open || trigMa.containsMouse) ? Sys.accent : Sys.textDim
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            }
        }

        MouseArea {
            id: trigMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggled(!root.open)
        }
    }

    // ---- panel desplegable (en línea: empuja el contenido) -------------
    Rectangle {
        id: panel
        Layout.fillWidth: true
        implicitHeight: root.open ? panelCol.implicitHeight + Theme.s4 : 0
        visible: implicitHeight > 0
        radius: Theme.rLg
        color: Sys.surface
        border.width: 1
        border.color: Sys.borderSubtle
        clip: true
        Behavior on implicitHeight {
            NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic }
        }

        ColumnLayout {
            id: panelCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Theme.s2
            anchors.rightMargin: Theme.s2
            anchors.topMargin: Theme.s2
            spacing: Theme.s1

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.s2
                Layout.rightMargin: Theme.s2
                Layout.topMargin: Theme.s1
                Layout.bottomMargin: Theme.s1
                spacing: Theme.s2
                Text {
                    text: "FUENTES DE AUDIO"
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    font.letterSpacing: 1.2
                    font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: "Elige una fuente para ver sus listas"
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                }
            }

            Repeater {
                model: root.entries

                delegate: Rectangle {
                    id: ent
                    required property var modelData

                    readonly property bool isCurrent: root.currentId === modelData.id
                    readonly property bool isLocked: modelData.status !== "ready"

                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.rowCompact
                    radius: Theme.rMd
                    color: ent.isCurrent ? Sys.accentDim
                           : (entMa.containsMouse ? Theme.hover(Sys.surface)
                                                  : "transparent")
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s2
                        anchors.rightMargin: Theme.s3
                        spacing: Theme.s3

                        Rectangle {
                            Layout.preferredWidth: 30
                            Layout.preferredHeight: 30
                            radius: Theme.rMd
                            color: ent.isLocked ? Sys.surfaceAlt : Sys.accentDim
                            Glyph {
                                anchors.centerIn: parent
                                width: 15
                                height: 15
                                kind: root.iconFor(ent.modelData.id)
                                color: ent.isLocked ? Sys.textDim
                                       : (ent.isCurrent ? Sys.accent : Sys.text)
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: ent.modelData.name || ""
                                color: ent.isCurrent ? Sys.accent : Sys.text
                                font.pixelSize: Theme.tBase
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.metaText(ent.modelData)
                                color: Sys.textDim
                                font.pixelSize: Theme.tSm
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        // portadas de las listas de esta fuente
                        Row {
                            spacing: Theme.s1
                            visible: !ent.isLocked
                                     && (ent.modelData.thumbs || []).length > 0
                            Repeater {
                                model: Math.min(4, (ent.modelData.thumbs || []).length)
                                delegate: Rectangle {
                                    required property int index
                                    width: 26
                                    height: 26
                                    radius: Theme.rMd
                                    clip: true
                                    color: Sys.surfaceAlt
                                    Image {
                                        anchors.fill: parent
                                        source: (ent.modelData.thumbs || [])[index] || ""
                                        sourceSize.width: 52
                                        sourceSize.height: 52
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        cache: true
                                    }
                                }
                            }
                        }

                        Glyph {
                            width: 15
                            height: 15
                            kind: ent.isLocked ? "lock" : "check"
                            visible: ent.isLocked || ent.isCurrent
                            color: ent.isCurrent ? Sys.accent : Sys.textDim
                        }
                    }

                    MouseArea {
                        id: entMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selected(ent.modelData.id)
                    }
                }
            }
        }
    }
}
