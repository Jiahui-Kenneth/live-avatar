#define MyAppName "Live Avatar"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "HeiXia2077"
#define MyAppURL "https://github.com/HeiXia2077/live-avatar"

[Setup]
AppId={{5F864A9B-2C6F-4B96-8B0D-A56B6358A7A1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={localappdata}\LiveAvatar
DefaultGroupName=Live Avatar
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=dist
OutputBaseFilename=LiveAvatar-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Live Avatar {#MyAppVersion}
VersionInfoVersion=0.1.0.0
VersionInfoProductVersion=0.1.0
VersionInfoDescription=Live Avatar online installer
ChangesEnvironment=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "bootstrap.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "modules\*.psm1"; DestDir: "{app}\installer\modules"; Flags: ignoreversion
Source: "manifests\*.json"; DestDir: "{app}\installer\manifests"; Flags: ignoreversion
Source: "ui\*.psm1"; DestDir: "{app}\installer\ui"; Flags: ignoreversion
Source: "..\launcher\*.ps1"; DestDir: "{app}\launcher"; Flags: ignoreversion
Source: "..\launcher\*.cmd"; DestDir: "{app}\launcher"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Live Avatar\Live Avatar"; Filename: "{app}\launcher\Start-LiveAvatar.cmd"; WorkingDir: "{app}"
Name: "{userprograms}\Live Avatar\Stop Live Avatar"; Filename: "{app}\launcher\Stop-LiveAvatar.cmd"; WorkingDir: "{app}"
Name: "{userprograms}\Live Avatar\Live Avatar Maintenance"; Filename: "{app}\launcher\Maintain-LiveAvatar.cmd"; Parameters: "doctor"; WorkingDir: "{app}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\installer\bootstrap.ps1"" -InstallRoot ""{app}"" -DataRoot ""{code:GetDataRoot}"""; StatusMsg: "Downloading and verifying Live Avatar components..."; Flags: postinstall waituntilterminated skipifsilent

[Code]
var
  DataDirPage: TInputDirWizardPage;
  DeleteModels: TNewCheckBox;
  DeleteAvatars: TNewCheckBox;
  DeleteSettings: TNewCheckBox;
  DeleteModelsSelected: Boolean;
  DeleteAvatarsSelected: Boolean;
  DeleteSettingsSelected: Boolean;
  UninstallDataRoot: string;

procedure InitializeWizard;
begin
  DataDirPage := CreateInputDirPage(wpSelectDir,
    'Models and user data',
    'Choose where models, avatars, settings, and caches are stored.',
    'Keeping this separate lets upgrades preserve your personal data.', False, '');
  DataDirPage.Add('Data directory:');
  DataDirPage.Values[0] := ExpandConstant('{param:DataRoot|{localappdata}\LiveAvatar\data}');
end;

function GetDataRoot(Param: string): string;
begin
  Result := DataDirPage.Values[0];
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    SaveStringToFile(ExpandConstant('{app}\installer-data-root.txt'),
      GetDataRoot(''), False);
end;

function IsSafeDataRoot(Path: string): Boolean;
var
  Expanded: string;
begin
  Expanded := ExpandFileName(Trim(Path));
  Result := (Length(Expanded) > 3) and
    (CompareText(AddBackslash(Expanded), AddBackslash(ExtractFileDrive(Expanded))) <> 0);
end;

function InitializeUninstall(): Boolean;
var
  RootFile: string;
  RootValue: AnsiString;
  ChoiceForm: TSetupForm;
  DescriptionLabel: TNewStaticText;
  OkButton: TNewButton;
  CancelButton: TNewButton;
begin
  RootFile := ExpandConstant('{app}\installer-data-root.txt');
  UninstallDataRoot := '';
  if FileExists(RootFile) and LoadStringFromFile(RootFile, RootValue) then
    UninstallDataRoot := String(RootValue);

  ChoiceForm := CreateCustomForm(ScaleX(460), ScaleY(240), False, True);
  ChoiceForm.Caption := 'Uninstall Live Avatar';

  DescriptionLabel := TNewStaticText.Create(ChoiceForm);
  DescriptionLabel.Parent := ChoiceForm;
  DescriptionLabel.Left := ScaleX(20);
  DescriptionLabel.Top := ScaleY(18);
  DescriptionLabel.Width := ScaleX(420);
  DescriptionLabel.Height := ScaleY(42);
  DescriptionLabel.AutoSize := False;
  DescriptionLabel.Caption := 'Program files will be removed. Personal data is preserved unless explicitly selected below.';

  DeleteModels := TNewCheckBox.Create(ChoiceForm);
  DeleteModels.Parent := ChoiceForm;
  DeleteModels.Left := ScaleX(20);
  DeleteModels.Top := ScaleY(76);
  DeleteModels.Width := ScaleX(420);
  DeleteModels.Caption := 'Also delete downloaded LLM models';
  DeleteModels.Checked := False;

  DeleteAvatars := TNewCheckBox.Create(ChoiceForm);
  DeleteAvatars.Parent := ChoiceForm;
  DeleteAvatars.Left := ScaleX(20);
  DeleteAvatars.Top := DeleteModels.Top + ScaleY(30);
  DeleteAvatars.Width := ScaleX(420);
  DeleteAvatars.Caption := 'Also delete custom avatars';
  DeleteAvatars.Checked := False;

  DeleteSettings := TNewCheckBox.Create(ChoiceForm);
  DeleteSettings.Parent := ChoiceForm;
  DeleteSettings.Left := ScaleX(20);
  DeleteSettings.Top := DeleteAvatars.Top + ScaleY(30);
  DeleteSettings.Width := ScaleX(420);
  DeleteSettings.Caption := 'Also delete settings and local management token';
  DeleteSettings.Checked := False;

  OkButton := TNewButton.Create(ChoiceForm);
  OkButton.Parent := ChoiceForm;
  OkButton.Caption := 'Uninstall';
  OkButton.ModalResult := mrOk;
  OkButton.Left := ScaleX(270);
  OkButton.Top := ScaleY(192);
  OkButton.Width := ScaleX(80);

  CancelButton := TNewButton.Create(ChoiceForm);
  CancelButton.Parent := ChoiceForm;
  CancelButton.Caption := 'Cancel';
  CancelButton.ModalResult := mrCancel;
  CancelButton.Left := ScaleX(360);
  CancelButton.Top := ScaleY(192);
  CancelButton.Width := ScaleX(80);

  if UninstallSilent then
    Result := True
  else
    Result := ChoiceForm.ShowModal = mrOk;
  DeleteModelsSelected := DeleteModels.Checked;
  DeleteAvatarsSelected := DeleteAvatars.Checked;
  DeleteSettingsSelected := DeleteSettings.Checked;
  ChoiceForm.Free;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and IsSafeDataRoot(UninstallDataRoot) then
  begin
    if DeleteModelsSelected then
      DelTree(AddBackslash(UninstallDataRoot) + 'models', True, True, True);
    if DeleteAvatarsSelected then
      DelTree(AddBackslash(UninstallDataRoot) + 'avatars', True, True, True);
    if DeleteSettingsSelected then
      DelTree(AddBackslash(UninstallDataRoot) + 'config', True, True, True);
  end;
end;
