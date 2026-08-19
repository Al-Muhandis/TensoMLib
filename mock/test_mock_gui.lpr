program test_mock_gui;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, test_mock_server, GuiTestRunner
  ;

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TGuiTestRunner, TestRunner);
  Application.Run;
end.

