program run_tests;

{
  Консольный запускатор юнит-тестов TensoMLib (FPCUnit).

  Сборка (из корня проекта TensoMLib/):
    fpc -MObjFPC -Sh -FUsrc -Futests tests/run_tests.lpr

  Запуск:
    ./run_tests --format=plain
    ./run_tests --all
}

{$mode objfpc}{$H+}

uses
  consoletestrunner,
  test_crc in 'test_crc.pas',
  test_bcd in 'test_bcd.pas',
  test_frames in 'test_frames.pas',
  test_transport in 'test_transport.pas',
  test_client in 'test_client.pas'
  ;

type
  TMyRunner = class(TTestRunner)
  end;

var
  Application: TMyRunner;

begin
  DefaultRunAllTests := True;
  Application := TMyRunner.Create(nil);
  try
    Application.Initialize;
    Application.Title := 'TensoMLib Tests';
    Application.Run;
  finally
    Application.Free;
  end;
end.
