#include <furi.h>
#include <gui/gui.h>
#include <input/input.h>
#include <notification/notification_messages.h>
#include <bt/bt_service/bt.h>
#include <profiles/serial_profile.h>

#include <furi_hal_power.h>

#include "font.h"
#include "icons.h"
#include "protocol.h"

#define TAG         "SordioRemote"
#define RX_BUF_SIZE 64
#define KEYS_PATH   APP_DATA_PATH(".bt_serial.keys")

/* Вибро: «включён» — один длинный, «выключен» — два коротких, остальное — три.
 * message_force_vibro_setting_on обходит пользовательскую настройку Vibro. */
static const NotificationSequence seq_unmuted = {
    &message_force_vibro_setting_on,
    &message_vibro_on,
    &message_delay_500,
    &message_vibro_off,
    &message_force_vibro_setting_off,
    NULL,
};
static const NotificationSequence seq_muted = {
    &message_force_vibro_setting_on,
    &message_vibro_on,
    &message_delay_100,
    &message_vibro_off,
    &message_delay_100,
    &message_vibro_on,
    &message_delay_100,
    &message_vibro_off,
    &message_force_vibro_setting_off,
    NULL,
};
static const NotificationSequence seq_other = {
    &message_force_vibro_setting_on,
    &message_vibro_on,
    &message_delay_100,
    &message_vibro_off,
    &message_delay_100,
    &message_vibro_on,
    &message_delay_100,
    &message_vibro_off,
    &message_delay_100,
    &message_vibro_on,
    &message_delay_100,
    &message_vibro_off,
    &message_force_vibro_setting_off,
    NULL,
};

typedef enum {
    EventTypeInput,
    EventTypeRx,
    EventTypeBtStatus,
} EventType;

typedef struct {
    EventType type;
    union {
        InputEvent input;
        uint8_t byte;
        BtStatus bt;
    };
} AppEvent;

typedef struct {
    Gui* gui;
    ViewPort* view_port;
    FuriMessageQueue* queue;
    FuriMutex* mutex;
    NotificationApp* notifications;
    Bt* bt;
    FuriHalBleProfileBase* profile;

    /* Ниже — под mutex. */
    BtStatus bt_status;
    uint8_t mic_state; /* 0 — ещё ничего не пришло */
    uint32_t state_tick; /* когда состояние сменилось — для анимации волн */
    bool ok_down;
    /* «Нажата» уже ушло на Mac — значит, на отпускании нужно отправить «отпущена». */
    bool down_sent;
    uint32_t press_tick;
    /* Предыдущее нажатие было коротким тычком, которому нечего было отправлять;
     * если следом придёт второе, это двойное нажатие. */
    bool tap_pending;
    uint32_t tap_release_tick;
    uint32_t rx_count;
} App;

/* Включить микрофон можно только удержанием или двойным нажатием: одиночный
 * случайный тычок в кармане ничего не отправляет. Когда микрофон уже включён,
 * кнопка работает сразу — иначе «выключить» пришлось бы делать с задержкой. */
#define HOLD_TO_UNMUTE_MS 600
/* Сколько после отпускания первого тычка ждём второго нажатия. */
#define DOUBLE_TAP_MS 400
/* Кадр анимации «ищу Mac». */
#define WAIT_FRAME_MS 250

static bool needs_hold(const App* app) {
    return app->mic_state != SORDIO_STATE_UNMUTED;
}

/* Штатные шрифты Flipper'а рисуют только ASCII, поэтому текст — своим
 * растровым шрифтом (font.h, см. tools/gen_font.py). Строки — UTF-8. */
static uint16_t next_code(const char** s) {
    const uint8_t* p = (const uint8_t*)*s;
    if(p[0] < 0x80) {
        *s += 1;
        return p[0];
    }
    if((p[0] & 0xE0) == 0xC0 && (p[1] & 0xC0) == 0x80) {
        *s += 2;
        return (uint16_t)(((p[0] & 0x1F) << 6) | (p[1] & 0x3F));
    }
    *s += 1;
    return '?';
}

static const uint8_t* glyph_bits(const BitmapFont* font, uint16_t code) {
    int lo = 0, hi = (int)font->count - 1;
    while(lo <= hi) {
        int mid = (lo + hi) / 2;
        if(font->codes[mid] == code) return &font->bits[mid * font->height];
        if(font->codes[mid] < code)
            lo = mid + 1;
        else
            hi = mid - 1;
    }
    return NULL;
}

static int text_width(const BitmapFont* font, const char* s) {
    int n = 0;
    while(*s) {
        next_code(&s);
        n++;
    }
    return n * font->advance;
}

/* y — верх ячейки шрифта. Рисует текущим цветом холста. */
static void draw_text(Canvas* canvas, const BitmapFont* font, int x, int y, const char* s) {
    while(*s) {
        const uint8_t* bits = glyph_bits(font, next_code(&s));
        if(bits) canvas_draw_xbm(canvas, x, y, font->width, font->height, bits);
        x += font->advance;
    }
}

static void draw_text_centered(
    Canvas* canvas,
    const BitmapFont* font,
    int center_x,
    int y,
    const char* s) {
    draw_text(canvas, font, center_x - text_width(font, s) / 2, y, s);
}

typedef struct {
    const uint8_t* icon;
    const char* title;
    const char* line1;
    const char* line2;
} StateView;

/* Волны вокруг включённого микрофона разбегаются за ANIM_MS после включения. */
#define ANIM_MS       360
#define WAVE_FRAME_MS 120

static StateView state_view(const App* app) {
    switch(app->mic_state) {
    case SORDIO_STATE_UNMUTED: {
        uint32_t age = furi_get_tick() - app->state_tick;
        uint32_t frame = age / WAVE_FRAME_MS;
        if(frame > 2) frame = 2;
        const uint8_t* icons[] = {icon_mic_on_0, icon_mic_on_1, icon_mic_on_2};
        return (StateView){icons[frame], "Включён", "Вас", "слышно"};
    }
    case SORDIO_STATE_MUTED:
        return (StateView){icon_mic_off, "Выключен", "Вас не", "слышно"};
    case SORDIO_STATE_NO_CALL:
        return (StateView){icon_mic_unknown, "Нет звонка", "Войдите", "в звонок"};
    case SORDIO_STATE_NO_BRIDGE:
        return (StateView){icon_mic_unknown, "Нет браузера", "Проверьте", "расширение"};
    case SORDIO_STATE_BUTTON_NOT_FOUND:
        return (StateView){icon_mic_unknown, "Нет кнопки", "Обновите", "страницу"};
    default:
        return (StateView){icon_mic_unknown, "Подключён", "Ждём", "состояние"};
    }
}

static void draw_battery(Canvas* canvas, int x, int y) {
    uint8_t pct = furi_hal_power_get_pct();
    canvas_draw_frame(canvas, x, y, 17, 8);
    canvas_draw_box(canvas, x + 17, y + 2, 2, 4); /* контакт */
    canvas_draw_box(canvas, x + 2, y + 2, (uint8_t)(13 * pct / 100), 4);
}

static void draw_top_bar(Canvas* canvas, const App* app) {
    bool connected = app->bt_status == BtStatusConnected;
    canvas_draw_xbm(canvas, 2, 1, ICON_BLUETOOTH_W, ICON_BLUETOOTH_H, icon_bluetooth);
    draw_text(canvas, &font_small, 13, 2, connected ? "Mac подключён" : "Ждём Mac");
    draw_battery(canvas, 108, 1);
}

/* Расходящиеся круги вокруг значка Bluetooth: «ищу Mac». */
static void draw_waiting(Canvas* canvas) {
    const int cx = 64, cy = 32;
    uint32_t frame = (furi_get_tick() / WAIT_FRAME_MS) % 4;
    for(uint32_t i = 0; i < 3; i++) {
        uint32_t r = 8 + ((frame + i) % 4) * 6;
        if(r < 28) canvas_draw_circle(canvas, cx, cy, r);
    }
    /* Белая «подложка» под значком, чтобы круги его не пересекали. */
    canvas_set_color(canvas, ColorWhite);
    canvas_draw_box(canvas, cx - 7, cy - 9, 14, 18);
    canvas_set_color(canvas, ColorBlack);
    canvas_draw_xbm(
        canvas,
        cx - ICON_BLUETOOTH_W / 2,
        cy - ICON_BLUETOOTH_H / 2,
        ICON_BLUETOOTH_W,
        ICON_BLUETOOTH_H,
        icon_bluetooth);
}

static void draw_bottom_bar(Canvas* canvas, const App* app, bool connected) {
    canvas_draw_box(canvas, 0, 53, 128, 11);
    canvas_set_color(canvas, ColorWhite);

    if(connected && app->ok_down && !app->down_sent) {
        /* Удержание: полоса заполняется до порога. */
        uint32_t held = furi_get_tick() - app->press_tick;
        if(held > HOLD_TO_UNMUTE_MS) held = HOLD_TO_UNMUTE_MS;
        canvas_draw_frame(canvas, 14, 55, 100, 7);
        canvas_draw_box(canvas, 14, 55, (uint8_t)(100 * held / HOLD_TO_UNMUTE_MS), 7);
    } else {
        const char* hint = "Выход: держать Back";
        if(connected) {
            if(app->ok_down)
                hint = "OK удерживается";
            else if(app->mic_state == SORDIO_STATE_UNMUTED)
                hint = "OK: выкл  Держать: речь";
            else if(app->mic_state == SORDIO_STATE_MUTED)
                hint = "Держать или 2xOK: вкл";
            else if(app->mic_state != 0)
                hint = "Держать или 2xOK";
        }
        draw_text_centered(canvas, &font_small, 64, 55, hint);
    }
    canvas_set_color(canvas, ColorBlack);
}

static void draw_callback(Canvas* canvas, void* context) {
    App* app = context;
    furi_mutex_acquire(app->mutex, FuriWaitForever);

    bool connected = app->bt_status == BtStatusConnected;
    canvas_clear(canvas);
    canvas_set_color(canvas, ColorBlack);
    draw_top_bar(canvas, app);

    if(connected) {
        StateView view = state_view(app);
        canvas_draw_xbm(canvas, 2, 17, ICON_MIC_ON_0_W, ICON_MIC_ON_0_H, view.icon);
        draw_text(canvas, &font_big, 54, 15, view.title);
        draw_text(canvas, &font_mid, 54, 30, view.line1);
        draw_text(canvas, &font_mid, 54, 41, view.line2);
    } else {
        draw_waiting(canvas);
    }
    draw_bottom_bar(canvas, app, connected);

    furi_mutex_release(app->mutex);
}

static void input_callback(InputEvent* input, void* context) {
    App* app = context;
    AppEvent event = {.type = EventTypeInput, .input = *input};
    furi_message_queue_put(app->queue, &event, 0);
}

/* Вызывается из потока BLE. */
static uint16_t rx_callback(SerialServiceEvent event, void* context) {
    App* app = context;
    if(event.event == SerialServiceEventTypeDataReceived) {
        for(uint16_t i = 0; i < event.data.size; i++) {
            AppEvent e = {.type = EventTypeRx, .byte = event.data.buffer[i]};
            furi_message_queue_put(app->queue, &e, 0);
        }
    }
    /* Всё забираем сразу, поэтому свободно весь буфер. */
    return RX_BUF_SIZE;
}

/* Вызывается из потока службы Bluetooth.
 * Служба сама открывает RPC-сессию на serial-профиле при каждом подключении
 * и ставит свой колбэк — перехватываем его обратно уже после этого. */
static void bt_status_callback(BtStatus status, void* context) {
    App* app = context;
    if(status == BtStatusConnected && app->profile) {
        ble_profile_serial_set_event_callback(app->profile, RX_BUF_SIZE, rx_callback, app);
        ble_profile_serial_set_rpc_active(app->profile, false);
    }
    AppEvent e = {.type = EventTypeBtStatus, .bt = status};
    furi_message_queue_put(app->queue, &e, 0);
}

static void send_event(App* app, uint8_t byte) {
    if(app->profile) ble_profile_serial_tx(app->profile, &byte, 1);
}

static void handle_rx(App* app, uint8_t byte) {
    const NotificationSequence* seq = NULL;
    switch(byte) {
    case SORDIO_STATE_UNMUTED:
        seq = &seq_unmuted;
        break;
    case SORDIO_STATE_MUTED:
        seq = &seq_muted;
        break;
    case SORDIO_STATE_NO_CALL:
    case SORDIO_STATE_NO_BRIDGE:
    case SORDIO_STATE_BUTTON_NOT_FOUND:
        seq = &seq_other;
        break;
    default:
        FURI_LOG_W(TAG, "unknown byte 0x%02X", byte);
        return;
    }
    furi_mutex_acquire(app->mutex, FuriWaitForever);
    bool changed = app->mic_state != byte;
    if(changed) app->state_tick = furi_get_tick();
    app->mic_state = byte;
    app->rx_count++;
    furi_mutex_release(app->mutex);
    /* Повтор того же состояния (например, при переподключении) не вибрирует. */
    if(changed) notification_message(app->notifications, seq);
}

int32_t sordio_remote_app(void* p) {
    UNUSED(p);

    App* app = malloc(sizeof(App));
    memset(app, 0, sizeof(App));
    app->queue = furi_message_queue_alloc(32, sizeof(AppEvent));
    app->mutex = furi_mutex_alloc(FuriMutexTypeNormal);
    app->notifications = furi_record_open(RECORD_NOTIFICATION);
    app->bt = furi_record_open(RECORD_BT);
    app->bt_status = BtStatusAdvertising;

    /* Отдельное хранилище ключей, чтобы не трогать связь с телефоном. */
    bt_disconnect(app->bt);
    furi_delay_ms(200);
    bt_keys_storage_set_storage_path(app->bt, KEYS_PATH);
    bt_set_status_changed_callback(app->bt, bt_status_callback, app);
    app->profile = bt_profile_start(app->bt, ble_profile_serial, NULL);
    furi_check(app->profile);
    ble_profile_serial_set_event_callback(app->profile, RX_BUF_SIZE, rx_callback, app);

    app->gui = furi_record_open(RECORD_GUI);
    app->view_port = view_port_alloc();
    view_port_draw_callback_set(app->view_port, draw_callback, app);
    view_port_input_callback_set(app->view_port, input_callback, app);
    gui_add_view_port(app->gui, app->view_port, GuiLayerFullscreen);

    bool running = true;
    AppEvent event;
    while(running) {
        /* Пока идёт удержание, просыпаемся часто: нужно и дождаться порога, и
         * перерисовывать полосу прогресса. В остальное время спим до события. */
        bool arming = app->ok_down && !app->down_sent;
        bool connected = app->bt_status == BtStatusConnected;
        bool waves = connected && app->mic_state == SORDIO_STATE_UNMUTED &&
                     furi_get_tick() - app->state_tick < ANIM_MS;
        uint32_t timeout = FuriWaitForever;
        if(arming)
            timeout = 30;
        else if(waves)
            timeout = 40;
        else if(!connected)
            timeout = WAIT_FRAME_MS;
        FuriStatus status = furi_message_queue_get(app->queue, &event, timeout);

        if(status == FuriStatusOk) {
            switch(event.type) {
            case EventTypeInput:
                if(event.input.key == InputKeyOk) {
                    if(event.input.type == InputTypePress && !app->ok_down) {
                        furi_mutex_acquire(app->mutex, FuriWaitForever);
                        app->ok_down = true;
                        app->down_sent = false;
                        app->press_tick = furi_get_tick();
                        furi_mutex_release(app->mutex);

                        bool double_tap = app->tap_pending &&
                                          app->press_tick - app->tap_release_tick <= DOUBLE_TAP_MS;
                        app->tap_pending = false;
                        if(!needs_hold(app) ||
                           (double_tap && app->bt_status == BtStatusConnected)) {
                            send_event(app, SORDIO_EVT_DOWN);
                            app->down_sent = true;
                        }
                    } else if(event.input.type == InputTypeRelease && app->ok_down) {
                        if(app->down_sent) {
                            send_event(app, SORDIO_EVT_UP);
                        } else {
                            /* Не дождались порога — Mac ничего не узнает о нажатии,
                             * но запомним тычок: вдруг за ним придёт второй. */
                            app->tap_pending = true;
                            app->tap_release_tick = furi_get_tick();
                        }
                        furi_mutex_acquire(app->mutex, FuriWaitForever);
                        app->ok_down = false;
                        app->down_sent = false;
                        furi_mutex_release(app->mutex);
                    }
                } else if(event.input.key == InputKeyBack && event.input.type == InputTypeLong) {
                    running = false;
                }
                break;
            case EventTypeRx:
                handle_rx(app, event.byte);
                break;
            case EventTypeBtStatus:
                furi_mutex_acquire(app->mutex, FuriWaitForever);
                app->bt_status = event.bt;
                if(event.bt != BtStatusConnected) {
                    app->mic_state = 0;
                    /* Связи нет: «отпущена» отправлять некуда. */
                    app->down_sent = false;
                    app->tap_pending = false;
                }
                furi_mutex_release(app->mutex);
                break;
            }
        }

        if(app->ok_down && !app->down_sent && app->bt_status == BtStatusConnected &&
           furi_get_tick() - app->press_tick >= HOLD_TO_UNMUTE_MS) {
            send_event(app, SORDIO_EVT_DOWN);
            app->down_sent = true;
        }
        view_port_update(app->view_port);
    }

    gui_remove_view_port(app->gui, app->view_port);
    view_port_free(app->view_port);
    furi_record_close(RECORD_GUI);

    bt_set_status_changed_callback(app->bt, NULL, NULL);
    ble_profile_serial_set_event_callback(app->profile, 0, NULL, NULL);
    bt_disconnect(app->bt);
    furi_delay_ms(200);
    bt_keys_storage_set_default_path(app->bt);
    furi_check(bt_profile_restore_default(app->bt));
    furi_record_close(RECORD_BT);
    furi_record_close(RECORD_NOTIFICATION);

    furi_message_queue_free(app->queue);
    furi_mutex_free(app->mutex);
    free(app);
    return 0;
}
