program tensotest;

{
  Утилита удаленного тестирования TensoMLib.

  Использование:
    tensotest <порт> [адрес] [время ожидания]

  Примеры:
    tensotest COM3
    tensotest COM3 1 1000
    tensotest /dev/ttyUSB0 1

  Создает XML-отчет: tensotest_<порт>_<временная метка>.xml
  Создает лог кадров: tensotest_<порт>_<временная метка>.log
  Только безопасные команды только для чтения - не изменяет состояние устройства.

  Не гарантируется, что все тесты, помеченные как "необязательные", будут поддерживаться
  Устройства TensoM (например, TV-003/05H поддерживает только C0,C1,C2,C3,C8:06,CE).
  Неудачные дополнительные тесты записываются как пропущенные (без СБОЕВ) и не
  влияют на код завершения.
}

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, StrUtils, DateUtils, core, transport, transport_serial, client
  ;

const
  APP_VERSION = '1.4';
  DEFAULT_ADDRESS = 1;
  DEFAULT_TIMEOUT = 3000; { мс }
  WEIGHT_READINGS = 5;
  COUNTER_MIN = 0;
  COUNTER_MAX = 9;

type

  { TFrameLogger }

  TFrameLogger = class
  private
    procedure HandleFrameLog(aDirection: TFrameDirection; const aFrameHex: string);
  end;

var
  F: TextFile;
  FLog: TextFile;
  Dev: TTensoMDevice;
  Trans: TSerialTransport;
  TestPort: string;
  TestAddr: Byte;
  TestTimeout: Cardinal;
  ReportFilename: string;
  LogFilename: string;
  TotalTests: Integer = 0;
  PassCount: Integer = 0;
  FailCount: Integer = 0;
  SkipCount: Integer = 0;
  StartTime: TDateTime;
  FrameLogger: TFrameLogger;

{ --- Helpers --- }

procedure XmlWrite(const S: string);
begin
  WriteLn(F, S);
end;

procedure XmlEscapedWrite(const aTag, aValue: string);
var
  V: string;
begin
  V := aValue;
  V := StringReplace(V, '&', '&amp;', [rfReplaceAll]);
  V := StringReplace(V, '<', '&lt;', [rfReplaceAll]);
  V := StringReplace(V, '>', '&gt;', [rfReplaceAll]);
  V := StringReplace(V, '"', '&quot;', [rfReplaceAll]);
  XmlWrite('      <' + aTag + '>' + V + '</' + aTag + '>');
end;

procedure WriteProgress(const aMsg: string);
begin
  WriteLn(aMsg);
end;

function MsElapsed: Int64;
begin
  Result := MilliSecondsBetween(Now, StartTime);
end;

{ === Логирование кадров === }

procedure TFrameLogger.HandleFrameLog(aDirection: TFrameDirection; const aFrameHex: string);
var
  aDirStr: string;
begin
  if aDirection = fdSend then
    aDirStr := '>>'
  else
    aDirStr := '<<';
  WriteLn(FLog, Format('[%8d ms] %s %s', [MsElapsed, aDirStr, aFrameHex]));
end;

{ Возвращает суффикс с ошибкой транспорта, если она есть }
function TransportErrSuffix: string;
var
  aErr: string;
begin
  aErr := Trans.GetLastErrorMessage;
  if aErr <> '' then
    Result := ' [transport: ' + aErr + ']'
  else
    Result := '';
end;

{ Record a single test result. aOptional: if True, failures are recorded as SKIP }
procedure RecordTest(const aName, aCOP: string; aPass: Boolean;
  const aValue, aError, aReqHex, aRespHex: string;
  const aExtraXml: string = ''; aOptional: Boolean = False);
var
  aStatus: string;
  aOptAttr: string;
begin
  Inc(TotalTests);

  aOptAttr := '';
  if aOptional then
    aOptAttr := ' optional="true"';

  if aPass then
  begin
    Inc(PassCount);
    aStatus := 'PASS';
  end
  else if aOptional then
  begin
    Inc(SkipCount);
    aStatus := 'SKIP';
  end
  else
  begin
    Inc(FailCount);
    aStatus := 'FAIL';
  end;

  XmlWrite('    <test name="' + aName + '" cop="' + aCOP + '" status="' +
    aStatus + '"' + aOptAttr + ' ms="' + IntToStr(MsElapsed) + '">');
  if aValue <> '' then
    XmlEscapedWrite('value', aValue);
  if aError <> '' then
    XmlEscapedWrite('error', aError);
  if aReqHex <> '' then
    XmlEscapedWrite('request_hex', aReqHex);
  if aRespHex <> '' then
    XmlEscapedWrite('response_hex', aRespHex);
  if aExtraXml <> '' then
    XmlWrite(aExtraXml);
  XmlWrite('    </test>');

  if aStatus = 'PASS' then
    WriteProgress('  [PASS] ' + aName)
  else if aStatus = 'SKIP' then
    WriteProgress('  [SKIP] ' + aName + ': ' + aError)
  else
    WriteProgress('  [FAIL] ' + aName + ': ' + aError);
end;


{ --- Test routines --- }

procedure TestAutoDetectCRC;
var
  aUseCRC: Boolean;
  aErrMsg: string;
  aReqHex, aRespHex: string;
begin
  aErrMsg := '';
  aReqHex := '';
  aRespHex := '';
  aUseCRC := Dev.UseCRC;
  try
    Dev.AutoDetectCRC;
    aReqHex := Dev.LastRequestHex;
    aRespHex := Dev.LastResponseHex;
    RecordTest('Auto-detect CRC', 'C3h (probe)', True,
      IfThen(Dev.UseCRC, 'CRC enabled', 'CRC disabled'), '', aReqHex, aRespHex);
  except
    on E: Exception do
    begin
      aErrMsg := E.Message + TransportErrSuffix;
      aReqHex := Dev.LastRequestHex;
      aRespHex := Dev.LastResponseHex;
      RecordTest('Auto-detect CRC', 'C3h (probe)', False, '', aErrMsg, aReqHex, aRespHex);
      { Restore original CRC setting after failure }
      Dev.UseCRC := aUseCRC;
    end;
  end;
end;

procedure TestGetSerialNumber;
var
  aSN: Cardinal;
begin
  try
    aSN := Dev.GetSerialNumber;
    RecordTest('Serial number', 'A1h', True, IntToStr(aSN), '',
      Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  except
    on E: Exception do
      RecordTest('Serial number', 'A1h', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  end;
end;

procedure TestGetDeviceConfig;
var
  aMaxW, aDiv_: Double;
  aDecimals: Integer;
  aMode: string;
  aADCFreq, aFilt, aVSEN: Byte;
  aExtra: string;
begin
  aExtra := '';
  try
    Dev.GetDeviceConfig(aMaxW, aDiv_, aDecimals, aMode, aADCFreq, aVSEN, aFilt);
    aExtra := '      <config>' + sLineBreak +
      '        <max_weight>' + FloatToStr(aMaxW) + '</max_weight>' + sLineBreak +
      '        <division>' + FloatToStr(aDiv_) + '</division>' + sLineBreak +
      '        <decimal_places>' + IntToStr(aDecimals) + '</decimal_places>' + sLineBreak +
      '        <mode>' + aMode + '</mode>' + sLineBreak +
      '        <adc_freq_code>' + IntToStr(aADCFreq) + '</adc_freq_code>' + sLineBreak +
      '        <vsen_code>' + IntToStr(aVSEN) + '</vsen_code>' + sLineBreak +
      '        <filter_code>' + IntToStr(aFilt) + '</filter_code>' + sLineBreak +
      '      </config>';
    RecordTest('Device configuration', 'C1h', True,
      Format('max=%.2f div=%.2f dec=%d mode=%s', [aMaxW, aDiv_, aDecimals, aMode]),
      '', Dev.LastRequestHex, Dev.LastResponseHex, aExtra);
  except
    on E: Exception do
      RecordTest('Device configuration', 'C1h', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex);
  end;
end;

procedure TestGetBruttoWeight;
var
  W: TWeightData;
  S: string;
begin
  try
    W := Dev.GetBruttoWeight;
    S := Format('%.*f kg', [W.DecimalPlaces, W.Weight]);
    if W.Stable then S := S + ' STABLE';
    if W.Negative then S := S + ' NEGATIVE';
    if W.Overload then S := S + ' OVERLOAD';
    RecordTest('GROSS weight', 'C3h', True, S, '',
      Dev.LastRequestHex, Dev.LastResponseHex);
  except
    on E: Exception do
      RecordTest('GROSS weight', 'C3h', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex);
  end;
end;

procedure TestGetNettoWeight;
var
  W: TWeightData;
  S: string;
begin
  try
    W := Dev.GetNettoWeight;
    S := Format('%.*f kg', [W.DecimalPlaces, W.Weight]);
    if W.Stable then S := S + ' STABLE';
    if W.Negative then S := S + ' NEGATIVE';
    if W.Overload then S := S + ' OVERLOAD';
    RecordTest('NET weight', 'C2h', True, S, '',
      Dev.LastRequestHex, Dev.LastResponseHex);
  except
    on E: Exception do
      RecordTest('NET weight', 'C2h', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex);
  end;
end;

procedure TestGetSystemStatus;
var
  aStatusByte: Byte;
  aExtra: string;
begin
  try
    aStatusByte := Dev.GetSystemStatus;
    aExtra := '      <status_byte value="' + IntToStr(aStatusByte) + '">' + sLineBreak +
      '        <bit7_command_accepted>' + IfThen((aStatusByte and $80) <> 0, '1', '0') + '</bit7_command_accepted>' + sLineBreak +
      '        <bit6>' + IfThen((aStatusByte and $40) <> 0, '1', '0') + '</bit6>' + sLineBreak +
      '        <bit5_weight_stable>' + IfThen((aStatusByte and $20) <> 0, '1', '0') + '</bit5_weight_stable>' + sLineBreak +
      '        <bit4_overload>' + IfThen((aStatusByte and $10) <> 0, '1', '0') + '</bit4_overload>' + sLineBreak +
      '        <bit3_battery_low>' + IfThen((aStatusByte and $08) <> 0, '1', '0') + '</bit3_battery_low>' + sLineBreak +
      '        <bit2_zero_in_range>' + IfThen((aStatusByte and $04) <> 0, '1', '0') + '</bit2_zero_in_range>' + sLineBreak +
      '        <bit1_tare_active>' + IfThen((aStatusByte and $02) <> 0, '1', '0') + '</bit1_tare_active>' + sLineBreak +
      '        <bit0_motion>' + IfThen((aStatusByte and $01) <> 0, '1', '0') + '</bit0_motion>' + sLineBreak +
      '      </status_byte>';
    RecordTest('System status', 'BFh', True,
      Format('$%02X', [aStatusByte]), '',
      Dev.LastRequestHex, Dev.LastResponseHex, aExtra, True);
  except
    on E: Exception do
      RecordTest('System status', 'BFh', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  end;
end;

procedure TestGetDiscreteInputs;
var
  aData: TBytes;
  I: Integer;
  S: string;
begin
  try
    aData := Dev.GetDiscreteInputs;
    S := '';
    for I := 0 to High(aData) do
    begin
      if I > 0 then S := S + ' ';
      S := S + IntToHex(aData[I], 2);
    end;
    RecordTest('Discrete inputs', 'C4h', True,
      Format('%d byte(s): %s', [Length(aData), S]), '',
      Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  except
    on E: Exception do
      RecordTest('Discrete inputs', 'C4h', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  end;
end;

procedure TestGetDiscreteOutputs;
var
  aData: TBytes;
  I: Integer;
  S: string;
begin
  try
    aData := Dev.GetDiscreteOutputs;
    S := '';
    for I := 0 to High(aData) do
    begin
      if I > 0 then S := S + ' ';
      S := S + IntToHex(aData[I], 2);
    end;
    RecordTest('Discrete outputs', 'C5h', True,
      Format('%d byte(s): %s', [Length(aData), S]), '',
      Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  except
    on E: Exception do
      RecordTest('Discrete outputs', 'C5h', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  end;
end;

procedure TestGetIndicators;
var
  aText_: string;
  aFlags: Byte;
  aExtra: string;
begin
  try
    Dev.GetIndicators(aText_, aFlags);
    aExtra := '      <indicators>' + sLineBreak +
      '        <text>' + StringReplace(StringReplace(aText_, '&', '&amp;', [rfReplaceAll]), '<', '&lt;', [rfReplaceAll]) + '</text>' + sLineBreak +
      '        <flags>$' + IntToHex(aFlags, 2) + '</flags>' + sLineBreak +
      '      </indicators>';
    RecordTest('Indicators', 'C6h', True,
      Format('text="%s" flags=$%02X', [aText_, aFlags]), '',
      Dev.LastRequestHex, Dev.LastResponseHex, aExtra, True);
  except
    on E: Exception do
      RecordTest('Indicators', 'C6h', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  end;
end;

procedure TestGetProductCode;
var
  aCode: string;
begin
  try
    aCode := Dev.GetProductCode;
    RecordTest('Product code', 'C7h', True, aCode, '',
      Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  except
    on E: Exception do
      RecordTest('Product code', 'C7h', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  end;
end;

procedure TestGetCounters;
var
  I: Integer;
  aData: TBytes;
  J: Integer;
  S: string;
  aIsOpt: Boolean;
begin
  { TV-003/05H supports only counter #6 (max measured load).
    All others are marked optional. }
  for I := COUNTER_MIN to COUNTER_MAX do
  begin
    aIsOpt := (I <> 6);
    try
      aData := Dev.GetCounter(Byte(I));
      S := '';
      for J := 0 to High(aData) do
      begin
        if J > 0 then S := S + ' ';
        S := S + IntToHex(aData[J], 2);
      end;
      RecordTest(Format('Counter #%d', [I]), 'C8h', True,
        Format('%d byte(s): %s', [Length(aData), S]), '',
        Dev.LastRequestHex, Dev.LastResponseHex, '', aIsOpt);
    except
      on E: Exception do
        RecordTest(Format('Counter #%d', [I]), 'C8h', False, '',
          E.Message + TransportErrSuffix,
          Dev.LastRequestHex, Dev.LastResponseHex, '', aIsOpt);
    end;
  end;
end;

procedure TestGetCalibrationParams;
var
  aData: TBytes;
  I: Integer;
  S: string;
begin
  try
    aData := Dev.GetCalibrationParams;
    S := '';
    for I := 0 to High(aData) do
    begin
      if I > 0 then S := S + ' ';
      S := S + IntToHex(aData[I], 2);
    end;
    RecordTest('Calibration parameters', 'CBh', True,
      Format('%d byte(s): %s', [Length(aData), S]), '',
      Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  except
    on E: Exception do
      RecordTest('Calibration parameters', 'CBh', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  end;
end;

procedure TestGetADCCode;
var
  aData: TBytes;
  I: Integer;
  S: string;
begin
  try
    aData := Dev.GetADCCode;
    S := '';
    for I := 0 to High(aData) do
    begin
      if I > 0 then S := S + ' ';
      S := S + IntToHex(aData[I], 2);
    end;
    RecordTest('ADC code', 'CCh', True,
      Format('%d byte(s): %s', [Length(aData), S]), '',
      Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  except
    on E: Exception do
      RecordTest('ADC code', 'CCh', False, '',
        E.Message + TransportErrSuffix,
        Dev.LastRequestHex, Dev.LastResponseHex, '', True);
  end;
end;

procedure TestMultipleWeightReadings;
var
  I: Integer;
  W: TWeightData;
  S: string;
  aExtra: string;
begin
  WriteProgress('  Multiple weight readings (' + IntToStr(WEIGHT_READINGS) + 'x):');
  XmlWrite('    <test_group name="Multiple GROSS weight readings" count="' +
    IntToStr(WEIGHT_READINGS) + '">');
  for I := 1 to WEIGHT_READINGS do
  begin
    try
      W := Dev.GetBruttoWeight;
      S := Format('%.*f', [W.DecimalPlaces, W.Weight]);
      aExtra := '      <reading index="' + IntToStr(I) + '"' +
        ' weight="' + S + '"' +
        ' stable="' + IfThen(W.Stable, 'true', 'false') + '"' +
        ' negative="' + IfThen(W.Negative, 'true', 'false') + '"' +
        ' overload="' + IfThen(W.Overload, 'true', 'false') + '"' +
        ' decimals="' + IntToStr(W.DecimalPlaces) + '"' +
        ' req="' + Dev.LastRequestHex + '"' +
        ' resp="' + Dev.LastResponseHex + '"' +
        ' />';
      XmlWrite(aExtra);
      Inc(TotalTests);
      Inc(PassCount);
      WriteProgress('    [' + IntToStr(I) + '] ' + S + ' kg' +
        IfThen(W.Stable, ' STABLE', '') +
        IfThen(W.Overload, ' OVERLOAD', ''));
    except
      on E: Exception do
      begin
        Inc(TotalTests);
        Inc(FailCount);
        XmlWrite('      <reading index="' + IntToStr(I) +
          '" error="' + StringReplace(
            StringReplace(E.Message + TransportErrSuffix,
              '&', '&amp;', [rfReplaceAll]),
              '<', '&lt;', [rfReplaceAll]) +
          '" req="' + Dev.LastRequestHex + '" resp="' + Dev.LastResponseHex + '" />');
        WriteProgress('    [' + IntToStr(I) + '] ERROR: ' + E.Message + TransportErrSuffix);
      end;
    end;
    Sleep(200);
  end;
  XmlWrite('    </test_group>');
end;

{ --- Main --- }

procedure PrintUsage;
begin
  WriteLn('TensoMLib Test Utility v' + APP_VERSION);
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  tensotest <port> [address] [timeout_ms]');
  WriteLn;
  WriteLn('Arguments:');
  WriteLn('  port        - COM port name (e.g. COM3, /dev/ttyUSB0)');
  WriteLn('  address     - device address 1..159 (default: 1)');
  WriteLn('  timeout_ms  - response timeout in ms (default: 1000)');
  WriteLn;
  WriteLn('Example:');
  {$IFDEF MSWINDOWS}
  WriteLn('  tensotest COM3 1 1000');
  {$ELSE}
  WriteLn('  tensotest /dev/ttyUSB0 1 1000');
  {$ENDIF}
  WriteLn;
  WriteLn('Output:');
  WriteLn('  tensotest_<port>_<timestamp>.xml  - test report');
  WriteLn('  tensotest_<port>_<timestamp>.log   - frame-level log');
  WriteLn;
  WriteLn('Legend:');
  WriteLn('  PASS - test passed');
  WriteLn('  FAIL - test failed (required command)');
  WriteLn('  SKIP - test skipped (optional command not supported by device)');
  Halt(1);
end;

procedure ParseArgs;
var
  i: Longint;
begin
  if ParamCount < 1 then
    PrintUsage;

  TestPort := ParamStr(1);

  TestAddr := DEFAULT_ADDRESS;
  if ParamCount >= 2 then
  begin
    if not TryStrToInt(ParamStr(2), i) or (i < 1) or (i > 159) then
    begin
      WriteLn('ERROR: Address must be 1..159');
      Halt(1);
    end;
    TestAddr:=i;
  end;

  TestTimeout := DEFAULT_TIMEOUT;
  if ParamCount >= 3 then
  begin
    if not TryStrToInt(ParamStr(3), Integer(TestTimeout)) then
    begin
      WriteLn('ERROR: Timeout must be a number');
      Halt(1);
    end;
  end;
end;

procedure WriteReportHeader;
var
  aPortSafe: string;
begin
  aPortSafe := StringReplace(TestPort, ' ', '_', [rfReplaceAll]);
  aPortSafe := StringReplace(aPortSafe, '\\', '_', [rfReplaceAll]);
  aPortSafe := StringReplace(aPortSafe, '/', '_', [rfReplaceAll]);
  aPortSafe := StringReplace(aPortSafe, ':', '_', [rfReplaceAll]);
  ReportFilename := Format('tensotest_%s_%s.xml',
    [aPortSafe, FormatDateTime('yyyymmdd_hhnnss', Now)]);
  LogFilename := Format('tensotest_%s_%s.log',
    [aPortSafe, FormatDateTime('yyyymmdd_hhnnss', Now)]);

  AssignFile(F, ReportFilename);
  Rewrite(F);

  AssignFile(FLog, LogFilename);
  Rewrite(FLog);

  XmlWrite('<?xml version="1.0" encoding="UTF-8"?>');
  XmlWrite('<tensotest_report version="' + APP_VERSION + '">');
  XmlWrite('  <environment>');
  XmlWrite('    <timestamp>' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '</timestamp>');
  XmlWrite('    <platform>' + {$I %FPCTARGETOS%} + ' ' + {$I %FPCTARGETCPU%} + '</platform>');
  XmlWrite('    <port>' + TestPort + '</port>');
  XmlWrite('    <address>' + IntToStr(TestAddr) + '</address>');
  XmlWrite('    <timeout_ms>' + IntToStr(TestTimeout) + '</timeout_ms>');
  XmlWrite('  </environment>');
  XmlWrite('  <tests>');

  WriteLn(FLog, '=== TensoMLib Frame Log v' + APP_VERSION + ' ===');
  WriteLn(FLog, Format('Port: %s  Address: $%s  Timeout: %d ms',
    [TestPort, IntToHex(TestAddr, 2), TestTimeout]));
  WriteLn(FLog, Format('Started: %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]));
  WriteLn(FLog, '---');
end;

procedure WriteReportFooter;
begin
  XmlWrite('  </tests>');
  XmlWrite('  <summary>');
  XmlWrite('    <total>' + IntToStr(TotalTests) + '</total>');
  XmlWrite('    <passed>' + IntToStr(PassCount) + '</passed>');
  XmlWrite('    <failed>' + IntToStr(FailCount) + '</failed>');
  XmlWrite('    <skipped>' + IntToStr(SkipCount) + '</skipped>');
  XmlWrite('    <elapsed_ms>' + IntToStr(MsElapsed) + '</elapsed_ms>');
  XmlWrite('  </summary>');
  XmlWrite('</tensotest_report>');
  CloseFile(F);

  WriteLn(FLog, '---');
  WriteLn(FLog, Format('Finished: %s  Total: %d  Passed: %d  Failed: %d  Skipped: %d  Elapsed: %d ms',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), TotalTests, PassCount, FailCount, SkipCount, MsElapsed]));
  CloseFile(FLog);
end;

begin
  FrameLogger:=TFrameLogger.Create;
  ParseArgs;

  WriteLn('=== TensoMLib Test Utility v' + APP_VERSION + ' ===');
  WriteLn('Port: ', TestPort, '  Address: $', IntToHex(TestAddr, 2),
    '  Timeout: ', TestTimeout, ' ms');
  WriteLn;

  StartTime := Now;
  WriteReportHeader;

  { --- Connect --- }
  WriteProgress('[1/12] Connecting...');
  Trans := TSerialTransport.Create;
  try
    if not Trans.Connect(TestPort, 9600) then
    begin
      RecordTest('Port open', '-', False, '', Trans.GetLastErrorMessage, '', '');
      WriteReportFooter;
      WriteLn;
      WriteLn('FATAL: Cannot open port. See ', ReportFilename);
      WriteLn('Frame log: ', LogFilename);
      Trans.Free;
      Halt(2);
    end;
    RecordTest('Port open', '-', True, 'Connected at 9600 baud', '', '', '');

    { --- Create device --- }
    Dev := TTensoMDevice.Create(Trans, TestAddr, True);
    Dev.ResponseTimeout := TestTimeout;
    Dev.OnFrameLog := @FrameLogger.HandleFrameLog;
    try
      { --- Run tests --- }

      WriteProgress('[2/12] Auto-detect CRC...');
      TestAutoDetectCRC;

      WriteProgress('[3/12] Serial number (opt)...');
      TestGetSerialNumber;

      WriteProgress('[4/12] Device configuration...');
      TestGetDeviceConfig;

      WriteProgress('[5/12] Single GROSS weight reading...');
      TestGetBruttoWeight;

      WriteProgress('[6/12] Single NET weight reading...');
      TestGetNettoWeight;

      WriteProgress('[7/12] System status (opt)...');
      TestGetSystemStatus;

      WriteProgress('[8/12] Discrete inputs / outputs (opt)...');
      TestGetDiscreteInputs;
      TestGetDiscreteOutputs;

      WriteProgress('[9/12] Indicators & product code (opt)...');
      TestGetIndicators;
      TestGetProductCode;

      WriteProgress('[10/12] Counters (#0..#9)...');
      TestGetCounters;

      WriteProgress('[11/12] Calibration & ADC (opt)...');
      TestGetCalibrationParams;
      TestGetADCCode;

      WriteProgress('[12/12] Multiple weight readings...');
      TestMultipleWeightReadings;

    finally;
      Dev.Free;
    end;

    Trans.Disconnect;
  finally
    Trans.Free;
  end;

  { --- Done --- }
  WriteReportFooter;

  WriteLn;
  WriteLn('=== Results ===');
  WriteLn(Format('  Total:   %d', [TotalTests]));
  WriteLn(Format('  Passed:  %d', [PassCount]));
  WriteLn(Format('  Failed:  %d', [FailCount]));
  WriteLn(Format('  Skipped: %d (optional, not supported by device)', [SkipCount]));
  WriteLn(Format('  Time:    %d ms', [MsElapsed]));
  WriteLn;
  WriteLn('Report saved: ' + ReportFilename);
  WriteLn('Frame log:    ' + LogFilename);
  WriteLn('Please send these files to the developer.');

  if FailCount > 0 then
    Halt(3);
  FrameLogger.Free;
end.
