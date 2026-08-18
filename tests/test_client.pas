unit test_client;

{
  Юнит-тесты для client.pas — TTensoMDevice.

  Все тесты используют TMockTransport: мок отвечает предустановленным
  кадром, а клиент разбирает его через полный стек (BuildFrame → Send →
  Collector → ParseFrame → DecodeWeight). Так проверяется вся цепочка.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, core in '../src/core.pas', frames in '../src/frames.pas',
  transport in '../src/transport.pas', client in '../src/client.pas'
  ;

type

  { TTestClient }

  TTestClient = class(TTestCase)
  private
    fMock: TMockTransport;
    fDev: TTensoMDevice;
    procedure SetupMock(aUseCRC: Boolean);
    procedure QueueWeightResponse(const aWeightBCD: array of Byte; aCON: Byte);
    procedure QueueBadCRCWeightResponse;
  published
    { Вес }
    procedure Test_GetBrutto_Stable;
    procedure Test_GetBrutto_Negative;
    procedure Test_GetBrutto_Overload;
    procedure Test_GetNetto;

    { Тарирование }
    procedure Test_Tare;

    { Серийный номер }
    procedure Test_GetSerialNumber;

    { Статус }
    procedure Test_GetSystemStatus;

    { Ошибки прибора }
    procedure Test_DeviceError_EEh;
    procedure Test_UnsupportedCommand_FDh;
    procedure Test_Timeout;
    procedure Test_CRCError_Type;

    { CRC-автоопределение }
    procedure Test_AutoDetectCRC_NoCRC;
    procedure Test_AutoDetectCRC_WithCRC;
    procedure Test_AutoDetectCRC_Fails;

    { Конфигурация }
    procedure Test_GetDeviceConfig;

    { Дискретные }
    procedure Test_GetDiscreteInputs;

    { Индикаторы }
    procedure Test_GetIndicators;

    { Счётчики }
    procedure Test_GetCounter;

    { Дозирование }
    procedure Test_DosingStart;

    { Проверка отправленного кадра }
    procedure Test_SentFrameFormat;

    { Повторные попытки }
    procedure Test_Retry_DefaultsZero;
    procedure Test_Retry_SuccessFirstTry;
    procedure Test_Retry_CRCErrThenSuccess;
    procedure Test_Retry_TimeoutExhausted;
    procedure Test_Retry_EEhNotRetried;
    procedure Test_Retry_FDhNotRetried;
    procedure Test_Retry_COPMismatchNotRetried;

    { Протоколирование кадра }
    procedure Test_FrameLog_NotCalledWhenNil;
    procedure Test_FrameLog_SendAndReceive;
    procedure Test_FrameLog_HexContent;
    procedure Test_FrameLog_OnRetry;
    procedure Test_FrameLog_TimeoutOnlySend;
    procedure Test_FrameLog_SemanticErrorLogsBoth;

    { Иерархия исключений }
    procedure Test_ExceptionHierarchy;
  end;

implementation

uses
  errors
  ;

type

  { Вспомогательный класс: записывает вызовы OnFrameLog для проверок.
    Каждый вызов добавляет запись (Direction, Hex) в лог. }

  TFrameLogCollector = class
  private
    type
      TLogEntry = record
        Dir: TFrameDirection;
        Hex: string;
      end;
  private
    fLog: array of TLogEntry;
  public
    procedure HandleLog(aDirection: TFrameDirection; const aFrameHex: string);
    function GetCount: Integer;
    function GetDir(aIndex: Integer): TFrameDirection;
    function GetHex(aIndex: Integer): string;
    procedure Clear;
  end;

procedure TFrameLogCollector.HandleLog(aDirection: TFrameDirection; const aFrameHex: string);
begin
  SetLength(fLog, Length(fLog) + 1);
  fLog[High(fLog)].Dir := aDirection;
  fLog[High(fLog)].Hex := aFrameHex;
end;

function TFrameLogCollector.GetCount: Integer;
begin
  Result := Length(fLog);
end;

function TFrameLogCollector.GetDir(aIndex: Integer): TFrameDirection;
begin
  Assert((aIndex >= 0) and (aIndex < Length(fLog)), 'TFrameLogCollector: index out of range');
  Result := fLog[aIndex].Dir;
end;

function TFrameLogCollector.GetHex(aIndex: Integer): string;
begin
  Assert((aIndex >= 0) and (aIndex < Length(fLog)), 'TFrameLogCollector: index out of range');
  Result := fLog[aIndex].Hex;
end;

procedure TFrameLogCollector.Clear;
begin
  SetLength(fLog, 0);
end;

{ === Вспомогательные === }

procedure TTestClient.SetupMock(aUseCRC: Boolean);
begin
  fMock := TMockTransport.Create;
  fMock.Connect('/dev/mock', 9600);
  fDev := TTensoMDevice.Create(fMock, $01, aUseCRC);
  fDev.ResponseTimeout := 200; { короткий таймаут для тестов }
end;

procedure TTestClient.QueueWeightResponse(const aWeightBCD: array of Byte; aCON: Byte);
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
begin
  { Формируем данные: W0,W1,W2,CON }
  SetLength(aData, Length(aWeightBCD) + 1);
  Move(aWeightBCD[0], aData[0], Length(aWeightBCD));
  aData[Length(aWeightBCD)] := aCON;
  aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, fDev.UseCRC);
  fMock.QueueResponse(aRespFrame);
end;

procedure TTestClient.QueueBadCRCWeightResponse;
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
begin
  { Строим корректный кадр веса с CRC, затем искажаем байт данных.
    CRC не сойдётся → ParseFrame выбросит 'CRC error in response'.
    Искажаем байт данных (индекс 3 = первый байт payload после адреса и COP),
    не трогая адрес и COP, чтобы пройти проверку адреса в ParseFrame. }
  SetLength(aData, 4);
  aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
  aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
  aRespFrame[3] := aRespFrame[3] xor $FF;
  fMock.QueueResponse(aRespFrame);
end;

{ === Тесты веса === }

procedure TTestClient.Test_GetBrutto_Stable;
var
  W: TWeightData;
begin
  SetupMock(True);
  try
    { Вес 123.4 стабильно положительный
      BCD 1234 → LE [$34, $12, $00]
      CON: Stable=1 (D4), DecimalPos=1 (D0-D2) → 0x11 }
    QueueWeightResponse([$34, $12, $00], $11);

    W := fDev.GetBruttoWeight;

    AssertEquals('Weight', 123.4, W.Weight, 0.001);
    AssertTrue('Stable', W.Stable);
    AssertFalse('Negative', W.Negative);
    AssertFalse('Overload', W.Overload);
    AssertEquals('Decimals', 1, W.DecimalPlaces);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_GetBrutto_Negative;
var
  W: TWeightData;
begin
  SetupMock(True);
  try
    { Пример из документации: вес -0.5, стабилен
      BCD 5 → LE [$05, $00, $00]
      CON: Stable=1 (D4), Negative=1 (D7), DecimalPos=1 → 0x91 }
    QueueWeightResponse([$05, $00, $00], $91);

    W := fDev.GetBruttoWeight;

    AssertEquals('Weight', -0.5, W.Weight, 1e-9);
    AssertTrue('Stable', W.Stable);
    AssertTrue('Negative', W.Negative);
    AssertEquals('Decimals', 1, W.DecimalPlaces);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_GetBrutto_Overload;
var
  W: TWeightData;
begin
  SetupMock(True);
  try
    { Перегруз: D3=1 (Overload), D4=0 (unstable), DecimalPos=0 → CON=$08 }
    QueueWeightResponse([$99, $99, $99], $08);

    W := fDev.GetBruttoWeight;

    AssertTrue('Overload', W.Overload);
    AssertFalse('Stable', W.Stable);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_GetNetto;
var
  W: TWeightData;
  aRespFrame: TBytes;
  aData: TBytes;
begin
  SetupMock(True);
  try
    Initialize(aData);
    { Вес нетто: 50.0 стабильно
      BCD 50 → LE [$50, $00, $00], CON: Stable=1, Dec=0 → $10 }
    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_NETTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    W := fDev.GetNettoWeight;

    AssertEquals('Weight', 50.0, W.Weight, 0.001);
    AssertTrue('Stable', W.Stable);
    AssertEquals('Decimals', 0, W.DecimalPlaces);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Тарирование === }

procedure TTestClient.Test_Tare;
var
  aRespFrame: TBytes;
begin
  SetupMock(True);
  try
    aRespFrame := BuildFrame($01, COP_ZERO, nil, True);
    fMock.QueueResponse(aRespFrame);

    fDev.Tare;
    AssertEquals('Sent count', 1, fMock.GetSentCount);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Серийный номер === }

procedure TTestClient.Test_GetSerialNumber;
var
  aRespFrame: TBytes;
  aData: TBytes;
  aSN: Cardinal;
begin
  SetupMock(True);
  try
    Initialize(aData);
    { Серийный номер: SN2=$00, SN1=$01, SN0=$23 → 0x000123 = 291 }
    SetLength(aData, 3);
    aData[0] := $00; aData[1] := $01; aData[2] := $23;
    aRespFrame := BuildFrame($01, COP_GET_SERIAL, aData, True);
    fMock.QueueResponse(aRespFrame);

    aSN := fDev.GetSerialNumber;
    AssertEquals('Serial', 291, aSN);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Статус === }

procedure TTestClient.Test_GetSystemStatus;
var
  aRespFrame: TBytes;
  aData: TBytes;
  aStatus: Byte;
begin
  SetupMock(True);
  try
    Initialize(aData);
    SetLength(aData, 1);
    aData[0] := $41; { D0=1 (идёт дозирование), D6=1 (ошибка) }
    aRespFrame := BuildFrame($01, COP_GET_STATUS, aData, True);
    fMock.QueueResponse(aRespFrame);

    aStatus := fDev.GetSystemStatus;
    AssertEquals('Status', $41, aStatus);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Ошибки === }

procedure TTestClient.Test_DeviceError_EEh;
var
  aRespFrame: TBytes;
  aData: TBytes;
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    Initialize(aData);
    SetLength(aData, 1);
    aData[0] := ERR_CRC; { $06 }
    aRespFrame := BuildFrame($01, COP_ERROR, aData, True);
    fMock.QueueResponse(aRespFrame);

    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: ETensoMDeviceError do
      begin
        aRaised := True;
        AssertTrue('Contains error text', Pos('Error CRC', E.Message) > 0);
      end;
    end;
    AssertTrue('Should raise ETensoMDeviceError', aRaised);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_UnsupportedCommand_FDh;
var
  aRespFrame: TBytes;
  aData: TBytes;
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    Initialize(aData);
    { Прибор отвечает FDh на CCh (ADC код) }
    SetLength(aData, 10);
    aData[0] := Byte('T'); aData[1] := Byte('B');
    aData[2] := Byte('1'); aData[3] := Byte('0');
    aData[4] := Byte('2'); aData[5] := Byte(' ');
    aData[6] := Byte('V'); aData[7] := Byte('1');
    aData[8] := Byte('.'); aData[9] := Byte('0');
    aData := Copy(aData, 0, 10);
    aRespFrame := BuildFrame($01, COP_UNSUPPORTED, aData, True);
    fMock.QueueResponse(aRespFrame);

    aRaised := False;
    try
      fDev.GetADCCode;
    except
      on E: ETensoMProtocolError do
      begin
        aRaised := True;
        AssertTrue('Contains unsupported text', Pos('is not supported', E.Message) > 0);
      end;
    end;
    AssertTrue('Should raise ETensoMProtocolError', aRaised);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_Timeout;
var
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    { Мок не имеет ответов в очереди → таймаут }
    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: ETensoMTimeoutError do
        aRaised := True;
    end;
    AssertTrue('Should raise ETensoMTimeoutError', aRaised);
    AssertTrue('Contains timeout text', Pos('timeout', fDev.LastError) > 0);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === CRC автоопределение === }

procedure TTestClient.Test_AutoDetectCRC_NoCRC;
var
  aRespFrame: TBytes;
  aData: TBytes;
  aOK: Boolean;
begin
  SetupMock(False);
  try
    Initialize(aData);
    { Прибор отвечает без CRC }
    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, False);
    fMock.QueueResponse(aRespFrame);

    aOK := fDev.AutoDetectCRC;
    AssertTrue('AutoDetect succeeded', aOK);
    AssertFalse('UseCRC should be False', fDev.UseCRC);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_AutoDetectCRC_WithCRC;
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
  aOK: Boolean;
begin
  SetupMock(True);
  try
    { Прибор работает с CRC.
      Первая попытка (без CRC): прибор отвечает ошибкой EEh,
      т.к. CRC-фрейм при парсинге без CRC «успешно» разбирается
      (CRC-байт воспринимается как лишний байт данных).
      Поэтому эмулируем отказ: прибор присылает EEh. }
    SetLength(aData, 1);
    aData[0] := ERR_CRC;
    aRespFrame := BuildFrame($01, COP_ERROR, aData, True);
    fMock.QueueResponse(aRespFrame);

    { Вторая попытка (с CRC): корректный ответ }
    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    aOK := fDev.AutoDetectCRC;
    AssertTrue('AutoDetect succeeded', aOK);
    AssertTrue('UseCRC should be True', fDev.UseCRC);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_AutoDetectCRC_Fails;
var
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    { Мок не отвечает ни разу }
    aRaised := False;
    try
      fDev.AutoDetectCRC;
    except
      on E: Exception do
      begin
        aRaised := True;
        AssertTrue('Contains both errors',
          (Pos('timeout', E.Message) > 0) and
          (Pos('timeout', E.Message) > 0));
      end;
    end;
    AssertTrue('Should raise when both fail', aRaised);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Конфигурация === }

procedure TTestClient.Test_GetDeviceConfig;
var
  aRespFrame, aData: TBytes;
  aMaxW, aDiv_: Double;
  aDecimals: Integer;
  aMode: string;
  aADCFreq, aFilt, aVSEN: Byte;
begin
  SetupMock(True);
  try
    Initialize(aData);
    { Ответ C1h: 3 байта MaxWeight BCD, 1 байт N, 2 байта Division BCD,
      1 байт Freq, 1 байт VSEN, 1 байт Filtr }
    SetLength(aData, 9);
    { MaxWeight = 50000 (BCD: LE [$00, $00, $05]) }
    aData[0] := $00; aData[1] := $00; aData[2] := $05;
    { N: 1 decimal, БРУТТО aMode (bit 5 = 1) }
    aData[3] := $21;
    { Division = 50 (BCD: LE [$50, $00]) }
    aData[4] := $50; aData[5] := $00;
    { Freq = $04 (50 Гц) }
    aData[6] := $04;
    { VSEN }
    aData[7] := $00;
    { Filtr = $05 }
    aData[8] := $05;
    aRespFrame := BuildFrame($01, COP_GET_SETTINGS, aData, True);
    fMock.QueueResponse(aRespFrame);

    fDev.GetDeviceConfig(aMaxW, aDiv_, aDecimals, aMode, aADCFreq, aVSEN, aFilt);

    AssertEquals('MaxWeight', 5000.0, aMaxW, 0.001); { 50000 / 10^1 }
    AssertEquals('Division', 5.0, aDiv_, 0.001);    { 50 / 10^1 }
    AssertEquals('Decimals', 1, aDecimals);
    AssertEquals('Mode', 'GROSS', aMode);
    AssertEquals('ADCFreq', $04, aADCFreq);
    AssertEquals('VSEN', $00, aVSEN);
    AssertEquals('Filter', $05, aFilt);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Дискретные входы === }

procedure TTestClient.Test_GetDiscreteInputs;
var
  aRespFrame, aData, aResult: TBytes;
begin
  SetupMock(True);
  Initialize(aData);
  try
    SetLength(aData, 2);
    aData[0] := $A5; aData[1] := $3C;
    aRespFrame := BuildFrame($01, COP_GET_DISC_IN, aData, True);
    fMock.QueueResponse(aRespFrame);

    aResult := fDev.GetDiscreteInputs;
    AssertEquals('Length', 2, Length(aResult));
    AssertEquals('Byte 0', $A5, aResult[0]);
    AssertEquals('Byte 1', $3C, aResult[1]);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Индикаторы === }

procedure TTestClient.Test_GetIndicators;
var
  aRespFrame, aData: TBytes;
  aText: string;
  aFlags: Byte;
begin
  SetupMock(True);
  try
    Initialize(aData);
    { '12345' + aFlags byte $24 (БРУТТО=1, НЕТТО=0) }
    SetLength(aData, 6);
    aData[0] := Byte('1'); aData[1] := Byte('2'); aData[2] := Byte('3');
    aData[3] := Byte('4'); aData[4] := Byte('5');
    aData[5] := $24;
    aRespFrame := BuildFrame($01, COP_GET_DISPLAY, aData, True);
    fMock.QueueResponse(aRespFrame);

    fDev.GetIndicators(aText, aFlags);
    AssertEquals('Text', '12345', aText);
    AssertEquals('Flags', $24, aFlags);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Счётчики === }

procedure TTestClient.Test_GetCounter;
var
  aRespFrame, aData, aResult: TBytes;
begin
  SetupMock(True);
  try
    Initialize(aData);
    { Запрос счётчика 1, ответ: NW=01, данные счётчика }
    SetLength(aData, 5);
    aData[0] := $01; { NW }
    aData[1] := $00; aData[2] := $00; aData[3] := $05; aData[4] := $00;
    aRespFrame := BuildFrame($01, COP_GET_COUNTER, aData, True);
    fMock.QueueResponse(aRespFrame);

    aResult := fDev.GetCounter(1);
    AssertEquals('Length', 5, Length(aResult));
    AssertEquals('NW', $01, aResult[0]);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Дозирование === }

procedure TTestClient.Test_DosingStart;
var
  aRespFrame: TBytes;
begin
  SetupMock(True);
  try
    aRespFrame := BuildFrame($01, COP_DOSING_CTRL, nil, True);
    fMock.QueueResponse(aRespFrame);

    fDev.DosingControl(DOS_START);
    AssertEquals('Sent', 1, fMock.GetSentCount);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Проверка отправленного кадра === }

procedure TTestClient.Test_SentFrameFormat;
var
  aRespFrame, aData, aSent: TBytes;
begin
  SetupMock(True);
  try
    Initialize(aData);
    { Ожидаем вес, даём минимальный ответ }
    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    fDev.GetBruttoWeight;

    AssertEquals('Sent 1 frame', 1, fMock.GetSentCount);
    aSent := fMock.GetSentData(0);

    { Кадр должен начинаться с FF, содержать адрес и C3h }
    AssertEquals('Start FF', $FF, aSent[0]);
    AssertEquals('Address', $01, aSent[1]);
    AssertEquals('COP', $C3, aSent[2]);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Повторные попытки === }

procedure TTestClient.Test_Retry_DefaultsZero;
begin
  SetupMock(True);
  try
    AssertEquals('Default RetryCount', 0, fDev.RetryCount);
    AssertEquals('Default RetryDelayMS', 0, fDev.RetryDelayMS);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_Retry_SuccessFirstTry;
var
  W: TWeightData;
  aRespFrame: TBytes;
  aData: TBytes = nil;
begin
  SetupMock(True);
  try
    fDev.RetryCount := 2; { 2 повтора разрешены, но не нужны }
    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    W := fDev.GetBruttoWeight;

    AssertEquals('Weight', 50.0, W.Weight, 0.001);
    AssertEquals('Sent count should be 1 (no retries needed)',
      1, fMock.GetSentCount);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_Retry_CRCErrThenSuccess;
var
  W: TWeightData;
  aRespFrame: TBytes;
  aData: TBytes = nil;
begin
  SetupMock(True);
  try
    fDev.RetryCount := 1;

    { Первая попытка: кадр с ошибкой CRC → повторяемая ошибка }
    QueueBadCRCWeightResponse;

    { Вторая попытка: корректный кадр }
    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    W := fDev.GetBruttoWeight;

    AssertEquals('Weight', 50.0, W.Weight, 0.001);
    AssertEquals('Sent count should be 2 (first CRC error, retry OK)',
      2, fMock.GetSentCount);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_CRCError_Type;
var
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    QueueBadCRCWeightResponse;

    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: ETensoMCRCError do
        aRaised := True;
    end;

    AssertTrue('Should raise ETensoMCRCError', aRaised);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_Retry_TimeoutExhausted;
var
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    fDev.RetryCount := 2;
    fDev.ResponseTimeout := 50; { короткий таймаут для ускорения теста }

    { Мок не имеет ответов → все попытки таймаутятся }
    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: ETensoMTimeoutError do
        aRaised := True;
    end;

    AssertTrue('Should raise ETensoMTimeoutError after exhausting retries', aRaised);

    AssertTrue('Should raise after exhausting retries', aRaised);
    AssertEquals('Should send 3 times (1 initial + 2 retries)', 3, fMock.GetSentCount);
    AssertTrue('Error should mention timeout', Pos('timeout', fDev.LastError) > 0);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_Retry_EEhNotRetried;
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    fDev.RetryCount := 5; { 5 повторов разрешены, но EEh — смысловая ошибка }

    SetLength(aData, 1);
    aData[0] := ERR_CRC; { $06 }
    aRespFrame := BuildFrame($01, COP_ERROR, aData, True);
    fMock.QueueResponse(aRespFrame);

    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: ETensoMDeviceError do
        aRaised := True;
    end;

    AssertTrue('Should raise EEh', aRaised);
    AssertEquals('Should send only once (EEh is not retried)',
      1, fMock.GetSentCount);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_Retry_FDhNotRetried;
var
  aRespFrame: TBytes;
  aData: TBytes;
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    fDev.RetryCount := 5; { 5 повторов разрешены, но FDh — смысловая ошибка }

    Initialize(aData);
    SetLength(aData, 1);
    aData[0] := $00;
    aRespFrame := BuildFrame($01, COP_UNSUPPORTED, aData, True);
    fMock.QueueResponse(aRespFrame);

    aRaised := False;
    try
      fDev.GetADCCode;
    except
      on E: ETensoMProtocolError do
        aRaised := True;
    end;

    AssertTrue('Should raise ETensoMProtocolError', aRaised);
    AssertEquals('Should send only once (FDh is not retried)', 1, fMock.GetSentCount);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_Retry_COPMismatchNotRetried;
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    fDev.RetryCount := 3; { 3 повтора разрешены, но несовпадение COP — смысловая ошибка }

    { Запрашиваем C3h (GetBruttoWeight), отвечаем C2h (Netto) }
    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_NETTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: ETensoMProtocolError do
        aRaised := True;
    end;

    AssertTrue('Should raise COP mismatch (ETensoMProtocolError)', aRaised);
    AssertEquals('Should send only once (COP mismatch is not retried)',
      1, fMock.GetSentCount);
    AssertTrue('Error should mention COP codes',
      Pos('instead of', fDev.LastError) > 0);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Протоколирование кадра === }

procedure TTestClient.Test_FrameLog_NotCalledWhenNil;
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
  aLog: TFrameLogCollector;
begin
  SetupMock(True);
  aLog := TFrameLogCollector.Create;
  try
    { OnFrameLog НЕ назначен (nil по умолчанию) }
    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    { Выполняем команду — не должно быть исключений }
    fDev.GetBruttoWeight;

    { Коллектор не назначался, поэтому его счётчик остаётся 0.
      Это также проверяет, что вызов с nil-указателем не падает. }
    AssertEquals('Log count should be 0 (callback not assigned)', 0, aLog.GetCount);
  finally
    aLog.Free;
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_FrameLog_SendAndReceive;
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
  aLog: TFrameLogCollector;
begin
  SetupMock(True);
  aLog := TFrameLogCollector.Create;
  try
    fDev.OnFrameLog := @aLog.HandleLog;

    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    fDev.GetBruttoWeight;

    { Ожидаем ровно 2 вызова: отправка и приём }
    AssertEquals('Log count', 2, aLog.GetCount);
    AssertTrue('First is send', aLog.GetDir(0) = fdSend);
    AssertTrue('Second is receive', aLog.GetDir(1) = fdReceive);
  finally
    aLog.Free;
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_FrameLog_HexContent;
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
  aLog: TFrameLogCollector;
  aExpectedReqHex, aExpectedRespHex: string;
begin
  SetupMock(True);
  aLog := TFrameLogCollector.Create;
  try
    fDev.OnFrameLog := @aLog.HandleLog;

    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    fDev.GetBruttoWeight;

    { Hex в логе должен совпадать с LastRequestHex / LastResponseHex }
    aExpectedReqHex := fDev.LastRequestHex;
    aExpectedRespHex := fDev.LastResponseHex;

    AssertEquals('Send hex mismatch', aExpectedReqHex, aLog.GetHex(0));
    AssertEquals('Receive hex mismatch', aExpectedRespHex, aLog.GetHex(1));

    { Дополнительно: hex начинается с ff (разделитель) и содержит адрес $01 }
    AssertTrue('Send hex starts with ff', Pos('ff', aLog.GetHex(0)) = 1);
    AssertTrue('Receive hex starts with ff', Pos('ff', aLog.GetHex(1)) = 1);
  finally
    aLog.Free;
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_FrameLog_OnRetry;
var
  W: TWeightData;
  aRespFrame: TBytes;
  aData: TBytes = nil;
  aLog: TFrameLogCollector;
begin
  SetupMock(True);
  aLog := TFrameLogCollector.Create;
  try
    fDev.OnFrameLog := @aLog.HandleLog;
    fDev.RetryCount := 1;

    { Попытка 1: CRC-ошибка → логируется отправка и приём (битый кадр)
      Попытка 2: успех → логируется отправка и приём }
    QueueBadCRCWeightResponse;

    SetLength(aData, 4);
    aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    fMock.QueueResponse(aRespFrame);

    W := fDev.GetBruttoWeight;

    { 2 попытки × (send + receive) = 4 вызова }
    AssertEquals('Log count', 4, aLog.GetCount);

    { Порядок: send, receive, send, receive }
    AssertTrue('Entry 0 is send',    aLog.GetDir(0) = fdSend);
    AssertTrue('Entry 1 is receive', aLog.GetDir(1) = fdReceive);
    AssertTrue('Entry 2 is send',    aLog.GetDir(2) = fdSend);
    AssertTrue('Entry 3 is receive', aLog.GetDir(3) = fdReceive);

    { Оба запроса одинаковы (фрейм не меняется между попытками) }
    AssertEquals('Request hex same on retry',
      aLog.GetHex(0), aLog.GetHex(2));

    { Ответы различаются (битый и корректный) }
    AssertTrue('Response hex differs after retry',
      aLog.GetHex(1) <> aLog.GetHex(3));

    AssertEquals('Weight', 50.0, W.Weight, 0.001);
  finally
    aLog.Free;
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_FrameLog_TimeoutOnlySend;
var
  aLog: TFrameLogCollector;
  aRaised: Boolean;
begin
  SetupMock(True);
  aLog := TFrameLogCollector.Create;
  try
    fDev.OnFrameLog := @aLog.HandleLog;
    fDev.ResponseTimeout := 50;

    { Мок не имеет ответов → таймаут }
    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: Exception do
        aRaised := True;
    end;

    AssertTrue('Should raise timeout', aRaised);

    { При таймауте кадр отправляется, но ответ не получен —
      DoFrameLog(fdReceive) не вызывается. }
    AssertEquals('Log count should be 1 (send only)', 1, aLog.GetCount);
    AssertTrue('Entry 0 is send', aLog.GetDir(0) = fdSend);
  finally
    aLog.Free;
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_FrameLog_SemanticErrorLogsBoth;
var
  aRespFrame: TBytes;
  aData: TBytes = nil;
  aLog: TFrameLogCollector;
  aRaised: Boolean;
begin
  SetupMock(True);
  aLog := TFrameLogCollector.Create;
  try
    fDev.OnFrameLog := @aLog.HandleLog;

    { Прибор отвечает EEh — кадр физически корректен (CRC OK),
      но семантически это ошибка. Лог должен зафиксировать
      и отправку, и приём до того, как будет брошено исключение. }
    SetLength(aData, 1);
    aData[0] := ERR_CRC; { $06 }
    aRespFrame := BuildFrame($01, COP_ERROR, aData, True);
    fMock.QueueResponse(aRespFrame);

    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: Exception do
        aRaised := True;
    end;

    AssertTrue('Should raise EEh', aRaised);

    { Оба кадра (отправка и приём) должны быть залогированы,
      т.к. ошибка EEh обнаруживается ПОСЛЕ успешного разбора кадра. }
    AssertEquals('Log count', 2, aLog.GetCount);
    AssertTrue('Entry 0 is send',    aLog.GetDir(0) = fdSend);
    AssertTrue('Entry 1 is receive', aLog.GetDir(1) = fdReceive);

    { Hex ответа содержит EEh (COP ошибки) }
    AssertTrue('Response contains EEh',
      Pos('ee', aLog.GetHex(1)) > 0);
  finally
    aLog.Free;
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestClient.Test_ExceptionHierarchy;
var
  aRaised: Boolean;
begin
  SetupMock(True);
  try
    QueueBadCRCWeightResponse;

    aRaised := False;
    try
      fDev.GetBruttoWeight;
    except
      on E: ETensoMFrameError do
        aRaised := True;
    end;

    AssertTrue(
      'ETensoMCRCError must be an ETensoMFrameError',
      aRaised
    );
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

initialization
  RegisterTest(TTestClient);

end.
