unit tensom_errors;

{
  TensoMLib — иерархия исключений.

  Исключения разделены по семантике ошибки, чтобы клиент мог
  определить, имеет ли смысл повторять операцию.

  ETensoMError
    ├── ETensoMTransportError
    │     └── ETensoMTimeoutError
    │
    ├── ETensoMFrameError
    │     └── ETensoMCRCError
    │
    ├── ETensoMDeviceError
    │
    └── ETensoMProtocolError
          └── ETensoMAddressMismatchError
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils
  ;

type
  { Базовая ошибка Tenso-M. }
  ETensoMError = class(Exception);

  { Ошибка транспортного уровня: COM/TTY, невозможность отправки, отсутствие соединения и т.п. }
  ETensoMTransportError = class(ETensoMError);

  { Таймаут ожидания ответа от прибора. }
  ETensoMTimeoutError = class(ETensoMTransportError);

  { Ошибка структуры или целостности кадра. }
  ETensoMFrameError = class(ETensoMError);

  { Ошибка CRC кадра. Является разновидностью ошибки кадра. }
  ETensoMCRCError = class(ETensoMFrameError);

  { Ошибка, возвращённая самим прибором через EEh. }
  ETensoMDeviceError = class(ETensoMError);

  { Ошибка протокола/семантики обмена: неожиданный COP, неподдерживаемая команда и т.п. }
  ETensoMProtocolError = class(ETensoMError);

  { Ответ пришёл с чужого сетевого адреса. На одиночном приборе это признак
    неисправности, на многоприборной шине (RS-485) — чаще всего поздний
    ответ соседа, поэтому клиент ретраит её как ошибку связи. }
  ETensoMAddressMismatchError = class(ETensoMProtocolError);

implementation

end.
