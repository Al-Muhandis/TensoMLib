unit frames;

{
 TensoMLib - построение и анализ фреймов для протокола Tensor-M.

  Базовый фрейм: FF [FF...] Adr COP [Данные...] [CRC] FF FF FF
  Начало фрейма — первый байт, отличный от FFh и FEh.
  Конец кадра — два последовательных байта FFh.
  FF в полезной нагрузке экранируется как FF FE (заполнение байтов).
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, core, crc8
  ;

{ Создайте фрейм (frame) для передачи.
  aAddress — сетевой адрес ($01..$9F).
  aCOP — код операции.
  aData — полезная нагрузка (может быть нулевой).
  aUseCRC — включать ли байт CRC.
  Возвращает полный кадр с разделителями и заполнением. }
function BuildFrame(aAddress, aCOP: Byte; const aData: TBytes; aUseCRC: Boolean): TBytes;

{ Потоковый (stream) сборщик кадров (конечный автомат).
  Для чтения из COM-порта байт за байтом.
  Функция Feed() возвращает значение True, когда кадр полностью собран. }
type

  TFrameCollector = class
  private
    fStarted:   Boolean;
    fPendingFF: Boolean;
    fBody:      TBytes;
    fRaw:       TBytes;
  public
    constructor Create;
    procedure Reset;
    { Передает следующий байт. Возвращает значение True, если кадр завершен }
    function Feed(B: Byte; out aBody, aRaw: TBytes): Boolean;
  end;

{ Парсит полезную нагрузку фрейма в структуру TParsedFrame.
  aBody — полезная нагрузка (адрес + COP + данные + необязательный CRC), БЕЗ разделителей.
  aRaw — необработанные байты (для отладки).
  aExpectedAddress — ожидаемый адрес (проверенный).
  aUseCRC — нужно ли проверять CRC.
    Вызывает исключение при ошибках синтаксического анализа! }
function ParseFrame(const aBody, aRaw: TBytes; aExpectedAddress: Byte; aUseCRC: Boolean): TParsedFrame;

implementation

{ --- BuildFrame --- }

function BuildFrame(aAddress, aCOP: Byte; const aData: TBytes; aUseCRC: Boolean): TBytes;
var
  aBody: TBytes = nil;
  aOutBuf: TBytes = nil;
  B: Byte;
  C: Byte;
begin;
  { Build body: Adr + COP + Data }
  SetLength(aBody, 2);
  aBody[0] := aAddress;
  aBody[1] := aCOP;
  if Length(aData) > 0 then
  begin
    SetLength(aBody, 2 + Length(aData));
    Move(aData[0], aBody[2], Length(aData));
  end;

  { Добавить CRC, если нужен — вычислить ПЕРЕД расширением массива }
  if aUseCRC then
  begin
    C := MakeCRC(aBody);
    SetLength(aBody, Length(aBody) + 1);
    aBody[High(aBody)] := C;
  end;

  SetLength(aOutBuf, 0);

  { Старт разделителя }
  SetLength(aOutBuf, 1);
  aOutBuf[0] := FRAME_DELIMITER;

  { Тело с байтовой начинкой }
  for B in aBody do
  begin
    SetLength(aOutBuf, Length(aOutBuf) + 1);
    aOutBuf[High(aOutBuf)] := B;
    if B = FRAME_DELIMITER then
    begin
      SetLength(aOutBuf, Length(aOutBuf) + 1);
      aOutBuf[High(aOutBuf)] := FRAME_STUFF_BYTE;
    end;
  end;

  { Конечные разделители: FF FF }
  SetLength(aOutBuf, Length(aOutBuf) + 2);
  aOutBuf[High(aOutBuf) - 1] := FRAME_DELIMITER;
  aOutBuf[High(aOutBuf)]     := FRAME_DELIMITER;

  Result := aOutBuf;
end;

{ --- TFrameCollector --- }

constructor TFrameCollector.Create;
begin
  inherited Create;
  SetLength(fBody, 0);
  SetLength(fRaw, 0);
  fStarted   := False;
  fPendingFF := False;
end;

procedure TFrameCollector.Reset;
begin
  fStarted   := False;
  fPendingFF := False;
  SetLength(fBody, 0);
  SetLength(fRaw, 0);
end;

function TFrameCollector.Feed(B: Byte; out aBody, aRaw: TBytes): Boolean;
begin
  aBody := nil;
  aRaw  := nil;
  Result := False;

  { Сохранить "сырые" байты }
  SetLength(fRaw, Length(fRaw) + 1);
  fRaw[High(fRaw)] := B;

  { --- Ожидание начала фрейма --- }
  if not fStarted then
  begin
    if (B = FRAME_DELIMITER) or (B = FRAME_STUFF_BYTE) then
      Exit; { пропустить ведущие FF / FE }
    fStarted := True;
    SetLength(fBody, Length(fBody) + 1);
    fBody[High(fBody)] := B;
    Exit;
  end;

  { --- Предыдущий байт был FF — проверить что последует --- }
  if fPendingFF then
  begin
    case B of
      FRAME_STUFF_BYTE:
        begin
          { FF FE — экранирование FF в данных }
          SetLength(fBody, Length(fBody) + 1);
          fBody[High(fBody)] := FRAME_DELIMITER;
          fPendingFF := False;
          Exit;
        end;
      FRAME_DELIMITER:
        begin
          { FF FF — конец фрейма }
          aBody := Copy(fBody, 0, Length(fBody));
          aRaw  := Copy(fRaw, 0, Length(fRaw));
          Reset;
          Result := True;
          Exit;
        end;
    else
      { Неверная последовательность: FF <не FE и не FF>.
        Сброс настройки и попытка запустить новый кадр/фрейм. }
      Reset;
      { Этот байт может быть началом нового кадра }
      if (B <> FRAME_DELIMITER) and (B <> FRAME_STUFF_BYTE) then
      begin
        fStarted := True;
        { Повторно сохранить в новый буфер (сброс очистил его) }
        SetLength(fRaw, 1);
        fRaw[0] := B;
        SetLength(fBody, 1);
        fBody[0] := B;
      end;
      Exit;
    end;
  end;

  { --- Обычный байт в теле --- }
  if B = FRAME_DELIMITER then
  begin
    fPendingFF := True;
  end
  else
  begin
    SetLength(fBody, Length(fBody) + 1);
    fBody[High(fBody)] := B;
  end;
end;

{ --- ParseFrame --- }

function ParseFrame(const aBody, aRaw: TBytes; aExpectedAddress: Byte; aUseCRC: Boolean): TParsedFrame;
var
  aMinLen: Integer;
  aDataEnd: Integer;
begin
  Initialize(Result);

  aMinLen := 2; { Минимум: Adr + COP }
  if aUseCRC then
    Inc(aMinLen);

  if Length(aBody) < aMinLen then
    raise Exception.Create('Frame too short');

  if aBody[0] <> aExpectedAddress then
    raise Exception.CreateFmt(
      'Response from address %d, expected %d', [aBody[0], aExpectedAddress]);

  aDataEnd := Length(aBody);
  if aUseCRC then
  begin
    if not VerifyCRC(aBody) then
      raise Exception.Create('CRC error in response');
    Dec(aDataEnd); { исключить CRC-байт из данных }
  end;

  Result.Address := aBody[0];
  Result.COP     := aBody[1];
  Result.Raw     := Copy(aRaw, 0, Length(aRaw));
  Result.CRCOK   := True;

  { Данные - это все, что находится между COP и CRC }
  if aDataEnd > 2 then
    Result.Data := Copy(aBody, 2, aDataEnd - 2)
  else
    Result.Data := nil;
end;

end.
