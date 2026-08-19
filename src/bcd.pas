unit bcd;

{
  TensoMLib — упакованный BCD и декодирование веса.

  Протокол Тензо-М использует упакованный BCD (packed BCD):
  каждый байт содержит две десятичные цифры — старшая в старшем полубайте.
  Младшие байты передаются первыми (little-endian).
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, core
  ;

{ Декодировать массив упакованных BCD-байтов (little-endian) в целое число.
  Пример: [$05, $00, $00] → 5.  [$12, $34, $56] → 563412. }
function DecodePackedBCD(const aBytesLE: TBytes): Int64;

{ Кодировать целое число в массив упакованных BCD-байтов (little-endian).
  AByteCount — сколько байт результирующего массива (2 или 3).
  Возвращает False, если значение не помещается. }
function EncodePackedBCD(aValue: Int64; aByteCount: Integer; out aBytes: TBytes): Boolean;

{ Декодировать 4-байтовый ответ веса (W0,W1,W2,CON) из команд C2h/C3h/B8h.
  AData — payload ответа (без адреса, COP, CRC).
  Пример из документации: [$05,$00,$00,$91] → вес -0.5, стабилен. }
function DecodeWeight(const aData: TBytes): TWeightData;

implementation

uses
  tensom_errors
  ;

function DecodePackedBCD(const aBytesLE: TBytes): Int64;
var
  B: Byte;
  aLo, aHi: Byte;
  aMultiplier: Int64;
begin
  Result := 0;
  aMultiplier := 1;
  for B in aBytesLE do
  begin
    aLo := B and $0F;
    aHi := (B shr 4) and $0F;
    if (aLo > 9) or (aHi > 9) then
      raise ETensoMProtocolError.CreateFmt('Invalid BCD-byte %02X', [B]);
    Result := Result + Int64(aLo) * aMultiplier;
    aMultiplier := aMultiplier * 10;
    Result := Result + Int64(aHi) * aMultiplier;
    aMultiplier := aMultiplier * 10;
  end;
end;

function EncodePackedBCD(aValue: Int64; aByteCount: Integer; out aBytes: TBytes): Boolean;
var
  I, D: Integer;
  aAbsVal: Int64;
begin           
  aBytes := nil;
  if aValue < 0 then
    Exit(False);
  aAbsVal := aValue;

  { Проверка: максимальное значение для aByteCount байт BCD }
  case aByteCount of
    2: if aAbsVal > 9999 then Exit(False);
    3: if aAbsVal > 999999 then Exit(False);
  else
    Exit(False);
  end;

  SetLength(aBytes, aByteCount);
  for I := 0 to aByteCount - 1 do
  begin
    { Младшая цифра → младший полубайт }
    D := aAbsVal mod 10;
    aAbsVal := aAbsVal div 10;
    { Старшая цифра → старший полубайт }
    aBytes[I] := Byte(D);
    D := aAbsVal mod 10;
    aAbsVal := aAbsVal div 10;
    aBytes[I] := aBytes[I] or Byte(D shl 4);
  end;
  Result := True;
end;

function DecodeWeight(const aData: TBytes): TWeightData;
var
  aRaw: Int64;
  aCON: Byte;
  aDecimals: Integer;
  aDivisor: Double;
  I: Integer;
begin
  Initialize(Result);

  if Length(aData) <> 4 then
    raise ETensoMProtocolError.CreateFmt(
      'Expected 4 bytes of weight, received %d', [Length(aData)]);

  { Декодируем 3 байта BCD }
  aRaw := DecodePackedBCD(Copy(aData, 0, 3));

  { Байт aCON: флаги и позиция запятой }
  aCON := aData[3];
  aDecimals := aCON and $07;
  Result.DecimalPlaces := aDecimals;

  { Учёт позиции запятой: делим на 10^Decimals }
  aDivisor := 1.0;
  for I := 0 to aDecimals - 1 do
    aDivisor := aDivisor * 10.0;
  Result.Weight := aRaw / aDivisor;

  { D7 = знак минус }
  Result.Negative := (aCON and $80) <> 0;
  if Result.Negative then
    Result.Weight := -Result.Weight;

  { D4 = успокоение }
  Result.Stable := (aCON and $10) <> 0;

  { D3 = перегруз }
  Result.Overload := (aCON and $08) <> 0;
end;

end.
