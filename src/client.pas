unit client;

{
  TensoMLib — высокоуровневый клиент прибора Тензо-М.

  TTensoMDevice — фасад, скрывающий детали протокола:
  построение кадров, CRC, байт-стаффинг, разбор ответов.

  Использование:
    Trans := TSerialTransport.Create;
    Trans.Connect('/dev/ttyUSB0', 9600);
    Dev := TTensoMDevice.Create(Trans, 1);
    W := Dev.GetBruttoWeight;
    Dev.Free;
    Trans.Free;
}

{$mode objfpc}{$H+}
{$INTERFACES CORBA}

interface

uses
  Classes, SysUtils, core, bcd, frames, transport
  ;

type
  { Направление кадра для протоколирования. }
  TFrameDirection = (fdSend, fdReceive);

  { Callback для протоколирования обменов.
    Вызывается для каждого отправленного и полученного кадра.
    При включённых повторах (RetryCount) вызывается для каждой попытки.
    aDirection — направление: fdSend (запрос к прибору) или fdReceive (ответ прибора).
    aFrameHex — кадр в виде hex-строки (байты через пробел).
    Пример назначения:
      Dev.OnFrameLog := @MyForm.HandleFrameLog;
    где
      procedure TMyForm.HandleFrameLog(aDir: TFrameDirection; const aHex: string);
      begin
        LogMemo.Lines.Add(Format('[%s] %s',
          [IfThen(aDir = fdSend, '>>', '<<'), aHex]));
      end; }
  TFrameLogEvent = procedure(aDirection: TFrameDirection; const aFrameHex: string) of object;

  { Основной класс-клиент для работы с одним прибором. }

  { TTensoMDevice }

  TTensoMDevice = class
  private
    fTransport: ITensoMTransport;
    fAddress: Byte;
    fUseCRC: Boolean;
    fResponseTimeout: Cardinal;
    fRetryCount: Integer;
    fRetryDelayMS: Cardinal;
    fOnFrameLog: TFrameLogEvent;
    fLastRequestHex: string;
    fLastResponseHex: string;
    fLastError: string;

    procedure RaiseDeviceError(const aMsg: string); 
    procedure RaiseFrameError(const aMsg: string);
    procedure RaiseProtocolError(const aMsg: string);
    procedure RaiseTimeoutError(const aMsg: string);
    procedure RaiseTransportError(const aMsg: string);
    function SendCommand(aCOP: Byte; const aData: TBytes = nil): TParsedFrame;
    procedure DoFrameLog(aDirection: TFrameDirection; const aHex: string);
    function IsRetryableException(E: Exception): Boolean;
  public
    constructor Create(aTransport: ITensoMTransport; aAddress: Byte; aUseCRC: Boolean = True);

    { === Свойства === }
    property Address: Byte read fAddress;
    property UseCRC: Boolean read fUseCRC write fUseCRC;
    property ResponseTimeout: Cardinal read fResponseTimeout write fResponseTimeout;
    property LastRequestHex: string read fLastRequestHex;
    property LastResponseHex: string read fLastResponseHex;
    property LastError: string read fLastError;

    { === Политика повторов === }

    { Количество повторов при таймауте, неполной отправке или ошибке целостности входного кадра (0 = без повторов).
      Не повторяются: неверный адрес, ошибка прибора (EEh), неподдерживаемая команда (FDh), несовпадение COP
      и другие семантические ошибки. }
    property RetryCount: Integer read fRetryCount write fRetryCount;

    { Пауза между повторами в мс (0 = без паузы, по умолчанию). }
    property RetryDelayMS: Cardinal read fRetryDelayMS write fRetryDelayMS;

    { === Протоколирование === }

    { Callback для логирования кадров. nil по умолчанию (логирование отключено).
      Вызывается внутри SendCommand для каждого отправленного и полученного кадра.
      При повторах вызывается для каждой попытки, что позволяет диагностировать проблемы со связью. }
    property OnFrameLog: TFrameLogEvent read fOnFrameLog write fOnFrameLog;

    { === Весовые измерения === }

    { Передать вес БРУТТО (C3h). }
    function GetBruttoWeight: TWeightData;

    { Передать вес НЕТТО (C2h). }
    function GetNettoWeight: TWeightData;

    { Обнулить показания веса / тарирование (C0h). }
    procedure Tare;

    { === Конфигурация прибора === }

    { Передать настройку параметров (C1h).
      Возвращает: MaxWeight, Division, DecimalPlaces, DeviceMode, ADCFreqCode, FilterCode. }
    procedure GetDeviceConfig(out aMaxWeight: Double; out aDivision: Double; out aDecimalPlaces: Integer;
      out aDeviceMode: string; out aADCFreqCode: Byte; out aFilterCode: Byte);

    { Установить скорость обмена (DBh). }
    procedure SetBaudRate(aRateCode: Byte);

    { Установить полосу пропускания фильтра (DAh). }
    procedure SetFilter(aFilterCode: Byte);

    { Установить частоту обновления АЦП (D9h). }
    procedure SetADCFrequency(aFreqCode: Byte);

    { === Системная информация === }

    { Получить серийный номер (A1h). Возвращает 3-байтовый SN как Cardinal. }
    function GetSerialNumber: Cardinal;

    { Передать состояние весоизмерительной системы (BFh). }
    function GetSystemStatus: Byte;

    { Присвоить устройству новый сетевой адрес (A0h). }
    procedure SetNetworkAddress(aNewAddr: Byte);

    { === Дискретные входы/выходы === }

    { Состояние дискретных входов (C4h). }
    function GetDiscreteInputs: TBytes;

    { Состояние дискретных выходов (C5h). }
    function GetDiscreteOutputs: TBytes;

    { Установить сигналы на дискретных выходах (D0h). }
    procedure SetDiscreteOutputs(const aValue: TBytes);

    { === Индикаторы и клавиатура === }

    { Значение индикаторов (C6h). Текст + флаги. }
    procedure GetIndicators(out aText: string; out aFlags: Byte);

    { Введённая кодовая последовательность — код продукта (C7h). }
    function GetProductCode: string;

    { === Счётчики === }

    { Передать счётчик (C8h). NW=0..9. }
    function GetCounter(aCounterNum: Byte): TBytes;

    { === Калибровка и диагностика === }

    { Запрос параметров калибровки (CBh). }
    function GetCalibrationParams: TBytes;

    { Запрос значения кода АЦП (CCh). }
    function GetADCCode: TBytes;

    { === Дозирование === }

    { Управление дозированием (DFh). }
    procedure DosingControl(aCmd: Byte);

    { === Инициативная передача === }

    { Начать инициативную передачу (CEh). ACOP — какой код данных запрашивать. }
    procedure StartInitTransmit(aCOP: Byte);

    { Остановить инициативную передачу (CFh). }
    procedure StopInitTransmit;

    { === Отображение === }

    { Вывести символьное сообщение (D2h). }
    procedure DisplayMessage(aDeviceNum: Byte; const aMsg: string);

    { Перевести прибор в режим индикации веса (CDh). }
    procedure SetDisplayWeightMode;

    { === Диагностика === }

    { Автоопределение режима CRC: пробует без CRC, затем с CRC.
      Меняет fUseCRC. Возвращает True если прибор ответил. }
    function AutoDetectCRC: Boolean;
  end;

implementation

uses
  errors
  ;

{ === Создание / уничтожение === }

constructor TTensoMDevice.Create(aTransport: ITensoMTransport; aAddress: Byte; aUseCRC: Boolean);
begin
  inherited Create;
  if Assigned(aTransport) then
    raise EArgumentNilException.Create('Transport not assigned');
  fTransport := aTransport;
  fAddress := aAddress;
  fUseCRC := aUseCRC;
  fResponseTimeout := 700; { мс }
  fRetryCount := 0;
  fRetryDelayMS := 0;
  fOnFrameLog := nil;
end;

{ === Внутренние методы === }

procedure TTensoMDevice.RaiseFrameError(const aMsg: string);
begin
  fLastError := aMsg;
  raise ETensoMFrameError.Create(aMsg);
end;

procedure TTensoMDevice.RaiseTransportError(const aMsg: string);
begin
  fLastError := aMsg;
  raise ETensoMTransportError.Create(aMsg);
end;

procedure TTensoMDevice.RaiseTimeoutError(const aMsg: string);
begin
  fLastError := aMsg;
  raise ETensoMTimeoutError.Create(aMsg);
end;

procedure TTensoMDevice.RaiseDeviceError(const aMsg: string);
begin
  fLastError := aMsg;
  raise ETensoMDeviceError.Create(aMsg);
end;

procedure TTensoMDevice.RaiseProtocolError(const aMsg: string);
begin
  fLastError := aMsg;
  raise ETensoMProtocolError.Create(aMsg);
end;

procedure TTensoMDevice.DoFrameLog(aDirection: TFrameDirection; const aHex: string);
begin
  if Assigned(fOnFrameLog) then
    fOnFrameLog(aDirection, aHex);
end;

function TTensoMDevice.IsRetryableException(E: Exception): Boolean;
begin
  Result := (E is ETensoMTransportError) or (E is ETensoMFrameError);
end;

function TTensoMDevice.SendCommand(aCOP: Byte; const aData: TBytes): TParsedFrame;
var
  aReqFrame: TBytes;
  aRawResp: TBytes;
  aCollector: TFrameCollector;
  J: Integer;
  aBody, aRaw: TBytes;
  aComplete: Boolean;
  T0: QWord;
  aPollInterval: Cardinal;
  aAttempt, aMaxAttempts, aSent: Integer;
  aLastErrMsg: string;
  aParseOK: Boolean;
begin
  fLastError := EmptyStr;
  Initialize(Result);

  if not fTransport.IsConnected then
    RaiseTransportError('Transport is not connected');

  { 1. Строим кадр запроса (не меняется между попытками) }
  aReqFrame := BuildFrame(fAddress, aCOP, aData, fUseCRC);
  fLastRequestHex := HexBytes(aReqFrame);

  aMaxAttempts := 1 + fRetryCount;
  aLastErrMsg := EmptyStr;

  for aAttempt := 1 to aMaxAttempts do
  begin
    aParseOK := False;
    try
      { 2. Очищаем входной буфер и отправляем }
      fTransport.Flush;

      aSent := fTransport.Send(aReqFrame);
      if aSent <> Length(aReqFrame) then
      begin
        aLastErrMsg := Format('Failed to send complete frame: %d of %d bytes. %s',
          [aSent, Length(aReqFrame), fTransport.GetLastErrorMessage]);

        if aAttempt < aMaxAttempts then
        begin
          if fRetryDelayMS > 0 then
            Sleep(fRetryDelayMS);
          Continue;
        end;

        RaiseTransportError(aLastErrMsg);
      end;

      DoFrameLog(fdSend, fLastRequestHex);

      { 3. Читаем ответ с таймаутом }
      aCollector := TFrameCollector.Create;
      try
        T0 := GetTickCount64;
        aPollInterval := 50; { мс между попытками чтения }

        while (GetTickCount64 - T0) < Cardinal(fResponseTimeout) do
        begin
          aRawResp := fTransport.Receive(aPollInterval);
          if Length(aRawResp) = 0 then
            Continue;

          for J := 0 to High(aRawResp) do
          begin
            aComplete := aCollector.Feed(aRawResp[J], aBody, aRaw);
            if not aComplete then Continue;

            fLastResponseHex := HexBytes(aRaw);
            DoFrameLog(fdReceive, fLastResponseHex);

            { 4. Разбираем payload (может бросить исключение при CRC-ошибке) }
            Result := ParseFrame(aBody, aRaw, fAddress, fUseCRC);
            aParseOK := True;
            Break; { кадр получен и разобран — выходим из цикла опроса }
          end;
          if aParseOK then Break;
        end;

        if not aParseOK then
        begin
          { Таймаут — повторяемая ошибка }
          fLastResponseHex := '';
          aLastErrMsg := 'Device response timeout';
          if aAttempt < aMaxAttempts then
          begin
            if fRetryDelayMS > 0 then
              Sleep(fRetryDelayMS);
            Continue;
          end;
          RaiseTimeoutError(aLastErrMsg);
        end;

      finally
        aCollector.Free;
      end;

    except
      { Повторяем только ошибки, явно классифицированные как повторяемые
        (см. IsRetryableException): ETensoMTransportError и ETensoMFrameError.
        Семантические (ETensoMDeviceError, ETensoMProtocolError) и любые
        прочие ошибки пробрасываются выше без повтора. }
      on E: ETensoMError do
      begin
        if IsRetryableException(E) then
        begin
          aLastErrMsg := E.Message;

          if aAttempt < aMaxAttempts then
          begin
            if fRetryDelayMS > 0 then
              Sleep(fRetryDelayMS);
            Continue;
          end;
        end;

        raise;
      end;
    end;

    { === Проверки ответа (смысловые ошибки — НЕ повторяемые) === }
    { Сюда попадаем только при успешно разобранном кадре (aParseOK = True).
      Прибор ответил корректно, но семантически это ошибка — повтор не поможет. }

    { 5. Ошибка прибора (EEh) }
    if Result.COP = COP_ERROR then
    begin
      if Length(Result.Data) > 0 then
        RaiseDeviceError(Format('Device error EEh, code %02X: %s', [Result.Data[0], ErrorDescription(Result.Data[0])]))
      else
        RaiseDeviceError('Device error EEh');
    end;

    { 6. Неподдерживаемая команда (FDh) }
    if Result.COP = COP_UNSUPPORTED then
      RaiseProtocolError(Format('The %02Xh command is not supported by the device', [aCOP]));

    { 7. COP ответа совпадает с запросом }
    if Result.COP <> aCOP then
      RaiseProtocolError(Format('Response with the code %02Xh instead of %02Xh', [Result.COP, aCOP]));

    Exit; { Успех }
  end;
end;

{ === Весовые измерения === }

function TTensoMDevice.GetBruttoWeight: TWeightData;
var
  aPF: TParsedFrame;
begin
  aPF := SendCommand(COP_GET_BRUTTO);
  try
    Result := DecodeWeight(aPF.Data);
  except
    on E: Exception do
      RaiseFrameError(Format('GROSS weight analysis error: %s', [E.Message]));
  end;
end;

function TTensoMDevice.GetNettoWeight: TWeightData;
var
  aPF: TParsedFrame;
begin
  aPF := SendCommand(COP_GET_NETTO);
  try
    Result := DecodeWeight(aPF.Data);
  except
    on E: Exception do
      RaiseFrameError(Format('Error in analyzing the NET weight: %s', [E.Message]));
  end;
end;

procedure TTensoMDevice.Tare;
begin
  SendCommand(COP_ZERO);
end;

{ === Конфигурация прибора === }

procedure TTensoMDevice.GetDeviceConfig(out aMaxWeight: Double; out aDivision: Double; out aDecimalPlaces: Integer; out
  aDeviceMode: string; out aADCFreqCode: Byte; out aFilterCode: Byte);
var
  aPF: TParsedFrame;
  aMaxRaw, aDivRaw: Int64;
  aDecimals: Integer;
  aDivisor: Double;
  I: Integer;
begin
  { Инициализация выходных параметров }
  aMaxWeight := 0;
  aDivision := 0;
  aDecimalPlaces := 0;
  aDeviceMode := '';
  aADCFreqCode := 0;
  aFilterCode := 0;

  aPF := SendCommand(COP_GET_SETTINGS);
  if Length(aPF.Data) < 9 then
    RaiseFrameError(Format('Incomplete response C1h: %d byte(s)', [Length(aPF.Data)]));

  { L0,L1,L2 — максимальный предел взвешивания, BCD }
  aMaxRaw := DecodePackedBCD(Copy(aPF.Data, 0, 3));

  { N — количество знаков после запятой (биты 0-2), режим (бит 5) }
  aDecimals := Integer(aPF.Data[3] and $07);
  aDecimalPlaces := aDecimals;
  if (aPF.Data[3] and $20) <> 0 then
    aDeviceMode := 'GROSS' // = БРУТТО
  else
    aDeviceMode := 'NET'; // = НЕТТО

  { aDivisor для перевода BCD в вещественное }
  aDivisor := 1.0;
  for I := 0 to aDecimals - 1 do
    aDivisor := aDivisor * 10.0;
  aMaxWeight := aMaxRaw / aDivisor;

  { Dis0,Dis1 — дискретность, BCD }
  if Length(aPF.Data) >= 6 then
  begin
    aDivRaw := DecodePackedBCD(Copy(aPF.Data, 4, 2));
    aDivision := aDivRaw / aDivisor;
  end;

  { Freq — частота АЦП (байт 6) }
  if Length(aPF.Data) >= 7 then
    aADCFreqCode := aPF.Data[6];

  { Filtr — фильтр (байт 8) }
  if Length(aPF.Data) >= 9 then
    aFilterCode := aPF.Data[8];
end;

procedure TTensoMDevice.SetBaudRate(aRateCode: Byte);
var
  aData: TBytes = nil;
  aBaudRate: LongInt;
begin
  aBaudRate := BaudRateToValue(aRateCode);

  SetLength(aData, 1);
  aData[0] := aRateCode;

  { DBh + ответ ещё на старой скорости }
  SendCommand(COP_SET_BAUD, aData);

  { Только после получения корректного ответа
    переводим локальный COM-порт }
  if not fTransport.SetBaudRate(aBaudRate) then
    RaiseTransportError('incorrect bauderate command');
end;

procedure TTensoMDevice.SetFilter(aFilterCode: Byte);
var
  aData: TBytes = nil;
begin
  SetLength(aData, 1);
  aData[0] := aFilterCode;
  SendCommand(COP_SET_FILTER, aData);
end;

procedure TTensoMDevice.SetADCFrequency(aFreqCode: Byte);
var
  aData: TBytes = nil;
begin
  SetLength(aData, 1);
  aData[0] := aFreqCode;
  SendCommand(COP_SET_ADC_FREQ, aData);
end;

{ === Системная информация === }

function TTensoMDevice.GetSerialNumber: Cardinal;
var
  aPF: TParsedFrame;
begin
  aPF := SendCommand(COP_GET_SERIAL);
  if Length(aPF.Data) < 3 then
    RaiseFrameError('Incomplete serial number');

  { SN2 — старший, SN0 — младший (передаются в порядке SN2,SN1,SN0) }
  Result := Cardinal(aPF.Data[0]) shl 16
          or Cardinal(aPF.Data[1]) shl 8
          or Cardinal(aPF.Data[2]);
end;

function TTensoMDevice.GetSystemStatus: Byte;
var
  aPF: TParsedFrame;
begin
  aPF := SendCommand(COP_GET_STATUS);
  if Length(aPF.Data) < 1 then
    RaiseFrameError('Empty status');
  Result := aPF.Data[0];
end;

procedure TTensoMDevice.SetNetworkAddress(aNewAddr: Byte);
var
  aData: TBytes = nil;
begin
  if (aNewAddr < $01) or (aNewAddr > $9F) then
  begin
    fLastError := 'The address must be between $01 and $9F';
    raise EArgumentOutOfRangeException.Create(fLastError);
  end;
  SetLength(aData, 1);
  aData[0] := aNewAddr;
  SendCommand(COP_SET_ADDRESS, aData);
end;

{ === Дискретные входы/выходы === }

function TTensoMDevice.GetDiscreteInputs: TBytes;
var
  aPF: TParsedFrame;
begin
  aPF := SendCommand(COP_GET_DISC_IN);
  Result := Copy(aPF.Data, 0, Length(aPF.Data));
end;

function TTensoMDevice.GetDiscreteOutputs: TBytes;
var
  aPF: TParsedFrame;
begin
  aPF := SendCommand(COP_GET_DISC_OUT);
  Result := Copy(aPF.Data, 0, Length(aPF.Data));
end;

procedure TTensoMDevice.SetDiscreteOutputs(const aValue: TBytes);
begin
  SendCommand(COP_SET_DISC_OUT, aValue);
end;

{ === Индикаторы и клавиатура === }

procedure TTensoMDevice.GetIndicators(out aText: string; out aFlags: Byte);
var
  aPF: TParsedFrame;
  I: Integer;
begin
  aText := '';
  aFlags := 0;

  aPF := SendCommand(COP_GET_DISPLAY);
  if Length(aPF.Data) < 1 then
    RaiseFrameError('An empty indicator response');

  { Последний байт — флаги (L), остальные — символы ASCII }
  if Length(aPF.Data) >= 2 then
    for I := 0 to Length(aPF.Data) - 2 do
      aText := aText + Char(aPF.Data[I]);

  aFlags := aPF.Data[High(aPF.Data)];
end;

function TTensoMDevice.GetProductCode: string;
var
  aPF: TParsedFrame;
  I: Integer;
begin
  aPF := SendCommand(COP_GET_PRODUCT_CODE);
  Result := '';
  for I := 0 to High(aPF.Data) do
    Result := Result + Char(aPF.Data[I]);
end;

{ === Счётчики === }

function TTensoMDevice.GetCounter(aCounterNum: Byte): TBytes;
var
  aData: TBytes = nil;
  aPF: TParsedFrame;
begin
  SetLength(aData, 1);
  aData[0] := aCounterNum;
  aPF := SendCommand(COP_GET_COUNTER, aData);
  Result := Copy(aPF.Data, 0, Length(aPF.Data));
end;

{ === Калибровка и диагностика === }

function TTensoMDevice.GetCalibrationParams: TBytes;
var
  aPF: TParsedFrame;
begin
  aPF := SendCommand(COP_GET_CALIB_PARAMS);
  Result := Copy(aPF.Data, 0, Length(aPF.Data));
end;

function TTensoMDevice.GetADCCode: TBytes;
var
  aPF: TParsedFrame;
begin
  aPF := SendCommand(COP_GET_ADC_CODE);
  Result := Copy(aPF.Data, 0, Length(aPF.Data));
end;

{ === Дозирование === }

procedure TTensoMDevice.DosingControl(aCmd: Byte);
var
  aData: TBytes = nil;
begin
  SetLength(aData, 1);
  aData[0] := aCmd;
  SendCommand(COP_DOSING_CTRL, aData);
end;

{ === Инициативная передача === }

procedure TTensoMDevice.StartInitTransmit(aCOP: Byte);
var
  aData: TBytes = nil;
begin
  SetLength(aData, 1);
  aData[0] := aCOP;
  SendCommand(COP_START_INIT_SEND, aData);
end;

procedure TTensoMDevice.StopInitTransmit;
begin
  SendCommand(COP_STOP_INIT_SEND);
end;

{ === Отображение === }

procedure TTensoMDevice.DisplayMessage(aDeviceNum: Byte; const aMsg: string);
var
  aData: TBytes = nil;
  I: Integer;
begin
  SetLength(aData, 1 + Length(aMsg));
  aData[0] := aDeviceNum;
  for I := 1 to Length(aMsg) do
    aData[I] := Byte(aMsg[I]);
  SendCommand(COP_DISPLAY_MSG, aData);
end;

procedure TTensoMDevice.SetDisplayWeightMode;
begin
  SendCommand(COP_SET_DISPLAY_MODE);
end;

{ === Диагностика === }

function TTensoMDevice.AutoDetectCRC: Boolean;
var
  aSavedCRC: Boolean;
begin
  { Пытаемся запросить вес без CRC }
  aSavedCRC := fUseCRC;
  fUseCRC := False;
  try
    GetBruttoWeight;
    Result := True; { Ответили без CRC }
  except
    on E: ETensoMError do
    begin
      { Не ответили без CRC — пробуем с CRC }
      fUseCRC := True;
      try
        GetBruttoWeight;
        Result := True; { Ответили с CRC }
      except
        on E2: ETensoMError do
        begin
          { Ни один режим не сработал — восстанавливаем и выходим }
          fUseCRC := aSavedCRC;
          RaiseTimeoutError(Format('Device does not respond: without CRC: %s; with CRC: %s',
            [E.Message, E2.Message]));
        end;
      end;
    end;
  end;
end;

end.
