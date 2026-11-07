import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Artist page (full screen layer), in sections and in this order:
//   songs -> albums -> singles/EPs -> radios/playlists -> similar artists.
// "Reproducir todo" walks the WHOLE discography (newest first) adding each
// album to the queue on the fly; "Aleatorio" does the same and then shuffles
// the queue. Clicking an album plays only that album; clicking a song plays
// the artist's top songs from that one; a radio/playlist opens as a list.
Item {
    id: page

    // Data coming from Main: artist { name, browseId, thumb } (the search
    // result, for the instant header) and `data`, the artist page
    // { name, thumb, songs, albums, singles, radios, similar, discography }.
    property var artist: null
    // `data` is taken (Item's default property): the sections live in
    // pageData.
    property var pageData: ({})
    property bool busy: false
    // Release order for "Reproducir todo": newest first (default) or
    // oldest first.
    property bool oldestFirst: false
    // Room at the end of the scroll so the last section can come out from
    // under the floating playback pill.
    property int bottomInset: 0
    // The washed background of the app (the blurred artwork): this page is
    // opaque (nothing behind it may show through) but it keeps the same
    // background as the rest of the app, edge to edge.
    property string washSource: ""

    signal backRequested()
    // `oldestFirst` flips the release order for "Reproducir todo": the
    // discography arrives newest first, so the app reverses it when asked.
    signal playAllRequested(bool random, bool oldestFirst)
    signal albumPlayRequested(var album)
    // Click on the cover of a record: it OPENS its track list (it does not
    // start playing). The play button of the card is the one that sounds.
    signal albumOpenRequested(var album)
    // Download one album / single (a whole record) or the complete
    // discography of the artist.
    signal albumDownloadRequested(var album)
    signal discographyDownloadRequested()
    // A song of the "Canciones" section: `list` is the whole section so the
    // rest keeps playing after it.
    signal songPlayRequested(var list, int index)
    // The synthetic "Radio de <artist>" card (the existing artist radio).
    signal radioRequested()
    // A playlist/radio of the artist: it opens as a list (id without VL).
    signal listRequested(string id, string name)
    // A similar artist card: opens that artist's page.
    signal similarRequested(var artist)

    readonly property var songs: (page.pageData && page.pageData.songs) ? page.pageData.songs : []
    readonly property var albums: (page.pageData && page.pageData.albums) ? page.pageData.albums : []
    readonly property var singles: (page.pageData && page.pageData.singles) ? page.pageData.singles : []
    readonly property var radios: (page.pageData && page.pageData.radios) ? page.pageData.radios : []
    readonly property var similar: (page.pageData && page.pageData.similar) ? page.pageData.similar : []

    readonly property string artistName: {
        if (page.pageData && String(page.pageData.name || "") !== "")
            return String(page.pageData.name)
        return page.artist ? String(page.artist.name || "") : ""
    }
    readonly property string artistThumb: {
        if (page.pageData && String(page.pageData.thumb || "") !== "")
            return String(page.pageData.thumb)
        return page.artist ? String(page.artist.thumb || "") : ""
    }

    // Radios rail: the artist's own radio first (it always exists), then
    // the playlists/radios YouTube Music puts on their page.
    readonly property var radioModel: {
        const out = [{ radio: true, title: "Radio de " + page.artistName,
                       subtitle: "Sin fin, a partir de sus éxitos", thumb: page.artistThumb }]
        for (let i = 0; i < page.radios.length; i++)
            out.push(page.radios[i])
        return out
    }

    readonly property int cardW: Theme.touch ? 108 : 128
    readonly property int railH: cardW + Theme.cardLineH(Theme.tMd)
                                  + Theme.cardLineH(Theme.tSm) + Theme.s1

    // Is this record already in the Downloads library? (the download
    // button shows a check instead of the arrow).
    function isDownloaded(album) {
        if (typeof downloads === "undefined" || !album)
            return false
        const seg = downloads.listFolderName(String(album.title || ""))
        const fs = downloads.folders || []
        for (var i = 0; i < fs.length; i++)
            if (String(fs[i].folder || "") === seg)
                return true
        return false
    }

    // Swallows the clicks: nothing behind (content, bar) should react.
    MouseArea {
        anchors.fill: parent
    }

    // Opaque base: the pages behind must never show through.
    Rectangle {
        anchors.fill: parent
        color: Sys.bg
    }
    // The same wash the rest of the app paints (so the background keeps
    // going edge to edge on this page).
    Image {
        anchors.fill: parent
        source: page.washSource
        fillMode: Image.Stretch
        smooth: true
        asynchronous: true
        cache: false
        visible: page.washSource !== ""
    }
    Rectangle {
        anchors.fill: parent
        visible: page.washSource !== ""
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.alpha(Sys.bg, 0.60) }
            GradientStop { position: 1.0; color: Theme.alpha(Sys.bg, 0.34) }
        }
    }

    // ---- back: floats over the page -----------------------------------
    // It is not part of the header any more: it does not take room from
    // the artist (which starts at the left margin, lower down, with the
    // button above it).
    Rectangle {
        z: 3
        width: Theme.touch ? 44 : 38
        height: width
        radius: width / 2
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: Theme.s5
        anchors.topMargin: Theme.s5
        // A dark disc behind the arrow so it reads over any artwork.
        color: Theme.alpha(Sys.bg, backMa.containsMouse ? 0.90 : 0.55)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

        Glyph {
            anchors.centerIn: parent
            width: 18
            height: 18
            kind: "back"
            color: Sys.text
        }
        MouseArea {
            id: backMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (typeof sfx !== "undefined") sfx.play("tap")
                page.backRequested()
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.s5
        // The artist sits below the floating back button, not next to it.
        anchors.topMargin: Theme.s5 + (Theme.touch ? 44 : 38) + Theme.s3
        spacing: Theme.s3

        // ---- header: portrait + name + actions ----------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s3

            Rectangle {
                Layout.preferredWidth: Theme.touch ? 84 : 104
                Layout.preferredHeight: Layout.preferredWidth
                radius: Theme.rLg
                clip: true
                color: Theme.sAlt(Sys.bg, Sys.text)
                RoundedArt {
                    id: artImg
                    anchors.fill: parent
                    source: page.artistThumb
                    radiusSpec: Theme.rLg
                }
                Glyph {
                    anchors.centerIn: parent
                    width: 38
                    height: 38
                    visible: !artImg.ready
                    kind: "music"
                    color: Theme.tDim(Sys.bg, Sys.text)
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.s1

                Text {
                    Layout.fillWidth: true
                    text: page.artistName
                    color: Sys.text
                    font.pixelSize: Theme.t2xl
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    // The page itself does not always carry the
                    // "Artista • N oyentes" line: the search result does.
                    text: (page.pageData && String(page.pageData.subtitle || "") !== "")
                          ? String(page.pageData.subtitle)
                          : (page.artist ? String(page.artist.subtitle || "") : "")
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tSm
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                Text {
                    Layout.fillWidth: true
                    visible: page.busy
                    text: "Leyendo la página del artista en YouTube Music…"
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tSm
                }
            }

            // Actions: they stay next to the name on desktop and drop to
            // their own line on the phone (no room for both).
            ColumnLayout {
                Layout.alignment: Qt.AlignBottom
                spacing: Theme.s2
                visible: !Theme.touch

                RowLayout {
                    spacing: Theme.s2
                    Rectangle {
                        width: playAllLabel.implicitWidth + Theme.pillHPad * 2 + 22
                        height: 40
                        radius: Theme.rPill
                        color: playAllMa.containsMouse ? Theme.hover(Sys.accent) : Sys.accent
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s2
                            Glyph { width: 15; height: 15; kind: "play"; color: Sys.bg }
                            Text {
                                id: playAllLabel
                                text: "Reproducir todo"
                                color: Sys.bg
                                font.pixelSize: Theme.tMd
                                font.weight: Font.DemiBold
                            }
                        }
                        MouseArea {
                            id: playAllMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !page.busy
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.playAllRequested(false, page.oldestFirst)
                            }
                        }
                    }

                    Rectangle {
                        width: shuffleAllLabel.implicitWidth + Theme.pillHPad * 2 + 22
                        height: 40
                        radius: Theme.rPill
                        color: shuffleAllMa.containsMouse ? Theme.sAlt(Sys.bg, Sys.text) : "transparent"
                        border.width: 1
                        border.color: Theme.alpha(Sys.text, 0.28)
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s2
                            Glyph { width: 15; height: 15; kind: "shuffle"; color: Sys.text }
                            Text {
                                id: shuffleAllLabel
                                text: "Aleatorio"
                                color: Sys.text
                                font.pixelSize: Theme.tMd
                            }
                        }
                        MouseArea {
                            id: shuffleAllMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !page.busy
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.playAllRequested(true, page.oldestFirst)
                            }
                        }
                    }
                }

                // Download the whole discography (one folder per record).
                // It is asked album by album in the background; when
                // everything is queued the toast says how many records.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        width: discLabel.implicitWidth + Theme.pillHPad * 2 + 22
                        height: Theme.pillH
                        radius: Theme.rPill
                        color: discMa.containsMouse
                               ? Theme.sAlt(Sys.bg, Sys.text) : "transparent"
                        border.width: 1
                        border.color: Theme.alpha(Sys.text, 0.18)
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s1
                            Glyph {
                                width: 13
                                height: 13
                                kind: "download"
                                color: page.busy ? Theme.alpha(Sys.text, 0.4)
                                                 : Sys.accent
                            }
                            Text {
                                id: discLabel
                                text: "Descargar discografía"
                                color: page.busy ? Theme.tDim(Sys.bg, Sys.text)
                                                 : Sys.text
                                font.pixelSize: Theme.tSm
                            }
                        }
                        MouseArea {
                            id: discMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !page.busy
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.discographyDownloadRequested()
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }
                }

                // Release order of "Reproducir todo": newest first (what a
                // discography usually wants) or oldest first.
                Rectangle {
                    Layout.alignment: Qt.AlignRight
                    width: orderLabel.implicitWidth + Theme.pillHPad * 2 + 16
                    height: Theme.pillH
                    radius: Theme.rPill
                    color: orderMa.containsMouse
                           ? Theme.sAlt(Sys.bg, Sys.text) : "transparent"
                    border.width: 1
                    border.color: Theme.alpha(Sys.text, 0.18)
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: Theme.s1
                        Glyph {
                            width: 13
                            height: 13
                            kind: page.oldestFirst ? "arrow-up" : "arrow-down"
                            color: Theme.tDim(Sys.bg, Sys.text)
                        }
                        Text {
                            id: orderLabel
                            text: page.oldestFirst ? "Más antiguos primero"
                                                   : "Más nuevos primero"
                            color: Theme.tDim(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tSm
                        }
                    }
                    MouseArea {
                        id: orderMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            page.oldestFirst = !page.oldestFirst
                        }
                    }
                }
            }
        }

        // Phone: the actions go under the name, full width.
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s2
            visible: Theme.touch

            Rectangle {
                Layout.fillWidth: true
                height: 42
                radius: Theme.rPill
                color: Sys.accent
                RowLayout {
                    anchors.centerIn: parent
                    spacing: Theme.s2
                    Glyph { width: 15; height: 15; kind: "play"; color: Sys.bg }
                    Text {
                        text: "Reproducir todo"
                        color: Sys.bg
                        font.pixelSize: Theme.tMd
                        font.weight: Font.DemiBold
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: !page.busy
                    onClicked: {
                        if (typeof sfx !== "undefined") sfx.play("tap")
                        page.playAllRequested(false, page.oldestFirst)
                    }
                }
            }

            Rectangle {
                width: shuffleLabel2.implicitWidth + Theme.pillHPad * 2 + 20
                height: 42
                radius: Theme.rPill
                color: "transparent"
                border.width: 1
                border.color: Theme.alpha(Sys.text, 0.28)
                RowLayout {
                    anchors.centerIn: parent
                    spacing: Theme.s2
                    Glyph { width: 15; height: 15; kind: "shuffle"; color: Sys.text }
                    Text {
                        id: shuffleLabel2
                        text: "Aleatorio"
                        color: Sys.text
                        font.pixelSize: Theme.tMd
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: !page.busy
                    onClicked: {
                        if (typeof sfx !== "undefined") sfx.play("tap")
                        page.playAllRequested(true, page.oldestFirst)
                    }
                }
            }
        }

        // Phone: release order chip (it fits under the two buttons).
        Rectangle {
            visible: Theme.touch
            Layout.preferredWidth: orderLabelP.implicitWidth + Theme.pillHPad * 2 + 16
            Layout.preferredHeight: Theme.pillH
            Layout.alignment: Qt.AlignLeft
            radius: Theme.rPill
            color: "transparent"
            border.width: 1
            border.color: Theme.alpha(Sys.text, 0.18)
            RowLayout {
                anchors.centerIn: parent
                spacing: Theme.s1
                Glyph {
                    width: 13
                    height: 13
                    kind: page.oldestFirst ? "arrow-up" : "arrow-down"
                    color: Theme.tDim(Sys.bg, Sys.text)
                }
                Text {
                    id: orderLabelP
                    text: page.oldestFirst ? "Más antiguos primero"
                                           : "Más nuevos primero"
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tSm
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (typeof sfx !== "undefined") sfx.play("tap")
                    page.oldestFirst = !page.oldestFirst
                }
            }
        }

        // Phone: download the whole discography (its own row: there is no
        // room next to the other buttons).
        Rectangle {
            visible: Theme.touch
            Layout.fillWidth: true
            Layout.preferredHeight: 42
            radius: Theme.rPill
            color: discPhoneMa.containsMouse ? Theme.sAlt(Sys.bg, Sys.text)
                                             : "transparent"
            border.width: 1
            border.color: Theme.alpha(Sys.text, 0.28)
            RowLayout {
                anchors.centerIn: parent
                spacing: Theme.s2
                Glyph { width: 15; height: 15; kind: "download"; color: Sys.accent }
                Text {
                    text: "Descargar discografía"
                    color: Sys.text
                    font.pixelSize: Theme.tMd
                }
            }
            MouseArea {
                id: discPhoneMa
                anchors.fill: parent
                enabled: !page.busy
                onClicked: {
                    if (typeof sfx !== "undefined") sfx.play("tap")
                    page.discographyDownloadRequested()
                }
            }
        }

        // ---- sections -----------------------------------------------------
        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: sections.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: sections
                width: parent.width
                spacing: Theme.s4
                // The pill floats over the page: the last section gets
                // enough air to be scrolled above it.
                bottomPadding: Theme.s4 + page.bottomInset

                // ---- songs -------------------------------------------------
                Column {
                    width: parent.width
                    spacing: Theme.s1
                    visible: page.songs.length > 0

                    Text {
                        leftPadding: Theme.s1
                        text: "CANCIONES"
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.4
                        opacity: 0.85
                    }

                    Repeater {
                        model: page.songs
                        delegate: Rectangle {
                            id: srow
                            required property int index
                            required property var modelData
                            width: sections.width
                            height: Theme.rowH
                            radius: Theme.rMd
                            color: srowMa.containsMouse
                                   ? Theme.hover(Theme.sAlt(Sys.bg, Sys.text))
                                   : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                            MouseArea {
                                id: srowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    page.songPlayRequested(page.songs, srow.index)
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s2
                                anchors.rightMargin: Theme.s3
                                spacing: Theme.s3

                                Rectangle {
                                    Layout.preferredWidth: 40
                                    Layout.preferredHeight: 40
                                    Layout.alignment: Qt.AlignVCenter
                                    radius: Theme.rMd
                                    clip: true
                                    color: Theme.sAlt(Sys.bg, Sys.text)
                                    RoundedArt {
                                        anchors.fill: parent
                                        source: String(srow.modelData.thumb || "")
                                        radiusSpec: Theme.rMd
                                    }
                                    Glyph {
                                        anchors.centerIn: parent
                                        width: 16
                                        height: 16
                                        visible: String(srow.modelData.thumb || "") === ""
                                        kind: "music"
                                        color: Theme.tDim(Sys.bg, Sys.text)
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text {
                                        Layout.fillWidth: true
                                        text: String(srow.modelData.title || "")
                                        color: Sys.text
                                        font.pixelSize: Theme.tBase
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        visible: text !== ""
                                        text: String(srow.modelData.artist || "")
                                        color: Theme.tDim(Sys.bg, Sys.text)
                                        font.pixelSize: Theme.tSm
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: Number(srow.modelData.duration || 0) > 0
                                    text: Theme.mmss(Number(srow.modelData.duration || 0))
                                    color: Theme.tFaint(Sys.bg, Sys.text)
                                    font.pixelSize: Theme.tSm
                                }

                                Glyph {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: 16
                                    height: 16
                                    visible: srowMa.containsMouse
                                    kind: "play"
                                    color: Theme.accentOn(Sys.accent, Sys.bg)
                                }
                            }
                        }
                    }
                }

                // ---- albums ------------------------------------------------
                Column {
                    width: parent.width
                    spacing: Theme.s2
                    visible: page.albums.length > 0

                    Text {
                        leftPadding: Theme.s1
                        text: "ÁLBUMES"
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.4
                        opacity: 0.85
                    }

                    ListView {
                        id: albumRail
                        width: parent.width
                        height: page.railH
                        orientation: ListView.Horizontal
                        spacing: Theme.s3
                        clip: true
                        model: page.albums
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: CoverCard {
                            required property var modelData
                            width: page.cardW
                            height: page.railH
                            name: String(modelData.title || "")
                            subtitle: String(modelData.subtitle || "")
                            thumb: String(modelData.thumb || "")
                            glyph: "disc"
                            showActions: true
                            downloaded: page.isDownloaded(modelData)
                            onClicked: page.albumOpenRequested(modelData)
                            onPlayClicked: page.albumPlayRequested(modelData)
                            onDownloadClicked: page.albumDownloadRequested(modelData)
                        }
                    }
                }

                // ---- singles and EPs ---------------------------------------
                Column {
                    width: parent.width
                    spacing: Theme.s2
                    visible: page.singles.length > 0

                    Text {
                        leftPadding: Theme.s1
                        text: "SINGLES Y EPS"
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.4
                        opacity: 0.85
                    }

                    ListView {
                        id: singleRail
                        width: parent.width
                        height: page.railH
                        orientation: ListView.Horizontal
                        spacing: Theme.s3
                        clip: true
                        model: page.singles
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: CoverCard {
                            required property var modelData
                            width: page.cardW
                            height: page.railH
                            name: String(modelData.title || "")
                            subtitle: String(modelData.subtitle || "")
                            thumb: String(modelData.thumb || "")
                            glyph: "disc"
                            showActions: true
                            downloaded: page.isDownloaded(modelData)
                            onClicked: page.albumOpenRequested(modelData)
                            onPlayClicked: page.albumPlayRequested(modelData)
                            onDownloadClicked: page.albumDownloadRequested(modelData)
                        }
                    }
                }

                // ---- radios / playlists ------------------------------------
                Column {
                    width: parent.width
                    spacing: Theme.s2
                    visible: page.radioModel.length > 0

                    Text {
                        leftPadding: Theme.s1
                        text: "RADIOS Y LISTAS"
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.4
                        opacity: 0.85
                    }

                    ListView {
                        id: radioRail
                        width: parent.width
                        height: page.railH
                        orientation: ListView.Horizontal
                        spacing: Theme.s3
                        clip: true
                        model: page.radioModel
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: CoverCard {
                            required property var modelData
                            width: page.cardW
                            height: page.railH
                            name: String(modelData.title || "")
                            subtitle: String(modelData.subtitle || "")
                            thumb: String(modelData.thumb || "")
                            glyph: modelData.radio === true ? "radio" : "list"
                            onClicked: {
                                if (modelData.radio === true)
                                    page.radioRequested()
                                else
                                    page.listRequested(String(modelData.id || ""),
                                                       String(modelData.title || ""))
                            }
                        }
                    }
                }

                // ---- similar artists (always last) -------------------------
                Column {
                    width: parent.width
                    spacing: Theme.s2
                    visible: page.similar.length > 0

                    Text {
                        leftPadding: Theme.s1
                        text: "ARTISTAS SIMILARES"
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.4
                        opacity: 0.85
                    }

                    ListView {
                        id: similarRail
                        width: parent.width
                        height: page.railH
                        orientation: ListView.Horizontal
                        spacing: Theme.s3
                        clip: true
                        model: page.similar
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: CoverCard {
                            required property var modelData
                            width: page.cardW
                            height: page.railH
                            name: String(modelData.name || "")
                            subtitle: String(modelData.subtitle || "")
                            thumb: String(modelData.thumb || "")
                            onClicked: page.similarRequested(modelData)
                        }
                    }
                }

                // ---- empty state -------------------------------------------
                Text {
                    width: parent.width
                    visible: !page.busy && page.songs.length === 0
                             && page.albums.length === 0 && page.singles.length === 0
                    text: "Esta búsqueda no dejó discos a la vista."
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tMd
                    horizontalAlignment: Text.AlignHCenter
                    topPadding: Theme.s5
                }
            }
        }
    }
}
