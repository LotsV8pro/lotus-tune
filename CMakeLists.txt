cmake_minimum_required(VERSION 3.19)

project(lotus-tune
    VERSION 1.2.0
    DESCRIPTION "Reproductor de música para YouTube Music (Qt 6 / QML)"
    HOMEPAGE_URL "https://github.com/LotsV8pro/lotus-tune"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# ---------------------------------------------------------------------------
# Platform
#
# The app is a desktop application (Linux, Windows) and the same sources are
# built for Android. The pieces that need the desktop are guarded with
# Q_OS_ANDROID in the code: mpv (the playback engine), yt-dlp (the stream
# resolver), the D-Bus service (MPRIS) and the Discord rich presence.
# ---------------------------------------------------------------------------
option(LOTUS_ANDROID "Build the Android (APK) flavour" OFF)
if(LOTUS_ANDROID)
    set(ANDROID TRUE)
endif()

if(ANDROID)
    # The Android NDK build: no D-Bus and no desktop integrations.
    find_package(Qt6 6.5 REQUIRED COMPONENTS Quick Network Sql Multimedia)
    set(LOTUS_DESKTOP OFF)
else()
    find_package(Qt6 6.5 REQUIRED COMPONENTS Quick Network DBus Sql Multimedia Test)
    set(LOTUS_DESKTOP ON)
endif()

qt_standard_project_setup()


set(LOTUS_SOURCES
    src/main.cpp
    src/roundedart.cpp
    src/roundedart.h
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
    src/stubs.h
    src/downloads.h
    src/downloads.cpp
    src/sfx.h
    src/sfx.cpp
    src/perf.h
    src/wash.h
    src/wash.cpp
    src/updates.h
    src/updates.cpp
)

qt_add_executable(lotus-tune ${LOTUS_SOURCES})

# The native catalogue helper for the phone: on Android Catalog runs this
# binary instead of "python3 ytm_api.py" / "yt-dlp" (there is no Python and
# no yt-dlp in an APK). Its name must start with lib…so so the Android
# packaging includes it as an extra native library; it stays a PIE
# EXECUTABLE (Android launches it through QProcess like the python one).
option(LOTUS_TMCLI "Build the ytmcli helper" OFF)
if(ANDROID)
    set(LOTUS_TMCLI ON)
endif()
if(LOTUS_TMCLI)
    add_executable(lotus-ytmcli src/ytmcli_main.cpp)
    target_link_libraries(lotus-ytmcli PRIVATE Qt6::Core Qt6::Network)
    if(ANDROID)
        set_target_properties(lotus-ytmcli PROPERTIES
            OUTPUT_NAME "ytmcli" PREFIX "lib" SUFFIX ".so")
        # The NDK toolchain links executables with -static-libstdc++ (two
        # std-lib entities: the static copy in this binary and the shared
        # libc++_shared.so of the Qt libs) -> at start the locale facets
        # resolve to the wrong copy and libc++ throws std::bad_cast inside
        # std::ios_base::Init. -nostdlib++ (later than the toolchain flag,
        # so it wins) plus an explicit libc++_shared.so make the executable
        # a member of the same std library the Qt libs use.
        target_link_options(lotus-ytmcli PRIVATE -nostdlib++)
        target_include_directories(lotus-ytmcli SYSTEM PRIVATE
            ${CMAKE_SOURCE_DIR}/third_party/openssl)
        # OpenSSL transport: link the same packaged libs (their SONAME are
        # libssl.so / libcrypto.so, resolved from LD_LIBRARY_PATH when the
        # helper is launched).
        target_link_libraries(lotus-ytmcli PRIVATE
            ${CMAKE_SOURCE_DIR}/build-android/android-build/libs/arm64-v8a/libssl_3.so
            ${CMAKE_SOURCE_DIR}/build-android/android-build/libs/arm64-v8a/libcrypto_3.so)
        # Derive the absolute libc++_shared.so path from the toolchain's
        # own bin directory (ANDROID_NDK_ROOT is not always exported).
        get_filename_component(_lotus_ndk_bin "${CMAKE_AR}" DIRECTORY)
        target_link_libraries(lotus-ytmcli PRIVATE
            ${_lotus_ndk_bin}/../sysroot/usr/lib/aarch64-linux-android/libc++_shared.so)
    else()
        set_target_properties(lotus-ytmcli PROPERTIES OUTPUT_NAME "ytmcli")
        # TEMP: force the OpenSSL transport on the host as well for the
        # parity debugging of this build iteration.
        target_compile_definitions(lotus-ytmcli PRIVATE LTM_OSSL)
        target_include_directories(lotus-ytmcli SYSTEM PRIVATE
            ${CMAKE_SOURCE_DIR}/third_party/openssl)
        target_link_libraries(lotus-ytmcli PRIVATE ssl crypto)
    endif()
endif()

# The QML module is the same for desktop and Android: qt_add_qml_module
# embeds it in the binary resources (qmldir + types) and the finalizer
# links the static plugin so loadFromModule("LotusTune", "Main") works
# on both desktop and Android.
qt_add_qml_module(lotus-tune
    URI LotusTune
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/Panel.qml
        qml/Sidebar.qml
        qml/BottomNav.qml
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
        qml/ArtImage.qml
        qml/HomeCard.qml
        qml/RoundedArt.qml
        qml/SearchPage.qml
        qml/ArtistPage.qml
        qml/LibraryPage.qml
        qml/CoverTile.qml
        qml/ContextMenu.qml
        qml/PlaylistEditor.qml
        qml/LyricsView.qml
        qml/FullscreenLyrics.qml
    RESOURCES
        packaging/icons/lotus-tune.svg
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

# The Discord rich presence works on Android too (the socket is in the
# abstract namespace there), so it is always built. MPRIS needs D-Bus and
# stays for the desktop only.
target_sources(lotus-tune PRIVATE
    src/discordrpc.h
    src/discordrpc.cpp
)
if(LOTUS_DESKTOP)
    target_sources(lotus-tune PRIVATE
        src/mpris.h
        src/mpris.cpp
    )
endif()

# The version is compiled in so the app can compare it with the one
# published in the repository.
target_compile_definitions(lotus-tune PRIVATE
    LOTUS_TUNE_VERSION="${PROJECT_VERSION}")

# For Android, the QML module must be importable from the source tree
# (the APK does not embed the module by default). We add the QML import
# path as a CMake property so that the "LotusTune" module can be found.

target_link_libraries(lotus-tune PRIVATE
    Qt6::Quick
    Qt6::Network
    Qt6::Sql
    Qt6::Multimedia
    Qt6::Qml
)

# On Android the executable is packaged as an APK: the Gradle project of
# the app (manifest, activity, resources) lives in android/. The
# finalization (which also links the static QML plugin so
# loadFromModule("LotusTune", "Main") resolves types) is already done
# automatically at the end of the directory scope - calling it manually
# here runs it twice and skips qt_import_qml_plugins.
if(ANDROID)
    set_property(TARGET lotus-tune PROPERTY
        QT_ANDROID_PACKAGE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/android")
endif()
if(LOTUS_DESKTOP)
    target_link_libraries(lotus-tune PRIVATE Qt6::DBus)
endif()

# ---------------------------------------------------------------------------
# Install (Linux / Windows)
# ---------------------------------------------------------------------------
if(NOT ANDROID)
    # On Android the executable is packaged by Gradle (it is a library
    # there, so the install rules do not apply).
    install(TARGETS lotus-tune RUNTIME DESTINATION bin)
    install(PROGRAMS
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/ytm_login.py"
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/ytm_api.py"
        DESTINATION bin)
endif()
if(NOT ANDROID)
install(FILES
        "${CMAKE_CURRENT_SOURCE_DIR}/packaging/lotus-tune.desktop"
    DESTINATION share/applications)
install(FILES
        "${CMAKE_CURRENT_SOURCE_DIR}/packaging/icons/lotus-tune.svg"
    DESTINATION share/icons/hicolor/scalable/apps)
install(FILES
        "${CMAKE_CURRENT_SOURCE_DIR}/packaging/lotus-tune.metainfo.xml"
    DESTINATION share/metainfo)
install(FILES
        "${CMAKE_CURRENT_SOURCE_DIR}/README.md"
    DESTINATION share/doc/lotus-tune
    OPTIONAL)
endif()

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
enable_testing()
if(NOT ANDROID)
# The test module does not exist for Android.
add_executable(lotus-tune-tests
    tests/test_all.cpp
    src/downloads.cpp
    src/player.cpp
    src/appconfig.cpp
    src/sources.cpp
    src/lyrics.cpp
    src/catalog.cpp
)
target_include_directories(lotus-tune-tests PRIVATE src)
target_link_libraries(lotus-tune-tests PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Network
    Qt6::Sql
    Qt6::Test
)
add_test(NAME AllTests COMMAND lotus-tune-tests)
endif()

# ---------------------------------------------------------------------------
# Packaging (CPack): .deb, .rpm, .AppImage, .exe (NSIS) and .zip
# ---------------------------------------------------------------------------
set(CPACK_PACKAGE_NAME "lotus-tune")
set(CPACK_PACKAGE_VENDOR "LotsV8pro")
set(CPACK_PACKAGE_CONTACT "LotsV8pro <lotsv8pro@users.noreply.github.com>")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "LotsV8pro")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "${PROJECT_DESCRIPTION}")
set(CPACK_PACKAGE_HOMEPAGE_URL "${PROJECT_HOMEPAGE_URL}")
set(CPACK_PACKAGE_INSTALL_DIRECTORY "LotusTune")
set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
set(CPACK_DEBIAN_PACKAGE_SECTION "audio")
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libqt6quick6, libqt6network6, libqt6sql6, libqt6multimedia6, qt6-qpa-plugins, mpv, yt-dlp, python3")
set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)
set(CPACK_RPM_PACKAGE_GROUP "Applications/Multimedia")
set(CPACK_RPM_PACKAGE_LICENSE "MIT")
set(CPACK_RPM_FILE_NAME RPM-DEFAULT)
set(CPACK_RPM_PACKAGE_SUGGESTS "mpv yt-dlp python3")
set(CPACK_GENERATOR "TGZ")
if(NOT ANDROID)
    set(CPACK_GENERATOR "DEB;RPM;TGZ")
endif()
include(CPack)
