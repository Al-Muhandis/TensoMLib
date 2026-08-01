unit test_frames;

{
  Юнит-тесты для frames.pas

  Покрывает:
  - Построение кадров (BuildFrame) с/без CRC, с/without данных
  - Байт-стаффинг (FF в данных → FF FE в кадре)
  - Потоковый разбор (TFrameCollector)
  - Разбор кадра (ParseFrame)
  - Обнаружение ошибки CRC
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, frames in '../src/frames.pas', crc8 in '../src/crc8.pas'
  ;

type
  TTestFrames = class(TTestCase)
  published
    { BuildFrame }
    procedure Test_Build_SimpleRequest_NoCRC;
    procedure Test_Build_SimpleRequest_WithCRC;
    procedure Test_Build_WithData_NoCRC;
    procedure Test_Build_ByteStuffing;
    procedure Test_Build_NoData_Minimal;

    { TFrameCollector }
    procedure Test_Collector_SimpleFrame;
    procedure Test_Collector_FrameWithCRC;
    procedure Test_Collector_FrameWithStuffing;
    procedure Test_Collector_LeadingFFs;
    procedure Test_Collector_Reset;
    procedure Test_Collector_ByteByByte;

    { ParseFrame }
    procedure Test_Parse_Simple;
    procedure Test_Parse_WithCRC;
    procedure Test_Parse_BadCRC;
    procedure Test_Parse_WrongAddress;
    procedure Test_Parse_TooShort;

    { Интеграционные }
    procedure Test_RoundTrip_BuildAndCollect;
    procedure Test_RoundTrip_WithFFInData;
  end;

implementation

uses
  core in '../src/core.pas'
  ;

{ --- Вспомогательные функции --- }

function MakeArr(const A: array of Byte): TBytes;
var
  I: Integer;
begin
  Initialize(Result);
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

{ Ищем пару FF FE в массиве }
function ContainsFFFE(const A: TBytes): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(A) - 1 do
    if (A[I] = $FF) and (A[I + 1] = $FE) then
      Exit(True);
end;

{ --- BuildFrame --- }

procedure TTestFrames.Test_Build_SimpleRequest_NoCRC;
var
  aFrame: TBytes;
begin
  aFrame := BuildFrame($01, COP_GET_BRUTTO, nil, False);
  { Ожидаем: FF 01 C3 FF FF }
  AssertEquals('Length', 5, Length(aFrame));
  AssertEquals('Delimiter start', $FF, aFrame[0]);
  AssertEquals('Address', $01, aFrame[1]);
  AssertEquals('COP', COP_GET_BRUTTO, aFrame[2]);
  AssertEquals('End FF1', $FF, aFrame[3]);
  AssertEquals('End FF2', $FF, aFrame[4]);
end;

procedure TTestFrames.Test_Build_SimpleRequest_WithCRC;
var
  aFrame: TBytes;
  aExpectedCRC: Byte;
  aBody: TBytes;
begin
  aBody := MakeArr([$01, COP_GET_BRUTTO]);
  aExpectedCRC := MakeCRC(aBody);

  aFrame := BuildFrame($01, COP_GET_BRUTTO, nil, True);
  { Ожидаем: FF 01 C3 [CRC] FF FF }
  AssertEquals('Length', 6, Length(aFrame));
  AssertEquals('Delimiter', $FF, aFrame[0]);
  AssertEquals('Address', $01, aFrame[1]);
  AssertEquals('COP', COP_GET_BRUTTO, aFrame[2]);
  AssertEquals('CRC byte', aExpectedCRC, aFrame[3]);
  AssertEquals('End FF1', $FF, aFrame[4]);
  AssertEquals('End FF2', $FF, aFrame[5]);
end;

procedure TTestFrames.Test_Build_WithData_NoCRC;
var
  aFrame: TBytes;
  aData: TBytes;
begin
  { Команда A0h с новым адресом $05 }
  aData := MakeArr([$05]);
  aFrame := BuildFrame($01, COP_SET_ADDRESS, aData, False);
  { FF 01 A0 05 FF FF }
  AssertEquals('Length', 6, Length(aFrame));
  AssertEquals('Address', $01, aFrame[1]);
  AssertEquals('COP', COP_SET_ADDRESS, aFrame[2]);
  AssertEquals('Data', $05, aFrame[3]);
end;

procedure TTestFrames.Test_Build_ByteStuffing;
var
  aFrame: TBytes;
  aData: TBytes;
begin
  { Данные содержат FF — он должен быть экранирован как FF FE }
  aData := MakeArr([$FF, $10]);
  aFrame := BuildFrame($01, COP_GET_BRUTTO, aData, False);

  { FF 01 C3 FF FE 10 FF FF }
  AssertEquals('Length with stuffing', 8, Length(aFrame));
  AssertTrue('Must contain FF FE escape', ContainsFFFE(aFrame));

  { Проверяем структуру подробнее }
  AssertEquals('start FF', $FF, aFrame[0]);
  AssertEquals('addr', $01, aFrame[1]);
  AssertEquals('cop', $C3, aFrame[2]);
  AssertEquals('escaped FF', $FF, aFrame[3]);
  AssertEquals('stuff byte', $FE, aFrame[4]);
  AssertEquals('data $10', $10, aFrame[5]);
  AssertEquals('end FF1', $FF, aFrame[6]);
  AssertEquals('end FF2', $FF, aFrame[7]);
end;

procedure TTestFrames.Test_Build_NoData_Minimal;
var
  aFrame: TBytes;
begin
  { Запрос тарирования (C0h), без данных, без CRC }
  aFrame := BuildFrame($01, COP_ZERO, nil, False);
  AssertEquals('Length', 5, Length(aFrame));
  AssertEquals('Frame[2] = C0h', COP_ZERO, aFrame[2]);
end;

{ --- TFrameCollector --- }

procedure TTestFrames.Test_Collector_SimpleFrame;
var
  aCol: TFrameCollector;
  aFrame: TBytes;
  I: Integer;
  aBody, aRaw: TBytes;
  aOK: Boolean;
begin
  { Кадр: FF 01 C3 05 00 00 91 FF FF }
  aFrame := MakeArr([$FF, $01, $C3, $05, $00, $00, $91, $FF, $FF]);

  aCol := TFrameCollector.Create;
  try
    for I := 0 to High(aFrame) do
    begin
      aOK := aCol.Feed(aFrame[I], aBody, aRaw);
      if aOK then Break;
    end;

    AssertTrue('Frame collected', aOK);
    AssertEquals('Body length', 6, Length(aBody));
    AssertEquals('Address', $01, aBody[0]);
    AssertEquals('COP', $C3, aBody[1]);
  finally
    aCol.Free;
  end;
end;

procedure TTestFrames.Test_Collector_FrameWithCRC;
var
  aCol: TFrameCollector;
  aBody: TBytes;
  I: Integer;
  aFrame, aRaw: TBytes;
  aOK: Boolean;
begin
  { Кадр с CRC: FF 01 C3 [CRC] 05 00 00 91.
    Ответ: FF 01 C3 05 00 00 91 [CRC] FF FF }
  aFrame := BuildFrame($01, COP_GET_BRUTTO, MakeArr([$05, $00, $00, $91]), True);

  aCol := TFrameCollector.Create;
  try
    for I := 0 to High(aFrame) do
    begin
      aOK := aCol.Feed(aFrame[I], aBody, aRaw);
      if aOK then Break;
    end;

    AssertTrue('Frame with CRC collected', aOK);
    { aBody должен содержать: 01 C3 05 00 00 91 CRC }
    AssertEquals('Body length (addr+cop+4data+crc)', 7, Length(aBody));
    AssertEquals('COP', COP_GET_BRUTTO, aBody[1]);
    { Проверяем CRC }
    AssertTrue('CRC valid', VerifyCRC(aBody));
  finally
    aCol.Free;
  end;
end;

procedure TTestFrames.Test_Collector_FrameWithStuffing;
var
  aCol: TFrameCollector;
  aFrame: TBytes;
  I: Integer;
  aBody, aRaw: TBytes;
  aOK: Boolean;
begin
  { Данные содержат FF: BuildFrame заэкранирует его.
    Проверяем, что Collector корректно декодирует FF FE → FF. }
  aFrame := BuildFrame($01, COP_GET_BRUTTO, MakeArr([$FF, $10]), False);

  aCol := TFrameCollector.Create;
  try
    for I := 0 to High(aFrame) do
    begin
      aOK := aCol.Feed(aFrame[I], aBody, aRaw);
      if aOK then Break;
    end;

    AssertTrue('Stuffed frame collected', aOK);
    { aBody: 01 C3 FF 10 }
    AssertEquals('Body length', 4, Length(aBody));
    AssertEquals('Address', $01, aBody[0]);
    AssertEquals('COP', $C3, aBody[1]);
    AssertEquals('Unstuffed FF', $FF, aBody[2]);
    AssertEquals('Data $10', $10, aBody[3]);
  finally
    aCol.Free;
  end;
end;

procedure TTestFrames.Test_Collector_LeadingFFs;
var
  aCol: TFrameCollector;
  aBody, aRaw: TBytes;
  aOK: Boolean;
begin
  { Несколько ведущих FF перед кадром }
  aCol := TFrameCollector.Create;
  try
    { Три ведущих FF }
    aCol.Feed($FF, aBody, aRaw);
    aCol.Feed($FF, aBody, aRaw);
    aCol.Feed($FF, aBody, aRaw);
    { Затем реальный кадр: 01 C3 FF FF }
    aOK := aCol.Feed($01, aBody, aRaw); AssertFalse('not done', aOK);
    aOK := aCol.Feed($C3, aBody, aRaw); AssertFalse('not done', aOK);
    aOK := aCol.Feed($FF, aBody, aRaw); AssertFalse('not done', aOK);
    aOK := aCol.Feed($FF, aBody, aRaw);

    AssertTrue('Frame after leading FFs', aOK);
    AssertEquals('Body len', 2, Length(aBody));
    AssertEquals('Addr', $01, aBody[0]);
    AssertEquals('COP', $C3, aBody[1]);
  finally
    aCol.Free;
  end;
end;

procedure TTestFrames.Test_Collector_Reset;
var
  aCol: TFrameCollector;
  aBody, aRaw: TBytes;
  aOK: Boolean;
begin
  aCol := TFrameCollector.Create;
  try
    { Начинаем приём, но сбрасываем }
    aCol.Feed($01, aBody, aRaw);
    aCol.Reset;

    { Новые данные после сброса }
    aCol.Feed($01, aBody, aRaw);
    aCol.Feed($C0, aBody, aRaw);
    aOK := aCol.Feed($FF, aBody, aRaw);
    AssertFalse('one FF', aOK);
    aOK := aCol.Feed($FF, aBody, aRaw);

    AssertTrue('Frame after reset', aOK);
    AssertEquals('COP after reset', COP_ZERO, aBody[1]);
  finally
    aCol.Free;
  end;
end;

procedure TTestFrames.Test_Collector_ByteByByte;
var
  aCol: TFrameCollector;
  aFrame: TBytes;
  I: Integer;
  aBody, aRaw: TBytes;
  aOK: Boolean;
begin
  { Имитация чтения из порта: данные приходят по одному байту,
    кадр подаётся в середине потока мусорных FF }
  aFrame := BuildFrame($01, COP_GET_BRUTTO, nil, False);

  aCol := TFrameCollector.Create;
  try
    { Мусорные FF до кадра }
    aOK := aCol.Feed($FF, aBody, aRaw); AssertFalse('junk ff1', aOK);
    aOK := aCol.Feed($FF, aBody, aRaw); AssertFalse('junk ff2', aOK);

    { Кадр байт за байтом }
    for I := 0 to High(aFrame) do
    begin
      aOK := aCol.Feed(aFrame[I], aBody, aRaw);
      if aOK then Break;
    end;

    AssertTrue('Frame extracted', aOK);
  finally
    aCol.Free;
  end;
end;

{ --- ParseFrame --- }

procedure TTestFrames.Test_Parse_Simple;
var
  aPF: TParsedFrame;
  aBody, aRaw: TBytes;
begin
  aBody := MakeArr([$01, COP_GET_BRUTTO]);
  aRaw  := aBody;

  aPF := ParseFrame(aBody, aRaw, $01, False);

  AssertEquals('Address', $01, aPF.Address);
  AssertEquals('COP', COP_GET_BRUTTO, aPF.COP);
  AssertEquals('Data length', 0, Length(aPF.Data));
  AssertTrue('CRCOK (no CRC check)', aPF.CRCOK);
end;

procedure TTestFrames.Test_Parse_WithCRC;
var
  aPF: TParsedFrame;
  aBody: TBytes = nil;
  C: Byte;
begin
  { aBody с CRC: 01 C3 [CRC] }
  SetLength(aBody, 3);
  aBody[0] := $01;
  aBody[1] := COP_GET_BRUTTO;
  aBody[2] := $00; { временно }
  C := MakeCRC(MakeArr([$01, COP_GET_BRUTTO]));
  aBody[2] := C;

  aPF := ParseFrame(aBody, aBody, $01, True);

  AssertEquals('COP', COP_GET_BRUTTO, aPF.COP);
  AssertEquals('Data len', 0, Length(aPF.Data));
end;

procedure TTestFrames.Test_Parse_BadCRC;
var
  aRaised: Boolean;
  aBody: TBytes = nil;
begin
  SetLength(aBody, 3);
  aBody[0] := $01;
  aBody[1] := COP_GET_BRUTTO;
  aBody[2] := $FF; { неверный CRC }

  aRaised := False;
  try
    ParseFrame(aBody, aBody, $01, True);
  except
    on E: Exception do
      aRaised := True;
  end;
  AssertTrue('Should raise on bad CRC', aRaised);
end;

procedure TTestFrames.Test_Parse_WrongAddress;
var
  aRaised: Boolean;
  aBody: TBytes;
begin
  aBody := MakeArr([$02, COP_GET_BRUTTO]);

  aRaised := False;
  try
    ParseFrame(aBody, aBody, $01, False);
  except
    on E: Exception do
      aRaised := True;
  end;
  AssertTrue('Should raise on wrong address', aRaised);
end;

procedure TTestFrames.Test_Parse_TooShort;
var
  aRaised: Boolean;
  aBody: TBytes;
begin
  aBody := MakeArr([$01]); { только адрес, нет COP }

  aRaised := False;
  try
    ParseFrame(aBody, aBody, $01, False);
  except
    on E: Exception do
      aRaised := True;
  end;
  AssertTrue('Should raise on too short frame', aRaised);
end;

{ --- Интеграционные --- }

procedure TTestFrames.Test_RoundTrip_BuildAndCollect;
var
  aFrame: TBytes;
  aCol: TFrameCollector;
  I: Integer;
  aBody, aRaw: TBytes;
  aOK: Boolean;
  aPF: TParsedFrame;
begin
  { Строим кадр с CRC и данными, собираем через коллектор, парсим }
  aFrame := BuildFrame($01, COP_GET_BRUTTO, MakeArr([$05, $00, $00, $91]), True);

  aCol := TFrameCollector.Create;
  try
    for I := 0 to High(aFrame) do
    begin
      aOK := aCol.Feed(aFrame[I], aBody, aRaw);
      if aOK then Break;
    end;

    AssertTrue('Collected', aOK);
    aPF := ParseFrame(aBody, aRaw, $01, True);

    AssertEquals('COP', COP_GET_BRUTTO, aPF.COP);
    AssertEquals('Data length', 4, Length(aPF.Data));
    AssertEquals('Data[0]', $05, aPF.Data[0]);
    AssertEquals('Data[3]', $91, aPF.Data[3]);
    AssertTrue('CRC OK', aPF.CRCOK);
  finally
    aCol.Free;
  end;
end;

procedure TTestFrames.Test_RoundTrip_WithFFInData;
var
  aFrame: TBytes;
  aCol: TFrameCollector;
  I: Integer;
  aBody, aRaw: TBytes;
  aOK: Boolean;
  aPF: TParsedFrame;
begin
  { Данные содержат FF — проверяем что round-trip корректен }
  aFrame := BuildFrame($01, COP_DISPLAY_MSG, MakeArr([$FF, $41, $42]), True);

  aCol := TFrameCollector.Create;
  try
    for I := 0 to High(aFrame) do
    begin
      aOK := aCol.Feed(aFrame[I], aBody, aRaw);
      if aOK then Break;
    end;

    AssertTrue('Collected with FF in data', aOK);
    aPF := ParseFrame(aBody, aRaw, $01, True);

    AssertEquals('COP', COP_DISPLAY_MSG, aPF.COP);
    AssertEquals('Data length', 3, Length(aPF.Data));
    AssertEquals('Data[0] = FF', $FF, aPF.Data[0]);
    AssertEquals('Data[1] = A',  $41, aPF.Data[1]);
    AssertEquals('Data[2] = B',  $42, aPF.Data[2]);
  finally
    aCol.Free;
  end;
end;

initialization
  RegisterTest(TTestFrames);

end.
