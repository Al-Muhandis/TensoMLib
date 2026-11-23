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
    -a <addr-list>  Адрес(а) прибора $01..$9F через запятую: «-a 1,3,5» -
                    НЕСКОЛЬКО виртуальных приборов на одной шине (мультиадрес,
                    адрес маршрутизирует кадры; по умолчанию: 1)
    -model <name>   Профиль модели прибора (по умолчанию: uni):
                      uni — весь протокол;
                      05n — ТВ-003/05Н (C0,C1,C2,C3,C8,CE);
                      05d — ТВ-003/05Д (C0,C2,C3,CC с байтом N,FD; нетто с
                            битом D5). Неподдерживаемые команды — ответ FDh.
    -baud <rate>    Скорость (по умолчанию: 9600)
    -crc            Использовать CRC (по умолчанию: автоопределение)
    -nocrc          Не использовать CRC
    -w <value>      Начальный вес (по умолчанию: 0.0)
    -decimals <n>   Знаков после запятой, 0..3 (по умолчанию: 1)
    -stable         Вес стабилен (по умолчанию)
    -unstable       Вес нестабилен
    -negative       Отрицательный вес
    -overload       Перегрузка
    -sn <number>    Серийный номер (по умолчанию: 12345; на шине из
                    нескольких приборов SN = база+i, у каждого свой)
    -maxw <value>   Максимальный вес (по умолчанию: 150.0)
    -div <value>    Цена деления (по умолчанию: 0.5)
    -mode <g|n>     Режим: g=GROSS, n=NET (по умолчанию: GROSS)
    -delay <ms>     Искусственная задержка ответа, мс (по умолчанию: 0)
    -status <hex>   Байт системного статуса (по умолчанию: $00)
    -err <COP>:<ERR>  Имитировать ошибку EEh на указанный COP (всем приборам)
    -h, -?          Справка
    -step <value>   Шаг изменения веса стрелками (по умолчанию: 1 знак последнего разряда)
    -nokb           Отключить управление с клавиатуры

  Автоопределение CRC:
    По умолчанию сервер пробует разобрать входящий кадр сначала с CRC,
    затем без. Если удалось — отвечает тем же режимом. После первого
    успешного разбора режим фиксируется.
}

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, StrUtils, Math, Crt,
  LazSynaSer,
  core, frames, mock_server
  ;

const
  APP_VERSION = '1.6';
  RECV_TIMEOUT_MS = 100;

var
  Bus: TMockBus;
  Serial: TBlockSerial;
  PortName: string;
  Running: Boolean;
  CRCForced: Boolean;
  CRCDetected: Boolean;
  FrameCount: Integer;
  ByteCount: Integer;
  KbEnabled: Boolean;
  WeightStep: Double;
  InputMode: Boolean;
  InputBuf: string;

{ === Ввод/вывод через TBlockSerial === }

procedure IOWrite(const aBuf: TBytes);
begin
  if Length(aBuf) = 0 then
    Exit;
  Serial.SendBuffer(@aBuf[0], Length(aBuf));
end;

function IORead(out aBuf: TBytes; out aReadCount: Integer): Boolean;
var
  aData: AnsiString;
begin
  aBuf := nil;
  aReadCount := 0;
  Result := False;

  aData := Serial.RecvPacket(RECV_TIMEOUT_MS);

  if Serial.LastError <> 0 then
    Exit;

  if Length(aData) = 0 then
    Exit;

  aReadCount := Length(aData);
  SetLength(aBuf, aReadCount);
  Move(aData[1], aBuf[0], aReadCount);

  Result := True;
end;

{ === Автоопределение CRC === }
{ (роль выполняет TMockBus.TryRoute: кадр пробуется под адресами шины) }

{ === Обработка одного собранного кадра === }

procedure ProcessFrame(const aBody, aRaw: TBytes);
var
  aParsed: TParsedFrame;
  aResponse: TBytes = nil;
  aUseCRC: Boolean;
  aMock: TMockDeviceTransport;
begin
  aParsed := Default(TParsedFrame);
  aUseCRC := Bus.Device(0).UseCRC;
  aMock := nil;

  if (not CRCForced) and (not CRCDetected) then
  begin
    if Bus.TryRoute(aBody, aRaw, True, aParsed, aMock) then
    begin
      CRCDetected := True;
      Bus.SetUseCRC(True);
      WriteLn(Format('[auto] CRC detected: ON  (COP=$%02X)', [aParsed.COP]));
    end
    else if Bus.TryRoute(aBody, aRaw, False, aParsed, aMock) then
    begin
      CRCDetected := True;
      Bus.SetUseCRC(False);
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
    if not Bus.TryRoute(aBody, aRaw, aUseCRC, aParsed, aMock) then
    begin
      { Битый кадр: на шине несколько приборов адресата не определить -
        реальная шина молчит; единственный прибор - прежнее поведение
        (ответ ERR_CRC). }
      if Bus.Count = 1 then
      begin
        WriteLn('[warn] Parse error, responding with ERR_CRC');
        SetLength(aResponse, 1);
        aResponse[0] := ERR_CRC;
        aResponse := BuildFrame(Bus.Device(0).Address, COP_ERROR, aResponse, aUseCRC);
        IOWrite(aResponse);
      end
      else
        WriteLn('[warn] Frame not routed to any device (bad CRC / unknown address) - silence');
      Exit;
    end;
  end;

  //WriteLn(Format('>> $%02X  [%s]  (%d bytes)', [aParsed.COP, HexBytes(aParsed.Data), Length(aParsed.Data)]));

  Inc(FrameCount);
  aMock.HandleRequest(aParsed, aResponse);

  if Length(aResponse) > 0 then
  begin
    IOWrite(aResponse);
    //WriteLn(Format('<< $%02X  (%d bytes)', [aResponse[0], Length(aResponse)]));
  end;
end;

{ === Интерактивное управление весом === }
{ Клавиатура управляет ВСЕМИ приборами шины синхронно (ручная среда). }

function SignedWeight: Double;
begin
  if Bus.Device(0).WeightNegative then
    Result := -Bus.Device(0).Weight
  else
    Result := Bus.Device(0).Weight;
end;

procedure PrintWeightState;
begin
  WriteLn(Format('[kb] Weight = %.*f  step=%s  %s%s%s  (всего приборов: %d)',
    [Bus.Device(0).WeightDecimalPlaces, SignedWeight,
     FloatToStr(WeightStep),
     IfThen(Bus.Device(0).WeightStable, 'STABLE', 'UNSTABLE'),
     IfThen(Bus.Device(0).WeightNegative, ' NEG', ''),
     IfThen(Bus.Device(0).WeightOverload, ' OVERLOAD', ''), Bus.Count]));
end;

{ Устанавливает вес со знаком; в BCD-поле влезает 6 цифр }
procedure ApplyWeight(aValue: Double);
var
  aMax: Double;
  I: Integer;
begin
  aValue := RoundTo(aValue, -Bus.Device(0).WeightDecimalPlaces);
  for I := 0 to Bus.Count - 1 do
  begin
    aMax := 999999 / IntPower(10, Bus.Device(I).WeightDecimalPlaces);
    if aValue > aMax then aValue := aMax;
    if aValue < -aMax then aValue := -aMax;
    Bus.Device(I).WeightNegative := aValue < 0;
    Bus.Device(I).Weight := Abs(aValue);
  end;
  PrintWeightState;
end;

procedure PrintKeyHelp;
begin
  WriteLn('Keys:');
  WriteLn('  Up/Right, Down/Left  weight +/- step');
  WriteLn('  ] / [                step x10 / /10');
  WriteLn('  w or digit           enter exact value (Enter - apply, Esc - cancel)');
  WriteLn('  z                    zero');
  WriteLn('  s                    toggle stable');
  WriteLn('  n                    toggle negative sign');
  WriteLn('  o                    toggle overload');
  WriteLn('  ?                    this help');
  WriteLn('  q                    quit');
end;

procedure StartInput(const aFirst: string);
begin
  InputMode := True;
  InputBuf := aFirst;
  Write('Weight> ', InputBuf);
end;

procedure HandleInputKey(K: Char);
var
  aVal: Double;
  aStr: string;
begin
  case K of
    #0: ReadKey;  { расширенный код — игнорируем }
    #3: begin WriteLn; Running := False; end;   { Ctrl+C }
    #13:
    begin
      WriteLn;
      InputMode := False;
      aStr := StringReplace(InputBuf, ',', DefaultFormatSettings.DecimalSeparator, []);
      aStr := StringReplace(aStr, '.', DefaultFormatSettings.DecimalSeparator, []);
      if TryStrToFloat(aStr, aVal) then
        ApplyWeight(aVal)
      else
        WriteLn('[kb] Invalid number: ', InputBuf);
    end;
    #27:
    begin
      WriteLn;
      WriteLn('[kb] Cancelled');
      InputMode := False;
    end;
    #8, #127:
      if Length(InputBuf) > 0 then
      begin
        SetLength(InputBuf, Length(InputBuf) - 1);
        Write(#8' '#8);
      end;
    '0'..'9', '-', '.', ',':
    begin
      InputBuf := InputBuf + K;
      Write(K);
    end;
  end;
end;

procedure HandleCommandKey(K: Char);
var
  aExt: Char;
  aMinStep: Double;
  I: Integer;
begin
  aMinStep := 1 / IntPower(10, Bus.Device(0).WeightDecimalPlaces);
  case K of
    #3: Running := False;   { Ctrl+C }
    #0:
    begin
      aExt := ReadKey;
      case aExt of
        #72, #77: ApplyWeight(SignedWeight + WeightStep);  { Up, Right }
        #80, #75: ApplyWeight(SignedWeight - WeightStep);  { Down, Left }
      end;
    end;
    ']':
    begin
      WeightStep := Min(WeightStep * 10, 1000);
      PrintWeightState;
    end;
    '[':
    begin
      WeightStep := Max(WeightStep / 10, aMinStep);
      PrintWeightState;
    end;
    'w', 'W': StartInput('');
    '0'..'9', '-', '.', ',': StartInput(K);
    'z', 'Z': ApplyWeight(0);
    's', 'S':
    begin
      for I := 0 to Bus.Count - 1 do
        Bus.Device(I).WeightStable := not Bus.Device(I).WeightStable;
      PrintWeightState;
    end;
    'n', 'N':
    begin
      for I := 0 to Bus.Count - 1 do
        Bus.Device(I).WeightNegative := not Bus.Device(I).WeightNegative;
      PrintWeightState;
    end;
    'o', 'O':
    begin
      for I := 0 to Bus.Count - 1 do
        Bus.Device(I).WeightOverload := not Bus.Device(I).WeightOverload;
      PrintWeightState;
    end;
    '?': PrintKeyHelp;
    'q', 'Q': Running := False;
  end;
end;

procedure PollKeyboard;
var
  K: Char;
begin
  while KbEnabled and KeyPressed do
  begin
    K := ReadKey;
    if InputMode then
      HandleInputKey(K)
    else
      HandleCommandKey(K);
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
      PollKeyboard;
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
  WriteLn('  -a <addr-list>  Device address(es) $01..$9F, comma-separated');
  WriteLn('                  (e.g. -a 1,3,5 = MULTIPLE devices on one bus,');
  WriteLn('                  default: 1)');
  WriteLn('  -model <name>   Device model profile (default: uni):');
  WriteLn('                    uni - full protocol;');
  WriteLn('                    05n - TV-003/05N (C0,C1,C2,C3,C8,CE only);');
  WriteLn('                    05d - TV-003/05D (C0,C2,C3,CC with N byte,FD);');
  WriteLn('                  unsupported commands answer FDh');
  WriteLn('  -crc            Force CRC mode (default: auto-detect)');
  WriteLn('  -nocrc          Force no-CRC mode');
  WriteLn('  -w <value>      Initial weight (default: 0.0)');
  WriteLn('  -decimals <n>   Decimal places 0..3 (default: 1)');
  WriteLn('  -stable         Weight is stable (default)');
  WriteLn('  -unstable       Weight is unstable');
  WriteLn('  -negative       Weight is negative');
  WriteLn('  -overload       Weight overload');
  WriteLn('  -sn <number>    Serial number (default: 12345; on a multi-device');
  WriteLn('                  bus each device gets SN = base + index)');
  WriteLn('  -maxw <value>   Max weight for C1h (default: 150.0)');
  WriteLn('  -div <value>    Division for C1h (default: 0.5)');
  WriteLn('  -mode <g|n>     Mode: g=GROSS, n=NET (default: GROSS)');
  WriteLn('  -delay <ms>     Response delay in ms (default: 0)');
  WriteLn('  -status <hex>   System status byte (default: $00)');
  WriteLn('  -err <COP>:<ERR> Simulate error EEh on a COP (all devices)');
  WriteLn('  -h, -?          Show this help');
  WriteLn('  -step <value>   The step of changing the weight using the arrows (by default: 1 digit of the last digit)');
  WriteLn('  -nokb           Disable keyboard control');

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
  WriteLn;
  WriteLn('  # One bus, three devices at addresses 1, 3, 5');
  WriteLn('  tenso_mock_server -p COM10 -a 1,3,5 -w 42.0');
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

{ Разбор списка адресов «1,3,5» (мультиадресная шина) }
function ParseAddrList(const aArg: string): TBytes;
var
  aParts: TStringList;
  I, aVal: Integer;
  aSeen: TStringList;
begin
  SetLength(Result, 0);
  aParts := TStringList.Create;
  aSeen := TStringList.Create;
  try
    aParts.Delimiter := ',';
    aParts.StrictDelimiter := True;
    aParts.DelimitedText := aArg;
    for I := 0 to aParts.Count - 1 do
    begin
      aVal := StrToIntDef(Trim(aParts[I]), -1);
      if (aVal < 1) or (aVal > 159) then
      begin
        WriteLn('ERROR: Address must be 1..159, got "', aParts[I], '"');
        Halt(1);
      end;
      if aSeen.IndexOf(IntToStr(aVal)) >= 0 then
      begin
        WriteLn('ERROR: Duplicate address ', aVal, ' in -a list');
        Halt(1);
      end;
      aSeen.Add(IntToStr(aVal));
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Byte(aVal);
    end;
    if Length(Result) = 0 then
    begin
      WriteLn('ERROR: empty -a list');
      Halt(1);
    end;
  finally
    aSeen.Free;
    aParts.Free;
  end;
end;

var
  aAddrs: TBytes;
  aBaud: Integer;
  aUseCRC: Boolean;
  aWeight, aMaxW, aDiv: Double;
  aDecimals: Integer;
  aSN: Cardinal;
  aStatusVal: Integer;
  aErrArg, aCOPStr, aErrStr: string;
  aStatusStr: string;
  aCOPVal, aErrVal: Integer;
  aDelay: Integer;
  aDev: TMockDeviceTransport;
  aAddrList: string;
  aModel: TMockModel;
  aModelArg: string;
  I: Integer;
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

  aAddrList := ArgValue('-a', '1');
  aAddrs := ParseAddrList(aAddrList);

  CRCForced := HasFlag('-crc') or HasFlag('-nocrc');
  aUseCRC := not HasFlag('-nocrc');

  aModelArg := LowerCase(ArgValue('-model', 'uni'));
  case aModelArg of
    'uni': aModel := mmUniversal;
    '05n': aModel := mmTV003_05N;
    '05d': aModel := mmTV003_05D;
  else
    begin
      WriteLn('ERROR: -model expects uni|05n|05d, got "', aModelArg, '"');
      Halt(2);
    end;
  end;

  aWeight := StrToFloatDef(ArgValue('-w', '0'), 0.0);
  aDecimals := StrToIntDef(ArgValue('-decimals', '1'), 1);
  if (aDecimals < 0) or (aDecimals > 3) then
  begin
    WriteLn('ERROR: -decimals must be 0..3 (CON byte holds 0..7, protocol uses 0..3), got ', aDecimals);
    Halt(2);
  end;
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

  { --- Шина виртуальных приборов (мультиадрес: по прибору на адрес) --- }
  Bus := TMockBus.Create;
  try
    for I := 0 to High(aAddrs) do
    begin
      aDev := Bus.AddDevice(aAddrs[I], aUseCRC);
      aDev.Model := aModel;
      case aModel of
        mmTV003_05N:
        begin
          aDev.DeviceName := 'TB003/05N';
          aDev.DeviceVersion := '10.02';
        end;
        mmTV003_05D:
        begin
          aDev.DeviceName := 'TB003/05D';
          aDev.DeviceVersion := '10.13AX';
        end;
      else
        ; { uni — идентификация по умолчанию (TB003/05 1.0) }
      end;
      aDev.Weight := aWeight;
      aDev.WeightStable := not HasFlag('-unstable');
      aDev.WeightNegative := HasFlag('-negative');
      aDev.WeightOverload := HasFlag('-overload');
      aDev.WeightDecimalPlaces := aDecimals;
      if Length(aAddrs) > 1 then
        aDev.SerialNumber := aSN + Cardinal(I)   { каждому прибору свой SN }
      else
        aDev.SerialNumber := aSN;
      aDev.MaxWeight := aMaxW;
      aDev.Division := aDiv;
      aDev.DeviceModeIsGross := (ArgValue('-mode', 'g') <> 'n');
      aDev.ResponseDelayMS := aDelay;
      aDev.SystemStatus := Byte(aStatusVal);
    end;

    aErrArg := ArgValue('-err', '');
    if aErrArg <> '' then
    begin
      { Без двоеточия COPStr оказался бы пустым - ошибка «на COP $00» вместо
        внятного сообщения о неверном формате опции }
      if Pos(':', aErrArg) = 0 then
      begin
        WriteLn('ERROR: -err expects COP:ERR format (e.g. -err C3:06), got "', aErrArg, '"');
        Halt(2);
      end;
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
      for I := 0 to Bus.Count - 1 do
        Bus.Device(I).SimulateError(Byte(aCOPVal), Byte(aErrVal));
      WriteLn(Format('Simulating error $%02X on COP $%02X (all devices)', [aErrVal, aCOPVal]));
    end;

    Write(Format('Devices (%d): ', [Bus.Count]));
    for I := 0 to Bus.Count - 1 do
    begin
      if I > 0 then
        Write(', ');
      Write(Format('$%02X (SN %d)', [Bus.Device(I).Address, Bus.Device(I).SerialNumber]));
    end;
    WriteLn;
    case aModel of
      mmTV003_05N: WriteLn('Model: TV-003/05N (C0,C1,C2,C3,C8,CE; rest answers FDh)');
      mmTV003_05D: WriteLn('Model: TV-003/05D (C0,C2,C3,CC(N),FD; rest answers FDh)');
    else
      WriteLn('Model: universal (full protocol)');
    end;
    WriteLn(Format('FDh identity: %s %s',
      [Bus.Device(0).DeviceName, Bus.Device(0).DeviceVersion]));
    WriteLn(Format('CRC: %s  Weight: %s  Decimals: %d',
      [IfThen(Bus.Device(0).UseCRC, 'ON', 'OFF (auto)'), FloatToStr(Bus.Device(0).Weight), Bus.Device(0).WeightDecimalPlaces]));
    WriteLn;

    KbEnabled := not HasFlag('-nokb');
    InputMode := False;
    WeightStep := StrToFloatDef(ArgValue('-step', ''), 1 / IntPower(10, aDecimals));
    if KbEnabled then
      PrintKeyHelp;

    Running := True;
    FrameCount := 0;
    ByteCount := 0;
    CRCDetected := False;

    RunServerLoop;

    WriteLn('--- Shutting down ---');
    WriteLn(Format('Statistics: %d frames processed, %d bytes received',
      [FrameCount, ByteCount]));

  finally
    Bus.Free;
    Serial.Free;
  end;
end.
