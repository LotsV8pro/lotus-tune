import QtQuick

// Minimal line/fill icon set drawn on a Canvas. The18x18 design grid scales
// to the item's width/height.
Canvas {
    id: g

    property string kind: "home"
    property color color: "#ffffff"
    property real weight: 1.7

    onColorChanged: requestPaint()
    onKindChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Component.onCompleted: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        const u = Math.min(width, height) / 18
        const ox = (width - 18 * u) / 2
        const oy = (height - 18 * u) / 2
        const X = (v) => ox + v * u
        const Y = (v) => oy + v * u

        ctx.strokeStyle = String(color)
        ctx.fillStyle = String(color)
        ctx.lineWidth = weight * u
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        switch (kind) {
        case "home":
            ctx.beginPath()
            ctx.moveTo(X(2.5), Y(9))
            ctx.lineTo(X(9), Y(3))
            ctx.lineTo(X(15.5), Y(9))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(4.5), Y(8))
            ctx.lineTo(X(4.5), Y(15.5))
            ctx.lineTo(X(13.5), Y(15.5))
            ctx.lineTo(X(13.5), Y(8))
            ctx.stroke()
            break
        case "search":
            ctx.beginPath()
            ctx.arc(X(8), Y(8), 4.6 * u, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(11.6), Y(11.6))
            ctx.lineTo(X(15.5), Y(15.5))
            ctx.stroke()
            break
        case "library":
            ctx.lineWidth = 3 * u
            ctx.beginPath()
            ctx.moveTo(X(5), Y(13.5))
            ctx.lineTo(X(5), Y(6.5))
            ctx.moveTo(X(9), Y(15.5))
            ctx.lineTo(X(9), Y(3.5))
            ctx.moveTo(X(13), Y(12.5))
            ctx.lineTo(X(13), Y(7.5))
            ctx.stroke()
            break
        case "play":
            ctx.beginPath()
            ctx.moveTo(X(5.5), Y(3.5))
            ctx.lineTo(X(15), Y(9))
            ctx.lineTo(X(5.5), Y(14.5))
            ctx.closePath()
            ctx.fill()
            break
        case "repeat":
            // top arrow pointing right
            ctx.beginPath()
            ctx.moveTo(X(3), Y(6.5))
            ctx.lineTo(X(13.2), Y(6.5))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(11), Y(4.2))
            ctx.lineTo(X(13.4), Y(6.5))
            ctx.lineTo(X(11), Y(8.8))
            ctx.stroke()
            // bottom arrow pointing left
            ctx.beginPath()
            ctx.moveTo(X(15), Y(11.5))
            ctx.lineTo(X(5), Y(11.5))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(7), Y(9.2))
            ctx.lineTo(X(4.8), Y(11.5))
            ctx.lineTo(X(7), Y(13.8))
            ctx.stroke()
            break
        case "lyrics":
            // musical note: head + stem + flag
            ctx.beginPath()
            ctx.ellipse(X(6.4) - 2.3 * u, Y(13.4) - 1.7 * u, 2.3 * u, 1.7 * u, 0, 0, Math.PI * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.moveTo(X(8.6), Y(13.4))
            ctx.lineTo(X(8.6), Y(4))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(8.6), Y(4))
            ctx.bezierCurveTo(X(11), Y(4.4), X(12.6), Y(6), X(12.6), Y(8.4))
            ctx.stroke()
            break
        case "mic":
            ctx.beginPath()
            ctx.moveTo(X(6.8), Y(6.5))
            ctx.lineTo(X(6.8), Y(4.6))
            ctx.arc(X(9), Y(4.6), 2.2 * u, Math.PI, 0)
            ctx.lineTo(X(11.2), Y(10))
            ctx.arc(X(9), Y(10), 2.2 * u, 0, Math.PI)
            ctx.closePath()
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(10), 4.6 * u, 0, Math.PI)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(9), Y(14.6))
            ctx.lineTo(X(9), Y(16.4))
            ctx.moveTo(X(6.6), Y(16.4))
            ctx.lineTo(X(11.4), Y(16.4))
            ctx.stroke()
            break
        case "disc":
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 7 * u, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 2.2 * u, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 4.7 * u, -Math.PI * 0.95, -Math.PI * 0.4)
            ctx.stroke()
            break
        case "chevron-down":
            ctx.beginPath()
            ctx.moveTo(X(4.5), Y(7))
            ctx.lineTo(X(9), Y(11.5))
            ctx.lineTo(X(13.5), Y(7))
            ctx.stroke()
            break
        case "expand":
            ctx.beginPath()
            ctx.moveTo(X(10.5), Y(7.5))
            ctx.lineTo(X(14), Y(4))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(10.5), Y(4))
            ctx.lineTo(X(14), Y(4))
            ctx.lineTo(X(14), Y(7.5))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(7.5), Y(10.5))
            ctx.lineTo(X(4), Y(14))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(7.5), Y(14))
            ctx.lineTo(X(4), Y(14))
            ctx.lineTo(X(4), Y(10.5))
            ctx.stroke()
            break
        case "download":
            ctx.beginPath()
            ctx.moveTo(X(9), Y(3))
            ctx.lineTo(X(9), Y(11.5))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(5.4), Y(8))
            ctx.lineTo(X(9), Y(11.6))
            ctx.lineTo(X(12.6), Y(8))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(3.6), Y(13.4))
            ctx.lineTo(X(3.6), Y(15))
            ctx.lineTo(X(14.4), Y(15))
            ctx.lineTo(X(14.4), Y(13.4))
            ctx.stroke()
            break
        case "pause":
            ctx.beginPath()
            ctx.rect(X(5), Y(3.5), 3.2 * u, 11 * u)
            ctx.rect(X(10), Y(3.5), 3.2 * u, 11 * u)
            ctx.fill()
            break
        case "next":
            ctx.beginPath()
            ctx.moveTo(X(4), Y(4))
            ctx.lineTo(X(12.5), Y(9))
            ctx.lineTo(X(4), Y(14))
            ctx.closePath()
            ctx.fill()
            ctx.beginPath()
            ctx.rect(X(13.5), Y(4), 2.2 * u, 10 * u)
            ctx.fill()
            break
        case "prev":
            ctx.beginPath()
            ctx.moveTo(X(14), Y(4))
            ctx.lineTo(X(5.5), Y(9))
            ctx.lineTo(X(14), Y(14))
            ctx.closePath()
            ctx.fill()
            ctx.beginPath()
            ctx.rect(X(2.3), Y(4), 2.2 * u, 10 * u)
            ctx.fill()
            break
        case "volume":
            ctx.beginPath()
            ctx.moveTo(X(3), Y(7))
            ctx.lineTo(X(6), Y(7))
            ctx.lineTo(X(9.5), Y(3.8))
            ctx.lineTo(X(9.5), Y(14.2))
            ctx.lineTo(X(6), Y(11))
            ctx.lineTo(X(3), Y(11))
            ctx.closePath()
            ctx.fill()
            ctx.beginPath()
            ctx.arc(X(9.5), Y(9), 3 * u, -Math.PI / 3, Math.PI / 3)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9.5), Y(9), 5.4 * u, -Math.PI / 3, Math.PI / 3)
            ctx.stroke()
            break
        case "plus":
            ctx.beginPath()
            ctx.moveTo(X(9), Y(4))
            ctx.lineTo(X(9), Y(14))
            ctx.moveTo(X(4), Y(9))
            ctx.lineTo(X(14), Y(9))
            ctx.stroke()
            break
        case "x":
            ctx.beginPath()
            ctx.moveTo(X(5), Y(5))
            ctx.lineTo(X(13), Y(13))
            ctx.moveTo(X(13), Y(5))
            ctx.lineTo(X(5), Y(13))
            ctx.stroke()
            break
        case "back":
            ctx.beginPath()
            ctx.moveTo(X(11.5), Y(3.5))
            ctx.lineTo(X(5.5), Y(9))
            ctx.lineTo(X(11.5), Y(14.5))
            ctx.stroke()
            break
        case "lock":
            ctx.beginPath()
            ctx.rect(X(4), Y(8), 10 * u, 7 * u)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(8), 3 * u, Math.PI, 0)
            ctx.stroke()
            break
        case "heart":
            ctx.beginPath()
            ctx.arc(X(6.2), Y(7), 3.2 * u, 0, Math.PI * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.arc(X(11.8), Y(7), 3.2 * u, 0, Math.PI * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.moveTo(X(4.4), Y(7.6))
            ctx.lineTo(X(13.6), Y(7.6))
            ctx.lineTo(X(9), Y(15.2))
            ctx.closePath()
            ctx.fill()
            break
        case "heart-outline":
            ctx.beginPath()
            ctx.moveTo(X(9), Y(14.6))
            ctx.bezierCurveTo(X(3.2), Y(10.6), X(2.4), Y(7.6), X(4.0), Y(5.6))
            ctx.bezierCurveTo(X(5.2), Y(4.1), X(7.4), Y(4.1), X(9), Y(6.2))
            ctx.bezierCurveTo(X(10.6), Y(4.1), X(12.8), Y(4.1), X(14.0), Y(5.6))
            ctx.bezierCurveTo(X(15.6), Y(7.6), X(14.8), Y(10.6), X(9), Y(14.6))
            ctx.closePath()
            ctx.stroke()
            break
        case "queue":
            ctx.beginPath()
            ctx.rect(X(3.5), Y(4), 11 * u, 1.8 * u)
            ctx.rect(X(3.5), Y(8.1), 11 * u, 1.8 * u)
            ctx.rect(X(3.5), Y(12.2), 7 * u, 1.8 * u)
            ctx.fill()
            break
        case "gear":
            ctx.lineWidth = 1.6 * u
            for (let i = 0; i < 8; i++) {
                const a = i * Math.PI / 4
                ctx.beginPath()
                ctx.moveTo(X(9 + 5.6 * Math.cos(a)), Y(9 + 5.6 * Math.sin(a)))
                ctx.lineTo(X(9 + 7.8 * Math.cos(a)), Y(9 + 7.8 * Math.sin(a)))
                ctx.stroke()
            }
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 4.6 * u, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 1.7 * u, 0, Math.PI * 2)
            ctx.stroke()
            break
        case "radio":
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 1.9 * u, 0, Math.PI * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 4.6 * u, -Math.PI / 4, Math.PI / 4)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 4.6 * u, Math.PI * 3 / 4, Math.PI * 5 / 4)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 7.2 * u, -Math.PI / 4, Math.PI / 4)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 7.2 * u, Math.PI * 3 / 4, Math.PI * 5 / 4)
            ctx.stroke()
            break
        case "shuffle":
            ctx.beginPath() // top-right arrowhead
            ctx.moveTo(X(12), Y(2.25))
            ctx.lineTo(X(15.75), Y(2.25))
            ctx.lineTo(X(15.75), Y(6))
            ctx.stroke()
            ctx.beginPath() // long crossed line
            ctx.moveTo(X(3), Y(15))
            ctx.lineTo(X(15.75), Y(2.25))
            ctx.stroke()
            ctx.beginPath() // bottom-right arrowhead
            ctx.moveTo(X(15.75), Y(12))
            ctx.lineTo(X(15.75), Y(15.75))
            ctx.lineTo(X(12), Y(15.75))
            ctx.stroke()
            ctx.beginPath() // short crossed line
            ctx.moveTo(X(11.25), Y(11.25))
            ctx.lineTo(X(15.75), Y(15.75))
            ctx.stroke()
            ctx.beginPath() // left stub
            ctx.moveTo(X(3), Y(3))
            ctx.lineTo(X(6.75), Y(6.75))
            ctx.stroke()
            break
        case "chevron-left":
            ctx.beginPath()
            ctx.moveTo(X(11.5), Y(4))
            ctx.lineTo(X(6), Y(9))
            ctx.lineTo(X(11.5), Y(14))
            ctx.stroke()
            break
        case "chevron-right":
            ctx.beginPath()
            ctx.moveTo(X(6.5), Y(4))
            ctx.lineTo(X(12), Y(9))
            ctx.lineTo(X(6.5), Y(14))
            ctx.stroke()
            break
        case "ellipsis":
            ctx.beginPath()
            ctx.arc(X(4.5), Y(9), 1.5 * u, 0, Math.PI * 2)
            ctx.arc(X(9), Y(9), 1.5 * u, 0, Math.PI * 2)
            ctx.arc(X(13.5), Y(9), 1.5 * u, 0, Math.PI * 2)
            ctx.fill()
            break
        case "music":
            ctx.beginPath()
            ctx.arc(X(5.5), Y(13), 2.9 * u, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(13.5), Y(11.7), 2.9 * u, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(8.4), Y(13))
            ctx.lineTo(X(8.4), Y(4.5))
            ctx.lineTo(X(16.4), Y(3))
            ctx.lineTo(X(16.4), Y(11.7))
            ctx.stroke()
            break
        case "list":
            ctx.beginPath()
            ctx.arc(X(4), Y(5), 1 * u, 0, Math.PI * 2)
            ctx.arc(X(4), Y(9), 1 * u, 0, Math.PI * 2)
            ctx.arc(X(4), Y(13), 1 * u, 0, Math.PI * 2)
            ctx.fill()
            ctx.beginPath()
            ctx.moveTo(X(7.5), Y(5)); ctx.lineTo(X(15), Y(5))
            ctx.moveTo(X(7.5), Y(9)); ctx.lineTo(X(15), Y(9))
            ctx.moveTo(X(7.5), Y(13)); ctx.lineTo(X(15), Y(13))
            ctx.stroke()
            break
        case "clock":
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 6 * u, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(9), Y(5.4))
            ctx.lineTo(X(9), Y(9.3))
            ctx.lineTo(X(12), Y(11))
            ctx.stroke()
            break
        case "refresh":
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 5.4 * u, -Math.PI * 0.75, Math.PI * 0.75)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(13.6), Y(4.7))
            ctx.lineTo(X(14.4), Y(8.2))
            ctx.lineTo(X(10.9), Y(7.4))
            ctx.stroke()
            break
        case "check":
            ctx.beginPath()
            ctx.moveTo(X(4), Y(9.5))
            ctx.lineTo(X(7.5), Y(13))
            ctx.lineTo(X(14.5), Y(5))
            ctx.stroke()
            break
        case "volume-1":
            ctx.beginPath()
            ctx.moveTo(X(3), Y(7))
            ctx.lineTo(X(6), Y(7))
            ctx.lineTo(X(9.5), Y(3.8))
            ctx.lineTo(X(9.5), Y(14.2))
            ctx.lineTo(X(6), Y(11))
            ctx.lineTo(X(3), Y(11))
            ctx.closePath()
            ctx.fill()
            ctx.beginPath()
            ctx.arc(X(9.5), Y(9), 3 * u, -Math.PI / 3, Math.PI / 3)
            ctx.stroke()
            break
        case "volume-x":
            ctx.beginPath()
            ctx.moveTo(X(3), Y(7))
            ctx.lineTo(X(6), Y(7))
            ctx.lineTo(X(9.5), Y(3.8))
            ctx.lineTo(X(9.5), Y(14.2))
            ctx.lineTo(X(6), Y(11))
            ctx.lineTo(X(3), Y(11))
            ctx.closePath()
            ctx.fill()
            ctx.beginPath()
            ctx.moveTo(X(12), Y(6.5)); ctx.lineTo(X(16), Y(11.5))
            ctx.moveTo(X(16), Y(6.5)); ctx.lineTo(X(12), Y(11.5))
            ctx.stroke()
            break
        case "grid":
            ctx.beginPath()
            ctx.rect(X(3.5), Y(3.5), 5 * u, 5 * u)
            ctx.rect(X(9.5), Y(3.5), 5 * u, 5 * u)
            ctx.rect(X(3.5), Y(9.5), 5 * u, 5 * u)
            ctx.rect(X(9.5), Y(9.5), 5 * u, 5 * u)
            ctx.stroke()
            break
        case "pencil":
            ctx.beginPath()
            ctx.moveTo(X(3.6), Y(14.4))
            ctx.lineTo(X(4.4), Y(11.0))
            ctx.lineTo(X(11.6), Y(3.8))
            ctx.lineTo(X(14.2), Y(6.4))
            ctx.lineTo(X(7.0), Y(13.6))
            ctx.closePath()
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(10.6), Y(4.8))
            ctx.lineTo(X(13.2), Y(7.4))
            ctx.stroke()
            break
        case "trash":
            ctx.beginPath()
            ctx.moveTo(X(3.6), Y(5.2))
            ctx.lineTo(X(14.4), Y(5.2))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(6.6), Y(5.2))
            ctx.lineTo(X(7.1), Y(3.3))
            ctx.lineTo(X(10.9), Y(3.3))
            ctx.lineTo(X(11.4), Y(5.2))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(5.2), Y(5.2))
            ctx.lineTo(X(5.9), Y(14.7))
            ctx.lineTo(X(12.1), Y(14.7))
            ctx.lineTo(X(12.8), Y(5.2))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(7.7), Y(7.3))
            ctx.lineTo(X(8.0), Y(12.5))
            ctx.moveTo(X(10.3), Y(7.3))
            ctx.lineTo(X(10.0), Y(12.5))
            ctx.stroke()
            break
        case "link":
            ctx.beginPath()
            ctx.moveTo(X(9.8), Y(8.2))
            ctx.lineTo(X(8.2), Y(9.8))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(10.6), Y(6.4))
            ctx.lineTo(X(12.6), Y(4.4))
            ctx.bezierCurveTo(X(13.9), Y(3.1), X(15.6), Y(4.8), X(14.3), Y(6.1))
            ctx.lineTo(X(12.3), Y(8.1))
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(X(7.4), Y(11.6))
            ctx.lineTo(X(5.4), Y(13.6))
            ctx.bezierCurveTo(X(4.1), Y(14.9), X(2.4), Y(13.2), X(3.7), Y(11.9))
            ctx.lineTo(X(5.7), Y(9.9))
            ctx.stroke()
            break
        case "user":
            ctx.beginPath()
            ctx.arc(X(9), Y(6.4), 3.0 * u, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(X(9), Y(16.2), 6.0 * u, Math.PI * 1.16, Math.PI * 1.84)
            ctx.stroke()
            break
        default:
            ctx.beginPath()
            ctx.arc(X(9), Y(9), 5 * u, 0, Math.PI * 2)
            ctx.stroke()
        }
    }
}
