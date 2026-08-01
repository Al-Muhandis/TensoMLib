unit test_bcd;

{
  Unit-tests for bcd.pas

  Key test from docs: [$05, $00, $00, $91] -> weight -0.5 kg, stable.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, bcd in '../src/bcd.pas'
  ;

type
  TTestBCD = class(TTestCase)
  published
    procedure Test_BCD_DecodeZero;
    procedure Test_BCD_Decode123456;
    procedure Test_BCD_Decode000005;
    procedure Test_BCD_EncodeZero;
    procedure Test_BCD_Encode123456;
    procedure Test_BCD_Roundtrip_3byte;
    procedure Test_BCD_Roundtrip_2byte;
    procedure Test_BCD_InvalidNibble;
    procedure Test_Weight_DocExample;
    procedure Test_Weight_PositiveStable;
    procedure Test_Weight_NoDecimals;
    procedure Test_Weight_Overload;
    procedure Test_Weight_TooShort;
end;

implementation

uses
  core in '../src/core.pas'
  ;

procedure TTestBCD.Test_BCD_DecodeZero;
var
  V: Int64;
  aArr: TBytes = nil;
begin
  SetLength(aArr, 3);
  aArr[0] := $00; aArr[1] := $00; aArr[2] := $00;
  V := DecodePackedBCD(aArr);
  AssertEquals('Zero BCD', 0, V);
end;

procedure TTestBCD.Test_BCD_Decode123456;
var
  V: Int64;
  aArr: TBytes = nil;
begin
  { 123456 in LE BCD: least significant digits 56 -> byte[0], most significant 12 -> byte[2] }
  SetLength(aArr, 3);
  aArr[0] := $56; aArr[1] := $34; aArr[2] := $12;
  V := DecodePackedBCD(aArr);
  AssertEquals('123456 BCD', 123456, V);
end;

procedure TTestBCD.Test_BCD_Decode000005;
var
  V: Int64;
  aArr: TBytes = nil;
begin
  { $05 $00 $00 -> 5 }
  SetLength(aArr, 3);
  aArr[0] := $05; aArr[1] := $00; aArr[2] := $00;
  V := DecodePackedBCD(aArr);
  AssertEquals('5 BCD', 5, V);
end;

procedure TTestBCD.Test_BCD_EncodeZero;
var
  aArr: TBytes = nil;
  aExpected: TBytes = nil;
  aOK: Boolean;
begin
  aOK := EncodePackedBCD(0, 3, aArr);
  AssertTrue('Encode 0', aOK);
  SetLength(aExpected, 3);
  aExpected[0] := $00; aExpected[1] := $00; aExpected[2] := $00;
  AssertEquals('Encode 0 byte 0', aExpected[0], aArr[0]);
  AssertEquals('Encode 0 byte 1', aExpected[1], aArr[1]);
  AssertEquals('Encode 0 byte 2', aExpected[2], aArr[2]);
end;

procedure TTestBCD.Test_BCD_Encode123456;
var
  aArr: TBytes;
  aOK: Boolean;
begin
  { 123456 -> LE: [$56, $34, $12] }
  aOK := EncodePackedBCD(123456, 3, aArr);
  AssertTrue('Encode 123456', aOK);
  AssertEquals('byte 0', $56, aArr[0]);
  AssertEquals('byte 1', $34, aArr[1]);
  AssertEquals('byte 2', $12, aArr[2]);
end;

procedure TTestBCD.Test_BCD_Roundtrip_3byte;
var
  aValues: array[0..5] of Int64 = (0, 1, 5, 123, 123456, 999999);
  aArr: TBytes;
  aOK: Boolean;
  aDecoded: Int64;
  I: Integer;
begin
  for I := Low(aValues) to High(aValues) do
  begin
    aOK := EncodePackedBCD(aValues[I], 3, aArr);
    AssertTrue(Format('Encode %d', [aValues[I]]), aOK);
    aDecoded := DecodePackedBCD(aArr);
    AssertEquals(Format('Roundtrip %d', [aValues[I]]), aValues[I], aDecoded);
  end;
end;

procedure TTestBCD.Test_BCD_Roundtrip_2byte;
var
  aValues: array[0..4] of Int64 = (0, 1, 99, 1234, 9999);
  aArr: TBytes;
  aOK: Boolean;
  aDecoded: Int64;
  I: Integer;
begin
  for I := Low(aValues) to High(aValues) do
  begin
    aOK := EncodePackedBCD(aValues[I], 2, aArr);
    AssertTrue(Format('Encode2 %d', [aValues[I]]), aOK);
    aDecoded := DecodePackedBCD(aArr);
    AssertEquals(Format('Roundtrip2 %d', [aValues[I]]), aValues[I], aDecoded);
  end;
end;

procedure TTestBCD.Test_BCD_InvalidNibble;
var
  aArr: TBytes = nil;
  aRaised: Boolean;
begin
  SetLength(aArr, 1);
  aArr[0] := $FA; { nibble A = 10 - invalid }
  aRaised := False;
  try
    DecodePackedBCD(aArr);
  except
    on E: Exception do
      aRaised := True;
  end;
  AssertTrue('Should raise on invalid BCD nibble', aRaised);
end;

procedure TTestBCD.Test_Weight_DocExample;
var
  aData: TBytes = nil;
  W: TWeightData;
begin
  { Example from docs: 05, 00, 00, 91
    -> weight -0.5 kg, stable }
  SetLength(aData, 4);
  aData[0] := $05; aData[1] := $00; aData[2] := $00; aData[3] := $91;

  W := DecodeWeight(aData);

  AssertEquals('Weight value', -0.5, W.Weight, 1e-9);
  AssertTrue('Stable', W.Stable);
  AssertFalse('Overload', W.Overload);
  AssertTrue('Negative', W.Negative);
  AssertEquals('DecimalPlaces', 1, W.DecimalPlaces);
end;

procedure TTestBCD.Test_Weight_PositiveStable;
var
  aData: TBytes = nil;
  W: TWeightData;
begin
  { Weight 123.4 kg, stable, positive
    BCD 1234 -> LE [$34, $12, $00]
    CON: Stable=1 (D4), DecimalPos=1 (D0-D1) -> 0x11 }
  SetLength(aData, 4);
  aData[0] := $34; aData[1] := $12; aData[2] := $00; aData[3] := $11;

  W := DecodeWeight(aData);

  AssertEquals('Weight 123.4', 123.4, W.Weight, 1e-9);
  AssertTrue('Stable', W.Stable);
  AssertFalse('Negative', W.Negative);
  AssertFalse('Overload', W.Overload);
  AssertEquals('DecimalPlaces', 1, W.DecimalPlaces);
end;

procedure TTestBCD.Test_Weight_NoDecimals;
var
  aData: TBytes = nil;
  W: TWeightData;
begin
  { Weight 50 kg, no decimals, stable
    BCD 50 -> [$50, $00, $00]
    CON: Stable=1 (D4), DecimalPos=0 -> 0x10 }
  SetLength(aData, 4);
  aData[0] := $50; aData[1] := $00; aData[2] := $00; aData[3] := $10;

  W := DecodeWeight(aData);

  AssertEquals('Weight 50', 50.0, W.Weight, 1e-9);
  AssertTrue('Stable', W.Stable);
  AssertEquals('DecimalPlaces', 0, W.DecimalPlaces);
end;

procedure TTestBCD.Test_Weight_Overload;
var
  aData: TBytes = nil;
  W: TWeightData;
begin
  { Overload: D3=1, D4=0 (unstable), DecimalPos=0
    CON = $08 (D7=0, D4=0, D3=1) }
  SetLength(aData, 4);
  aData[0] := $99; aData[1] := $99; aData[2] := $99; aData[3] := $08;

  W := DecodeWeight(aData);

  AssertTrue('Overload', W.Overload);
  AssertFalse('Stable', W.Stable);
  AssertFalse('Negative', W.Negative);
end;

procedure TTestBCD.Test_Weight_TooShort;
var
  aData: TBytes = nil;
  aRaised: Boolean;
begin
  SetLength(aData, 2);
  aData[0] := $05; aData[1] := $00;
  aRaised := False;
  try
    DecodeWeight(aData);
  except
    on E: Exception do
      aRaised := True;
  end;
  AssertTrue('Should raise on too short data', aRaised);
end;

initialization
  RegisterTest(TTestBCD);

end.
