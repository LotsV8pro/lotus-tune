import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Buscar: consulta la fuente activa a través de yt-dlp y reproduce al clic.
// Filas y campos de tamaño fijo para que la lista no salte al cargar.
//
// Scroll: la única superficie con rueda es la lista de resultados
// (resultsFlick, con clip). El WheelHandler de la raíz corta la propagación
// del wheel que «sobra» (lista ya al borde, o puntero sobre la barra de
// búsqueda): el evento se queda en la página y nunca arrastra a un contenedor
// padre. Además, cada búsqueda nueva reinicia contentY para que la lista
// arranque siempre arriba (antes podía quedar «scrolled» de la búsqueda
// anterior y parecer que se movía sola).
Item {
    id: page

    signal playRequested(var list, int index)
    // Clic derecho: pide el menú contextual para esa pista (x/y en ventana).
    signal trackContextRequested(var track, real x, real y)

    WheelHandler {
        onWheel: (event) => { event.accepted = true }
    }

    function sourceEntry(id) {
        const l = sources.list
        for (var i = 0; i < l.length; i++)
            if (l[i].id === id)
                return l[i]
        return null
    }
    readonly property var src: sourceEntry(sources.activeId)
    readonly property bool locked: !src || src.status !== "ready"

    readonly property int rowHeight: 46

    function runSearch() {
        const q = String(input.text || "").trim()
        if (q.length === 0)
            return
        resultsFlick.contentY = 0     // toda búsqueda nueva empieza arriba
        pushHistory(q)
        catalog.search(q)
    }

    // API para re-ejecutar una búsqueda desde fuera (chips del Historial
    // en Inicio): rellena el campo y lanza la búsqueda.
    function startSearch(q) {
        input.text = String(q || "")
        runSearch()
        input.forceActiveFocus()
        input.selectAll()
    }

    // ---- historial de búsquedas (appcfg, clave "searchHistory") -----------
    // JSON: [{ "q": texto, "t": timestamp }…], máx. 20, sin duplicados.
    function pushHistory(q) {
        if (typeof appcfg === "undefined")
            return
        var arr = []
        try {
            arr = JSON.parse(String(appcfg.get("searchHistory") || "[]")) || []
        } catch (e) {
            arr = []
        }
        var out = [{ q: q, t: Date.now() }]
        for (var i = 0; i < arr.length && out.length < 20; i++) {
            const e = arr[i]
            if (!e || typeof e.q !== "string" || e.q.length === 0)
                continue
            if (e.q === q)          // sin duplicados (se mueve arriba)
                continue
            out.push({ q: e.q, t: Number(e.t || 0) })
        }
        try {
            appcfg.set("searchHistory", JSON.stringify(out))
            appcfg.save()
        } catch (e2) {
            console.warn("searchHistory: no se pudo guardar: " + e2)
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.s5
        spacing: Theme.s3

        LockedPanel {
            visible: page.locked
            Layout.alignment: Qt.AlignHCenter
            sourceName: page.src ? page.src.name : ""
            note: page.src ? page.src.note : ""
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !page.locked
            spacing: Theme.s2

            // ---- barra de búsqueda -----------------------------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    id: field
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    radius: Theme.rMd
                    color: Sys.surface
                    border.width: 1
                    border.color: input.activeFocus ? Sys.accent : "transparent"
                    Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

                    Glyph {
                        id: searchIcon
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s3
                        anchors.verticalCenter: parent.verticalCenter
                        width: 15
                        height: 15
                        kind: "search"
                        color: Sys.textDim
                    }

                    TextInput {
                        id: input
                        anchors.left: searchIcon.right
                        anchors.leftMargin: Theme.s2
                        anchors.right: clearBtn.left
                        anchors.rightMargin: Theme.s2
                        anchors.verticalCenter: parent.verticalCenter
                        color: Sys.text
                        font.pixelSize: Theme.tBase
                        clip: true
                        selectByMouse: true
                        Keys.onReturnPressed: { event.accepted = true; page.runSearch() }
                        Keys.onEnterPressed: { event.accepted = true; page.runSearch() }
                    }
                    Text {
                        visible: input.text.length === 0
                        anchors.left: input.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: input.width
                        text: "¿Qué quieres escuchar en "
                              + (page.src ? page.src.name : "") + "?"
                        color: Sys.textDim
                        font.pixelSize: Theme.tBase
                        elide: Text.ElideRight
                    }
                    Rectangle {
                        id: clearBtn
                        visible: input.text.length > 0
                        width: 24
                        height: 24
                        radius: Theme.rSm
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        color: clearMa.containsMouse ? Theme.hover(Sys.surface) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 11
                            height: 11
                            kind: "x"
                            color: clearMa.containsMouse ? Sys.accent : Sys.textDim
                        }
                        MouseArea {
                            id: clearMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { input.text = ""; input.forceActiveFocus() }
                        }
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 104
                    Layout.preferredHeight: 42
                    radius: Theme.rMd
                    color: btnMa.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                    scale: btnMa.pressed ? 0.96 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 7
                        Glyph { width: 14; height: 14; kind: "search"; color: Sys.onAccent }
                        Text {
                            text: "Buscar"
                            color: Sys.onAccent
                            font.pixelSize: Theme.tBase
                            font.bold: true
                        }
                    }
                    MouseArea {
                        id: btnMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.runSearch()
                    }
                }
            }

            // ---- estado ----------------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    visible: catalog.busy
                    property int dots: 1
                    text: "Buscando" + ".".repeat(dots)
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                    Timer {
                        running: catalog.busy
                        repeat: true
                        interval: 320
                        onTriggered: parent.dots = parent.dots % 3 + 1
                    }
                }
                Text {
                    visible: !catalog.busy && catalog.results.length > 0
                    text: catalog.results.length + " resultados para «" + catalog.resultsQuery + "»"
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Item { Layout.fillWidth: true }
            }

            // ---- resultados -----------------------------------------------
            // Único Flickable de la página: clip para que nada pinte fuera y
            // contentWidth fijo para que el wheel horizontal no cree contenido.
            Flickable {
                id: resultsFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: resultsCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: resultsCol
                    width: resultsFlick.width
                    spacing: 3

                    Repeater {
                        model: catalog.results

                        delegate: Rectangle {
                            id: rrow
                            required property int index
                            Layout.fillWidth: true
                            Layout.preferredHeight: 46
                            radius: Theme.rMd
                            color: rrowMouse.containsMouse ? Theme.hover(Sys.surface) : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                            MouseArea {
                                id: rrowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.RightButton)
                                        page.trackContextRequested(catalog.results[rrow.index],
                                                                   mouse.scenePos.x,
                                                                   mouse.scenePos.y)
                                    else
                                        page.playRequested(catalog.results, rrow.index)
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s3
                                anchors.rightMargin: Theme.s3
                                spacing: Theme.s3

                                Text {
                                    Layout.preferredWidth: 22
                                    text: rrow.index + 1
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    horizontalAlignment: Text.AlignRight
                                }
                                Rectangle {
                                    Layout.preferredWidth: 34
                                    Layout.preferredHeight: 34
                                    radius: Theme.rSm
                                    clip: true
                                    color: Sys.surfaceAlt

                                    Image {
                                        anchors.fill: parent
                                        source: catalog.results[rrow.index].thumb || ""
                                        visible: source != ""
                                        sourceSize.width: 34
                                        sourceSize.height: 34
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        cache: true
                                    }
                                    Glyph {
                                        anchors.centerIn: parent
                                        width: 15
                                        height: 15
                                        visible: !catalog.results[rrow.index].thumb
                                        kind: "play"
                                        color: rrowMouse.containsMouse ? Sys.accent : Sys.textDim
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Text {
                                            Layout.fillWidth: true
                                            text: catalog.results[rrow.index].title || ""
                                            color: Sys.text
                                            font.pixelSize: Theme.tBase
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                        }
                                        LikeButton {
                                            id: rrowLike
                                            interactive: catalog.loginState === "ok"
                                                         && catalog.videoIdOf(
                                                                catalog.results[rrow.index].url) !== ""
                                            revealed: rrowMouse.containsMouse
                                            liked: {
                                                const rev = catalog.likedRevision
                                                const tr = catalog.results[rrow.index]
                                                if (!tr)
                                                    return false
                                                if (catalog.likedReady)
                                                    return catalog.isLiked(tr.url)
                                                return tr.liked === true
                                            }
                                            onToggled: {
                                                const tr = catalog.results[rrow.index]
                                                if (tr)
                                                    catalog.toggleLiked(tr.url, rrowLike.liked)
                                            }
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: catalog.results[rrow.index].artist || ""
                                        color: Sys.textDim
                                        font.pixelSize: Theme.tSm
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                }
                                Text {
                                    text: Theme.mmss(catalog.results[rrow.index].duration)
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                }
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.s4
                        visible: !catalog.busy && catalog.results.length === 0
                        text: "Escribe algo y pulsa Buscar. Se usa la extracción directa\nde la fuente: sin anuncios, sin navegador."
                        color: Sys.textDim
                        font.pixelSize: Theme.tMd
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        lineHeight: 1.3
                    }
                }
            }
        }
    }
}