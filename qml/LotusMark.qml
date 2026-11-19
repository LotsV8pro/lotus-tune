import QtQuick

// Five-petal lotus identity mark. `active` gives ONE short, gentle pulse
// (<=280 ms) when the mark is visible; otherwise it stays perfectly still.
// No infinite loops: the app must remain cheap on the compositor.
Canvas {
    id: mark

    property color petalColor: "#e9c7e0"
    property bool active: false
    property real baseScale: 1.0
    // The Lotus interface draws the same five petals with a thicker stroke
    // and a soft halo. Classic keeps the original flat, hairline-free mark.
    readonly property bool lotusStyle: typeof Sys !== "undefined"
                                       && Sys.interfaceStyle === "lotus"

    Connections {
        target: typeof Sys !== "undefined" ? Sys : null
        function onPaletteChanged() { mark.requestPaint() }
    }

    onPetalColorChanged: requestPaint()
    onLotusStyleChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Component.onCompleted: {
        requestPaint()
        maybePulse()
    }

    scale: baseScale * pulseAnim.currentValue

    // pulse value driven below
    QtObject {
        id: pulseAnim
        property real currentValue: 1.0
    }

    onActiveChanged: maybePulse()
    onVisibleChanged: maybePulse()

    // It only pulses when active AND visible; otherwise it stays
    // still.
    function maybePulse() {
        if (active && visible)
            pulse.restart()
        else {
            pulse.stop()
            pulseAnim.currentValue = 1.0
        }
    }

    // A single short pulse (2 x 130 ms = 260 ms), no `loops`.
    SequentialAnimation {
        id: pulse
        running: false
        PropertyAnimation {
            target: pulseAnim
            property: "currentValue"
            from: 1.0
            to: 1.08
            duration: 130
            easing.type: Easing.InOutSine
        }
        PropertyAnimation {
            target: pulseAnim
            property: "currentValue"
            from: 1.08
            to: 1.0
            duration: 130
            easing.type: Easing.InOutSine
        }
    }

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)

        const cx = width / 2
        const cy = height * 0.74
        const s = Math.min(width, height) / 24
        const angles = [-70, -35, 0, 35, 70]

        if (lotusStyle) {
            // Soft violet halo behind the petals: no image files, no shader.
            const halo = ctx.createRadialGradient(cx, cy - 5 * s, 0,
                                                  cx, cy - 5 * s, 13 * s)
            const C = Qt.rgba(0.55, 0.36, 0.89, 1)
            halo.addColorStop(0, Qt.rgba(C.r, C.g, C.b, 0.30))
            halo.addColorStop(1, Qt.rgba(C.r, C.g, C.b, 0))
            ctx.fillStyle = halo
            ctx.beginPath()
            ctx.arc(cx, cy - 5 * s, 13 * s, 0, Math.PI * 2)
            ctx.fill()
        }

        for (let i = 0; i < angles.length; i++) {
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(angles[i] * Math.PI / 180)
            ctx.scale(s, s)
            ctx.globalAlpha = (angles[i] === 0) ? 1.0 : (Math.abs(angles[i]) === 35 ? 0.72 : 0.48)
            ctx.fillStyle = String(petalColor)
            ctx.beginPath()
            ctx.moveTo(0, 0)
            ctx.bezierCurveTo(-5.4, -4, -4.3, -10.5, 0, -13)
            ctx.bezierCurveTo(4.3, -10.5, 5.4, -4, 0, 0)
            ctx.fill()
            if (lotusStyle) {
                // Thicker contour: the petals stay the same shape, only the
                // outline gains weight so the mark reads at small sizes.
                ctx.lineWidth = 1.6
                ctx.strokeStyle = Qt.rgba(0.42, 0.22, 0.66, 0.85)
                ctx.globalAlpha = 1
                ctx.stroke()
            }
            ctx.restore()
        }
    }
}
