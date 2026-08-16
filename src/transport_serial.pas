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
  Classes, SysUtils, transport
  ;

type
  { Реализация через LazSerial (SynSer) }

  { TSerialTransport }

  TSerialTransport = class(ITensoMTransport)
  private
    fHandle: THandle;
    fConnected: Boolean;
    fLastError: string;
    fPortName: string;
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
  end;

{ Возвращает список имён доступных последовательных портов.
  Windows: перебирает COM1..COM64 через QueryDosDeviceA (быстро, не открывает порт).
  Linux: сканирует /dev/ttyS*, /dev/ttyUSB*, /dev/ttyACM*.
  Возвращает пустой массив, если порты не найдены. }
function ScanSerialPorts: TStringArray;

implementation

{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
uses
  LazSynaSer{$IFDEF MSWINDOWS}, windows{$ENDIF}
  ;
{$ENDIF}

{$IFDEF MSWINDOWS}
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
function WinSetCommTimeouts(h: THandle; aReadIntervalTimeout, aReadTotalTimeoutMultiplier, aReadTotalTimeoutConstant,
  aWriteTotalTimeoutMultiplier, aWriteTotalTimeoutConstant: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetCommTimeouts';

function ConfigureDCBDirect(aHandle: THandle; aBaudRate: LongInt; aDataBits: Byte; aParity: Char;
  aStopBits: Byte): string;
var
  aDCB: TDCBRecord;
  aParityVal: Byte;
begin
  Result := EmptyStr;
  Initialize(aDCB);
  aDCB.DCBlength := SizeOf(aDCB);
  if not WinGetCommState(aHandle, aDCB) then
    Exit('GetCommState failed');
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
  aDCB.Flags := $00000001 or $00000010 or $00001000;
  if not WinSetCommState(aHandle, aDCB) then
    Exit('SetCommState failed');
  { SetCommTimeouts
      ReadIntervalTimeout=50:        максимальное время ожидания между двумя последовательными байтами.
      ReadTotalTimeoutConstant=250:  общее время ожидания чтения в мс.
      WriteTotalTimeoutConstant=500: общее время ожидания записи в мс.
      Без этого RecvBuffer может зависнуть на неопределенный срок после сбоя SynSer Config(),
      потому что тайм-ауты синхронизации никогда не применялись. }
  if not WinSetCommTimeouts(aHandle, 50, 0, 250, 0, 500) then
    Exit('SetCommTimeouts failed');
  Result:=EmptyStr;
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
      fHandle := THandle(aSer);
      fPortName := aPortName;
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
  FLastError := 'The LazZerial transport is not compiled (requires Lazarus + LazZerial)';
{$ENDIF}

  Result := fConnected;
end;

procedure TSerialTransport.Disconnect;
begin
  if fConnected and (fHandle <> 0) then
  begin
{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
    try
      TBlockSerial(fHandle).CloseSocket;
      TBlockSerial(fHandle).Free;
    except
    end;
{$ENDIF}
    fHandle := 0;
  end;
  fConnected := False;
end;

function TSerialTransport.IsConnected: Boolean;
begin
  Result := fConnected;
end;

function TSerialTransport.Send(const aData: TBytes): Integer;
begin
  Result := 0;
  if not fConnected then Exit;

{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  try
    TBlockSerial(fHandle).SendBuffer(@aData[0], Length(aData));
    if TBlockSerial(fHandle).LastError = 0 then
      Result := Length(aData)
    else
      fLastError := TBlockSerial(fHandle).LastErrorDesc;
  except
    on E: Exception do
      fLastError := E.Message;
  end;
{$ENDIF}
end;

function TSerialTransport.Receive(aTimeoutMS: Cardinal): TBytes;
var
  aBuf: TBytes = nil;
  aReadCount: Integer;
begin
  Result := nil;
  if not fConnected then Exit;

{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  try
    TBlockSerial(fHandle).DeadlockTimeout := aTimeoutMS;
    SetLength(aBuf, 256);
    aReadCount := TBlockSerial(fHandle).RecvBuffer(@aBuf[0], 256);
    if aReadCount > 0 then
    begin
      SetLength(Result, aReadCount);
      Move(aBuf[0], Result[0], aReadCount);
    end;
  except
    on E: Exception do
      fLastError := E.Message;
  end;
{$ENDIF}
end;

procedure TSerialTransport.Flush;
begin
  if not fConnected then Exit;
{$IF DEFINED(LAZSERIAL) OR DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  try
    TBlockSerial(fHandle).Purge;
  except
  end;
{$ENDIF}
end;

function TSerialTransport.GetLastErrorMessage: string;
begin
  Result := fLastError;
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
