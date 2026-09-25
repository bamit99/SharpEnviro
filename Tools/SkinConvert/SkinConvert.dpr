program SkinConvert;

uses
  Forms,
  MainForm in 'MainForm.pas' {Form31};

{$R *.res}
{$R 'SkinConvert.manifest.res'}   // Win11: supportedOS + comctl32 v6

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'SharpEnviro Skin Converter';
  Application.CreateForm(TForm31, Form31);
  Application.Run;
end.
