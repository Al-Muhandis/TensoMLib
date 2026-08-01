unit core;

{
  TensoMLib — ядро: типы, константы и перечисления протокола Тензо-М.

  Протокол Тензо-М: RS-232, 8N1, 2400..115200 бод.
  Структура кадра: FF [FF...] Adr COP [Data...] [CRC] FF FF
  Байт-стаффинг: FF в payload → FF FE.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils
  ;

const
  { Разделители кадра }
  FRAME_DELIMITER  = $FF;
  FRAME_STUFF_BYTE = $FE;
  FRAME_MAX_LEN    = 255;  { макс. длина payload без разделителей и stuff-байтов }

  { CRC-8: полином P(X)=101101001b, младшая часть = $69 }
  CRC_POLYNOMIAL = $69;

  { Коды операций (COP) }
  COP_SET_ADDRESS       = $A0;
  COP_GET_SERIAL        = $A1;
  COP_RUN_PROCEDURE     = $A2;
  COP_GET_WEIGHT_POINTS = $B1;
  COP_GET_SPECIAL_PAR   = $B3;
  COP_SET_SPECIAL_PAR   = $B4;
  COP_WRITE_T_NKP       = $B5;
  COP_WRITE_T_RKP       = $B6;
  COP_WRITE_LINEAR      = $B7;
  COP_GET_FIXED_BRUTTO  = $B8;
  COP_GET_STATUS        = $BF;
  COP_ZERO              = $C0;
  COP_GET_SETTINGS      = $C1;
  COP_GET_NETTO         = $C2;
  COP_GET_BRUTTO        = $C3;
  COP_GET_DISC_IN       = $C4;
  COP_GET_DISC_OUT      = $C5;
  COP_GET_DISPLAY       = $C6;
  COP_GET_PRODUCT_CODE  = $C7;
  COP_GET_COUNTER       = $C8;
  COP_GET_LAST_KEY      = $C9;
  COP_GET_COMPLEX       = $CA;
  COP_GET_CALIB_PARAMS  = $CB;
  COP_GET_ADC_CODE      = $CC;
  COP_SET_DISPLAY_MODE  = $CD;
  COP_START_INIT_SEND   = $CE;
  COP_STOP_INIT_SEND    = $CF;
  COP_SET_DISC_OUT      = $D0;
  COP_SET_WEIGHT_POINT  = $D1;
  COP_DISPLAY_MSG       = $D2;
  COP_STORE_MSG         = $D3;
  COP_SET_INPUT_RANGE   = $D8;
  COP_SET_ADC_FREQ      = $D9;
  COP_SET_FILTER        = $DA;
  COP_SET_BAUD          = $DB;
  COP_SET_ADC_CHANNEL   = $DC;
  COP_DOSING_CTRL       = $DF;
  COP_READ_T_NKP        = $E5;
  COP_READ_T_RKP        = $E6;
  COP_READ_LINEAR       = $E7;
  COP_ERROR             = $EE;
  COP_GET_PROC_STATUS   = $EF;
  COP_UNSUPPORTED       = $FD;

  { Коды ошибок прибора (NER) }
  ERR_GENERAL       = $01;
  ERR_GENERAL2      = $02;
  ERR_ZERO_RANGE    = $03;
  ERR_PARAMS_LOCKED = $04;
  ERR_FRAME_LEN     = $05;
  ERR_CRC           = $06;
  ERR_CALIB_ZERO    = $20;
  ERR_CALIB_SCALE   = $21;

  { Коды процедур калибровки }
  PROC_CALIB_ZERO  = $20;
  PROC_CALIB_SCALE = $21;
  PROC_CALIB_BOTH  = $22;

  { Команды дозирования }
  DOS_STOP   = $00;
  DOS_START  = $01;
  DOS_PAUSE  = $02;
  DOS_RESUME = $03;

  { Скорости обмена (байт RATE) }
  RATE_2400   = $01;
  RATE_4800   = $02;
  RATE_9600   = $03;
  RATE_14400  = $04;
  RATE_19200  = $05;
  RATE_28800  = $06;
  RATE_57600  = $07;
  RATE_115200 = $08;

type
  { Данные веса, возвращаемые командами C2h/C3h/B8h }
  TWeightData = record
    Weight:        Double;   { значение веса с учётом знака и позиции запятой }
    Stable:        Boolean;  { D4 байта CON = 1: вес успокоился }
    Overload:      Boolean;  { D3 байта CON = 1: перегруз }
    Negative:      Boolean;  { D7 байта CON = 1: минус }
    DecimalPlaces: Integer;  { D0-D2 байта CON: позиция запятой (0..3) }
  end;

  { Разобранный кадр ответа }
  TParsedFrame = record
    Address: Byte;
    COP:     Byte;
    Data:    TBytes;
    CRCOK:   Boolean;
    Raw:     TBytes;    { сырые байты кадра (с разделителями и stuff) }
  end;

  { Информация об ошибке прибора (ответ EEh) }
  TErrorInfo = record
    ErrorCode: Byte;
    ErrorMsg:  string;
  end;

{ Вспомогательная функция: форматирование массива байт как hex-строки }
function HexBytes(const aBytes: TBytes): string;

{ Определение кода ошибки по байту NER }
function ErrorDescription(aNER: Byte): string;

implementation

function HexBytes(const aBytes: TBytes): string;
var
  I: Integer;
begin
  Result := EmptyStr;
  for I := 0 to High(aBytes) do
  begin
    if I > 0 then
      Result += ' ';
    Result += LowerCase(IntToHex(aBytes[I], 2));
  end;
end;

function ErrorDescription(aNER: Byte): string;
begin
  case aNER of
    ERR_GENERAL:       Result := 'Error #1';
    ERR_GENERAL2:      Result := 'Error #2';
    ERR_ZERO_RANGE:    Result := 'Error zero range';
    ERR_PARAMS_LOCKED: Result := 'Error parameters changing is locked';
    ERR_FRAME_LEN:     Result := 'Exceeding the length of the frame';
    ERR_CRC:           Result := 'Error CRC';
    ERR_CALIB_ZERO:    Result := 'Zero calibration is not completed';
    ERR_CALIB_SCALE:   Result := 'Calibration of the scale is not completed';
  else
    Result := Format('Unknown error %02Xh', [aNER]);
  end;
end;

end.
