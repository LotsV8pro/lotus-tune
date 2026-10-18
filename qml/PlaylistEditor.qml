import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Editor de listas: crear o editar (nombre + privacidad), al estilo de Sonora.
// Es autónomo: recibe el estado por propiedades y emite `submitted` / 
// `deleteRequested`; Main habla con `catalog`.
Item {
    id: pel

    property bool open: false
    property bool createMode: true
    property string playlistId: ""
    property string initialTitle: ""
    property bool initialPrivate: false
    property string pendingVideoId: ""

    signal submitted(var data)
    signal deleteRequested(string id, string title)
    signal canceled()

    visible: opacity > 0
    opacity: open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

    onOpenChanged: if (open) Qt.callLater(function() {
        nameField.text = pel.createMode ? "" : String(pel.initialTitle || "")
        privToggle.priv = pel.initialPrivate
        nameField.forceActiveFocus()
    })
    // La info real de la lista (fetchPlaylistInfo) puede llegar DESPUÉS de abrir;
    // al llegar, refresca el nombre y la privacidad.
    onInitialTitleChanged: if (open && !pel.createMode) nameField.text = String(pel.initialTitle || "")
    onInitialPrivateChanged: if (open && !pel.createMode) privToggle.priv = pel.initialPrivate

    // Fondo oscuro: clic fuera cancela.
    MouseArea {
        anchors.fill: parent
        onClicked: pel.canceled()
    }

    // Isla flotante: `Panel` da las esquinas redondeadas y el filo luminoso
    // que despega el editor del fondo, sin sombras ni efectos.
    Panel {
        id: card
        anchors.centerIn: parent
        width: Math.min(440, parent.width - 60)
        height: body.implicitHeight + Theme.s6 + Theme.s2
        radius: Theme.rPanel
        scale: pel.open ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic } }

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Theme.s5
            spacing: Theme.s4

            // ---- cabecera ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2
                Glyph {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    kind: pel.createMode ? "plus" : "pencil"
                    color: Sys.accent
                }
                Text {
                    Layout.fillWidth: true
                    text: pel.createMode ? "Nueva lista" : "Editar lista"
                    color: Sys.text
                    font.pixelSize: Theme.tLg
                    font.weight: Font.DemiBold
                }
            }

            // ---- nombre ----
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 42
                radius: Theme.rPill
                color: Sys.bg
                border.width: 1
                border.color: nameField.activeFocus ? Sys.accent : Sys.borderSubtle
                Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

                TextInput {
                    id: nameField
                    anchors.fill: parent
                    anchors.leftMargin: Theme.s3
                    anchors.rightMargin: Theme.s3
                    verticalAlignment: Text.AlignVCenter
                    color: Sys.text
                    font.pixelSize: Theme.tBase
                    clip: true
                    selectByMouse: true
                    Keys.onReturnPressed: (e) => { e.accepted = true; pel.submit() }
                    Keys.onEnterPressed: (e) => { e.accepted = true; pel.submit() }
                }
                Text {
                    visible: nameField.text.length === 0
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.s3
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Nombre de la lista"
                    color: Sys.textDim
                    font.pixelSize: Theme.tBase
                }
            }

            // ---- privacidad ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2

                Text {
                    text: "Privacidad"
                    color: Sys.textDim
                    font.pixelSize: Theme.tMd
                }
                Item { Layout.fillWidth: true }

                Rectangle {
                    id: privToggle
                    property bool priv: false
                    Layout.preferredHeight: Theme.pillH
                    implicitWidth: privLabel.implicitWidth + 26
                    radius: Theme.rPill
                    color: privToggle.priv ? Sys.accentDim : Sys.surfaceAlt
                    border.width: 1
                    border.color: privToggle.priv ? Sys.accent : Sys.border
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 7
                        Glyph {
                            width: 13; height: 13
                            kind: privToggle.priv ? "lock" : "user"
                            color: privToggle.priv ? Sys.accent : Sys.textDim
                        }
                        Text {
                            id: privLabel
                            text: privToggle.priv ? "Privada" : "Pública"
                            color: privToggle.priv ? Sys.accent : Sys.text
                            font.pixelSize: Theme.tMd
                            font.weight: Font.DemiBold
                        }
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); privToggle.priv = !privToggle.priv } }
                }
            }

            // ---- acciones ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2

                Rectangle {
                    visible: !pel.createMode
                    Layout.preferredHeight: 34
                    implicitWidth: delLabel.implicitWidth + 34
                    radius: Theme.rPill
                    color: delHov.hovered
                           ? Qt.rgba(Sys.danger.r, Sys.danger.g, Sys.danger.b, 0.14)
                           : "transparent"
                    border.width: 1
                    border.color: delHov.hovered ? Sys.danger : Sys.border
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 7
                        Glyph {
                            width: 14; height: 14
                            kind: "trash"
                            color: delHov.hovered ? Sys.danger : Sys.textDim
                        }
                        Text {
                            id: delLabel
                            text: "Eliminar"
                            color: delHov.hovered ? Sys.danger : Sys.textDim
                            font.pixelSize: Theme.tMd
                            font.weight: Font.DemiBold
                        }
                    }
                    HoverHandler { id: delHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); pel.deleteRequested(pel.playlistId, pel.initialTitle) }
                    }
                }

                Item { Layout.fillWidth: true }

                Rectangle {
                    Layout.preferredHeight: 34
                    implicitWidth: cancelLabel.implicitWidth + 34
                    radius: Theme.rPill
                    color: cancelHov.hovered ? Theme.hover(Sys.surface) : "transparent"
                    border.width: 1
                    border.color: Sys.border
                    Text {
                        id: cancelLabel
                        anchors.centerIn: parent
                        text: "Cancelar"
                        color: Sys.text
                        font.pixelSize: Theme.tMd
                    }
                    HoverHandler { id: cancelHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); pel.canceled() } }
                }

                Rectangle {
                    Layout.preferredHeight: 34
                    implicitWidth: saveLabel.implicitWidth + 40
                    radius: Theme.rPill
                    enabled: nameField.text.trim().length > 0
                    color: !enabled ? Sys.surfaceAlt
                           : (saveHov.hovered ? Qt.lighter(Sys.accent, 1.12) : Sys.accent)
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Text {
                        id: saveLabel
                        anchors.centerIn: parent
                        text: pel.createMode ? "Crear" : "Guardar"
                        color: enabled ? Sys.onAccent : Sys.textDim
                        font.pixelSize: Theme.tMd
                        font.weight: Font.DemiBold
                    }
                    HoverHandler { id: saveHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler { enabled: nameField.text.trim().length > 0; onTapped: { if (typeof sfx !== "undefined") sfx.play("success"); pel.submit() } }
                }
            }
        }
    }

    function submit() {
        const t = nameField.text.trim()
        if (t.length === 0)
            return
        pel.submitted({
            create: pel.createMode,
            id: pel.playlistId,
            title: t,
            isPrivate: privToggle.priv,
            videoId: pel.pendingVideoId
        })
    }
}
