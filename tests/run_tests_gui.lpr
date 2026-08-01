program run_tests_gui;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, LazSerialPort, GuiTestRunner,
  test_crc in 'test_crc.pas',
  test_bcd in 'test_bcd.pas',
  test_frames in 'test_frames.pas',
  test_transport in 'test_transport.pas',
  test_client in 'test_client.pas'
  ;

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TGuiTestRunner, TestRunner);
  Application.Run;
end.

