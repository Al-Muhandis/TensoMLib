unit transport;

{
  TensoMLib - транспортный слой: интерфейс и базовые реализации.

  ITensoMTransport - интерфейс, позволяющий подменить реальный порт
  на мок-объект для тестирования.

  TMockTransport - мок для юнит-тестов (предустановленные ответы).
  Не имеет внешних зависимостей кроме core.

  Реальные транспорты вынесены в отдельные юниты:
    transport_serial.pas - TSerialTransport (LazSynaSer)
}

{$mode objfpc}{$H+}
{$INTERFACES CORBA}

interface

uses
  Classes, SysUtils, core
  ;

type
  { Интерфейс транспорта }
  ITensoMTransport = interface
    function Connect(const aPortName: string; aBaudRate: LongInt; aDataBits: Byte = 8; aParity: Char = 'N';
      aStopBits: Byte = 1): Boolean;
    procedure Disconnect;
    function IsConnected: Boolean;
    function Send(const aData: TBytes): Integer;
    { Читает данные из порта. Таймаут в мс. }
    function Receive(aTimeoutMS: Cardinal = 1000): TBytes;
    function SetBaudRate(aBaudRate: LongInt): Boolean;
    procedure Flush;
    function GetLastErrorMessage: string;
  end;

  { Мок-транспорт для тестирования.
    При каждом вызове Receive возвращает следующую
    посылку из очереди. Все отправленные данные записываются в SentLog. }

  { TMockTransport }

  TMockTransport = class(ITensoMTransport)
  private
    fConnected: Boolean;
    fResponses: array of TBytes;  { очередь ответов }
    fSentLog: array of TBytes;    { лог отправленных данных }
    fResponseIndex: Integer;
    fBaudRate: LongInt;
  public
    constructor Create;
    destructor Destroy; override;

    { Настройка мока }
    procedure QueueResponse(const aData: TBytes);
    procedure ClearResponses;
    function GetSentData(aIndex: Integer): TBytes;
    function GetSentCount: Integer;
    function GetAllSentHex: string;

    { ITensoMTransport }
    function Connect(const {%H-}aPortName: string; {%H-}aBaudRate: LongInt; {%H-}aDataBits: Byte = 8;
      {%H-}aParity: Char = 'N'; {%H-}aStopBits: Byte = 1): Boolean;
    procedure Disconnect;
    function IsConnected: Boolean;
    function Send(const aData: TBytes): Integer;
    function Receive({%H-}aTimeoutMS: Cardinal = 1000): TBytes;
    procedure Flush;
    function GetLastErrorMessage: string;
    function GetBaudRate: LongInt;
    function SetBaudRate(aBaudRate: LongInt): Boolean;
  end;

{ Скорость по умолчанию: 9600 бод }
function BaudRateToValue(aRateCode: Byte): LongInt;
function BaudRateToCode(aBaudRate: LongInt): Byte;

implementation

{ === TMockTransport === }

constructor TMockTransport.Create;
begin
  inherited Create;
  SetLength(fResponses, 0);
  SetLength(fSentLog, 0);
  fConnected := False;
  fResponseIndex := 0;
  fBaudRate := 9600;
end;

destructor TMockTransport.Destroy;
begin
  SetLength(fResponses, 0);
  SetLength(fSentLog, 0);
  inherited;
end;

procedure TMockTransport.QueueResponse(const aData: TBytes);
begin
  SetLength(fResponses, Length(fResponses) + 1);
  fResponses[High(fResponses)] := Copy(aData, 0, Length(aData));
end;

procedure TMockTransport.ClearResponses;
begin
  SetLength(fResponses, 0);
  fResponseIndex := 0;
end;

function TMockTransport.GetSentData(aIndex: Integer): TBytes;
begin
  if (aIndex >= 0) and (aIndex < Length(fSentLog)) then
    Result := Copy(fSentLog[aIndex], 0, Length(fSentLog[aIndex]))
  else
    Result := nil;
end;

function TMockTransport.GetSentCount: Integer;
begin
  Result := Length(fSentLog);
end;

function TMockTransport.GetAllSentHex: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(fSentLog) do
  begin
    if I > 0 then Result := Result + ' | ';
    Result := Result + HexBytes(fSentLog[I]);
  end;
end;

function TMockTransport.Connect(const aPortName: string; aBaudRate: LongInt;
  aDataBits: Byte; aParity: Char; aStopBits: Byte): Boolean;
begin
  fConnected := True;
  Result := True;
end;

procedure TMockTransport.Disconnect;
begin
  fConnected := False;
end;

function TMockTransport.IsConnected: Boolean;
begin
  Result := fConnected;
end;

function TMockTransport.Send(const aData: TBytes): Integer;
begin
  SetLength(fSentLog, Length(fSentLog) + 1);
  fSentLog[High(fSentLog)] := Copy(aData, 0, Length(aData));
  Result := Length(aData);
end;

function TMockTransport.Receive(aTimeoutMS: Cardinal): TBytes;
begin
  if fResponseIndex < Length(fResponses) then
  begin
    Result := Copy(fResponses[fResponseIndex], 0,
      Length(fResponses[fResponseIndex]));
    Inc(fResponseIndex);
  end
  else
    Result := nil;
end;

procedure TMockTransport.Flush;
begin
  { нет-op }
end;

function TMockTransport.GetLastErrorMessage: string;
begin
  Result := '';
end;

function TMockTransport.GetBaudRate: LongInt;
begin
  Result := fBaudRate;
end;

function TMockTransport.SetBaudRate(aBaudRate: LongInt): Boolean;
begin
  fBaudRate := aBaudRate;
  Result := True;
end;

{ === Вспомогательные функции === }

function BaudRateToValue(aRateCode: Byte): LongInt;
begin
  case aRateCode of
    RATE_2400:   Result := 2400;
    RATE_4800:   Result := 4800;
    RATE_9600:   Result := 9600;
    RATE_14400:  Result := 14400;
    RATE_19200:  Result := 19200;
    RATE_28800:  Result := 28800;
    RATE_57600:  Result := 57600;
    RATE_115200: Result := 115200;
  else
    Result := 9600;
  end;
end;

function BaudRateToCode(aBaudRate: LongInt): Byte;
begin
  case aBaudRate of
    2400:   Result := RATE_2400;
    4800:   Result := RATE_4800;
    9600:   Result := RATE_9600;
    14400:  Result := RATE_14400;
    19200:  Result := RATE_19200;
    28800:  Result := RATE_28800;
    57600:  Result := RATE_57600;
    115200: Result := RATE_115200;
  else
    Result := RATE_9600;
  end;
end;

end.
