program SharpSkin;

uses
  ShareMem,
  Forms,
  MainWnd in 'MainWnd.pas' {MainForm};

{$R 'VersionInfo.res'}
{$R *.res}
{$R 'SharpSkin.manifest.res'}   // Win11: supportedOS + comctl32 v6

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'SharpEnviro Skin Validator';
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
