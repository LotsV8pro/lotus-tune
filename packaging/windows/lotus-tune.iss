; Inno Setup 6 script for the Windows installer of LotusTune.
;
; The folder it packs is build\Release AFTER windeployqt and after the step
; that drops mpv, yt-dlp and the embedded Python in it (see the windows job
; of .github/workflows/build.yml). Everything the app needs to play travels
; inside: the machine it is installed on needs no Python, no yt-dlp and no
; mpv.
;
; Per-user install (no administrator rights): %LOCALAPPDATA%\Programs\
; LotusTune. That is also what keeps the built-in updater working, because
; it unpacks the new version over the folder of the running .exe and that
; folder is writable for the user who installed it.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "LotusTune"
#define AppExe "lotus-tune.exe"
#define AppPublisher "LotusTune"
#define AppURL "https://github.com/LotsV8pro/lotus-tune"
; Fixed id: the uninstaller of a newer version is the same application, so
; the entry of "Programs and features" is updated and not duplicated.
#define AppId "{{7C1B4F52-9A3E-4B7D-8E1C-5D2A6F03B9E4}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={localappdata}\Programs\LotusTune
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; No admin: a per-user install, like the configuration the app itself keeps
; in %APPDATA%.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\installer
OutputBaseFilename=LotusTune-Setup-{#AppVersion}
SetupIconFile=..\icons\lotus-tune.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; The player is running while the user updates: Setup asks the Restart
; Manager to close it instead of failing with "file in use".
CloseApplications=yes
RestartApplications=no
; 64-bit only payload: nothing to do on a 32-bit Windows.
MinVersion=10.0

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole deployed tree: the .exe, the Qt libraries, the plugins,
; ytm_api.py, ytm_login.py, mpv.exe, yt-dlp.exe and python\.
Source: "..\..\build\Release\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; \
    Flags: nowait postinstall skipifsilent

[UninstallDelete]
; The Qt cache, compiled QML and the covers the app wrote inside its own
; folder (if any). The library, the settings and the downloads live outside
; and are kept: reinstalling picks them up again.
Type: filesandordirs; Name: "{app}"
