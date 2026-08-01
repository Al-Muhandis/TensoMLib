unit test_crc;

{
  Юнит-тесты для crc8.pas

  Ключевое свойство: VerifyCRC(body + MakeCRC(body)) = True.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, crc8 in '../src/crc8.pas'
  ;

type
  TTestCRC = class(TTestCase)
  published
    procedure Test_CRC_EmptyArray;
    procedure Test_CRC_SingleZero;
    procedure Test_CRC_KnownVector_01C3;
    procedure Test_CRC_ResidueZero;
    procedure Test_CRC_VerifyZero;
    procedure Test_CRC_WrongCRC_Fails;
    procedure Test_CRC_Accumulation;
    procedure Test_CRC_ProtocolExample;
  end;

implementation

uses
  core in '../src/core.pas'
  ;

procedure TTestCRC.Test_CRC_EmptyArray;
var
  C: Byte;
  aAllWithCRC: TBytes = nil;
begin
  { CRC пустого массива + завершающий $00 }
  C := MakeCRC(nil);
  { Проверяем, что MakeCRC(nil) + VerifyCRC = True }
  SetLength(aAllWithCRC, 1);
  aAllWithCRC[0] := C;
  AssertTrue('VerifyCRC for empty', VerifyCRC(aAllWithCRC));
end;

procedure TTestCRC.Test_CRC_SingleZero;
var
  C: Byte;
  aArr: TBytes = nil;
begin
  { CRC одного нулевого байта: body=[$00], MakeCRC добавит ещё $00.
    По документации (стр. 2): начальное значение CRC = 0.
    При нулевом входе и нулевом начальном CRC результат всегда 0. }
  SetLength(aArr, 1);
  aArr[0] := $00;
  C := MakeCRC(aArr);
  AssertEquals('CRC of [00] = $00', $00, C);
end;

procedure TTestCRC.Test_CRC_KnownVector_01C3;
var
  aBody: TBytes = nil;
  aAll: TBytes = nil;
  C: Byte;
begin
  SetLength(aBody, 2);
  aBody[0] := $01;
  aBody[1] := $C3;

  C := MakeCRC(aBody);

  { Проверяем остаточное свойство: VerifyCRC(aBody+CRC) = 0 }
  SetLength(aAll, 3);
  aAll[0] := $01;
  aAll[1] := $C3;
  aAll[2] := C;
  AssertTrue('Residue must be zero', VerifyCRC(aAll));
end;

procedure TTestCRC.Test_CRC_ResidueZero;
var
  aBody: TBytes = nil;
  aAll: TBytes = nil;
  C: Byte;
  I: Integer;
begin
  { Для 256 различных первых байт проверяем остаточное свойство }
  for I := 0 to 255 do
  begin
    SetLength(aBody, 1);
    aBody[0] := Byte(I);
    C := MakeCRC(aBody);
    SetLength(aAll, 2);
    aAll[0] := Byte(I);
    aAll[1] := C;
    AssertTrue(Format('Residue failed for byte %02X', [I]), VerifyCRC(aAll));
  end;
end;

procedure TTestCRC.Test_CRC_VerifyZero;
var
  aBody: TBytes = nil;
  aData: TBytes = nil;
  C: Byte;
begin
  { Вектор: [$01, $C3, CRC] }
  { MakeCRC вызываем на 2-байтовом массиве, иначе aData[2]=0
    после SetLength попадёт в вычисление. }
  SetLength(aBody, 2);
  aBody[0] := $01;
  aBody[1] := $C3;
  C := MakeCRC(aBody);

  SetLength(aData, 3);
  aData[0] := $01;
  aData[1] := $C3;
  aData[2] := C;
  AssertTrue('VerifyCRC should return True', VerifyCRC(aData));
end;

procedure TTestCRC.Test_CRC_WrongCRC_Fails;
var
  aBody: TBytes = nil;
  aData: TBytes = nil;
begin
  { Искажаем CRC — проверка должна провалиться }
  SetLength(aBody, 2);
  aBody[0] := $01;
  aBody[1] := $C3;
  SetLength(aData, 3);
  aData[0] := $01;
  aData[1] := $C3;
  aData[2] := MakeCRC(aBody);
  aData[2] := aData[2] xor $FF; { искажаем }

  AssertFalse('Corrupted CRC should fail', VerifyCRC(aData));
end;

procedure TTestCRC.Test_CRC_Accumulation;
var
  C1, C2, C: Byte;
  aData: TBytes = nil;
begin
  { CRCUpdate пошагово должен совпадать с MakeCRC для всего массива }
  C1 := CRCUpdate($01, 0);
  C2 := CRCUpdate($C3, C1);
  C  := CRCUpdate($00, C2);

  { Альтернативная проверка: поэлементно }
  SetLength(aData, 2);
  aData[0] := $01;
  aData[1] := $C3;
  AssertEquals('MakeCRC via array', C, MakeCRC(aData));
end;

procedure TTestCRC.Test_CRC_ProtocolExample;
var
  aBody: TBytes = nil;
  aFrame: TBytes = nil;
  C: Byte;
begin
  { Имитация реального кадра запроса веса БРУТТО (C3h), адрес 1 }
  SetLength(aBody, 2);
  aBody[0] := $01;  { адрес }
  aBody[1] := COP_GET_BRUTTO;  { C3h }

  C := MakeCRC(aBody);

  { Кадр на проводе: FF 01 C3 [CRC] FF FF }
  SetLength(aFrame, 6);
  aFrame[0] := $FF;
  aFrame[1] := $01;
  aFrame[2] := $C3;
  aFrame[3] := C;
  aFrame[4] := $FF;
  aFrame[5] := $FF;

  { Внутренний payload для CRC-проверки: [$01, $C3, CRC] }
  AssertTrue('Real frame CRC check', VerifyCRC(Copy(aFrame, 1, 3)));
end;

initialization
  RegisterTest(TTestCRC);

end.
