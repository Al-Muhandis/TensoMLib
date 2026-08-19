program tenso_mock_server;

{
  Standalone mock-сервер прибора Тензо-М.

  Кроссплатформенный: работает через TBlockSerial (LazSerial),
  который уже является зависимостью TensoMLib.

  Использование:
    Требуется виртуальная пара портов (socat на Linux, com0com на Windows).

    Linux (socat):
      socat -d -d pty,raw,echo=0,link=/tmp/tenso_s1 pty,raw,echo=0,link=/tmp/tenso_s2 &
      tenso_mock_server -p /tmp/tenso_s1 -a 1 -w 123.4 -stable
      tensotest /tmp/tenso_s2 1

    Windows (com0com):
      tenso_mock_server -p COM10 -a 1 -w 123.4 -stable
      tensotest COM11 1

  Опции:
    -p <port>       Serial port (обязательный)
    -a <addr>       Адрес прибора $01..$9F (по умолчанию: 1)
    -baud <rate>    Скорость (по умолчанию: 9600)
    -crc            Использовать CRC (по умолчанию: автоопределение)
    -nocrc          Не использовать CRC
    -w <value>      Начальный вес (по умолчанию: 0.0)
    -decimals <n>   Знаков после запятой, 0..3 (по умолчанию: 1)
    -stable         Вес стабилен (по умолчанию)
    -unstable       Вес нестабилен
    -negative       Отрицательный вес
    -overload       Перегрузка
    -sn <number>    Серийный номер (по умолчанию: 12345)
    -maxw <value>   Максимальный вес (по умолчанию: 150.0)
    -div <value>    Цена деления (по умолчанию: 0.5)
    -mode <g|n>     Режим: g=GROSS, n=NET (по умолчанию: GROSS)
    -delay <ms>     Искусственная задержка ответа, мс (по умолчанию: 0)
    -status <hex>   Байт системного статуса (по умолчанию: $00)
    -err <COP>:<ERR>  Имитировать ошибку EEh на указанный COP
    -h, -?          Справка

  Автоопределение CRC:
    По умолчанию сервер пробует разобрать входящий кадр сначала с CRC,
    затем без. Если удалось — отвечает тем же режимом. После первого
    успешного разбора режим фиксируется.
}

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, StrUtils, Math,
  LazSynaSer, core, frames, mock_server
  {$IFDEF MSWINDOWS}, windows{$ENDIF}
  ;

const
  APP_VERSION = '1.3';
  READ_BUF_SIZE = 256;
  RECV_TIMEOUT_MS = 100;

{$IFDEF MSWINDOWS}
{ WinAPI: COMMTIMEOUTS для корректной работы RecvBuffer
  с виртуальными портами (com0com). SynSer может сбрасывать
  или игнорировать таймауты чтения.
  См. аналогичный код в transport_serial.pas (ConfigureDCBDirect). }

type
  TCommTimeoutsRec = packed record
    ReadIntervalTimeout: DWORD;
    ReadTotalTimeoutMultiplier: DWORD;
    ReadTotalTimeoutConstant: DWORD;
    WriteTotalTimeoutMultiplier: DWORD;
    WriteTotalTimeoutConstant: DWORD;
  end;

function WinSetCommTimeouts(h: THandle; var aTimeouts: TCommTimeoutsRec): BOOL; stdcall;
  external 'kernel32.dll' name 'SetCommTimeouts';

procedure ApplyReadTimeout(aHandle: THandle; aTimeoutMS: Cardinal);
var
  aTimeouts: TCommTimeoutsRec;
begin
  aTimeouts.ReadIntervalTimeout        := DWORD($FFFFFFFF);
  aTimeouts.ReadTotalTimeoutMultiplier := 0;
  aTimeouts.ReadTotalTimeoutConstant   := aTimeoutMS;
  aTimeouts.WriteTotalTimeoutMultiplier := 0;
  aTimeouts.WriteTotalTimeoutConstant  := 5000;
  WinSetCommTimeouts(aHandle, aTimeouts);
end;
{$ENDIF}

var
  Mock: TMockDeviceTransport;
  Serial: TBlockSerial;
  PortName: string;
  Running: Boolean;
  CRCForced: Boolean;
  CRCDetected: Boolean;
  FrameCount: Integer;
  ByteCount: Integer;

{ === Ввод/вывод через TBlockSerial === }

procedure IOWrite(const aBuf: TBytes);
begin
  if Length(aBuf) = 0 then
    Exit;
  Serial.SendBuffer(@aBuf[0], Length(aBuf));
end;

function IORead(out aBuf: TBytes; out aReadCount: Integer): Boolean;
var
  aRawBuf: array[0..READ_BUF_SIZE - 1] of Byte;
begin
  aBuf := nil;
  aReadCount := 0;
  Result := False;

  Serial.DeadlockTimeout := RECV_TIMEOUT_MS;
  {$IFDEF MSWINDOWS}
  ApplyReadTimeout(Serial.Handle, RECV_TIMEOUT_MS);
  {$ENDIF}
  aReadCount := Serial.RecvBuffer(@aRawBuf[0], READ_BUF_SIZE);
  if (aReadCount > 0) and (Serial.LastError = 0) then
  begin
    SetLength(aBuf, aReadCount);
    Move(aRawBuf[0], aBuf[0], aReadCount);
    Result := True;
  end;
end;

{ === Автоопределение CRC === }

function TryParseFrame(const aBody, aRaw: TBytes; aAddress: Byte;
  aUseCRC: Boolean; out aParsed: TParsedFrame): Boolean;
begin
  try
    aParsed := ParseFrame(aBody, aRaw, aAddress, aUseCRC);
    Result := True;
  except
    Result := False;
  end;
end;

{ === Обработка одного собранного кадра === }

procedure ProcessFrame(const aBody, aRaw: TBytes);
var
  aParsed: TParsedFrame;
  aResponse: TBytes = nil;
  aUseCRC: Boolean;
begin
  aParsed := Default(TParsedFrame);
  aUseCRC := Mock.UseCRC;

  if (not CRCForced) and (not CRCDetected) then
  begin
    if TryParseFrame(aBody, aRaw, Mock.Address, True, aParsed) then
    begin
      CRCDetected := True;
      Mock.UseCRC := True;
      WriteLn(Format('[auto] CRC detected: ON  (COP=$%02X)', [aParsed.COP]));
    end
    else if TryParseFrame(aBody, aRaw, Mock.Address, False, aParsed) then
    begin
      CRCDetected := True;
      Mock.UseCRC := False;
      WriteLn(Format('[auto] CRC detected: OFF (COP=$%02X)', [aParsed.COP]));
    end
    else
    begin
      WriteLn('[warn] Frame received but CRC auto-detect failed, ignoring.');
      Exit;
    end;
  end
  else
  begin
    if not TryParseFrame(aBody, aRaw, Mock.Address, aUseCRC, aParsed) then
    begin
      WriteLn('[warn] Parse error, responding with ERR_CRC');
      SetLength(aResponse, 1);
      aResponse[0] := ERR_CRC;
      aResponse := BuildFrame(Mock.Address, COP_ERROR, aResponse, aUseCRC);
      IOWrite(aResponse);
      Exit;
    end;
  end;

  WriteLn(Format('>> $%02X  [%s]  (%d bytes)',
    [aParsed.COP, HexBytes(aParsed.Data), Length(aParsed.Data)]));

  Inc(FrameCount);
  Mock.HandleRequest(aParsed, aResponse);

  if Length(aResponse) > 0 then
  begin
    IOWrite(aResponse);
    WriteLn(Format('<< $%02X  (%d bytes)', [aResponse[0], Length(aResponse)]));
  end;
end;

{ === Главный цикл === }

procedure RunServerLoop;
var
  aCollector: TFrameCollector;
  aBuf: TBytes;
  aReadCount: Integer;
  aBody, aRaw: TBytes;
  J: Integer;
begin
  aCollector := TFrameCollector.Create;
  try
    WriteLn('--- Server running. Press Ctrl+C to stop ---');
    WriteLn;
    while Running do
    begin
      if not IORead(aBuf, aReadCount) then
        Continue;
      Inc(ByteCount, aReadCount);
      for J := 0 to aReadCount - 1 do
      begin
        if not Running then
          Break;
        if aCollector.Feed(aBuf[J], aBody, aRaw) then
        begin
          ProcessFrame(aBody, aRaw);
          aBody := nil;
          aRaw := nil;
        end;
      end;
    end;
  finally
    aCollector.Free;
  end;
end;

{ === CLI === }

procedure PrintUsage;
begin
  WriteLn('Tenso-M Mock Server v' + APP_VERSION);
  WriteLn;
  WriteLn('Standalone mock device for Tenso-M protocol testing.');
  WriteLn('Cross-platform via LazSerial (TBlockSerial).');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  tenso_mock_server -p <port> [options]');
  WriteLn;
  WriteLn('Options:');
  WriteLn('  -p <port>       Serial port (required, e.g. COM10, /tmp/s1)');
  WriteLn('  -baud <rate>    Baud rate (default: 9600)');
  WriteLn('  -a <addr>       Device address $01..$9F (default: 1)');
  WriteLn('  -crc            Force CRC mode (default: auto-detect)');
  WriteLn('  -nocrc          Force no-CRC mode');
  WriteLn('  -w <value>      Initial weight (default: 0.0)');
  WriteLn('  -decimals <n>   Decimal places 0..3 (default: 1)');
  WriteLn('  -stable         Weight is stable (default)');
  WriteLn('  -unstable       Weight is unstable');
  WriteLn('  -negative       Weight is negative');
  WriteLn('  -overload       Weight overload');
  WriteLn('  -sn <number>    Serial number (default: 12345)');
  WriteLn('  -maxw <value>   Max weight for C1h (default: 150.0)');
  WriteLn('  -div <value>    Division for C1h (default: 0.5)');
  WriteLn('  -mode <g|n>     Mode: g=GROSS, n=NET (default: GROSS)');
  WriteLn('  -delay <ms>     Response delay in ms (default: 0)');
  WriteLn('  -status <hex>   System status byte (default: $00)');
  WriteLn('  -err <COP>:<ERR> Simulate error EEh on a COP');
  WriteLn('  -h, -?          Show this help');
  WriteLn;
  WriteLn('Examples:');
  WriteLn('  # Linux: via socat virtual pair');
  WriteLn('  socat -d -d pty,raw,echo=0,link=/tmp/s1 pty,raw,echo=0,link=/tmp/s2 &');
  WriteLn('  tenso_mock_server -p /tmp/s1 -a 1 -w 123.4 -stable');
  WriteLn('  tensotest /tmp/s2 1');
  WriteLn;
  WriteLn('  # Windows: via com0com virtual pair (COM10 <-> COM11)');
  WriteLn('  tenso_mock_server -p COM10 -a 1 -w 123.4 -stable');
  WriteLn('  tensotest COM11 1');
  Halt(0);
end;

function FindArg(const A: string): Integer;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if ParamStr(I) = A then
      Exit(I);
  Result := 0;
end;

function ArgValue(const A: string; const ADef: string): string;
var
  I: Integer;
begin
  I := FindArg(A);
  if (I > 0) and (I + 1 <= ParamCount) then
    Result := ParamStr(I + 1)
  else
    Result := ADef;
end;

function HasFlag(const A: string): Boolean;
begin
  Result := FindArg(A) > 0;
end;

{ === Точка входа === }

var
  aAddr, aBaud: Integer;
  aUseCRC: Boolean;
  aWeight, aMaxW, aDiv: Double;
  aDecimals: Integer;
  aSN: Cardinal;
  aStatusVal: Integer;
  aErrArg, aCOPStr, aErrStr: string;
  aStatusStr: string;
  aCOPVal, aErrVal: Integer;
  aDelay: Integer;
begin
  if HasFlag('-h') or HasFlag('-?') then
    PrintUsage;

  PortName := ArgValue('-p', '');
  if PortName = '' then
  begin
    WriteLn('ERROR: -p <port> is required.');
    WriteLn('Use -h for help.');
    Halt(2);
  end;

  aAddr := StrToIntDef(ArgValue('-a', '1'), 1);
  if (aAddr < 1) or (aAddr > 159) then
  begin
    WriteLn('ERROR: Address must be 1..159');
    Halt(1);
  end;

  CRCForced := HasFlag('-crc') or HasFlag('-nocrc');
  aUseCRC := not HasFlag('-nocrc');

  aWeight := StrToFloatDef(ArgValue('-w', '0'), 0.0);
  aDecimals := StrToIntDef(ArgValue('-decimals', '1'), 1);
  aSN := Cardinal(StrToInt64Def(ArgValue('-sn', '12345'), 12345));
  aMaxW := StrToFloatDef(ArgValue('-maxw', '150'), 150.0);
  aDiv := StrToFloatDef(ArgValue('-div', '0.5'), 0.5);
  aDelay := StrToIntDef(ArgValue('-delay', '0'), 0);
  aBaud := StrToIntDef(ArgValue('-baud', '9600'), 9600);

  aStatusVal := 0;
  if FindArg('-status') > 0 then
  begin
    aStatusStr := ArgValue('-status', '0');
    if (Length(aStatusStr) > 1) and (aStatusStr[1] = '$') then
      aStatusVal := StrToIntDef('$' + Copy(aStatusStr, 2, 10), 0)
    else
      aStatusVal := StrToIntDef(aStatusStr, 0);
  end;

  WriteLn('=== Tenso-M Mock Server v' + APP_VERSION + ' ===');
  WriteLn;

  { --- Открытие порта --- }
  Serial := TBlockSerial.Create;
  Serial.Connect(PortName);
  if Serial.LastError <> 0 then
  begin
    WriteLn('ERROR: Cannot open port ', PortName, ': ', Serial.LastErrorDesc);
    Serial.Free;
    Halt(2);
  end;
  Serial.Config(aBaud, 8, 'N', 1, False, False);
  if Serial.LastError <> 0 then
    WriteLn('WARNING: Config failed (', Serial.LastErrorDesc, '), continuing.');
  Serial.Purge;
  WriteLn('Port: ', PortName, '  (', aBaud, ' baud)');

  { --- Создание мока --- }
  Mock := TMockDeviceTransport.Create(Byte(aAddr), aUseCRC);
  try
    Mock.Weight := aWeight;
    Mock.WeightStable := not HasFlag('-unstable');
    Mock.WeightNegative := HasFlag('-negative');
    Mock.WeightOverload := HasFlag('-overload');
    Mock.WeightDecimalPlaces := aDecimals;
    Mock.SerialNumber := aSN;
    Mock.MaxWeight := aMaxW;
    Mock.Division := aDiv;
    Mock.DeviceModeIsGross := (ArgValue('-mode', 'g') <> 'n');
    Mock.ResponseDelayMS := aDelay;
    Mock.SystemStatus := Byte(aStatusVal);

    aErrArg := ArgValue('-err', '');
    if aErrArg <> '' then
    begin
      aCOPStr := Copy(aErrArg, 1, Pos(':', aErrArg) - 1);
      aErrStr := Copy(aErrArg, Pos(':', aErrArg) + 1, MaxInt);
      if (Length(aCOPStr) > 1) and (aCOPStr[1] = '$') then
        aCOPVal := StrToIntDef(aCOPStr, 0)
      else
        aCOPVal := StrToIntDef('$' + aCOPStr, 0);
      if (Length(aErrStr) > 1) and (aErrStr[1] = '$') then
        aErrVal := StrToIntDef(aErrStr, 0)
      else
        aErrVal := StrToIntDef('$' + aErrStr, 0);
      Mock.SimulateError(Byte(aCOPVal), Byte(aErrVal));
      WriteLn(Format('Simulating error $%02X on COP $%02X', [aErrVal, aCOPVal]));
    end;

    WriteLn(Format('Address: $%02X  CRC: %s  Weight: %s  Decimals: %d',
      [Mock.Address, IfThen(Mock.UseCRC, 'ON', 'OFF (auto)'),
       FloatToStr(Mock.Weight), Mock.WeightDecimalPlaces]));
    WriteLn;

    Running := True;
    FrameCount := 0;
    ByteCount := 0;
    CRCDetected := False;

    RunServerLoop;

    WriteLn('--- Shutting down ---');
    WriteLn(Format('Statistics: %d frames processed, %d bytes received',
      [FrameCount, ByteCount]));

  finally
    Mock.Free;
    Serial.Free;
  end;
end.
