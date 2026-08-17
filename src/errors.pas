unit errors;

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
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  { Базовая ошибка Tenso-M. }
  ETensoMError = class(Exception);

  { Ошибка транспортного уровня:
    COM/TTY, невозможность отправки, отсутствие соединения и т.п. }
  ETensoMTransportError = class(ETensoMError);

  { Таймаут ожидания ответа от прибора. }
  ETensoMTimeoutError = class(ETensoMTransportError);

  { Ошибка структуры или целостности кадра. }
  ETensoMFrameError = class(ETensoMError);

  { Ошибка CRC кадра. Является разновидностью ошибки кадра. }
  ETensoMCRCError = class(ETensoMFrameError);

  { Ошибка, возвращённая самим прибором через EEh. }
  ETensoMDeviceError = class(ETensoMError);

  { Ошибка протокола/семантики обмена:
    неверный адрес, неожиданный COP, неподдерживаемая команда и т.п. }
  ETensoMProtocolError = class(ETensoMError);

implementation

end.