#include <furi.h>
#include <gui/gui.h>
#include <input/input.h>
#include <notification/notification_messages.h>
#include <bt/bt_service/bt.h>
#include <profiles/serial_profile.h>

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

static bool needs_hold(const App* app) {
    return app->mic_state != SORDIO_STATE_UNMUTED;
}

static const char* mic_state_text(uint8_t state) {
    switch(state) {
    case SORDIO_STATE_UNMUTED:
        return "MIC ON";
    case SORDIO_STATE_MUTED:
        return "MIC OFF";
    case SORDIO_STATE_NO_CALL:
        return "NO CALL";
    case SORDIO_STATE_NO_BRIDGE:
        return "NO BROWSER";
    case SORDIO_STATE_BUTTON_NOT_FOUND:
        return "NO MIC BTN";
    default:
        return "WAITING";
    }
}

static const char* bt_status_text(BtStatus status) {
    switch(status) {
    case BtStatusConnected:
        return "Mac connected";
    case BtStatusAdvertising:
        return "Waiting for Mac...";
    case BtStatusOff:
        return "BT off";
    default:
        return "BT unavailable";
    }
}

static void draw_callback(Canvas* canvas, void* context) {
    App* app = context;
    furi_mutex_acquire(app->mutex, FuriWaitForever);

    canvas_clear(canvas);
    canvas_set_font(canvas, FontSecondary);
    canvas_draw_str_aligned(canvas, 64, 6, AlignCenter, AlignCenter, bt_status_text(app->bt_status));

    canvas_set_font(canvas, FontBigNumbers);
    canvas_draw_str_aligned(
        canvas, 64, 32, AlignCenter, AlignCenter, mic_state_text(app->mic_state));

    canvas_set_font(canvas, FontSecondary);
    if(app->ok_down && !app->down_sent) {
        uint32_t held = furi_get_tick() - app->press_tick;
        if(held > HOLD_TO_UNMUTE_MS) held = HOLD_TO_UNMUTE_MS;
        canvas_draw_frame(canvas, 14, 50, 100, 8);
        canvas_draw_box(canvas, 14, 50, (uint8_t)(100 * held / HOLD_TO_UNMUTE_MS), 8);
    } else if(app->ok_down) {
        canvas_draw_str_aligned(canvas, 64, 56, AlignCenter, AlignCenter, "OK held");
    } else {
        canvas_draw_str_aligned(
            canvas,
            64,
            56,
            AlignCenter,
            AlignCenter,
            needs_hold(app) ? "Hold or 2x OK: unmute" : "OK: mute / hold: talk");
    }

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
        FuriStatus status =
            furi_message_queue_get(app->queue, &event, arming ? 30 : FuriWaitForever);

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
