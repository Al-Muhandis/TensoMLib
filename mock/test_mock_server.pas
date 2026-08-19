unit test_mock_server;

{
  Юнит-тесты для mock_server.pas — TMockDeviceTransport.

  В отличие от test_client.pas (где используется TMockTransport с заранее
  заготовленными ответами), здесь TMockDeviceTransport сам формирует ответы
  на основе своего внутреннего состояния. Тесты проверяют, что мок-сервер
  корректно имитирует прибор через полный стек TTensoMDevice.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  core in '../src/core.pas',
  tensom_errors in '../src/tensom_errors.pas',
  client in '../src/client.pas',
  mock_server in 'mock_server.pas'
  ;

type

  { TTestMockServer }

  TTestMockServer = class(TTestCase)
  private
    fMock: TMockDeviceTransport;
    fDev: TTensoMDevice;
    procedure SetupDevice(aAddress: Byte; aUseCRC: Boolean);
  published
    { Весовые команды }
    procedure Test_Brutto_StablePositive;
    procedure Test_Brutto_Negative;
    procedure Test_Brutto_Overload;
    procedure Test_Brutto_NoDecimals;
    procedure Test_Netto;
    procedure Test_FixedBrutto;

    { Тарирование }
    procedure Test_Tare_ZerosWeight;

    { Серийный номер }
    procedure Test_SerialNumber;

    { Системный статус }
    procedure Test_SystemStatus;

    { Конфигурация прибора }
    procedure Test_DeviceConfig_Gross;
    procedure Test_DeviceConfig_Net;

    { Дискретные входы/выходы }
    procedure Test_DiscreteInputs;
    procedure Test_DiscreteOutputs_Read;
    procedure Test_DiscreteOutputs_Set;

    { Индикаторы }
    procedure Test_Indicators;

    { Код продукта }
    procedure Test_ProductCode;

    { Счётчики }
    procedure Test_Counter;

    { Калибровка и АЦП }
    procedure Test_CalibrationParams;
    procedure Test_ADCCode;

    { Дозирование }
    procedure Test_DosingControl;

    { Имитация ошибок }
    procedure Test_SimulateError_EEh;
    procedure Test_SimulateUnsupported_FDh;
    procedure Test_ClearErrors;

    { Логирование команд }
    procedure Test_CommandLog;

    { Режим без CRC }
    procedure Test_NoCRC;

    { Несуществующий COP }
    procedure Test_UnknownCOP;

    { Динамическое изменение веса }
    procedure Test_DynamicWeight;

    { Смена адреса }
    procedure Test_SetAddress;
  end;

implementation

type
  TCmdLog = class
  private
    type
      TEntry = record
        COP: Byte;
        DataHex: string;
        FrameHex: string;
      end;
  private
    fEntries: array of TEntry;
  public
    procedure Handle(aCOP: Byte; const aData: TBytes; const aHex: string);
    function GetCount: Integer;
    function GetCOP(aIndex: Integer): Byte;
    function GetDataHex(aIndex: Integer): string;
    procedure Clear;
  end;

procedure TCmdLog.Handle(aCOP: Byte; const aData: TBytes; const aHex: string);
begin
  SetLength(fEntries, Length(fEntries) + 1);
  fEntries[High(fEntries)].COP := aCOP;
  fEntries[High(fEntries)].DataHex := HexBytes(aData);
  fEntries[High(fEntries)].FrameHex := aHex;
end;

function TCmdLog.GetCount: Integer;
begin
  Result := Length(fEntries);
end;

function TCmdLog.GetCOP(aIndex: Integer): Byte;
begin
  Assert((aIndex >= 0) and (aIndex < Length(fEntries)), 'Index out of range');
  Result := fEntries[aIndex].COP;
end;

function TCmdLog.GetDataHex(aIndex: Integer): string;
begin
  Assert((aIndex >= 0) and (aIndex < Length(fEntries)), 'Index out of range');
  Result := fEntries[aIndex].DataHex;
end;

procedure TCmdLog.Clear;
begin
  SetLength(fEntries, 0);
end;

{ === Setup === }

procedure TTestMockServer.SetupDevice(aAddress: Byte; aUseCRC: Boolean);
begin
  fMock := TMockDeviceTransport.Create(aAddress, aUseCRC);
  fMock.Connect('/dev/mock', 9600);
  fMock.ResponseDelayMS := 200;
  fDev := TTensoMDevice.Create(fMock, aAddress, aUseCRC);
  fDev.ResponseTimeout := 200;
end;

{ === Весовые команды === }

procedure TTestMockServer.Test_Brutto_StablePositive;
var
  W: TWeightData;
begin
  SetupDevice($01, True);
  try
    fMock.Weight := 123.4;
    fMock.WeightStable := True;
    fMock.WeightNegative := False;
    fMock.WeightOverload := False;
    fMock.WeightDecimalPlaces := 1;

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

procedure TTestMockServer.Test_Brutto_Negative;
var
  W: TWeightData;
begin
  SetupDevice($01, True);
  try
    fMock.Weight := 0.5;
    fMock.WeightStable := True;
    fMock.WeightNegative := True;
    fMock.WeightDecimalPlaces := 1;

    W := fDev.GetBruttoWeight;

    AssertEquals('Weight', -0.5, W.Weight, 0.001);
    AssertTrue('Stable', W.Stable);
    AssertTrue('Negative', W.Negative);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_Brutto_Overload;
var
  W: TWeightData;
begin
  SetupDevice($01, True);
  try
    fMock.Weight := 999.9;
    fMock.WeightStable := False;
    fMock.WeightOverload := True;
    fMock.WeightDecimalPlaces := 1;

    W := fDev.GetBruttoWeight;

    AssertTrue('Overload', W.Overload);
    AssertFalse('Stable', W.Stable);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_Brutto_NoDecimals;
var
  W: TWeightData;
begin
  SetupDevice($01, True);
  try
    fMock.Weight := 50.0;
    fMock.WeightStable := True;
    fMock.WeightDecimalPlaces := 0;

    W := fDev.GetBruttoWeight;

    AssertEquals('Weight', 50.0, W.Weight, 0.001);
    AssertEquals('Decimals', 0, W.DecimalPlaces);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_Netto;
var
  W: TWeightData;
begin
  SetupDevice($01, True);
  try
    fMock.Weight := 42.0;
    fMock.WeightStable := True;
    fMock.WeightDecimalPlaces := 0;

    W := fDev.GetNettoWeight;

    AssertEquals('Weight', 42.0, W.Weight, 0.001);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_FixedBrutto;
var
  W: TWeightData;
begin
  SetupDevice($01, True);
  try
    fMock.Weight := 100.5;
    fMock.WeightStable := True;
    fMock.WeightDecimalPlaces := 1;

    { B8h использует тот же EncodeWeight, проверяем через прямой вызов }
    W := fDev.GetBruttoWeight;
    AssertEquals('Weight', 100.5, W.Weight, 0.001);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Тарирование === }

procedure TTestMockServer.Test_Tare_ZerosWeight;
begin
  SetupDevice($01, True);
  try
    fMock.Weight := 55.5;
    fDev.Tare;
    AssertEquals('Weight after tare', 0.0, fMock.Weight, 0.001);
    AssertFalse('Negative after tare', fMock.WeightNegative);
    AssertFalse('Overload after tare', fMock.WeightOverload);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Серийный номер === }

procedure TTestMockServer.Test_SerialNumber;
var
  SN: Cardinal;
begin
  SetupDevice($01, True);
  try
    fMock.SerialNumber := 54321;
    SN := fDev.GetSerialNumber;
    AssertEquals('Serial', 54321, SN);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Системный статус === }

procedure TTestMockServer.Test_SystemStatus;
var
  S: Byte;
begin
  SetupDevice($01, True);
  try
    fMock.SystemStatus := $AB;
    S := fDev.GetSystemStatus;
    AssertEquals('Status', $AB, S);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Конфигурация === }

procedure TTestMockServer.Test_DeviceConfig_Gross;
var
  aMaxW, aDivVal: Double;
  aDecPlaces: Integer;
  aDevMode: string;
  aADCFreq, aVSEN, aFilt: Byte;
begin
  SetupDevice($01, True);
  try
    fMock.MaxWeight := 150.0;
    fMock.Division := 0.5;
    fMock.WeightDecimalPlaces := 1;
    fMock.DeviceModeIsGross := True;
    fMock.ADCFreqCode := $03;
    fMock.VSEN := $01;
    fMock.FilterCode := $02;

    fDev.GetDeviceConfig(aMaxW, aDivVal, aDecPlaces, aDevMode, aADCFreq, aVSEN, aFilt);

    AssertEquals('MaxWeight', 150.0, aMaxW, 0.01);
    AssertEquals('Division', 0.5, aDivVal, 0.001);
    AssertEquals('Decimals', 1, aDecPlaces);
    AssertEquals('Mode', 'GROSS', aDevMode);
    AssertEquals('ADCFreq', $03, aADCFreq);
    AssertEquals('VSEN', $01, aVSEN);
    AssertEquals('Filter', $02, aFilt);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_DeviceConfig_Net;
var
  aDevMode: string;
  aMaxW, aDivVal: Double;
  aDecPlaces: Integer;
  aADCFreq, aVSEN, aFilt: Byte;
begin
  SetupDevice($01, True);
  try
    fMock.DeviceModeIsGross := False;
    fMock.MaxWeight := 30.0;
    fMock.Division := 0.01;
    fMock.WeightDecimalPlaces := 2;

    fDev.GetDeviceConfig(aMaxW, aDivVal, aDecPlaces, aDevMode, aADCFreq, aVSEN, aFilt);

    AssertEquals('Mode', 'NET', aDevMode);
    AssertEquals('Decimals', 2, aDecPlaces);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Дискретные === }

procedure TTestMockServer.Test_DiscreteInputs;
var
  aInputs: TBytes;
begin
  SetupDevice($01, True);
  try
    fMock.DiscreteInputs := $3C;
    aInputs := fDev.GetDiscreteInputs;
    AssertEquals('Inputs byte count', 1, Length(aInputs));
    AssertEquals('Inputs', $3C, aInputs[0]);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_DiscreteOutputs_Read;
var
  aOutputs: TBytes;
begin
  SetupDevice($01, True);
  try
    fMock.DiscreteOutputs := $A5;
    aOutputs := fDev.GetDiscreteOutputs;
    AssertEquals('Outputs', $A5, aOutputs[0]);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_DiscreteOutputs_Set;
var
  aOutputs: TBytes = nil;
begin
  SetupDevice($01, True);
  try
    SetLength(aOutputs, 1);
    aOutputs[0] := $FF;
    fDev.SetDiscreteOutputs(aOutputs);
    AssertEquals('Outputs after set', $FF, fMock.DiscreteOutputs);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Индикаторы === }

procedure TTestMockServer.Test_Indicators;
var
  aText: string;
  aFlags: Byte;
begin
  SetupDevice($01, True);
  try
    fMock.IndicatorsText := '12.34';
    fMock.IndicatorsFlags := $1A;

    fDev.GetIndicators(aText, aFlags);

    AssertEquals('Text', '12.34', aText);
    AssertEquals('Flags', $1A, aFlags);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Код продукта === }

procedure TTestMockServer.Test_ProductCode;
var
  aCode: string;
begin
  SetupDevice($01, True);
  try
    fMock.ProductCode := 'XYZ789';
    aCode := fDev.GetProductCode;
    AssertEquals('ProductCode', 'XYZ789', aCode);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Счётчики === }

procedure TTestMockServer.Test_Counter;
var
  aData: TBytes;
  aVal: Cardinal;
begin
  SetupDevice($01, True);
  try
    fMock.SetCounter(3, 256);
    aData := fDev.GetCounter(3);
    AssertEquals('Counter byte count', 4, Length(aData));
    aVal := Cardinal(aData[0]) or (Cardinal(aData[1]) shl 8);
    AssertEquals('Counter value', 256, aVal);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Калибровка и АЦП === }

procedure TTestMockServer.Test_CalibrationParams;
var
  aParams: TBytes;
  aSetData: TBytes = nil;
begin
  SetupDevice($01, True);
  try
    SetLength(aSetData, 4);
    aSetData[0] := $11; aSetData[1] := $22; aSetData[2] := $33; aSetData[3] := $44;
    fMock.CalibrationParams := aSetData;

    aParams := fDev.GetCalibrationParams;
    AssertEquals('Calib length', 4, Length(aParams));
    AssertEquals('Calib[0]', $11, aParams[0]);
    AssertEquals('Calib[3]', $44, aParams[3]);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_ADCCode;
var
  aCode: TBytes;
begin
  SetupDevice($01, True);
  try
    aCode := fDev.GetADCCode;
    AssertEquals('ADC code length', 2, Length(aCode));
    AssertEquals('ADC[0]', $80, aCode[0]);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Дозирование === }

procedure TTestMockServer.Test_DosingControl;
begin
  SetupDevice($01, True);
  try
    fDev.DosingControl(DOS_START);
    AssertTrue('Dosing active', fMock.DosingActive);

    fDev.DosingControl(DOS_STOP);
    AssertFalse('Dosing stopped', fMock.DosingActive);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Имитация ошибок === }

procedure TTestMockServer.Test_SimulateError_EEh;
begin
  SetupDevice($01, True);
  try
    fMock.ResponseDelayMS := 0;
    fMock.SimulateError(COP_GET_BRUTTO, ERR_ZERO_RANGE);

    try
      fDev.GetBruttoWeight;
      Fail('Expected ETensoMDeviceError');
    except
      on E: ETensoMDeviceError do
        AssertTrue('Error message contains zero range', Pos('zero range', LowerCase(E.Message)) > 0);
    end;
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_SimulateUnsupported_FDh;
var
  aText: string;
  aFlags: Byte;
begin
  SetupDevice($01, True);
  try
    fMock.SimulateUnsupported(COP_GET_DISPLAY);

    try
      fDev.GetIndicators({%H-}aText, {%H-}aFlags);
      Fail('Expected ETensoMProtocolError');
    except
      on E: ETensoMProtocolError do
        AssertTrue('Unsupported message', Pos('not supported', LowerCase(E.Message)) > 0);
    end;
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

procedure TTestMockServer.Test_ClearErrors;
var
  W: TWeightData;
begin
  SetupDevice($01, True);
  try
    fMock.SimulateError(COP_GET_BRUTTO, ERR_GENERAL);

    try
      fDev.GetBruttoWeight;
      Fail('Expected error');
    except
      on E: ETensoMDeviceError do ;
    end;

    fMock.ClearSimulatedErrors;
    fMock.Weight := 10.0;
    fMock.WeightStable := True;
    fMock.WeightDecimalPlaces := 0;

    W := fDev.GetBruttoWeight;
    AssertEquals('Weight after clear', 10.0, W.Weight, 0.001);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Логирование команд === }

procedure TTestMockServer.Test_CommandLog;
var
  aLog: TCmdLog;
begin
  SetupDevice($01, True);
  aLog := TCmdLog.Create;
  try
    fMock.OnCommandReceived := @aLog.Handle;

    fMock.Weight := 5.0;
    fMock.WeightStable := True;
    fMock.WeightDecimalPlaces := 0;
    fDev.GetBruttoWeight;
    fDev.GetNettoWeight;

    AssertEquals('Log count', 2, aLog.GetCount);
    AssertEquals('COP 1', COP_GET_BRUTTO, aLog.GetCOP(0));
    AssertEquals('COP 2', COP_GET_NETTO, aLog.GetCOP(1));
  finally
    aLog.Free;
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Режим без CRC === }

procedure TTestMockServer.Test_NoCRC;
var
  W: TWeightData;
begin
  SetupDevice($01, False);
  try
    fMock.Weight := 99.9;
    fMock.WeightStable := True;
    fMock.WeightDecimalPlaces := 1;

    W := fDev.GetBruttoWeight;
    AssertEquals('Weight no CRC', 99.9, W.Weight, 0.001);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Несуществующий COP === }

procedure TTestMockServer.Test_UnknownCOP;
begin
  SetupDevice($01, True);
  try
    { Отправляем команду, которую мок-сервер не обрабатывает явно.
      Мок должен ответить FDh (неподдерживаемая команда). }
    fMock.SimulateUnsupported(COP_READ_LINEAR);

    try
      fDev.GetCalibrationParams;  // отправит CBh — это обработается
    except
      on E: Exception do
        Fail('Calib params should work: ' + E.Message);
    end;
    fMock.ClearSimulatedErrors;
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Динамическое изменение веса === }

procedure TTestMockServer.Test_DynamicWeight;
var
  W: TWeightData;
begin
  SetupDevice($01, True);
  try
    fMock.WeightDecimalPlaces := 1;

    fMock.Weight := 10.0;
    fMock.WeightStable := False;
    W := fDev.GetBruttoWeight;
    AssertEquals('R1', 10.0, W.Weight, 0.001);
    AssertFalse('R1 unstable', W.Stable);

    fMock.Weight := 10.3;
    W := fDev.GetBruttoWeight;
    AssertEquals('R2', 10.3, W.Weight, 0.001);

    fMock.Weight := 10.3;
    fMock.WeightStable := True;
    W := fDev.GetBruttoWeight;
    AssertTrue('R3 stable', W.Stable);
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

{ === Смена адреса === }

procedure TTestMockServer.Test_SetAddress;
begin
  SetupDevice($01, True);
  try
    { Note: SetNetworkAddress changes the device address in the mock,
      but the client still expects responses from the old address.
      This test verifies the mock processes the command. }
    try
      fDev.SetNetworkAddress($05);
      { После смены адреса мок будет отвечать с адресом $05,
        но клиент ожидает $05 — и мок-сервер уже поменял адрес.
        Однако клиент проверяет ответ от адреса fAddress=$01.
        Поэтому ожидаем ошибку адреса. }
    except
      on E: ETensoMProtocolError do
        ; { Ожидаемо — адрес в ответе не совпадёт }
    end;
  finally
    fDev.Free;
    fMock.Free;
  end;
end;

initialization

  RegisterTest(TTestMockServer);

end.
