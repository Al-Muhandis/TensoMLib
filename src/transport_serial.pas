unit transport_serial;

{
  TensoMLib - транспорт через последовательный порт (COM/tty).

  TSerialTransport - реализация ITensoMTransport через LazSerial (SynSer).
  Требует наличия пакета LazSerial в Lazarus.

  ScanSerialPorts - сканирование доступных портов.
}

{$mode objfpc}{$H+}
{$INTERFACES CORBA}

interface

uses
  Classes, SysUtils, transport {$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}, LazSynaSer{$ENDIF}
  ;

type
  { Реализация через LazSerial (SynSer) }
  { TSerialTransport }

  TSerialTransport = class(ITensoMTransport)
  private{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
    fSerial: TBlockSerial;{$ENDIF}
    fConnected: Boolean;
    fLastError: string;
    { Параметры порта }
    fDataBits: Byte;
    fParity: Char;
    fStopBits: Byte;
    fBaudRate: LongInt; { Хранение текущей скорости }
  public
    destructor Destroy; override;
    function Connect(const aPortName: string; aBaudRate: LongInt; aDataBits: Byte = 8; aParity: Char = 'N';
      aStopBits: Byte = 1): Boolean;
    procedure Disconnect;
    function IsConnected: Boolean;
    function Send(const aData: TBytes): Integer;
    function Receive(aTimeoutMS: Cardinal = 1000): TBytes;
    procedure Flush;
    function GetLastErrorMessage: string;
    function SetBaudRate(aBaudRate: LongInt): Boolean;
  end;

{ Возвращает список имён доступных последовательных портов.
  Windows: перебирает COM1..COM64 через QueryDosDeviceA (быстро, не открывает порт).
  Linux: сканирует /dev/ttyS*, /dev/ttyUSB*, /dev/ttyACM*.
  Возвращает пустой массив, если порты не найдены. }
function ScanSerialPorts: TStringArray;

implementation

{$IFDEF MSWINDOWS}
uses
  windows
  ;

const
  DCB_F_BINARY = $00000001;
  DCB_F_DTR_CONTROL_ENABLE = $00000010;
  DCB_F_RTS_CONTROL_ENABLE = $00001000;

{ Хак для недоделанных USBtoCOM преобразователей под Windows: прямая настройка WinAPI DCB для исправленных стандартных
  драйверов USB serial, которые отклоняют SynSer Config() с помощью ERROR_INVALID_PARAMETER }

type
  TDCBRecord = packed record
    DCBlength: DWORD;
    BaudRate: DWORD;
    Flags: DWORD;
    wReserved: Word;
    XonLim: Word;
    XoffLim: Word;
    ByteSize: Byte;
    Parity: Byte;
    StopBits: Byte;
    XonChar: Byte;
    XoffChar: Byte;
    ErrorChar: Byte;
    EofChar: Byte;
    EvtChar: Byte;
    wReserved1: Word;
  end;

function WinGetCommState(h: THandle; var aDCB: TDCBRecord): BOOL; stdcall; external 'kernel32.dll' name 'GetCommState';
function WinSetCommState(h: THandle; var aDCB: TDCBRecord): BOOL; stdcall; external 'kernel32.dll' name 'SetCommState';

function ConfigureDCBDirect(aHandle: THandle; aBaudRate: LongInt; aDataBits: Byte; aParity: Char;
  aStopBits: Byte): string;
var
  aDCB: TDCBRecord;
  aParityVal: Byte;
  aErrorCode: DWORD;
begin
  Result := EmptyStr;
  Initialize(aDCB);
  aDCB.DCBlength := SizeOf(aDCB);

  if not WinGetCommState(aHandle, aDCB) then
  begin
    aErrorCode := GetLastError;
    Exit('GetCommState failed (Err:' + IntToStr(aErrorCode) + ')');
  end;

  aDCB.BaudRate := DWORD(aBaudRate);
  aDCB.ByteSize := aDataBits;

  case aParity of
    'E': aParityVal := 2;  { EVENPARITY }
    'O': aParityVal := 1;  { ODDPARITY }
  else
    aParityVal := 0;  { NOPARITY }
  end;
  aDCB.Parity := aParityVal;

  case aStopBits of
    2: aDCB.StopBits := 2; { TWOSTOPBITS }
  else
    aDCB.StopBits := 0; { ONESTOPBIT }
  end;

  { fBinary($01) + DTR_CONTROL_ENABLE($10) + RTS_CONTROL_ENABLE($1000) }
  aDCB.Flags := DCB_F_BINARY or DCB_F_DTR_CONTROL_ENABLE or DCB_F_RTS_CONTROL_ENABLE;

  if not WinSetCommState(aHandle, aDCB) then
  begin
    aErrorCode := GetLastError;
    Exit('SetCommState failed (Err:' + IntToStr(aErrorCode) + ')');
  end;

  Result := EmptyStr;
end;

{$ENDIF}

destructor TSerialTransport.Destroy;
begin
  Disconnect;
  inherited;
end;

function TSerialTransport.Connect(const aPortName: string; aBaudRate: LongInt; aDataBits: Byte; aParity: Char;
  aStopBits: Byte): Boolean;

  procedure DoConnect;
  var
    aSer: TBlockSerial;
    aParityChar: Char;
    aConfigError: string;
  begin
    aSer := TBlockSerial.Create;
    try
      case AParity of
        'E': aParityChar := 'E';
        'O': aParityChar := 'O';
      else
        aParityChar := 'N';
      end;
      aSer.Connect(aPortName);
      if aSer.LastError <> 0 then
      begin
        fLastError := Format('Couldn''t open %s: %s', [aPortName, aSer.LastErrorDesc]);
        Exit;
      end;

      { Настройка порта: сначала попробуем SynSer Config(), затем воспользуемся резервной версией через WinAPI.
      1. Это хак
      2. Для дешевых USB2COM, у которых драйвер не дописан. Из официальной документации:
      "если использовать именно сложный асинхронный режим Com-порта, тогда для всех дешевых устройств мы будем
      обращаться в ту часть драйвера, которая просто не написана, и устройство работать не будет. Этим мы просто
      убираем все дешевые преобразователи, которые потенциально из-за ошибок в своих драйверах приносили кучу
      неприятностей"
      }
      aSer.Config(ABaudRate, ADataBits, aParityChar, AStopBits, False, False);
      if aSer.LastError <> 0 then
      begin
        aConfigError := aSer.LastErrorDesc;
        {$IFDEF MSWINDOWS}
        { Запасной вариант: прямая настройка DCB для исправления ошибок в стандартных драйверах }
        aConfigError := ConfigureDCBDirect(aSer.Handle, ABaudRate, ADataBits, AParity, AStopBits);
        if aConfigError <> '' then
        begin
          fLastError := Format('Configuration error %s: %s (SynSer: %s)',
            [aPortName, aConfigError, aSer.LastErrorDesc]);
          aSer.CloseSocket;
          Exit;
        end;
        {$ELSE}
        fLastError := Format('Configuration error %s: %s', [aPortName, aConfigError]);
        aSer.CloseSocket;
        Exit;
        {$ENDIF}
      end;

      aSer.Purge;
      fSerial := aSer;
      fBaudRate := aBaudRate;
      fDataBits := aDataBits;
      fParity := aParityChar;
      fStopBits := aStopBits;
      fConnected := True;
    finally
      { Если не подключились - освобождаем }
      if not fConnected then
        aSer.Free;
    end;
  end;

begin
{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  try
    DoConnect;
  except
    on E: Exception do
      fLastError := E.Message;
  end;
{$ELSE}
  FLastError := 'The LazSerial transport is not compiled (requires Lazarus + LazZerial)';
{$ENDIF}

  Result := fConnected;
end;

procedure TSerialTransport.Disconnect;
begin
  if fConnected and Assigned(fSerial) then
  begin
{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
    try
      fSerial.CloseSocket;
      fSerial.Free;
    except
    end;
{$ENDIF}
    fSerial := nil;
  end;
  fDataBits := 0;
  fParity := #0;
  fStopBits := 0;
  fBaudRate := 0;
  fConnected := False;
end;

function TSerialTransport.IsConnected: Boolean;
begin
  Result := fConnected;
end;

function TSerialTransport.Send(const aData: TBytes): Integer;
begin
  Result := 0;
  fLastError := EmptyStr;

  if not fConnected then
  begin
    fLastError := 'Transport is not connected';
    Exit;
  end;

  if Length(aData) = 0 then
    Exit;

{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  try
    fSerial.SendBuffer(@aData[0], Length(aData));

    if fSerial.LastError <> 0 then
    begin
      fLastError := fSerial.LastErrorDesc;
      Exit;
    end;

    Result := Length(aData);
  except
    on E: Exception do
      fLastError := E.Message;
  end;
{$ENDIF}
end;

function TSerialTransport.Receive(aTimeoutMS: Cardinal): TBytes;
var
  aData: AnsiString;
begin
  Result := nil;
  fLastError := EmptyStr;

  if not fConnected then
    Exit;

{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  try
    aData := fSerial.RecvPacket(aTimeoutMS);

    if fSerial.LastError <> 0 then
    begin
      fLastError := fSerial.LastErrorDesc;
      Exit;
    end;

    if Length(aData) = 0 then
      Exit;

    SetLength(Result, Length(aData));
    Move(aData[1], Result[0], Length(aData));
  except
    on E: Exception do
      fLastError := E.Message;
  end;
{$ENDIF}
end;

procedure TSerialTransport.Flush;
begin
  if not fConnected then
  begin
    fLastError := 'Transport is not connected';
    Exit;
  end;

  fLastError := EmptyStr;

{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  try
    fSerial.Purge;

    if fSerial.LastError <> 0 then
      fLastError := fSerial.LastErrorDesc;
  except
    on E: Exception do
      fLastError := E.Message;
  end;
{$ENDIF}
end;

function TSerialTransport.GetLastErrorMessage: string;
begin
  Result := fLastError;
end;

function TSerialTransport.SetBaudRate(aBaudRate: LongInt): Boolean;
begin
  Result := False;
  fLastError := EmptyStr;

  if not fConnected then
  begin
    fLastError := 'Transport is not connected';
    Exit;
  end;

{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  try
    fSerial.Config(aBaudRate, fDataBits, fParity, fStopBits, False, False);

    if fSerial.LastError = 0 then
    begin
      fBaudRate := aBaudRate;
      Result := True;
      Exit;
    end;

{$IFDEF MSWINDOWS}
    { Fallback для драйверов, с которыми SynSer Config() не работает }
    fLastError := ConfigureDCBDirect(fSerial.Handle, aBaudRate, fDataBits, fParity, fStopBits);

    if fLastError = '' then
    begin
      fBaudRate := aBaudRate;
      Result := True;
    end;
{$ELSE}
    fLastError := fSerial.LastErrorDesc;
{$ENDIF}

  except
    on E: Exception do
      fLastError := E.Message;
  end;
{$ENDIF}
end;

{ === Сканирование портов === }

{$IFDEF MSWINDOWS}
{ QueryDosDeviceA проверяет существование DOS-имени устройства (COMx)
  без фактического открытия порта — работает мгновенно. }
function WinQueryDosDeviceA(lpDeviceName: PAnsiChar; lpTargetPath: PAnsiChar;
  ucchMax: DWORD): DWORD; stdcall; external 'kernel32.dll' name 'QueryDosDeviceA';

function ScanSerialPorts: TStringArray;
var
  I: Integer;
  aBuf: array[0..256] of AnsiChar;
  aName: string;
begin
  Result := nil;
  for I := 1 to 64 do
  begin
    aName := 'COM' + IntToStr(I);
    if WinQueryDosDeviceA(PAnsiChar(AnsiString(aName)), aBuf, SizeOf(aBuf)) > 0 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := aName;
    end;
  end;
end;
{$ENDIF MSWINDOWS}

{$IFDEF LINUX}
function ScanSerialPorts: TStringArray;
const
  PORT_PATTERNS: array[0..2] of string = (
    '/dev/ttyS*', '/dev/ttyUSB*', '/dev/ttyACM*'
  );
var
  I: Integer;
  aSR: TSearchRec;
begin
  Result := nil;
  SetLength(Result, 0);
  for I := 0 to High(PORT_PATTERNS) do
  begin
    if FindFirst(PORT_PATTERNS[I], faAnyFile, aSR) = 0 then
    try
      repeat
        if (aSR.Attr and faDirectory) = 0 then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := '/dev/' + aSR.Name;
        end;
      until FindNext(aSR) <> 0;
    finally
      FindClose(aSR);
    end;
  end;
end;
{$ENDIF LINUX}

end.
