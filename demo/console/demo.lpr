program demo;

{
  Пример использования TensoMLib — подключение к весам,
  чтение серийного номера и веса БРУТТО, тарирование.

  Сборка (из корня TensoMLib/):
    Linux:   fpc -MObjFPC -Sh -FUsrc demo/console/demo.lpr
    Windows: fpc -MObjFPC -Sh -FUsrc demo/console/demo.lpr

  Для сборки с реальным COM-портом требуется Lazarus + LazSerial.
  Демонстрация работает и с TMockTransport (см. закомментированный блок).
}

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, core, frames, transport, client, transport_serial{$IFDEF MSWINDOWS}, windows{$ENDIF}
  ;

const
  {$IFDEF MSWINDOWS}
  DEFAULT_PORT = 'COM3';
  {$ELSE}
  DEFAULT_PORT = '/dev/ttyUSB0';
  {$ENDIF}
  MOCK_PORT   = 'mock';

var
  aDev: TTensoMDevice;
  aTrans: TSerialTransport;
  aMock: TMockTransport;
  W: TWeightData;
  aSN: Cardinal;
  aMaxW, aDiv_: Double;
  aDecimals: Integer;
  aMode: string;
  aADCFreq, aFilt, aVSEN: Byte;
  aData: TBytes = nil;
  aRespFrame: TBytes;
  aPorts: TStringArray;
  I: Integer;
begin
  WriteLn('=== TensoMLib Demo ===');
  WriteLn('Platform: ', {$I %FPCTARGETOS%}, ' ', {$I %FPCTARGETCPU%});
  WriteLn;

  { --- Список доступных портов --- }
  Write('Available serial ports: ');
  aPorts := ScanSerialPorts;
  if Length(aPorts) = 0 then
    WriteLn('none found')
  else
  begin
    for I := 0 to High(aPorts) do
    begin
      if I > 0 then Write(', ');
      Write(aPorts[I]);
    end;
    WriteLn;
  end;
  WriteLn;

  { --- Попытка реального подключения --- }
  aTrans := TSerialTransport.Create;
  try
    Write('Connecting to ', DEFAULT_PORT, '... ');
    if not aTrans.Connect(DEFAULT_PORT, 9600) then
    begin
      WriteLn('ERROR: ', aTrans.GetLastErrorMessage);
      WriteLn('Falling back to Mock-transport.');
      WriteLn;
    end
    else
    begin
      WriteLn('OK');
      aDev := TTensoMDevice.Create(aTrans, $01, True);
      try
        { --- Автоопределение CRC --- }
        Write('Autodetection of CRC... ');
        try
          aDev.AutoDetectCRC;
          if aDev.UseCRC then
            WriteLn('CRC turned on')
          else
            WriteLn('CRC turned off');
        except
          on E: Exception do
            WriteLn('failed: ', E.Message);
        end;

        { --- Серийный номер --- }
        Write('serial number: ');
        try
          aSN := aDev.GetSerialNumber;
          WriteLn(aSN);
        except
          on E: Exception do
            WriteLn('error: ', E.Message);
        end;

        { --- Конфигурация --- }
        Write('Configuration... ');
        try
          aDev.GetDeviceConfig(aMaxW, aDiv_, aDecimals, aMode, aADCFreq, aVSEN, aFilt);
          WriteLn('OK');
          WriteLn(Format('  Max. w: %.*f', [aDecimals, aMaxW]));
          WriteLn(Format('  Div.: %.*f', [aDecimals, aDiv_]));
          WriteLn('  Decimals: ', aDecimals);
          WriteLn('  Mode: ', aMode);
        except
          on E: Exception do
            WriteLn('error: ', E.Message);
        end;

        { --- 5 чтений веса --- }
        WriteLn;
        WriteLn('Read weight (5 iterations):');
        for aDecimals := 1 to 5 do
        begin
          try
            W := aDev.GetBruttoWeight;
            if W.Stable then
              Write('  [STAB] ')
            else
              Write('  [~~]   ');
            Write(Format('%f kg', [W.Weight]));
            if W.Negative then Write(' minus');
            if W.Overload then Write(' OVERLOAD');
            WriteLn;
          except
            on E: Exception do
              WriteLn('  error: ', E.Message);
          end;
          Sleep(250);
        end;

        WriteLn('Request: ', aDev.LastRequestHex);
        WriteLn('Response:  ', aDev.LastResponseHex);
      finally
        aDev.Free;
      end;
      aTrans.Disconnect;
      WriteLn('Turned off.');
      Exit;
    end;
  finally
    aTrans.Free;
  end;

  { --- Мок-демонстрация (без железа) --- }
  aMock := TMockTransport.Create;
  aMock.Connect(MOCK_PORT, 9600);
  aDev := TTensoMDevice.Create(aMock, $01, True);
  try
    { Вес 123.4 стабильно (BCD 123400 LE = [$00, $34, $12], CON=0x11) }
    SetLength(aData, 4);
    aData[0] := $00; aData[1] := $34; aData[2] := $12; aData[3] := $11;
    aRespFrame := BuildFrame($01, COP_GET_BRUTTO, aData, True);
    aMock.QueueResponse(aRespFrame);

    W := aDev.GetBruttoWeight;
    WriteLn(Format('Weight (mock): %f kg, stability=%s',
      [W.Weight, BoolToStr(W.Stable, 'yes', 'no')]));
    WriteLn('Sent: ', aMock.GetAllSentHex);
  finally
    aDev.Free;
    aMock.Free;
  end;
end.
