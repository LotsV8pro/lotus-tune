cmake_minimum_required(VERSION 3.19)

project(lotus-tune VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Quick Network DBus Sql Multimedia)

qt_standard_project_setup()

qt_add_executable(lotus-tune
    src/main.cpp
    src/theme.h
    src/theme.cpp
    src/player.h
    src/player.cpp
    src/catalog.h
    src/catalog.cpp
    src/sources.h
    src/sources.cpp
    src/appconfig.h
    src/appconfig.cpp
    src/lyrics.h
    src/lyrics.cpp
    src/discordrpc.h
    src/discordrpc.cpp
    src/mpris.h
    src/mpris.cpp
    src/downloads.h
    src/downloads.cpp
    src/sfx.h
    src/sfx.cpp
    src/perf.h
)

qt_add_qml_module(lotus-tune
    URI LotusTune
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/Sidebar.qml
        qml/TopBar.qml
        qml/PlayerBar.qml
        qml/RightPanel.qml
        qml/QueueView.qml
        qml/Glyph.qml
        qml/LikeButton.qml
        qml/LotusMark.qml
        qml/LockedPanel.qml
        qml/theme.js
        qml/HomePage.qml
        qml/HomeCard.qml
        qml/SearchPage.qml
        qml/LibraryPage.qml
        qml/CoverTile.qml
        qml/ContextMenu.qml
        qml/PlaylistEditor.qml
        qml/NowPlaying.qml
        qml/LyricsView.qml
)

qt_add_resources(lotus-tune "ui_sounds"
    PREFIX "/sounds"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/sounds"
    FILES
        sounds/click.wav
        sounds/click_toggle.wav
        sounds/click_play.wav
        sounds/click_like.wav
        sounds/silence.wav
)

# Ship the embedded YT Music login helper and the "mis listas" API helper
# next to the executable.
add_custom_command(TARGET lotus-tune POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/tools/ytm_login.py"
        "$<TARGET_FILE_DIR:lotus-tune>/ytm_login.py"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/tools/ytm_api.py"
        "$<TARGET_FILE_DIR:lotus-tune>/ytm_api.py"
)

target_link_libraries(lotus-tune PRIVATE
    Qt6::Quick
    Qt6::Network
    Qt6::DBus
    Qt6::Sql
    Qt6::Multimedia
)

install(TARGETS lotus-tune RUNTIME DESTINATION bin)
