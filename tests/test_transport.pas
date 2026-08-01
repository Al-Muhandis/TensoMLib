unit test_transport;

{
  Юнит-тесты для transport.pas.

  TSerialTransport требует реальный COM-порт и тестируется только вручную.
  TMockTransport: лог отправки, очередь ответов, хелперы BaudRate.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, core in '../src/core.pas', transport in '../src/transport.pas'
  ;

type
  TTestTransport = class(TTestCase)
  published
    { === TMockTransport: создание и подключение === }
    procedure Test_Mock_Create_NotConnected;
    procedure Test_Mock_Connect;
    procedure Test_Mock_Disconnect;
    procedure Test_Mock_Reconnect;

    { === TMockTransport: отправка === }
    procedure Test_Mock_Send_LogsData;
    procedure Test_Mock_Send_ReturnsLength;
    procedure Test_Mock_Send_MultipleFrames;
    procedure Test_Mock_Send_EmptyData;

    { === TMockTransport: приём === }
    procedure Test_Mock_Receive_QueuedResponse;
    procedure Test_Mock_Receive_MultipleInOrder;
    procedure Test_Mock_Receive_EmptyQueue;
    procedure Test_Mock_Receive_AfterClear;

    { === TMockTransport: очередь === }
    procedure Test_Mock_QueueResponse_CopyIndependence;
    procedure Test_Mock_ClearResponses;

    { === TMockTransport: inspect отправленных === }
    procedure Test_Mock_GetSentData;
    procedure Test_Mock_GetSentCount;
    procedure Test_Mock_GetAllSentHex;
    procedure Test_Mock_GetSentData_OutOfRange;

    { === TMockTransport: прочее === }
    procedure Test_Mock_Flush_NoOp;
    procedure Test_Mock_LastError_Empty;
    procedure Test_Mock_Send_WithoutConnect;

    { === BaudRateToValue === }
    procedure Test_BaudRateToValue_AllCodes;
    procedure Test_BaudRateToValue_UnknownCode_Default9600;
    procedure Test_BaudRateToValue_ZeroCode_Default9600;

    { === BaudRateToCode === }
    procedure Test_BaudRateToCode_AllRates;
    procedure Test_BaudRateToCode_UnknownRate_Default9600;

    { === Круговой путь Baud === }
    procedure Test_Baud_RoundTrip;
  end;

implementation

{ === TMockTransport: создание и подключение === }

procedure TTestTransport.Test_Mock_Create_NotConnected;
var
  M: TMockTransport;
begin
  M := TMockTransport.Create;
  try
    AssertFalse('Не подключён после создания', M.IsConnected);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Connect;
var
  M: TMockTransport;
begin
  M := TMockTransport.Create;
  try
    AssertTrue('Connect возвращает True',
      M.Connect('/dev/ttyUSB0', 9600));
    AssertTrue('IsConnected после Connect', M.IsConnected);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Disconnect;
var
  M: TMockTransport;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/ttyS0', 19200);
    M.Disconnect;
    AssertFalse('IsConnected после Disconnect', M.IsConnected);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Reconnect;
var
  M: TMockTransport;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/ttyUSB0', 9600);
    M.Disconnect;
    AssertTrue('Повторный Connect',
      M.Connect('/dev/ttyUSB1', 115200));
    AssertTrue('IsConnected после reconnect', M.IsConnected);
  finally
    M.Free;
  end;
end;

{ === TMockTransport: отправка === }

procedure TTestTransport.Test_Mock_Send_LogsData;
var
  M: TMockTransport;
  aSent: TBytes = nil;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    SetLength(aSent, 3);
    aSent[0] := $FF; aSent[1] := $01; aSent[2] := $C3;
    M.Send(aSent);

    AssertEquals('1 фрейм отправлен', 1, M.GetSentCount);
    aSent := M.GetSentData(0);
    AssertEquals('Len', 3, Length(aSent));
    AssertEquals('Byte 0', $FF, aSent[0]);
    AssertEquals('Byte 1', $01, aSent[1]);
    AssertEquals('Byte 2', $C3, aSent[2]);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Send_ReturnsLength;
var
  M: TMockTransport;
  aData: TBytes = nil;
  aSentLen: Integer;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    SetLength(aData, 7);
    aData[0] := $AA; aData[1] := $BB; aData[2] := $CC;
    aData[3] := $DD; aData[4] := $EE; aData[5] := $11; aData[6] := $22;
    aSentLen := M.Send(aData);

    AssertEquals('Возвращает длину', 7, aSentLen);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Send_MultipleFrames;
var
  M: TMockTransport;
  D1, D2, D3: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    Initialize(D1);
    SetLength(D1, 2); D1[0] := $AA; D1[1] := $BB;
    Initialize(D2);
    SetLength(D2, 1); D2[0] := $CC;
    Initialize(D3);
    SetLength(D3, 4); D3[0] := $11; D3[1] := $22; D3[2] := $33; D3[3] := $44;

    M.Send(D1);
    M.Send(D2);
    M.Send(D3);

    AssertEquals('3 отправки', 3, M.GetSentCount);

    { Проверяем первый }
    D1 := M.GetSentData(0);
    AssertEquals('D1 len', 2, Length(D1));
    AssertEquals('D1[0]', $AA, D1[0]);

    { Проверяем второй }
    D2 := M.GetSentData(1);
    AssertEquals('D2 len', 1, Length(D2));
    AssertEquals('D2[0]', $CC, D2[0]);

    { Проверяем третий }
    D3 := M.GetSentData(2);
    AssertEquals('D3 len', 4, Length(D3));
    AssertEquals('D3[3]', $44, D3[3]);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Send_EmptyData;
var
  M: TMockTransport;
  aEmpty: TBytes = nil;
  aSentLen: Integer;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    SetLength(aEmpty, 0);
    aSentLen := M.Send(aEmpty);

    AssertEquals('Пустая отправка: len=0', 0, aSentLen);
    AssertEquals('Пустая отправка: залогирована', 1, M.GetSentCount);
  finally
    M.Free;
  end;
end;

{ === TMockTransport: приём === }

procedure TTestTransport.Test_Mock_Receive_QueuedResponse;
var
  M: TMockTransport;
  aResp, aGot: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    Initialize(aResp);
    SetLength(aResp, 5);
    aResp[0] := $FF; aResp[1] := $01; aResp[2] := $C3;
    aResp[3] := $05; aResp[4] := $FF;
    M.QueueResponse(aResp);

    aGot := M.Receive(1000);

    AssertEquals('Длина ответа', 5, Length(aGot));
    AssertEquals('Byte 0', $FF, aGot[0]);
    AssertEquals('Byte 4', $FF, aGot[4]);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Receive_MultipleInOrder;
var
  M: TMockTransport;
  R1, R2, R3, Got: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);
    Initialize(R1);
    SetLength(R1, 1); R1[0] := $AA;
    Initialize(R2);
    SetLength(R2, 2); R2[0] := $BB; R2[1] := $CC;
    Initialize(R3);
    SetLength(R3, 3); R3[0] := $DD; R3[1] := $EE; R3[2] := $FF;

    M.QueueResponse(R1);
    M.QueueResponse(R2);
    M.QueueResponse(R3);

    Got := M.Receive(100);
    AssertEquals('1-й ответ len', 1, Length(Got));
    AssertEquals('1-й ответ val', $AA, Got[0]);

    Got := M.Receive(100);
    AssertEquals('2-й ответ len', 2, Length(Got));
    AssertEquals('2-й ответ [0]', $BB, Got[0]);
    AssertEquals('2-й ответ [1]', $CC, Got[1]);

    Got := M.Receive(100);
    AssertEquals('3-й ответ len', 3, Length(Got));
    AssertEquals('3-й ответ [2]', $FF, Got[2]);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Receive_EmptyQueue;
var
  M: TMockTransport;
  aGot: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    { Очередь пуста }
    aGot := M.Receive(100);
    AssertEquals('Пустая очередь: nil', 0, Length(aGot));

    { Повторный вызов тоже nil }
    aGot := M.Receive(100);
    AssertEquals('Повторный nil', 0, Length(aGot));
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Receive_AfterClear;
var
  M: TMockTransport;
  aResp, aGot: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    Initialize(aResp);
    SetLength(aResp, 2); aResp[0] := $11; aResp[1] := $22;
    M.QueueResponse(aResp);
    M.ClearResponses;

    aGot := M.Receive(100);
    AssertEquals('После ClearResponses: nil', 0, Length(aGot));
  finally
    M.Free;
  end;
end;

{ === TMockTransport: очередь === }

procedure TTestTransport.Test_Mock_QueueResponse_CopyIndependence;
var
  M: TMockTransport;
  aResp, aGot: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    Initialize(aResp);
    SetLength(aResp, 3);
    aResp[0] := $AA; aResp[1] := $BB; aResp[2] := $CC;
    M.QueueResponse(aResp);

    { Меняем оригинал после помещения в очередь }
    aResp[0] := $00; aResp[1] := $00; aResp[2] := $00;

    aGot := M.Receive(100);
    AssertEquals('Независимость копии [0]', $AA, aGot[0]);
    AssertEquals('Независимость копии [1]', $BB, aGot[1]);
    AssertEquals('Независимость копии [2]', $CC, aGot[2]);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_ClearResponses;
var
  M: TMockTransport;
  R1, R2: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    Initialize(R1);
    SetLength(R1, 1); R1[0] := $01;
    Initialize(R2);
    SetLength(R2, 1); R2[0] := $02;
    M.QueueResponse(R1);
    M.QueueResponse(R2);

    { Два ответа в очереди }
    AssertEquals('До очистки: Receive даёт ответ', 1,
      Length(M.Receive(100)));

    { Очищаем — оставшийся ответ тоже исчезает }
    M.ClearResponses;
    AssertEquals('После очистки: nil', 0,
      Length(M.Receive(100)));
  finally
    M.Free;
  end;
end;

{ === TMockTransport: inspect отправленных === }

procedure TTestTransport.Test_Mock_GetSentData;
var
  M: TMockTransport;
  aData, aSent: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);
    Initialize(aData);
    SetLength(aData, 3);
    aData[0] := $DE; aData[1] := $AD; aData[2] := $BE;
    M.Send(aData);

    aSent := M.GetSentData(0);
    { Возвращённая копия не должна ссылаться на оригинал }
    AssertEquals('Sent[0]', $DE, aSent[0]);
    AssertEquals('Sent[1]', $AD, aSent[1]);
    AssertEquals('Sent[2]', $BE, aSent[2]);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_GetSentCount;
var
  M: TMockTransport;
  D: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);

    AssertEquals('0 отправок', 0, M.GetSentCount);
    Initialize(D);
    SetLength(D, 1); D[0] := $01;
    M.Send(D);
    AssertEquals('1 отправка', 1, M.GetSentCount);

    M.Send(D);
    M.Send(D);
    AssertEquals('3 отправки', 3, M.GetSentCount);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_GetAllSentHex;
var
  M: TMockTransport;
  D1, D2: TBytes;
  aHex: string;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);
    Initialize(D1);
    SetLength(D1, 2); D1[0] := $FF; D1[1] := $01;
    Initialize(D2);
    SetLength(D2, 1); D2[0] := $C3;
    M.Send(D1);
    M.Send(D2);

    aHex := M.GetAllSentHex;
    AssertTrue('Содержит ff 01', Pos('ff 01', LowerCase(aHex)) > 0);
    AssertTrue('Содержит c3', Pos('c3', LowerCase(aHex)) > 0);
    AssertTrue('Разделитель |', Pos('|', aHex) > 0);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_GetSentData_OutOfRange;
var
  M: TMockTransport;
  D, aGot: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);
    Initialize(D);
    SetLength(D, 1); D[0] := $AA;
    M.Send(D);

    { Индекс за пределами }
    aGot := M.GetSentData(-1);
    AssertEquals('Отрицательный индекс: nil', 0, Length(aGot));

    aGot := M.GetSentData(1);
    AssertEquals('Индекс > count: nil', 0, Length(aGot));

    aGot := M.GetSentData(42);
    AssertEquals('Индекс 42: nil', 0, Length(aGot));
  finally
    M.Free;
  end;
end;

{ === TMockTransport: прочее === }

procedure TTestTransport.Test_Mock_Flush_NoOp;
var
  M: TMockTransport;
  aResp, aGot: TBytes;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);
    Initialize(aResp);
    SetLength(aResp, 2); aResp[0] := $11; aResp[1] := $22;
    M.QueueResponse(aResp);

    { Flush не должен удалять ответы из очереди }
    M.Flush;

    aGot := M.Receive(100);
    AssertEquals('Ответ сохранён после Flush', 2, Length(aGot));
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_LastError_Empty;
var
  M: TMockTransport;
begin
  M := TMockTransport.Create;
  try
    M.Connect('/dev/mock', 9600);
    AssertEquals('LastError пуст', '', M.GetLastErrorMessage);
  finally
    M.Free;
  end;
end;

procedure TTestTransport.Test_Mock_Send_WithoutConnect;
var
  M: TMockTransport;
  D: TBytes;
  aSentLen: Integer;
begin
  M := TMockTransport.Create;
  try
    Initialize(D);
    { TMockTransport не проверяет подключение при отправке —
      это мок, он всегда «работает» }
    SetLength(D, 2); D[0] := $AA; D[1] := $BB;
    aSentLen := M.Send(D);

    { Отправка прошла, данные залогированы }
    AssertEquals('Send без Connect: len', 2, aSentLen);
    AssertEquals('Send без Connect: logged', 1, M.GetSentCount);
  finally
    M.Free;
  end;
end;

{ === BaudRateToValue === }

procedure TTestTransport.Test_BaudRateToValue_AllCodes;
begin
  AssertEquals('2400', 2400,   BaudRateToValue(RATE_2400));
  AssertEquals('4800', 4800,   BaudRateToValue(RATE_4800));
  AssertEquals('9600', 9600,   BaudRateToValue(RATE_9600));
  AssertEquals('14400', 14400,  BaudRateToValue(RATE_14400));
  AssertEquals('19200', 19200,  BaudRateToValue(RATE_19200));
  AssertEquals('28800', 28800,  BaudRateToValue(RATE_28800));
  AssertEquals('57600', 57600,  BaudRateToValue(RATE_57600));
  AssertEquals('115200', 115200, BaudRateToValue(RATE_115200));
end;

procedure TTestTransport.Test_BaudRateToValue_UnknownCode_Default9600;
begin
  AssertEquals('Неизвестный код $FF → 9600', 9600, BaudRateToValue($FF));
  AssertEquals('Неизвестный код $00 → 9600', 9600, BaudRateToValue($00));
  AssertEquals('Неизвестный код $10 → 9600', 9600, BaudRateToValue($10));
end;

procedure TTestTransport.Test_BaudRateToValue_ZeroCode_Default9600;
begin
  AssertEquals('Код $00 → 9600', 9600, BaudRateToValue($00));
end;

{ === BaudRateToCode === }

procedure TTestTransport.Test_BaudRateToCode_AllRates;
begin
  AssertEquals('2400',  RATE_2400,   BaudRateToCode(2400));
  AssertEquals('4800',  RATE_4800,   BaudRateToCode(4800));
  AssertEquals('9600',  RATE_9600,   BaudRateToCode(9600));
  AssertEquals('14400', RATE_14400,  BaudRateToCode(14400));
  AssertEquals('19200', RATE_19200,  BaudRateToCode(19200));
  AssertEquals('28800', RATE_28800,  BaudRateToCode(28800));
  AssertEquals('57600', RATE_57600,  BaudRateToCode(57600));
  AssertEquals('115200', RATE_115200, BaudRateToCode(115200));
end;

procedure TTestTransport.Test_BaudRateToCode_UnknownRate_Default9600;
begin
  AssertEquals('Неизвестная скорость 12345 → RATE_9600',
    RATE_9600, BaudRateToCode(12345));
  AssertEquals('Скорость 0 → RATE_9600',
    RATE_9600, BaudRateToCode(0));
  AssertEquals('Скорость -1 → RATE_9600',
    RATE_9600, BaudRateToCode(-1));
end;

{ === Круговой путь Baud === }

procedure TTestTransport.Test_Baud_RoundTrip;
var
  aCodes: array[0..7] of Byte = (
    RATE_2400, RATE_4800, RATE_9600, RATE_14400,
    RATE_19200, RATE_28800, RATE_57600, RATE_115200);
  I: Integer;
begin
  for I := 0 to High(aCodes) do
    AssertEquals(Format('RoundTrip code $%02X', [aCodes[I]]),
      aCodes[I], BaudRateToCode(BaudRateToValue(aCodes[I])));
end;

initialization
  RegisterTest(TTestTransport);

end.
