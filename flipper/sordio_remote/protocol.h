#pragma once

/* Протокол Flipper <-> Sordio поверх Bluetooth serial. Один байт на сообщение.
 * Зеркало этих значений живёт в SordioCore (FlipperProtocol.swift). */

/* Flipper -> Mac: состояние кнопки OK. */
#define SORDIO_EVT_DOWN 0xA1
#define SORDIO_EVT_UP   0xA2

/* Mac -> Flipper: подтверждённое состояние микрофона (то же, что OverlayState). */
#define SORDIO_STATE_UNMUTED          0x01
#define SORDIO_STATE_MUTED            0x02
#define SORDIO_STATE_NO_CALL          0x03
#define SORDIO_STATE_NO_BRIDGE        0x04
#define SORDIO_STATE_BUTTON_NOT_FOUND 0x05
