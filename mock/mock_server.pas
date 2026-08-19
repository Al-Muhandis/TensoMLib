unit mock_server;

{
  TensoMLib — мок-сервер прибора Тензо-М.

  TMockDeviceTransport реализует ITensoMTransport и является «виртуальным прибором»:
  при получении кадра от клиента (через Send+Receive) разбирает его, формирует ответ
  в соответствии с протоколом Тензо-М и возвращает его через Receive.

  Использование:
    Mock := TMockDeviceTransport.Create($01, True);
    Mock.Weight := 123.4;
    Mock.WeightStable := True;
    Mock.SerialNumber := 12345;
    Dev := TTensoMDevice.Create(Mock, $01, True);
    W := Dev.GetBruttoWeight;  // получит реальный ответ от мока

  Можно также сконфигурировать поведение:
    Mock.OnCommandReceived := @MyHandler;  // логирование входящих команд
    Mock.SimulateError(COP_GET_BRUTTO, ERR_GENERAL); // заставить отвечать ошибкой EEh
    Mock.SimulateUnsupported(COP_GET_DISPLAY);       // ответить FDh на конкретный COP
}

{$mode objfpc}{$H+}
{$INTERFACES CORBA}

interface

uses
  Classes, SysUtils, core, bcd, frames, transport
  ;

type
  { Callback для логирования входящих команд.
    aCOP — код операции полученного кадра.
    aData — payload полученного кадра (без адреса и COP).
    aHex — полный hex-дамп полученного кадра. }
  TCommandReceivedEvent = procedure(aCOP: Byte; const aData: TBytes; const aHex: string) of object;

  { TMockDeviceTransport — транспорт-заглушка, эмулирующий прибор Тензо-М.

    Внутренне:
    - Receive() читает данные, накопленные в fSendBuffer (отправленные клиентом);
    - Разбирает их через TFrameCollector + ParseFrame;
    - Формирует ответный кадр через BuildFrame и помещает в fResponseBuffer;
    - Последующий Receive() отдаёт данные из fResponseBuffer.

    Порядок вызовов со стороны TTensoMDevice:
      1. Send(requestFrame)  → данные попадают в fSendBuffer
      2. Receive(timeout)    → мок разбирает запрос, формирует ответ, отдаёт его }

  { TMockDeviceTransport }

  TMockDeviceTransport = class(ITensoMTransport)
  private
    fAddress: Byte;
    fUseCRC: Boolean;
    fConnected: Boolean;
    fBaudRate: LongInt;
    fLastErrorMsg: string;

    { Буферы для имитации COM-порта }
    fSendBuffer: TBytes;     { данные, отправленные клиентом (входящие для прибора) }
    fResponseBuffer: TBytes; { сформированный ответ прибора (исходящие для клиента) }
    fResponsePos: Integer;   { текущая позиция чтения из fResponseBuffer }

    { Состояние виртуального прибора }
    fWeight: Double;
    fWeightStable: Boolean;
    fWeightOverload: Boolean;
    fWeightNegative: Boolean;
    fWeightDecimalPlaces: Integer;
    fSerialNumber: Cardinal;   { 3 байта: SN2,SN1,SN0 }
    fSystemStatus: Byte;
    fDiscreteInputs: Byte;
    fDiscreteOutputs: Byte;
    fIndicatorsText: string;
    fIndicatorsFlags: Byte;
    fProductCode: string;
    fCounters: array[0..9] of Cardinal;
    fCalibParams: TBytes;
    fADCCode: TBytes;
    fMaxWeight: Double;
    fDivision: Double;
    fDeviceModeIsGross: Boolean;
    fADCFreqCode: Byte;
    fVSEN: Byte;
    fFilterCode: Byte;
    fDosingActive: Boolean;
    fInitTransmitActive: Boolean;
    fInitTransmitCOP: Byte;

    { Поведение ошибок }
    fErrorCOPs: array of record
      COP: Byte;
      ErrorCode: Byte;
    end;
    fUnsupportedCOPs: array of Byte;
    fDelayMS: Cardinal;     { искусственная задержка перед ответом }

    { Callback }
    fOnCommandReceived: TCommandReceivedEvent;

    { Внутренние методы }
    procedure BuildErrorResponse({%H-}aCOP, aErrorCode: Byte; out aResponse: TBytes);
    procedure BuildUnsupportedResponse({%H-}aCOP: Byte; out aResponse: TBytes);
    function HasErrorCOP(aCOP: Byte; out aErrorCode: Byte): Boolean;
    function IsUnsupportedCOP(aCOP: Byte): Boolean;
    function EncodeWeight(aWeight: Double; aStable, aOverload, aNegative: Boolean;
      aDecimalPlaces: Integer): TBytes;
    function EncodeBCD3(aValue: Cardinal): TBytes;
    function EncodeBCD2(aValue: Word): TBytes;
    procedure ProcessPendingData;
  public
    constructor Create(aAddress: Byte; aUseCRC: Boolean = True);

    procedure HandleRequest(const aFrame: TParsedFrame; out aResponse: TBytes);
    destructor Destroy; override;

    { Адрес прибора (read-only, задаётся в конструкторе) }
    property Address: Byte read fAddress;

    { === Конфигурация состояния прибора === }

    { Вес (используется для C2h, C3h, B8h) }
    property Weight: Double read fWeight write fWeight;
    property WeightStable: Boolean read fWeightStable write fWeightStable;
    property WeightOverload: Boolean read fWeightOverload write fWeightOverload;
    property WeightNegative: Boolean read fWeightNegative write fWeightNegative;
    property WeightDecimalPlaces: Integer read fWeightDecimalPlaces write fWeightDecimalPlaces;

    { Серийный номер (A1h), 3 байта }
    property SerialNumber: Cardinal read fSerialNumber write fSerialNumber;

    { Системный статус (BFh) }
    property SystemStatus: Byte read fSystemStatus write fSystemStatus;

    { Дискретные входы/выходы (C4h, C5h, D0h) }
    property DiscreteInputs: Byte read fDiscreteInputs write fDiscreteInputs;
    property DiscreteOutputs: Byte read fDiscreteOutputs write fDiscreteOutputs;

    { Индикаторы (C6h) }
    property IndicatorsText: string read fIndicatorsText write fIndicatorsText;
    property IndicatorsFlags: Byte read fIndicatorsFlags write fIndicatorsFlags;

    { Код продукта (C7h) }
    property ProductCode: string read fProductCode write fProductCode;

    { Счётчики (C8h), индекс 0..9 }
    procedure SetCounter(aIndex: Byte; aValue: Cardinal);
    function GetCounter(aIndex: Byte): Cardinal;

    { Конфигурация (C1h) }
    property MaxWeight: Double read fMaxWeight write fMaxWeight;
    property Division: Double read fDivision write fDivision;
    property DeviceModeIsGross: Boolean read fDeviceModeIsGross write fDeviceModeIsGross;
    property ADCFreqCode: Byte read fADCFreqCode write fADCFreqCode;
    property VSEN: Byte read fVSEN write fVSEN;
    property FilterCode: Byte read fFilterCode write fFilterCode;

    { Калибровка и диагностика (CBh, CCh) }
    property CalibrationParams: TBytes read fCalibParams write fCalibParams;
    property ADCRawCode: TBytes read fADCCode write fADCCode;

    { Искусственная задержка ответа (мс) }
    property ResponseDelayMS: Cardinal read fDelayMS write fDelayMS;

    { Состояние дозирования (только чтение, для тестов) }
    property DosingActive: Boolean read fDosingActive;

    { === Использование CRC === }
    property UseCRC: Boolean read fUseCRC write fUseCRC;

    { === Управление поведением ошибок === }

    { Заставить прибор отвечать EEh + aErrorCode на указанный COP.
      Можно вызвать несколько раз для разных COP. }
    procedure SimulateError(aCOP: Byte; aErrorCode: Byte);

    { Заставить прибор отвечать FDh (неподдерживаемая команда) на указанный COP }
    procedure SimulateUnsupported(aCOP: Byte);

    { Сбросить все настройки поведения ошибок }
    procedure ClearSimulatedErrors;

    { === Callback === }

    { Вызывается при получении каждой команды от клиента }
    property OnCommandReceived: TCommandReceivedEvent
      read fOnCommandReceived write fOnCommandReceived;

    { === Лог отправленных клиентом данных === }

    function GetLastSentHex: string;
    function GetSentFrameCount: Integer;

    { === ITensoMTransport === }
    function Connect(const {%H-}aPortName: string; aBaudRate: LongInt; {%H-}aDataBits: Byte = 8; {%H-}aParity: Char = 'N';
      {%H-}aStopBits: Byte = 1): Boolean;
    procedure Disconnect;
    function IsConnected: Boolean;
    function Send(const aData: TBytes): Integer;
    function Receive({%H-}aTimeoutMS: Cardinal = 1000): TBytes;
    function SetBaudRate(aBaudRate: LongInt): Boolean;
    procedure Flush;
    function GetLastErrorMessage: string;
  end;

implementation

uses
  Math
  ;

{ === Создание / уничтожение === }

constructor TMockDeviceTransport.Create(aAddress: Byte; aUseCRC: Boolean);
var
  I: Integer;
begin
  inherited Create;
  fAddress := aAddress;
  fUseCRC := aUseCRC;
  fConnected := False;
  fBaudRate := 9600;
  fLastErrorMsg := '';

  SetLength(fSendBuffer, 0);
  SetLength(fResponseBuffer, 0);
  fResponsePos := 0;

  { Значения по умолчанию — имитируют реальный прибор }
  fWeight := 0.0;
  fWeightStable := True;
  fWeightOverload := False;
  fWeightNegative := False;
  fWeightDecimalPlaces := 1;

  fSerialNumber := 12345;
  fSystemStatus := $00;
  fDiscreteInputs := $00;
  fDiscreteOutputs := $00;
  fIndicatorsText := '0.0';
  fIndicatorsFlags := $10; { Stable }
  fProductCode := '';

  for I := 0 to 9 do
    fCounters[I] := 0;

  SetLength(fCalibParams, 0);
  SetLength(fADCCode, 0);

  fMaxWeight := 150.0;
  fDivision := 0.5;
  fDeviceModeIsGross := True;
  fADCFreqCode := $03;
  fVSEN := $01;
  fFilterCode := $02;

  fDosingActive := False;
  fInitTransmitActive := False;
  fInitTransmitCOP := 0;

  fDelayMS := 0;

  SetLength(fErrorCOPs, 0);
  SetLength(fUnsupportedCOPs, 0);

  fOnCommandReceived := nil;
end;

destructor TMockDeviceTransport.Destroy;
begin
  SetLength(fSendBuffer, 0);
  SetLength(fResponseBuffer, 0);
  SetLength(fCalibParams, 0);
  SetLength(fADCCode, 0);
  SetLength(fErrorCOPs, 0);
  SetLength(fUnsupportedCOPs, 0);
  inherited;
end;

{ === Вспомогательные кодировщики === }

function TMockDeviceTransport.EncodeWeight(aWeight: Double;
  aStable, aOverload, aNegative: Boolean; aDecimalPlaces: Integer): TBytes;
var
  aRaw: Int64;
  aMultiplier: Double;
  aBcdBytes: TBytes;
  aCON: Byte;
begin
  Result := nil;
  { Вычисляем целое значение с учётом десятичных знаков }
  aMultiplier := 1.0;
  if aDecimalPlaces = 1 then aMultiplier := 10.0
  else if aDecimalPlaces = 2 then aMultiplier := 100.0
  else if aDecimalPlaces = 3 then aMultiplier := 1000.0;

  if aNegative then
    aRaw := Abs(Round(aWeight * aMultiplier))
  else
    aRaw := Round(aWeight * aMultiplier);

  { Кодируем в 3 байта BCD LE }
  if not EncodePackedBCD(aRaw, 3, aBcdBytes) then
  begin
    { Если не влезает — максимально возможное значение }
    aBcdBytes := nil;
    SetLength(aBcdBytes, 3);
    aBcdBytes[0] := $99; aBcdBytes[1] := $99; aBcdBytes[2] := $99;
  end;

  { Формируем CON-байт }
  aCON := Byte(aDecimalPlaces and $07);
  if aStable then aCON := aCON or $10;
  if aOverload then aCON := aCON or $08;
  if aNegative then aCON := aCON or $80;

  { Результат: 4 байта (W0, W1, W2, CON) }
  SetLength(Result, 4);
  Result[0] := aBcdBytes[0];
  Result[1] := aBcdBytes[1];
  Result[2] := aBcdBytes[2];
  Result[3] := aCON;
end;

function TMockDeviceTransport.EncodeBCD3(aValue: Cardinal): TBytes;
var
  aBcd: TBytes;
begin
  if EncodePackedBCD(Int64(aValue), 3, aBcd) then
    Result := aBcd
  else begin
    SetLength(Result, 3);
    Result[0] := $00; Result[1] := $00; Result[2] := $00;
  end;
end;

function TMockDeviceTransport.EncodeBCD2(aValue: Word): TBytes;
var
  aBcd: TBytes;
begin
  if EncodePackedBCD(Int64(aValue), 2, aBcd) then
    Result := aBcd
  else
  begin
    SetLength(Result, 2);
    Result[0] := $00; Result[1] := $00;
  end;
end;

{ === Управление поведением ошибок === }

procedure TMockDeviceTransport.SimulateError(aCOP: Byte; aErrorCode: Byte);
begin
  SetLength(fErrorCOPs, Length(fErrorCOPs) + 1);
  fErrorCOPs[High(fErrorCOPs)].COP := aCOP;
  fErrorCOPs[High(fErrorCOPs)].ErrorCode := aErrorCode;
end;

procedure TMockDeviceTransport.SimulateUnsupported(aCOP: Byte);
begin
  SetLength(fUnsupportedCOPs, Length(fUnsupportedCOPs) + 1);
  fUnsupportedCOPs[High(fUnsupportedCOPs)] := aCOP;
end;

procedure TMockDeviceTransport.ClearSimulatedErrors;
begin
  SetLength(fErrorCOPs, 0);
  SetLength(fUnsupportedCOPs, 0);
end;

function TMockDeviceTransport.HasErrorCOP(aCOP: Byte; out aErrorCode: Byte): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(fErrorCOPs) do
    if fErrorCOPs[I].COP = aCOP then
    begin
      aErrorCode := fErrorCOPs[I].ErrorCode;
      Exit(True);
    end;
  aErrorCode := 0;
  Result := False;
end;

function TMockDeviceTransport.IsUnsupportedCOP(aCOP: Byte): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(fUnsupportedCOPs) do
    if fUnsupportedCOPs[I] = aCOP then
      Exit(True);
  Result := False;
end;

{ === Построение ответов об ошибках === }

procedure TMockDeviceTransport.BuildErrorResponse(aCOP, aErrorCode: Byte;
  out aResponse: TBytes);
var
  aData: TBytes = nil;
begin
  SetLength(aData, 1);
  aData[0] := aErrorCode;
  aResponse := BuildFrame(fAddress, COP_ERROR, aData, fUseCRC);
end;

procedure TMockDeviceTransport.BuildUnsupportedResponse(aCOP: Byte;
  out aResponse: TBytes);
begin
  aResponse := BuildFrame(fAddress, COP_UNSUPPORTED, nil, fUseCRC);
end;

{ === Обработка запроса и формирование ответа === }

procedure TMockDeviceTransport.HandleRequest(const aFrame: TParsedFrame; out aResponse: TBytes);
var
  aCOP: Byte;
  aData: TBytes;
  aW: TBytes;
  aSN: TBytes;
  aCfgData: TBytes = nil;
  aCfgMode: Byte;
  aErrCode: Byte;
  aCounterIdx: Byte;
  aCounterData: TBytes = nil;
  I: Integer;
begin
  aCOP := aFrame.COP;
  aData := aFrame.Data;
  aResponse := nil;

  { Уведомление }
  if Assigned(fOnCommandReceived) then
    fOnCommandReceived(aCOP, aData, HexBytes(aFrame.Raw));

  { Искусственная задержка }
  if fDelayMS > 0 then
    Sleep(fDelayMS);

  { Проверка: имитация ошибки прибора }
  if HasErrorCOP(aCOP, aErrCode) then
  begin
    BuildErrorResponse(aCOP, aErrCode, aResponse);
    Exit;
  end;

  { Проверка: имитация неподдерживаемой команды }
  if IsUnsupportedCOP(aCOP) then
  begin
    BuildUnsupportedResponse(aCOP, aResponse);
    Exit;
  end;

  case aCOP of

    { === Весовые команды === }

    COP_GET_BRUTTO, COP_GET_NETTO, COP_GET_FIXED_BRUTTO:
    begin
      aW := EncodeWeight(fWeight, fWeightStable, fWeightOverload, fWeightNegative, fWeightDecimalPlaces);
      aResponse := BuildFrame(fAddress, aCOP, aW, fUseCRC);
    end;

    COP_ZERO:
    begin
      { При тарировании обнуляем вес }
      fWeight := 0.0;
      fWeightNegative := False;
      fWeightOverload := False;
      aResponse := BuildFrame(fAddress, COP_ZERO, nil, fUseCRC);
    end;

    { === Конфигурация === }

    COP_GET_SETTINGS:
    begin
      { Формат ответа C1h: L0..L2 (3 BCD), L3 (mode+decimals),
        L4..L5 (2 BCD division), L6 (ADC freq), L7 (VSEN), L8 (filter) }
      SetLength(aCfgData, 9);

      { Max weight — 3 BCD }
      aSN := EncodeBCD3(Round(fMaxWeight * (IntPower(10, fWeightDecimalPlaces))));
      aCfgData[0] := aSN[0];
      aCfgData[1] := aSN[1];
      aCfgData[2] := aSN[2];

      { L3: D0-D2 = decimal places, D5 = mode (0=NET, 1=GROSS) }
      aCfgMode := Byte(fWeightDecimalPlaces and $07);
      if fDeviceModeIsGross then aCfgMode := aCfgMode or $20;
      aCfgData[3] := aCfgMode;

      { Division — 2 BCD }
      aSN := EncodeBCD2(Word(Round(fDivision * (IntPower(10, fWeightDecimalPlaces)))));
      aCfgData[4] := aSN[0];
      aCfgData[5] := aSN[1];

      aCfgData[6] := fADCFreqCode;
      aCfgData[7] := fVSEN;
      aCfgData[8] := fFilterCode;

      aResponse := BuildFrame(fAddress, COP_GET_SETTINGS, aCfgData, fUseCRC);
    end;

    { === Системные команды === }

    COP_GET_SERIAL:
    begin
      { 3 байта: SN2 (старший), SN1, SN0 (младший) }
      SetLength(aSN, 3);
      aSN[0] := Byte((fSerialNumber shr 16) and $FF);
      aSN[1] := Byte((fSerialNumber shr 8) and $FF);
      aSN[2] := Byte(fSerialNumber and $FF);
      aResponse := BuildFrame(fAddress, COP_GET_SERIAL, aSN, fUseCRC);
    end;

    COP_GET_STATUS:
    begin
      SetLength(aData, 1);
      aData[0] := fSystemStatus;
      aResponse := BuildFrame(fAddress, COP_GET_STATUS, aData, fUseCRC);
    end;

    COP_SET_ADDRESS:
    begin
      if (Length(aData) >= 1) and (aData[0] >= $01) and (aData[0] <= $9F) then
      begin
        fAddress := aData[0];
        aResponse := BuildFrame(fAddress, COP_SET_ADDRESS, nil, fUseCRC);
      end
      else
        BuildErrorResponse(aCOP, ERR_GENERAL, aResponse);
    end;

    { === Дискретные входы/выходы === }

    COP_GET_DISC_IN:
    begin
      SetLength(aData, 1);
      aData[0] := fDiscreteInputs;
      aResponse := BuildFrame(fAddress, COP_GET_DISC_IN, aData, fUseCRC);
    end;

    COP_GET_DISC_OUT:
    begin
      SetLength(aData, 1);
      aData[0] := fDiscreteOutputs;
      aResponse := BuildFrame(fAddress, COP_GET_DISC_OUT, aData, fUseCRC);
    end;

    COP_SET_DISC_OUT:
    begin
      if Length(aData) >= 1 then
        fDiscreteOutputs := aData[0];
      aResponse := BuildFrame(fAddress, COP_SET_DISC_OUT, nil, fUseCRC);
    end;

    { === Индикаторы и клавиатура === }

    COP_GET_DISPLAY:
    begin
      { Последний байт — флаги, предшествующие — текст }
      SetLength(aData, Length(fIndicatorsText) + 1);
      for I := 1 to Length(fIndicatorsText) do
        aData[I - 1] := Byte(fIndicatorsText[I]);
      aData[High(aData)] := fIndicatorsFlags;
      aResponse := BuildFrame(fAddress, COP_GET_DISPLAY, aData, fUseCRC);
    end;

    COP_GET_PRODUCT_CODE:
    begin
      if Length(fProductCode) > 0 then
      begin
        SetLength(aData, Length(fProductCode));
        for I := 1 to Length(fProductCode) do
          aData[I - 1] := Byte(fProductCode[I]);
      end
      else
        aData := nil;
      aResponse := BuildFrame(fAddress, COP_GET_PRODUCT_CODE, aData, fUseCRC);
    end;

    COP_GET_LAST_KEY:
    begin
      { Возвращаем $00 — нет нажатой клавиши }
      SetLength(aData, 1);
      aData[0] := $00;
      aResponse := BuildFrame(fAddress, COP_GET_LAST_KEY, aData, fUseCRC);
    end;

    { === Счётчики === }

    COP_GET_COUNTER:
    begin
      aCounterIdx := 0;
      if Length(aData) >= 1 then
        aCounterIdx := aData[0];
      if aCounterIdx > 9 then aCounterIdx := 0;

      { Счётчик — 4 байта (little-endian) }
      SetLength(aCounterData, 4);
      aCounterData[0] := Byte(fCounters[aCounterIdx] and $FF);
      aCounterData[1] := Byte((fCounters[aCounterIdx] shr 8) and $FF);
      aCounterData[2] := Byte((fCounters[aCounterIdx] shr 16) and $FF);
      aCounterData[3] := Byte((fCounters[aCounterIdx] shr 24) and $FF);
      aResponse := BuildFrame(fAddress, COP_GET_COUNTER, aCounterData, fUseCRC);
    end;

    { === Калибровка и диагностика === }

    COP_GET_CALIB_PARAMS:
    begin
      if Length(fCalibParams) > 0 then
        aResponse := BuildFrame(fAddress, COP_GET_CALIB_PARAMS, fCalibParams, fUseCRC)
      else
      begin
        { Возвращаем 8 нулевых байт по умолчанию }
        SetLength(aData, 8);
        for I := 0 to 7 do aData[I] := $00;
        aResponse := BuildFrame(fAddress, COP_GET_CALIB_PARAMS, aData, fUseCRC);
      end;
    end;

    COP_GET_ADC_CODE:
    begin
      if Length(fADCCode) > 0 then
        aResponse := BuildFrame(fAddress, COP_GET_ADC_CODE, fADCCode, fUseCRC)
      else
      begin
        { Значение по умолчанию: 2 байта, имитирующие код АЦП }
        SetLength(aData, 2);
        aData[0] := $80; aData[1] := $00;
        aResponse := BuildFrame(fAddress, COP_GET_ADC_CODE, aData, fUseCRC);
      end;
    end;

    { === Установка параметров (без состояния — просто подтверждаем) === }

    COP_SET_BAUD:
    begin
      { Подтверждаем смену скорости }
      aResponse := BuildFrame(fAddress, COP_SET_BAUD, nil, fUseCRC);
    end;

    COP_SET_FILTER:
    begin
      if Length(aData) >= 1 then
        fFilterCode := aData[0];
      aResponse := BuildFrame(fAddress, COP_SET_FILTER, nil, fUseCRC);
    end;

    COP_SET_ADC_FREQ:
    begin
      if Length(aData) >= 1 then
        fADCFreqCode := aData[0];
      aResponse := BuildFrame(fAddress, COP_SET_ADC_FREQ, nil, fUseCRC);
    end;

    COP_SET_DISPLAY_MODE:
    begin
      aResponse := BuildFrame(fAddress, COP_SET_DISPLAY_MODE, nil, fUseCRC);
    end;

    COP_DISPLAY_MSG:
    begin
      aResponse := BuildFrame(fAddress, COP_DISPLAY_MSG, nil, fUseCRC);
    end;

    COP_STORE_MSG:
    begin
      aResponse := BuildFrame(fAddress, COP_STORE_MSG, nil, fUseCRC);
    end;

    { === Дозирование === }

    COP_DOSING_CTRL:
    begin
      if Length(aData) >= 1 then
      begin
        case aData[0] of
          DOS_START:  fDosingActive := True;
          DOS_STOP:   fDosingActive := False;
          DOS_PAUSE:  ; { просто подтверждаем }
          DOS_RESUME: fDosingActive := True;
        end;
      end;
      aResponse := BuildFrame(fAddress, COP_DOSING_CTRL, nil, fUseCRC);
    end;

    { === Инициативная передача === }

    COP_START_INIT_SEND:
    begin
      if Length(aData) >= 1 then
      begin
        fInitTransmitActive := True;
        fInitTransmitCOP := aData[0];
      end;
      aResponse := BuildFrame(fAddress, COP_START_INIT_SEND, nil, fUseCRC);
    end;

    COP_STOP_INIT_SEND:
    begin
      fInitTransmitActive := False;
      aResponse := BuildFrame(fAddress, COP_STOP_INIT_SEND, nil, fUseCRC);
    end;

    { === Запуск процедур === }

    COP_RUN_PROCEDURE:
    begin
      aResponse := BuildFrame(fAddress, COP_RUN_PROCEDURE, nil, fUseCRC);
    end;

    { === Остальные команды — подтверждение без данных === }

    COP_SET_INPUT_RANGE,
    COP_SET_ADC_CHANNEL,
    COP_SET_WEIGHT_POINT,
    COP_SET_SPECIAL_PAR,
    COP_WRITE_T_NKP,
    COP_WRITE_T_RKP,
    COP_WRITE_LINEAR,
    COP_GET_WEIGHT_POINTS,
    COP_GET_SPECIAL_PAR,
    COP_GET_COMPLEX,
    COP_GET_PROC_STATUS,
    COP_READ_T_NKP,
    COP_READ_T_RKP,
    COP_READ_LINEAR:
    begin
      aResponse := BuildFrame(fAddress, aCOP, nil, fUseCRC);
    end;

    else
    begin
      { Неизвестный COP — отвечаем «не поддерживается» }
      BuildUnsupportedResponse(aCOP, aResponse);
    end;

  end;
end;

{ === Разбор накопленных данных от клиента === }

procedure TMockDeviceTransport.ProcessPendingData;
var
  aCollector: TFrameCollector;
  aBody, aRaw: TBytes;
  aParsed: TParsedFrame;
  aResponse: TBytes;
  aReqCOP: Byte;
  J: Integer;
begin
  if Length(fSendBuffer) = 0 then
    Exit;

  aCollector := TFrameCollector.Create;
  try
    for J := 0 to High(fSendBuffer) do
    begin
      if aCollector.Feed(fSendBuffer[J], aBody, aRaw) then
      begin
        { Кадр получен — разбираем и формируем ответ }
        aReqCOP := $00;
        try
          aParsed := ParseFrame(aBody, aRaw, fAddress, fUseCRC);
          aReqCOP := aParsed.COP;
          HandleRequest(aParsed, aResponse);
        except
          on E: Exception do
          begin
            { Если не смогли разобрать — отвечаем ошибкой CRC.
              Если COP неизвестен, используем $00 в ответе. }
            BuildErrorResponse(aReqCOP, ERR_CRC, aResponse);
          end;
        end;

        { Помещаем ответ в буфер ответов }
        if Length(aResponse) > 0 then
        begin
          { Добавляем к существующему буферу ответов }
          SetLength(fResponseBuffer, Length(fResponseBuffer) + Length(aResponse));
          Move(aResponse[0], fResponseBuffer[Length(fResponseBuffer) - Length(aResponse)],
            Length(aResponse));
        end;

        Break; { Обрабатываем один кадр за раз }
      end;
    end;
  finally
    aCollector.Free;
  end;

  { Очищаем обработанные данные из буфера отправки }
  SetLength(fSendBuffer, 0);
end;

{ === ITensoMTransport === }

function TMockDeviceTransport.Connect(const aPortName: string; aBaudRate: LongInt; aDataBits: Byte; aParity: Char;
  aStopBits: Byte): Boolean;
begin
  fBaudRate := aBaudRate;
  fConnected := True;
  SetLength(fSendBuffer, 0);
  SetLength(fResponseBuffer, 0);
  fResponsePos := 0;
  Result := True;
end;

procedure TMockDeviceTransport.Disconnect;
begin
  fConnected := False;
  SetLength(fSendBuffer, 0);
  SetLength(fResponseBuffer, 0);
  fResponsePos := 0;
end;

function TMockDeviceTransport.IsConnected: Boolean;
begin
  Result := fConnected;
end;

function TMockDeviceTransport.Send(const aData: TBytes): Integer;
var
  aOldLen: Integer;
begin
  { Добавляем данные в буфер отправки }
  aOldLen := Length(fSendBuffer);
  SetLength(fSendBuffer, aOldLen + Length(aData));
  Move(aData[0], fSendBuffer[aOldLen], Length(aData));
  Result := Length(aData);
end;

function TMockDeviceTransport.Receive(aTimeoutMS: Cardinal): TBytes;
var
  aAvailable: Integer;
  aChunk: TBytes = nil;
begin
  { Если в буфере ответов ещё есть данные — отдаём }
  if fResponsePos < Length(fResponseBuffer) then
  begin
    aAvailable := Length(fResponseBuffer) - fResponsePos;
    SetLength(aChunk, aAvailable);
    Move(fResponseBuffer[fResponsePos], aChunk[0], aAvailable);
    fResponsePos := Length(fResponseBuffer);
    Result := aChunk;
    Exit;
  end;

  { Буфер ответов исчерпан — обрабатываем накопленные данные от клиента }
  ProcessPendingData;

  { После обработки — проверяем, появился ли ответ }
  if fResponsePos < Length(fResponseBuffer) then
  begin
    aAvailable := Length(fResponseBuffer) - fResponsePos;
    SetLength(aChunk, aAvailable);
    Move(fResponseBuffer[fResponsePos], aChunk[0], aAvailable);
    fResponsePos := Length(fResponseBuffer);
    Result := aChunk;
  end
  else
    Result := nil; { Нет данных — таймаут }
end;

function TMockDeviceTransport.SetBaudRate(aBaudRate: LongInt): Boolean;
begin
  fBaudRate := aBaudRate;
  Result := True;
end;

procedure TMockDeviceTransport.Flush;
begin
  { Очищаем буфер ответов, чтобы клиент получил свежие данные }
  SetLength(fResponseBuffer, 0);
  fResponsePos := 0;
end;

function TMockDeviceTransport.GetLastErrorMessage: string;
begin
  Result := fLastErrorMsg;
end;

{ === Счётчики === }

procedure TMockDeviceTransport.SetCounter(aIndex: Byte; aValue: Cardinal);
begin
  if aIndex <= 9 then
    fCounters[aIndex] := aValue;
end;

function TMockDeviceTransport.GetCounter(aIndex: Byte): Cardinal;
begin
  if aIndex <= 9 then
    Result := fCounters[aIndex]
  else
    Result := 0;
end;

{ === Лог отправленных данных === }

function TMockDeviceTransport.GetLastSentHex: string;
begin
  Result := HexBytes(fSendBuffer);
end;

function TMockDeviceTransport.GetSentFrameCount: Integer;
begin
  { Приблизительная оценка: считаем количество кадров по разделителям FF FF }
  Result := 0;
end;

{ === Вспомогательная функция (не экспортируется из core) === }

function Power10(aExp: Integer): Double;
begin
  case aExp of
    0: Result := 1.0;
    1: Result := 10.0;
    2: Result := 100.0;
    3: Result := 1000.0;
  else
    Result := 1.0;
  end;
end;

end.
