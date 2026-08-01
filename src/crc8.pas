unit crc8;

{
  TensoMLib — вычисление CRC-8 по протоколу Тензо-М.

  Алгоритм: полином P(X) = 101101001b, младшая часть = $69.
  Точная портировка ассемблерной реализации из документации протокола:
    ROL AL,1 / RCL AH,1 / JNC skip / XOR AH,69h.

  На передающей стороне: MakeCRC вычисляет CRC по body + нулевой байт ($00),
  возвращённый байт подставляется в кадр.

  На приёмной стороне: VerifyCRC вычисляет CRC по всему массиву, включая
  принятый байт CRC; результат 0 = кадр корректен.

}

{$mode objfpc}{$H+}

interface

uses
  SysUtils
  ;

{ Один шаг CRC-алгоритма. Порт инструкции crcUpdate }
function CRCUpdate(aInput, aCRC: Byte): Byte;

{ Вычислить CRC для массива данных.
  Добавляет завершающий нулевой байт ($00) перед финальным вычислением,
  как описано в документации протокола. }
function MakeCRC(const aData: TBytes): Byte;

{ Проверить CRC: вычисляет CRC по AData (включая байт CRC в конце).
  Возвращает True, если результат равен нулю. }
function VerifyCRC(const aDataWithCRC: TBytes): Boolean;

implementation

function CRCUpdate(aInput, aCRC: Byte): Byte;
var
  AL, AH: Byte;
  I: Integer;
  aInputCarry, aCRCCarry: Boolean;
  W: Word;
begin
  AL := aInput;
  AH := aCRC;
  for I := 0 to 7 do
  begin
    aInputCarry := (AL and $80) <> 0;
    aCRCCarry   := (AH and $80) <> 0;

    { ROL AL, 1 — через Word, чтобы избежать переполнения Byte }
    W := (Word(AL) shl 1) or (Word(AL) shr 7);
    AL := Byte(W);  { Byte() отсекает старший байт, не вызывая RangeCheck }

    { RCL AH, 1 — сдвиг + внесение бита переноса }
    W := Word(AH) shl 1;
    if aInputCarry then
      W := W or 1;
    AH := Byte(W);

    { XOR с полиномом, если был перенос из AH }
    if aCRCCarry then
      AH := AH xor $69;
  end;
  Result := AH;
end;

function MakeCRC(const aData: TBytes): Byte;
var
  B: Byte;
  C: Byte;
begin
  C := 0;
  for B in aData do
    C := CRCUpdate(B, C);
  { Завершающий нулевой байт по спецификации протокола }
  C := CRCUpdate($00, C);
  Result := C;
end;

function VerifyCRC(const aDataWithCRC: TBytes): Boolean;
var
  B: Byte;
  C: Byte;
begin
  C := 0;
  for B in aDataWithCRC do
    C := CRCUpdate(B, C);
  Result := (C = 0);
end;

end.
