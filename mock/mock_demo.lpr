{
  TensoMLib — демонстрация мок-сервера прибора Тензо-М.

  Программа показывает, как использовать TMockDeviceTransport для тестирования
  клиента TTensoMDevice без реального оборудования.

  Сборка:
    fpc -MObjFPC -Sh -FU../src -FU. mock_demo.lpr

  Запуск:
    ./mock_demo
}

program mock_demo;

{$mode objfpc}{$H+}

uses
  SysUtils,
  core in '../src/core.pas',
  errors in '../src/errors.pas',
  client in '../src/client.pas',
  mock_server in 'mock_server.pas';

type
  { Логгер входящих команд }
  TCommandLogger = class
  public
    procedure HandleCommand(aCOP: Byte; const aData: TBytes; const aHex: string);
  end;

procedure TCommandLogger.HandleCommand(aCOP: Byte; const aData: TBytes;
  const aHex: string);
begin
  WriteLn(Format('  [MOCK] Received COP=%02Xh  Data=[%s]  Frame=%s',
    [aCOP, HexBytes(aData), aHex]));
end;

var
  Mock: TMockDeviceTransport;
  Dev: TTensoMDevice;
  Logger: TCommandLogger;
  W: TWeightData;
  SN: Cardinal;
  Status: Byte;
  MaxW, DivVal: Double;
  DecPlaces: Integer;
  DevMode: string;
  ADCFreq, VSEN, Filt: Byte;
  aInputs, aOutputs: TBytes;
  aText: string;
  aFlags: Byte;
  aProduct: string;
  aCounter: TBytes;

begin
  WriteLn('=== TensoMLib Mock Server Demo ===');
  WriteLn;

  { Создаём мок-прибор с адресом $01, CRC включён }
  Mock := TMockDeviceTransport.Create($01, True);
  Logger := TCommandLogger.Create;
  try
    { Настраиваем состояние прибора }
    WriteLn('--- Set the mock device ---');
    Mock.Weight := 123.4;
    Mock.WeightStable := True;
    Mock.WeightDecimalPlaces := 1;
    Mock.SerialNumber := 12345;
    Mock.SystemStatus := $03;
    Mock.DiscreteInputs := $0F;
    Mock.DiscreteOutputs := $A5;
    Mock.IndicatorsText := '123.4';
    Mock.IndicatorsFlags := $10;
    Mock.ProductCode := 'ABC123';
    Mock.MaxWeight := 150.0;
    Mock.Division := 0.05;
    Mock.DeviceModeIsGross := True;
    Mock.SetCounter(0, 42);
    Mock.SetCounter(5, 1000);
    WriteLn('  Weight=123.4  Stable  Serial=12345  Status=$03');
    WriteLn('  Inputs=$0F  Outputs=$A5  ProductCode=ABC123');
    WriteLn('  Counter[0]=42  Counter[5]=1000');
    WriteLn;

    { Подключаем логирование команд }
    Mock.OnCommandReceived := @Logger.HandleCommand;

    { Создаём клиент, работающий через мок-транспорт }
    Mock.Connect('/dev/mock', 9600);
    Dev := TTensoMDevice.Create(Mock, $01, True);
    Dev.ResponseTimeout := 500;
    try

      { === Тест: запрос веса брутто === }
      WriteLn('--- GetBruttoWeight ---');
      W := Dev.GetBruttoWeight;
      WriteLn(Format('  Weight: %.1f kg  Stable=%s  Overload=%s  Negative=%s  Dec=%d',
        [W.Weight,
         BoolToStr(W.Stable, 'Yes', 'No'),
         BoolToStr(W.Overload, 'Yes', 'No'),
         BoolToStr(W.Negative, 'Yes', 'No'),
         W.DecimalPlaces]));
      WriteLn(Format('  Request:  %s', [Dev.LastRequestHex]));
      WriteLn(Format('  Response: %s', [Dev.LastResponseHex]));
      WriteLn;

      { === Тест: запрос веса нетто === }
      WriteLn('--- GetNettoWeight ---');
      W := Dev.GetNettoWeight;
      WriteLn(Format('  Netto Weight: %.1f kg', [W.Weight]));
      WriteLn;

      { === Тест: тарирование === }
      WriteLn('--- Tare ---');
      Dev.Tare;
      WriteLn(Format('  Weight after tare: %.1f kg', [Mock.Weight]));
      WriteLn;

      { === Тест: серийный номер === }
      WriteLn('--- GetSerialNumber ---');
      SN := Dev.GetSerialNumber;
      WriteLn(Format('  Serial Number: %d', [SN]));
      WriteLn;

      { === Тест: системный статус === }
      WriteLn('--- GetSystemStatus ---');
      Status := Dev.GetSystemStatus;
      WriteLn(Format('  System Status: %02Xh', [Status]));
      WriteLn;

      { === Тест: конфигурация прибора === }
      WriteLn('--- GetDeviceConfig ---');
      Dev.GetDeviceConfig(MaxW, DivVal, DecPlaces, DevMode, ADCFreq, VSEN, Filt);
      WriteLn(Format('  MaxWeight=%.1f  Division=%.2f  Decimals=%d  Mode=%s',
        [MaxW, DivVal, DecPlaces, DevMode]));
      WriteLn(Format('  ADCFreq=%02Xh  VSEN=%02Xh  Filter=%02Xh',
        [ADCFreq, VSEN, Filt]));
      WriteLn;

      { === Тест: дискретные входы/выходы === }
      WriteLn('--- Discrete I/O ---');
      aInputs := Dev.GetDiscreteInputs;
      aOutputs := Dev.GetDiscreteOutputs;
      WriteLn(Format('  Inputs:  %02Xh  Outputs: %02Xh', [aInputs[0], aOutputs[0]]));
      WriteLn('  Setting outputs to $FF...');
      SetLength(aOutputs, 1);
      aOutputs[0] := $FF;
      Dev.SetDiscreteOutputs(aOutputs);
      aOutputs := Dev.GetDiscreteOutputs;
      WriteLn(Format('  Outputs after set: %02Xh', [aOutputs[0]]));
      WriteLn;

      { === Тест: индикаторы === }
      WriteLn('--- GetIndicators ---');
      Dev.GetIndicators(aText, aFlags);
      WriteLn(Format('  Display: "%s"  Flags: %02Xh', [aText, aFlags]));
      WriteLn;

      { === Тест: код продукта === }
      WriteLn('--- GetProductCode ---');
      aProduct := Dev.GetProductCode;
      WriteLn(Format('  Product Code: "%s"', [aProduct]));
      WriteLn;

      { === Тест: счётчики === }
      WriteLn('--- GetCounter ---');
      aCounter := Dev.GetCounter(0);
      WriteLn(Format('  Counter[0] = %d', [Cardinal(aCounter[0]) or (Cardinal(aCounter[1]) shl 8)
        or (Cardinal(aCounter[2]) shl 16) or (Cardinal(aCounter[3]) shl 24)]));
      aCounter := Dev.GetCounter(5);
      WriteLn(Format('  Counter[5] = %d', [Cardinal(aCounter[0]) or (Cardinal(aCounter[1]) shl 8)
        or (Cardinal(aCounter[2]) shl 16) or (Cardinal(aCounter[3]) shl 24)]));
      WriteLn;

      { === Тест: дозирование === }
      WriteLn('--- DosingControl ---');
      Dev.DosingControl(DOS_START);
      WriteLn('  Dosing started');
      Dev.DosingControl(DOS_STOP);
      WriteLn('  Dosing stopped');
      WriteLn;

      { === Тест: установка фильтра === }
      WriteLn('--- SetFilter ---');
      Dev.SetFilter($05);
      WriteLn('  Filter set to $05');
      WriteLn;

      { === Демонстрация имитации ошибки === }
      WriteLn('--- Simulate Error ---');
      Mock.Weight := 50.0;
      Mock.WeightStable := True;
      Mock.SimulateError(COP_GET_BRUTTO, ERR_GENERAL);
      try
        W := Dev.GetBruttoWeight;
      except
        on E: ETensoMDeviceError do
          WriteLn(Format('  Expected error caught: %s', [E.Message]));
      end;
      Mock.ClearSimulatedErrors;

      { После очистки ошибок — нормальный ответ }
      W := Dev.GetBruttoWeight;
      WriteLn(Format('  After clear errors: Weight=%.1f kg', [W.Weight]));
      WriteLn;

      { === Демонстрация неподдерживаемой команды === }
      WriteLn('--- Simulate Unsupported ---');
      Mock.SimulateUnsupported(COP_GET_DISPLAY);
      try
        Dev.GetIndicators(aText, aFlags);
      except
        on E: ETensoMProtocolError do
          WriteLn(Format('  Expected unsupported: %s', [E.Message]));
      end;
      Mock.ClearSimulatedErrors;
      WriteLn;

      { === Тест: изменение веса (динамическое поведение) === }
      WriteLn('--- Dynamic Weight Changes ---');
      Mock.Weight := 10.0;
      Mock.WeightStable := False;
      W := Dev.GetBruttoWeight;
      WriteLn(Format('  Reading 1: %.1f kg  Stable=%s', [W.Weight,
        BoolToStr(W.Stable, 'Yes', 'No')]));

      Mock.Weight := 10.2;
      W := Dev.GetBruttoWeight;
      WriteLn(Format('  Reading 2: %.1f kg  Stable=%s', [W.Weight,
        BoolToStr(W.Stable, 'Yes', 'No')]));

      Mock.Weight := 10.3;
      Mock.WeightStable := True;
      W := Dev.GetBruttoWeight;
      WriteLn(Format('  Reading 3: %.1f kg  Stable=%s', [W.Weight,
        BoolToStr(W.Stable, 'Yes', 'No')]));
      WriteLn;

      WriteLn('=== All tests passed ===');

    finally
      Dev.Free;
      Mock.Disconnect;
    end;
  finally
    Logger.Free;
    Mock.Free;
  end;
end.
