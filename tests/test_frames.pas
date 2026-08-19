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

  { TTestFrames }

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
    procedure Test_Collector_MultipleStuffedFF;
    procedure Test_Collector_LeadingFFs;
    procedure Test_Collector_LeadingFFAndFE;
    procedure Test_Collector_Reset;
    procedure Test_Collector_ByteByByte;
    procedure Test_Collector_FrameTooLong;
    procedure Test_Collector_FrameTooLong_StuffedFF;
    procedure Test_Collector_RecoveryAfterInvalidFF;

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
  core in '../src/core.pas', tensom_errors
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

procedure TTestFrames.Test_Collector_MultipleStuffedFF;
var
  aCol: TFrameCollector;
  aFrame: TBytes;
  aBody, aRaw: TBytes;
  aOK: Boolean;
  I: Integer;
begin
  { Два FF подряд в данных:
      FF FE FF FE

    После распаковки:
      FF FF
  }

  aFrame := BuildFrame(
    $01,
    COP_GET_BRUTTO,
    MakeArr([$FF, $FF]),
    False
  );

  aCol := TFrameCollector.Create;
  try
    aOK := False;

    for I := 0 to High(aFrame) do
    begin
      aOK := aCol.Feed(aFrame[I], aBody, aRaw);
      if aOK then
        Break;
    end;

    AssertTrue('Frame collected', aOK);

    AssertEquals('Body length', 4, Length(aBody));
    AssertEquals('Address', $01, aBody[0]);
    AssertEquals('COP', COP_GET_BRUTTO, aBody[1]);
    AssertEquals('First unstuffed FF', $FF, aBody[2]);
    AssertEquals('Second unstuffed FF', $FF, aBody[3]);

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

procedure TTestFrames.Test_Collector_LeadingFFAndFE;
var
  aCol: TFrameCollector;
  aBody, aRaw: TBytes;
  aOK: Boolean;
begin
  aCol := TFrameCollector.Create;
  try
    { Мусор перед кадром }
    aOK := aCol.Feed($FF, aBody, aRaw);
    AssertFalse('Leading FF', aOK);

    aOK := aCol.Feed($FE, aBody, aRaw);
    AssertFalse('Leading FE', aOK);

    aOK := aCol.Feed($FF, aBody, aRaw);
    AssertFalse('Another leading FF', aOK);

    { Настоящий кадр: 01 C0 FF FF }
    aOK := aCol.Feed($01, aBody, aRaw);
    AssertFalse('Address', aOK);

    aOK := aCol.Feed(COP_ZERO, aBody, aRaw);
    AssertFalse('COP', aOK);

    aOK := aCol.Feed($FF, aBody, aRaw);
    AssertFalse('First ending FF', aOK);

    aOK := aCol.Feed($FF, aBody, aRaw);

    AssertTrue('Frame collected', aOK);
    AssertEquals('Body length', 2, Length(aBody));
    AssertEquals('Address', $01, aBody[0]);
    AssertEquals('COP', COP_ZERO, aBody[1]);

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

procedure TTestFrames.Test_Collector_FrameTooLong;
var
  aCol: TFrameCollector;
  aBody, aRaw: TBytes;
  I: Integer;
  aRaised: Boolean;
begin
  aCol := TFrameCollector.Create;
  try
    aRaised := False;

    { Начало кадра }
    aCol.Feed(FRAME_DELIMITER, aBody, aRaw);

    { Набираем ровно FRAME_MAX_LEN байт тела.
      Используем только значения $01..$FD,
      чтобы они не воспринимались как служебные FF/FE. }
    for I := 1 to FRAME_MAX_LEN do
      aCol.Feed(Byte(((I - 1) mod $FD) + 1), aBody, aRaw);

    try
      { Следующий байт должен вызвать переполнение }
      aCol.Feed($55, aBody, aRaw);
    except
      on E: ETensoMFrameError do
        aRaised := True;
    end;

    AssertTrue('Frame too long must raise EFrameError', aRaised);

  finally
    aCol.Free;
  end;
end;

procedure TTestFrames.Test_Collector_FrameTooLong_StuffedFF;
var
  aCol: TFrameCollector;
  aBody, aRaw: TBytes;
  aFrame: TBytes;
  I: Integer;
  aRaised: Boolean;
  aComplete: Boolean;
begin
  aCol := TFrameCollector.Create;
  try
    aRaised := False;

    { Начало кадра }
    aCol.Feed(FRAME_DELIMITER, aBody, aRaw);

    { Набираем FRAME_MAX_LEN - 1 байт тела.
      Используем только значения $01..$FD. }
    for I := 1 to FRAME_MAX_LEN - 1 do
      aCol.Feed(Byte(((I - 1) mod $FD) + 1), aBody, aRaw);

    { FF FE декодируется в один байт FF.
      Это будет ровно FRAME_MAX_LEN-й байт тела,
      поэтому ошибки быть НЕ должно. }
    aCol.Feed(FRAME_DELIMITER, aBody, aRaw);
    aCol.Feed(FRAME_STUFF_BYTE, aBody, aRaw);

    { Ещё один FF FE пытается добавить
      FRAME_MAX_LEN + 1-й байт тела. }
    try
      aCol.Feed(FRAME_DELIMITER, aBody, aRaw);
      aCol.Feed(FRAME_STUFF_BYTE, aBody, aRaw);
    except
      on E: ETensoMFrameError do
        aRaised := True;
    end;

    AssertTrue('Frame too long via stuffed FF must raise EFrameError', aRaised);

    { После переполнения collector должен быть сброшен.
      Проверяем сборкой нового корректного кадра. }
    aFrame := BuildFrame($01, COP_GET_BRUTTO, nil, False);

    aComplete := False;

    for I := 0 to High(aFrame) do
    begin
      aComplete := aCol.Feed(aFrame[I], aBody, aRaw);
      if aComplete then
        Break;
    end;

    AssertTrue(
      'Collector must accept a new frame after overflow',
      aComplete
    );

    AssertEquals(
      'New frame body length',
      2,
      Length(aBody)
    );

    AssertEquals(
      'Address',
      $01,
      aBody[0]
    );

    AssertEquals(
      'COP',
      COP_GET_BRUTTO,
      aBody[1]
    );

  finally
    aCol.Free;
  end;
end;

procedure TTestFrames.Test_Collector_RecoveryAfterInvalidFF;
var
  aCol: TFrameCollector;
  aBody, aRaw: TBytes;
  aOK: Boolean;
begin
  aCol := TFrameCollector.Create;
  try
    { Старый кадр:
        01 C3 FF 02

      FF 02 — некорректная последовательность.

      Байт 02 должен стать первым байтом нового кадра. }

    aCol.Feed($01, aBody, aRaw);
    aCol.Feed($C3, aBody, aRaw);
    aCol.Feed($FF, aBody, aRaw);

    aOK := aCol.Feed($02, aBody, aRaw);

    AssertFalse(
      'Invalid FF sequence must not complete frame',
      aOK
    );

    { Новый кадр теперь начинается с 02 }
    aOK := aCol.Feed($01, aBody, aRaw);
    AssertFalse('New frame is not complete', aOK);

    aOK := aCol.Feed($C0, aBody, aRaw);
    AssertFalse('New frame is not complete', aOK);

    aOK := aCol.Feed($FF, aBody, aRaw);
    AssertFalse('One FF is not enough', aOK);

    aOK := aCol.Feed($FF, aBody, aRaw);

    AssertTrue('Recovered frame collected', aOK);

    AssertEquals('Body length', 3, Length(aBody));
    AssertEquals('New address', $02, aBody[0]);
    AssertEquals('Data', $01, aBody[1]);
    AssertEquals('COP', COP_ZERO, aBody[2]);

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
    on E: ETensoMCRCError do
      aRaised := True;
  end;
  AssertTrue('Should raise on bad CRC (ETensoMCRCError)', aRaised);
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
    on E: ETensoMProtocolError do
      aRaised := True;
  end;
  AssertTrue('Should raise ETensoMProtocolError on wrong address', aRaised)
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
    on E: ETensoMFrameError do
      aRaised := True;
  end;
  AssertTrue('Should raise on too short frame (ETensoMFrameError)', aRaised);
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
