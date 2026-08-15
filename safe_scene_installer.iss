; ============================================================================
;  Safe Scene — Windows Installer Script (Inno Setup 6)
; ----------------------------------------------------------------------------
;  Build steps:
;     1. flutter build windows --release
;     2. iscc.exe safe_scene_installer.iss
;  Output: dist\SafeScene_Setup_vX.Y.Z.exe
; ============================================================================

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#define MyAppName        "Safe Scene"
#define MyAppExeName     "safe_scene.exe"
#define MyPublisher      "MRZMSOFT"
#define MyGroupName      "Safe Scene"
#define FlutterReleaseDir "build\windows\x64\runner\Release"
#define SetupIconFile    "windows\runner\resources\app_icon.ico"

[Setup]
; NOTE: The value of AppId uniquely identifies this application.
; Do not use the same AppId value in installers of other applications.
AppId={{D3C7E9B1-2F4A-4C8E-9B5A-6E2F1A8C3D45}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyPublisher}
DefaultDirName={autopf}\SafeScene
DefaultGroupName={#MyGroupName}
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=SafeScene_Setup_v{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
; "x64compatible" covers 64-bit Windows on x64 CPUs and ARM64 Windows
; running x64 code under emulation (matches the bundled x64 Flutter build).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile={#SetupIconFile}
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersion}.0
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoCompany={#MyPublisher}
VersionInfoDescription={#MyAppName} Installer
SetupLogging=yes
OutputManifestFile=SafeScene_Setup_v{#MyAppVersion}-manifest.txt
; Flutter for Windows requires Windows 10 or newer
MinVersion=10.0
; Gracefully close any running Safe Scene instance before installing a new version
CloseApplications=yes

[InstallDelete]
; Clean previous install so no stale files (old DLLs, removed assets) survive upgrades
Type: filesandordirs; Name: "{app}\*"

[Files]
; Flutter Windows Release Build
Source: "{#FlutterReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

; Offline AI binaries (ffmpeg.exe, scanner_engine.exe, ...)
; NOTE: assets\bin is optional; this section is only compiled once the
;       directory exists in the project root. Drop your binaries there and
;       they will be bundled automatically.
#if DirExists("assets\bin")
Source: "assets\bin\*"; DestDir: "{app}\assets\bin"; Flags: ignoreversion recursesubdirs
#endif

; Offline AI models (nudenet.onnx, whisper models, ...)
#if DirExists("assets\models")
Source: "assets\models\*"; DestDir: "{app}\assets\models"; Flags: ignoreversion recursesubdirs
#endif

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent