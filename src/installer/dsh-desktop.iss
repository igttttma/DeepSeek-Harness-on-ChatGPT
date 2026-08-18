#define PayloadDir "@@PAYLOAD_DIR@@"
#define OutputDir "@@OUTPUT_DIR@@"
#define ProductVersion "@@PRODUCT_VERSION@@"
#define ProductIcon "@@PRODUCT_ICON@@"

[Setup]
AppId={{CFE96916-C62E-4D38-91A2-E6596A505448}
AppName=DeepSeek Harness (on ChatGPT)
AppVersion={#ProductVersion}
AppPublisher=DeepSeek Harness (on ChatGPT)
AppPublisherURL=https://github.com/deepseek-ai/deepseek-harness
DefaultDirName={localappdata}\Programs\DeepSeek Harness (on ChatGPT)
DefaultGroupName=DeepSeek Harness (on ChatGPT)
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=DeepSeek-Harness-on-ChatGPT-Setup-{#ProductVersion}-win-x64
SetupIconFile={#ProductIcon}
UninstallDisplayIcon={app}\DeepSeek Harness (on ChatGPT).exe
UninstallDisplayName=DeepSeek Harness (on ChatGPT)
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoCompany=DeepSeek Harness (on ChatGPT)
VersionInfoDescription=DeepSeek Harness (on ChatGPT) Installer
VersionInfoProductName=DeepSeek Harness (on ChatGPT)

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\DeepSeek Harness (on ChatGPT).exe"; DestDir: "{tmp}"; DestName: "dsh-preflight.exe"; Flags: dontcopy solidbreak
Source: "{#PayloadDir}\dsh-runtime\meta\release-manifest.json"; DestDir: "{tmp}"; DestName: "dsh-release-manifest.json"; Flags: dontcopy solidbreak

[Icons]
Name: "{autoprograms}\DeepSeek Harness (on ChatGPT)"; Filename: "{app}\DeepSeek Harness (on ChatGPT).exe"; WorkingDir: "{app}"; AppUserModelID: "DeepSeek.HarnessOnChatGPT"
Name: "{autoprograms}\Uninstall DeepSeek Harness (on ChatGPT)"; Filename: "{uninstallexe}"
Name: "{autodesktop}\DeepSeek Harness (on ChatGPT)"; Filename: "{app}\DeepSeek Harness (on ChatGPT).exe"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "DeepSeek.HarnessOnChatGPT"

[Registry]
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\DeepSeek.HarnessOnChatGPT"; ValueType: string; ValueName: "DisplayName"; ValueData: "DeepSeek Harness (on ChatGPT)"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\DeepSeek.HarnessOnChatGPT"; ValueType: string; ValueName: "IconUri"; ValueData: "{app}\DeepSeek Harness (on ChatGPT).exe"; Flags: uninsdeletekey

[Run]
Filename: "{app}\DeepSeek Harness (on ChatGPT).exe"; Description: "Launch DeepSeek Harness (on ChatGPT)"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\parasite-runtime\owl-host"
Type: filesandordirs; Name: "{app}\parasite-runtime\owl-ud-dsh"
Type: filesandordirs; Name: "{app}\dsh-runtime\.dshhome"
Type: filesandordirs; Name: "{app}\dsh-runtime\node_modules"
Type: dirifempty; Name: "{app}\dsh-runtime"
Type: dirifempty; Name: "{app}"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
  ResultFile: String;
  Details: AnsiString;
  Args: String;
begin
  ExtractTemporaryFile('dsh-preflight.exe');
  ExtractTemporaryFile('dsh-release-manifest.json');
  ResultFile := ExpandConstant('{tmp}\dsh-preflight-result.txt');
  DeleteFile(ResultFile);
  Args := 'preflight "' + ExpandConstant('{tmp}\dsh-release-manifest.json') + '" "' + ResultFile + '"';
  if not Exec(ExpandConstant('{tmp}\dsh-preflight.exe'), Args, '', SW_HIDE,
    ewWaitUntilTerminated, ExitCode) then
  begin
    Result := 'Unable to run the ChatGPT compatibility check.';
    exit;
  end;
  if ExitCode <> 0 then
  begin
    if LoadStringFromFile(ResultFile, Details) then
      Result := String(Details)
    else
      Result := 'The local ChatGPT runtime does not provide every dependency required by DeepSeek Harness (on ChatGPT).';
    exit;
  end;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    if (not Exec(ExpandConstant('{app}\DeepSeek Harness (on ChatGPT).exe'), 'prepare', ExpandConstant('{app}'),
      SW_HIDE, ewWaitUntilTerminated, ExitCode)) or (ExitCode <> 0) then
      RaiseException('DeepSeek Harness (on ChatGPT) could not create its ChatGPT links. Setup will not complete.');
  end;
end;

function InitializeUninstall(): Boolean;
var
  ExitCode: Integer;
begin
  Result := True;
  if FileExists(ExpandConstant('{app}\DeepSeek Harness (on ChatGPT).exe')) then
  begin
    if (not Exec(ExpandConstant('{app}\DeepSeek Harness (on ChatGPT).exe'), 'uninstall', ExpandConstant('{app}'),
      SW_HIDE, ewWaitUntilTerminated, ExitCode)) or (ExitCode <> 0) then
    begin
      MsgBox('DeepSeek Harness (on ChatGPT) cleanup failed. Uninstall was stopped to avoid leaving junctions behind.',
        mbError, MB_OK);
      Result := False;
    end;
  end;
end;
