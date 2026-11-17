import QtQuick
import "theme.js" as Theme

// Floating island: rounded surface WITHOUT an edge (the light border was
// removed: in the current visual language the separation comes from the
// air and the fill, not from a line). It is the brick of the interface -
// the rail, the title bar, the playback bar, the side panel and the
// content are all `Panel`.
//
// Note about the shadow: on a background that dark (#151115) a black
// shadow adds no contrast, so the feeling of "floating" comes from the air
// of `panelMargin`/`panelGap`. No effects or textures: zero render cost.
//
// The children declared inside are placed ON the surface, so `clipContent`
// clips the content to the island's corners (useful for lists that
// scroll). The inner padding is up to each component.
Item {
    id: panel

    property real radius: Theme.rPanel
    // With the "dynamic background" on, the island becomes frosted glass:
    // it lets a bit of the artwork wash through (which already comes
    // "blurred" as a tiny image stretched), so the tint is soft and the
    // text keeps its contrast. Without the dynamic background, the
    // surface stays opaque as always.
    property color color: Sys.dynamicBg
                          ? Theme.alpha(Sys.surface, 0.84)
                          : Sys.surface
    property color borderColor: "transparent"
    property real borderWidth: 0
    property bool clipContent: false

    default property alias content: surface.data

    Rectangle {
        id: surface
        anchors.fill: parent
        radius: panel.radius
        color: panel.color
        border.width: panel.borderWidth
        border.color: panel.borderColor
        clip: panel.clipContent
    }
}
