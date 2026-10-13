import QtQuick

// Five-petal lotus identity mark. `active` pulses gently (now playing).
Canvas {
    id: mark

    property color petalColor: "#e9c7e0"
    property bool active: false
    property real baseScale: 1.0

    onPetalColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Component.onCompleted: requestPaint()

    scale: baseScale * pulseAnim.currentValue

    // pulse value driven below
    QtObject {
        id: pulseAnim
        property real currentValue: 1.0
    }

    onActiveChanged: {
        if (active)
            pulse.start()
        else {
            pulse.stop()
            pulseAnim.currentValue = 1.0
        }
    }

    SequentialAnimation {
        id: pulse
        loops: Animation.Infinite
        running: false
        PropertyAnimation {
            target: pulseAnim
            property: "currentValue"
            from: 1.0
            to: 1.09
            duration: 850
            easing.type: Easing.InOutSine
        }
        PropertyAnimation {
            target: pulseAnim
            property: "currentValue"
            from: 1.09
            to: 1.0
            duration: 850
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
            ctx.restore()
        }
    }
}
