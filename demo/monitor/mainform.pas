unit mainform;

{$mode objfpc}{$H+}
{$INTERFACES CORBA}
{$WARN 5024 off : Parameter "$1" not used}
interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, ComCtrls, Buttons, client,
  transport_serial, core, frames
  ;

type
  { TFrmMain }

  TFrmMain = class(TForm)
    btnConnect: TButton;
    btnDisconnect: TButton;
    btnGetSerial: TButton;
    btnGetStatus: TButton;
    btnSetAddress: TButton;
    btnGetBrutto: TButton;
    btnGetNetto: TButton;
    btnStartInit: TButton;
    btnStopInit: TButton;
    btnGetADC: TButton;
    btnClear: TButton;
    btnReadIndicators: TButton;
    btnGetInputs: TButton;
    btnGetOutputs: TButton;
    btnScanPorts: TButton;
    btnGetParam: TButton;
    btnSetParam: TButton;
    btnGetWeightPoint: TButton;
    btnSetWeightPoint: TButton;
    btnGetCalib: TButton;
    btnZeroCalib: TButton;
    btnScaleCalib: TButton;
    cbPort: TComboBox;
    cbBaudRate: TComboBox;
    edtAddress: TEdit;
    edtNewAddress: TEdit;
    edtResponse: TMemo;
    GroupBox1: TGroupBox;
    GroupBox2: TGroupBox;
    LblPort: TLabel;
    LblBaudRate: TLabel;
    LblAddress: TLabel;
    Label4: TLabel;
    Pnl: TPanel;
    Pnl2: TPanel;
    StatusBar1: TStatusBar;
    procedure btnClearClick(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
    procedure btnGetADCClick(Sender: TObject);
    procedure btnGetBruttoClick(Sender: TObject);
    procedure btnGetCalibClick(Sender: TObject);
    procedure btnGetInputsClick(Sender: TObject);
    procedure btnGetNettoClick(Sender: TObject);
    procedure btnGetOutputsClick(Sender: TObject);
    procedure btnGetParamClick(Sender: TObject);
    procedure btnGetSerialClick(Sender: TObject);
    procedure btnGetStatusClick(Sender: TObject);
    procedure btnGetWeightPointClick(Sender: TObject);
    procedure btnReadIndicatorsClick(Sender: TObject);
    procedure btnScaleCalibClick(Sender: TObject);
    procedure btnScanPortsClick(Sender: TObject);
    procedure btnSetAddressClick(Sender: TObject);
    procedure btnSetParamClick(Sender: TObject);
    procedure btnSetWeightPointClick(Sender: TObject);
    procedure btnStartInitClick(Sender: TObject);
    procedure btnStopInitClick(Sender: TObject);
    procedure btnZeroCalibClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    fTransport: TSerialTransport;
    fDevice: TTensoMDevice;
    fLogFile: TextFile;

    { Убедиться, что FDevice создан с текущим адресом из edtAddress }
    procedure EnsureDevice;

    { Низкоуровневая отправка для команд, отсутствующих в TTensoMDevice
      (A2, B1, B3, B4, D1). Использует BuildFrame/TFrameCollector/ParseFrame
      из библиотеки, но обходит фасад. }
    function SendLowLevel(aCOP: Byte; const aData: TBytes = nil): TParsedFrame;

    procedure LogMessage(const aMsg: string; aIsError: Boolean = False);
    procedure HandleFrameLog(aDirection: TFrameDirection; const aFrameHex: string);
    procedure UpdateStatus(aConnected: Boolean);
    function GetAddressFromEdit: Byte;
    function GetBaudRate: LongInt;
    procedure InitPorts;

    { Локальные форматировщики (в библиотеке их нет — они относятся к UI) }
    function ParseStatus(aStatus: Byte): string;
    function ParseIndicatorFlags(aFlags: Byte): string;
  public
  end;

var
  FrmMain: TFrmMain;

implementation

{$R *.lfm}

{ TFrmMain }

{ ============================================================================ }
{  Инициализация / завершение                                                }
{ ============================================================================ }

procedure TFrmMain.FormCreate(Sender: TObject);
begin
  { Порт и скорость }
  InitPorts;

  cbBaudRate.Items.Text :=
    '2400'#13#10'4800'#13#10'9600'#13#10'14400'#13#10 +
    '19200'#13#10'28800'#13#10'38400'#13#10'57600'#13#10'115200';
  cbBaudRate.ItemIndex := 2;  { 9600 по умолчанию }

  edtAddress.Text    := '01';
  edtNewAddress.Text := '02';

  UpdateStatus(False);

  { Лог-файл }
  AssignFile(fLogFile, 'tenso_log.txt');
  {$I-}
  Append(fLogFile);
  if IOResult <> 0 then
    Rewrite(fLogFile);
  {$I+}

  LogMessage('=== Tenso-M Protocol Monitor (TensoMLib) ===');
  LogMessage('Библиотека: tensom_rt');
end;

procedure TFrmMain.FormDestroy(Sender: TObject);
begin
  FreeAndNil(fDevice);
  FreeAndNil(fTransport);
  CloseFile(fLogFile);
end;

{ ============================================================================ }
{  Вспомогательные методы                                                    }
{ ============================================================================ }

procedure TFrmMain.InitPorts;
var
  aPorts: TStringArray;
  I: Integer;
begin
  cbPort.Items.Clear;
  aPorts := ScanSerialPorts;
  for I := 0 to High(aPorts) do
    cbPort.Items.Add(aPorts[I]);
  { Резервный вариант, если ScanSerialPorts ничего не нашёл }
  if cbPort.Items.Count = 0 then
  begin
    {$IFDEF MSWINDOWS}
    cbPort.Items.Add('COM1');
    {$ELSE}
    cbPort.Items.Add('/dev/ttyUSB0');
    cbPort.Items.Add('/dev/ttyS0');
    {$ENDIF}
  end;
  cbPort.ItemIndex := 0;
end;

function TFrmMain.GetBaudRate: LongInt;
begin
  case cbBaudRate.ItemIndex of
    0: Result := 2400;
    1: Result := 4800;
    2: Result := 9600;
    3: Result := 14400;
    4: Result := 19200;
    5: Result := 28800;
    6: Result := 38400;
    7: Result := 57600;
    8: Result := 115200;
  else
    Result := 9600;
  end;
end;

function TFrmMain.GetAddressFromEdit: Byte;
var
  aAddr: Integer;
begin
  try
    aAddr := StrToInt('$' + edtAddress.Text);
    if (aAddr < 1) or (aAddr > 159) then
      aAddr := 1;
    Result := aAddr;
  except
    Result := 1;
  end;
end;

procedure TFrmMain.EnsureDevice;
var
  aAddr: Byte;
begin
  if not Assigned(fTransport) or not fTransport.IsConnected then
    raise Exception.Create('Сначала подключитесь к устройству');

  aAddr := GetAddressFromEdit;
  { Пересоздаём fDevice, если адрес изменился или объект ещё не существует }
  if not Assigned(fDevice) or (fDevice.Address <> aAddr) then
  begin
    FreeAndNil(fDevice);
    fDevice := TTensoMDevice.Create(fTransport, aAddr, True);
    fDevice.OnFrameLog    := @HandleFrameLog;
    fDevice.ResponseTimeout := 1000;
  end;
end;

function TFrmMain.SendLowLevel(aCOP: Byte; const aData: TBytes): TParsedFrame;
var
  aReqFrame, aRawResp: TBytes;
  aCollector: TFrameCollector;
  J: Integer;
  aBody, aRaw: TBytes;
  aComplete: Boolean;
  T0: QWord;
begin
  Initialize(Result);

  if not Assigned(fTransport) or not fTransport.IsConnected then
    raise Exception.Create('Сначала подключитесь к устройству');

  EnsureDevice;

  { 1. Формируем кадр библиотечной функцией }
  aReqFrame := BuildFrame(fDevice.Address, aCOP, aData, fDevice.UseCRC);
  LogMessage('>> ' + HexBytes(aReqFrame));

  { 2. Отправляем через транспорт }
  fTransport.Flush;
  fTransport.Send(aReqFrame);

  { 3. Собираем ответ через TFrameCollector }
  aCollector := TFrameCollector.Create;
  try
    T0 := GetTickCount64;
    while (GetTickCount64 - T0) < Cardinal(fDevice.ResponseTimeout) do
    begin
      aRawResp := fTransport.Receive(50);
      if Length(aRawResp) = 0 then
        Continue;
      for J := 0 to High(aRawResp) do
      begin
        aComplete := aCollector.Feed(aRawResp[J], aBody, aRaw);
        if not aComplete then
          Continue;
        LogMessage('<< ' + HexBytes(aRaw));
        { 4. Парсим библиотечной функцией }
        Result := ParseFrame(aBody, aRaw, fDevice.Address, fDevice.UseCRC);
        Exit;
      end;
    end;
    raise Exception.Create('Таймаут ответа устройства');
  finally
    aCollector.Free;
  end;
end;

{ --- Логирование --- }

procedure TFrmMain.LogMessage(const aMsg: string; aIsError: Boolean);
begin
  if aIsError then
    edtResponse.Lines.Add('[ОШИБКА] ' + aMsg)
  else
    edtResponse.Lines.Add(aMsg);
  edtResponse.SelStart  := Length(edtResponse.Text);
  edtResponse.SelLength := 0;

  { Файл }
  WriteLn(fLogFile, DateTimeToStr(Now) + ': ' + aMsg);
  Flush(fLogFile);
end;

procedure TFrmMain.HandleFrameLog(aDirection: TFrameDirection; const aFrameHex: string);
var
  aPrefix: string;
begin
  if aDirection = fdSend then
    aPrefix := '>> '
  else
    aPrefix := '<< ';

  edtResponse.Lines.Add(aPrefix + aFrameHex);
  edtResponse.SelStart := Length(edtResponse.Text);

  WriteLn(fLogFile, DateTimeToStr(Now) + ': ' + aPrefix + aFrameHex);
  Flush(fLogFile);
end;

{ --- Статус --- }

procedure TFrmMain.UpdateStatus(aConnected: Boolean);
begin
  if aConnected then
  begin
    StatusBar1.Panels[0].Text := cbPort.Text;
    StatusBar1.Panels[1].Text := 'Скорость: ' + cbBaudRate.Text;
    StatusBar1.Panels[2].Text := 'Адрес: ' + edtAddress.Text;
    btnConnect.Enabled    := False;
    btnDisconnect.Enabled := True;
  end
  else
  begin
    StatusBar1.Panels[0].Text := 'Отключено';
    StatusBar1.Panels[1].Text := '';
    StatusBar1.Panels[2].Text := '';
    btnConnect.Enabled    := True;
    btnDisconnect.Enabled := False;
  end;
end;

{ --- Локальные форматировщики --- }

function TFrmMain.ParseStatus(aStatus: Byte): string;
begin
  Result := '';
  if (aStatus and $80) <> 0 then Result := Result + 'Перезапуск, ';
  if (aStatus and $40) <> 0 then Result := Result + 'Ошибка, ';
  if (aStatus and $20) <> 0 then Result := Result + 'НЕТТО, ';
  if (aStatus and $10) <> 0 then Result := Result + 'Клавиша нажата, ';
  if (aStatus and $08) <> 0 then Result := Result + 'Конец дозирования, ';
  if (aStatus and $04) <> 0 then Result := Result + 'Фиксация веса, ';
  if (aStatus and $02) <> 0 then Result := Result + 'Калибровка АЦП, ';
  if (aStatus and $01) <> 0 then Result := Result + 'Дозирование';
  if Result = '' then
    Result := 'Нет активных состояний';
end;

function TFrmMain.ParseIndicatorFlags(aFlags: Byte): string;
begin
  Result := '';
  if (aFlags and $01) <> 0 then Result := Result + 'Фикс, ';
  if (aFlags and $02) <> 0 then Result := Result + 'Нетто, ';
  if (aFlags and $04) <> 0 then Result := Result + 'Брутто, ';
  if (aFlags and $08) <> 0 then Result := Result + 'Ноль';
  if Result = '' then
    Result := 'Нет флагов';
end;

{ ============================================================================ }
{  Подключение / отключение                                                  }
{ ============================================================================ }

procedure TFrmMain.btnConnectClick(Sender: TObject);
begin
  FreeAndNil(fDevice);
  FreeAndNil(fTransport);

  fTransport := TSerialTransport.Create;
  if not fTransport.Connect(cbPort.Text, GetBaudRate) then
  begin
    LogMessage('Ошибка подключения: ' + fTransport.GetLastErrorMessage, True);
    FreeAndNil(fTransport);
    Exit;
  end;

  EnsureDevice;
  UpdateStatus(True);
  LogMessage('Подключено к ' + cbPort.Text + ' на скорости ' + cbBaudRate.Text +
    ', адрес ' + edtAddress.Text);
end;

procedure TFrmMain.btnDisconnectClick(Sender: TObject);
begin
  FreeAndNil(fDevice);
  if Assigned(fTransport) then
    fTransport.Disconnect;
  FreeAndNil(fTransport);
  UpdateStatus(False);
  LogMessage('Отключено');
end;

procedure TFrmMain.btnScanPortsClick(Sender: TObject);
begin
  InitPorts;
  LogMessage('Порты обновлены. Найдено: ' + IntToStr(cbPort.Items.Count));
end;

procedure TFrmMain.btnClearClick(Sender: TObject);
begin
  edtResponse.Clear;
end;

{ ============================================================================ }
{  Команды через TTensoMDevice (высокоуровневый API)                        }
{ ============================================================================ }

procedure TFrmMain.btnGetSerialClick(Sender: TObject);
var
  aSN: Cardinal;
begin
  try
    EnsureDevice;
    aSN := fDevice.GetSerialNumber;
    LogMessage('Серийный номер: ' + IntToHex(aSN, 6));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetStatusClick(Sender: TObject);
var
  aStatus: Byte;
begin
  try
    EnsureDevice;
    aStatus := fDevice.GetSystemStatus;
    LogMessage('Состояние (BFh): ' + IntToHex(aStatus, 2) + ' — ' + ParseStatus(aStatus));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnSetAddressClick(Sender: TObject);
var
  aNewAddr: Integer;
begin
  try
    aNewAddr := StrToInt('$' + edtNewAddress.Text);
    if (aNewAddr < 1) or (aNewAddr > 159) then
    begin
      LogMessage('Адрес должен быть в диапазоне 01h..9Fh', True);
      Exit;
    end;
    EnsureDevice;
    fDevice.SetNetworkAddress(Byte(aNewAddr));
    LogMessage('Адрес установлен: ' + IntToHex(aNewAddr, 2));
    edtAddress.Text := IntToHex(aNewAddr, 2);
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetBruttoClick(Sender: TObject);
var
  W: TWeightData;
begin
  try
    EnsureDevice;
    W := fDevice.GetBruttoWeight;
    LogMessage(Format('БРУТТО: %s  [стабилен: %s, перегруз: %s, минус: %s, запятая: %d]',
      [FloatToStrF(W.Weight, ffFixed, 15, W.DecimalPlaces),
       specialize IfThen<String>(W.Stable, 'Да', 'Нет'),
       specialize IfThen<String>(W.Overload, 'Да', 'Нет'),
       specialize IfThen<String>(W.Negative, 'Да', 'Нет'),
       W.DecimalPlaces]));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetNettoClick(Sender: TObject);
var
  W: TWeightData;
begin
  try
    EnsureDevice;
    W := fDevice.GetNettoWeight;
    LogMessage(Format('НЕТТО: %s  [стабилен: %s, перегруз: %s, минус: %s, запятая: %d]',
      [FloatToStrF(W.Weight, ffFixed, 15, W.DecimalPlaces),
       specialize IfThen<String>(W.Stable, 'Да', 'Нет'),
       specialize IfThen<String>(W.Overload, 'Да', 'Нет'),
       specialize IfThen<String>(W.Negative, 'Да', 'Нет'),
       W.DecimalPlaces]));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetADCClick(Sender: TObject);
var
  aData: TBytes;
begin
  try
    EnsureDevice;
    aData := fDevice.GetADCCode;
    LogMessage('Код АЦП (CCh): ' + HexBytes(aData));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetInputsClick(Sender: TObject);
var
  aData: TBytes;
begin
  try
    EnsureDevice;
    aData := fDevice.GetDiscreteInputs;
    LogMessage('Дискретные входы (C4h): ' + HexBytes(aData));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetOutputsClick(Sender: TObject);
var
  aData: TBytes;
begin
  try
    EnsureDevice;
    aData := fDevice.GetDiscreteOutputs;
    LogMessage('Дискретные выходы (C5h): ' + HexBytes(aData));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnReadIndicatorsClick(Sender: TObject);
var
  aDispText: string;
  aFlags: Byte;
begin
  try
    EnsureDevice;
    fDevice.GetIndicators(aDispText, aFlags);
    LogMessage('Индикация (C6h): ' + aDispText);
    LogMessage('Флаги: ' + IntToHex(aFlags, 2) + ' — ' + ParseIndicatorFlags(aFlags));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetCalibClick(Sender: TObject);
var
  aData: TBytes;
begin
  try
    EnsureDevice;
    aData := fDevice.GetCalibrationParams;
    LogMessage('Параметры калибровки (CBh): ' + HexBytes(aData));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnStartInitClick(Sender: TObject);
begin
  try
    EnsureDevice;
    fDevice.StartInitTransmit(COP_GET_BRUTTO);
    LogMessage('Инициативная передача запущена (CEh, COP=C3h)');
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnStopInitClick(Sender: TObject);
begin
  try
    EnsureDevice;
    fDevice.StopInitTransmit;
    LogMessage('Инициативная передача остановлена (CFh)');
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

{ ============================================================================ }
{  Команды через низкоуровневый API TensoMLib                                }
{  (A2h — выполнение процедур, B1h/B3h/B4h/D1h — нет метода в TTensoMDevice)    }
{  Используются: BuildFrame, TFrameCollector, ParseFrame из frames.pas           }
{ ============================================================================ }

procedure TFrmMain.btnZeroCalibClick(Sender: TObject);
var
  aData: TBytes = nil;
  aPF: TParsedFrame;
begin
  try
    SetLength(aData, 1);
    aData[0] := PROC_CALIB_ZERO;
    aPF := SendLowLevel(COP_RUN_PROCEDURE, aData);
    LogMessage('Калибровка нуля (A2h, код $20): команда выполнена');
    { Разбор ответа (прибор может вернуть EEh) }
    if (aPF.COP = COP_ERROR) and (Length(aPF.Data) > 0) then
      LogMessage('Прибор: ' + ErrorDescription(aPF.Data[0]), True);
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnScaleCalibClick(Sender: TObject);
var
  aData: TBytes = nil;
  aPF: TParsedFrame;
begin
  try
    SetLength(aData, 1);
    aData[0] := PROC_CALIB_SCALE;
    aPF := SendLowLevel(COP_RUN_PROCEDURE, aData);
    LogMessage('Калибровка шкалы (A2h, код $21): команда выполнена');
    if (aPF.COP = COP_ERROR) and (Length(aPF.Data) > 0) then
      LogMessage('Прибор: ' + ErrorDescription(aPF.Data[0]), True);
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetWeightPointClick(Sender: TObject);
var
  aData: TBytes = nil;
  aPF: TParsedFrame;
begin
  try
    SetLength(aData, 1);
    aData[0] := 1;  { Номер весовой точки }
    aPF := SendLowLevel(COP_GET_WEIGHT_POINTS, aData);
    LogMessage('Весовая точка (B1h): ' + HexBytes(aPF.Data));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnSetWeightPointClick(Sender: TObject);
var
  aData: TBytes = nil;
  I: Integer;
begin
  try
    SetLength(aData, 8);
    for I := 0 to 7 do
      aData[I] := 0;
    aData[0] := 1;  { Номер точки }
    aData[1] := $00; aData[2] := $00; aData[3] := $00;  { Нижний уровень }
    aData[4] := $00; aData[5] := $00; aData[6] := $64;  { Верхний уровень (100) }
    aData[7] := $00;
    SendLowLevel(COP_SET_WEIGHT_POINT, aData);
    LogMessage('Весовая точка установлена (D1h)');
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnGetParamClick(Sender: TObject);
var
  aPF: TParsedFrame;
begin
  try
    aPF := SendLowLevel(COP_GET_SPECIAL_PAR);
    LogMessage('Спец. параметры (B3h): ' + HexBytes(aPF.Data));
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

procedure TFrmMain.btnSetParamClick(Sender: TObject);
var
  aData: TBytes = nil;
  I: Integer;
begin
  try
    SetLength(aData, 15);
    for I := 0 to 14 do
      aData[I] := 0;
    aData[0] := $00; aData[1] := $00; aData[2] := $01;  { Доза 100 (BCD) }
    SendLowLevel(COP_SET_SPECIAL_PAR, aData);
    LogMessage('Спец. параметры установлены (B4h)');
  except
    on E: Exception do
      LogMessage(E.Message, True);
  end;
end;

end.
