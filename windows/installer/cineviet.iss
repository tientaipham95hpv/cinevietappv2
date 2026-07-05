; ============================================================
;  CineViet v2 - Inno Setup installer script
;  Builds a single-file .exe installer for the Windows release.
;
;  Usage (on Windows, after `flutter build windows --release`):
;    iscc /DAppVersion=2.0.1 /DAppBuild=9210 ^
;         /DSourceDir="build\windows\x64\runner\Release" ^
;         windows\installer\cineviet.iss
;
;  Requires Inno Setup 6+ (https://jrsoftware.org/isdl.php).
;  Output: dist\CineViet-Setup-<version>+<build>.exe
; ============================================================

#ifndef AppVersion
  #define AppVersion "2.0.1"
#endif
#ifndef AppBuild
  #define AppBuild "0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

#define AppName "CineViet"
#define AppPublisher "CineViet"
#define AppExeName "CineViet.exe"
#define AppUrl "https://cineviet.live"

[Setup]
; A stable GUID keeps upgrades in place (installs over the old version).
AppId={{9F3C1B7A-1D2E-4C6B-9A21-CINEVIET00002}
AppName={#AppName}
AppVersion={#AppVersion}.{#AppBuild}
AppVerName={#AppName} {#AppVersion} (build {#AppBuild})
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Per-user install => no admin/UAC prompt, and Process.start upgrade works
; without elevation. Change to "admin" + {autopf} only if you code-sign.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename=CineViet-Setup-{#AppVersion}+{#AppBuild}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "vietnamese"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Tạo shortcut ngoài Desktop"; GroupDescription: "Shortcuts:"; Flags: checkedonce

[Files]
; Copy the entire Flutter Windows release output (exe + dlls + data\).
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Gỡ cài đặt {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; Register the cineviet:// URL protocol (per-user) for Google login callback,
; replacing the manual Register-CineViet-Google-Login.ps1 step.
Root: HKCU; Subkey: "Software\Classes\cineviet"; ValueType: string; ValueName: ""; ValueData: "URL:CineViet Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\cineviet"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\cineviet\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"
Root: HKCU; Subkey: "Software\Classes\cineviet\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""

[Run]
; Offer to launch the app after install / after an in-app update.
Filename: "{app}\{#AppExeName}"; Description: "Mở {#AppName} ngay"; Flags: nowait postinstall skipifsilent
