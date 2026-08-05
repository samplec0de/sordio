import { PROTOCOL_VERSION, parseInbound } from './protocol';
import type { InboundMessage, OutboundMessage } from './protocol';

export interface BridgeOptions {
  ports: number[];
  extensionId: string;
  /// Секрет, выданный приложением при спаривании. null — спаривания ещё не было.
  secret?: string | null;
  /// Вызывается, когда приложение выдало новый секрет: его нужно сохранить.
  onPaired?: (secret: string) => void;
  createSocket?: (url: string) => WebSocket;
  onMessage?: (message: InboundMessage) => void;
  onOpen?: () => void;
  onClose?: () => void;
  /// Паузы перед повторными попытками, мс. Последняя повторяется дальше.
  delays?: number[];
}

/// Клиент локального моста: перебирает порты приложения и переподключается,
/// переживая перезапуск как приложения, так и браузера.
export class Bridge {
  private socket: WebSocket | null = null;
  private portIndex = 0;
  private attempt = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private stopped = true;

  private readonly ports: number[];
  private readonly extensionId: string;
  private secret: string | null;
  private readonly onPaired?: (secret: string) => void;
  private readonly createSocket: (url: string) => WebSocket;
  private readonly delays: number[];
  private readonly onMessage?: (message: InboundMessage) => void;
  private readonly onOpen?: () => void;
  private readonly onClose?: () => void;

  constructor(options: BridgeOptions) {
    this.ports = options.ports;
    this.extensionId = options.extensionId;
    this.secret = options.secret ?? null;
    this.onPaired = options.onPaired;
    this.createSocket = options.createSocket ?? ((url) => new WebSocket(url));
    this.delays = options.delays ?? [500, 1000, 2000, 5000];
    this.onMessage = options.onMessage;
    this.onOpen = options.onOpen;
    this.onClose = options.onClose;
  }

  get isConnected(): boolean {
    return this.socket !== null && this.socket.readyState === 1;
  }

  /// Подставить секрет, поднятый из хранилища, до первого подключения.
  useSecret(secret: string): void {
    this.secret = secret;
  }

  start(): void {
    // Повторный вызов, пока клиент уже работает (соединение установлено или
    // устанавливается), — не действие: service worker расширения может
    // засыпать и просыпаться, вызывая инициализацию заново поверх уже
    // живого экземпляра. Ничего не делаем, чтобы не потерять открытый сокет.
    if (!this.stopped) return;
    this.stopped = false;
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    const socket = this.socket;
    this.socket = null;
    socket?.close();
  }

  send(message: OutboundMessage): void {
    if (!this.isConnected) return;
    this.socket!.send(JSON.stringify(message));
  }

  private connect(): void {
    if (this.stopped) return;

    const port = this.ports[this.portIndex];
    const socket = this.createSocket(`ws://127.0.0.1:${port}/`);
    this.socket = socket;
    let opened = false;

    socket.onopen = () => {
      if (this.stopped) return;
      opened = true;
      this.attempt = 0;
      const hello: OutboundMessage = {
        v: PROTOCOL_VERSION,
        type: 'hello',
        extensionId: this.extensionId,
      };
      if (this.secret) hello.secret = this.secret;
      this.send(hello);
      this.onOpen?.();
    };

    socket.onmessage = (event: MessageEvent) => {
      const message = parseInbound(String(event.data));
      if (!message) return;
      if (message.type === 'paired') {
        // Приложение спарилось с нами — запоминаем секрет,
        // чтобы при следующем подключении не дёргать пользователя диалогом.
        this.secret = message.secret;
        this.onPaired?.(message.secret);
        return;
      }
      this.onMessage?.(message);
    };

    socket.onerror = () => {
      // Ошибку всегда сопровождает close — переподключение планируется там.
    };

    socket.onclose = () => {
      if (this.socket !== socket) return;
      this.socket = null;
      // Разрыв живого соединения и неудачная попытка подключения — разные события:
      // о первом надо сообщить, второе происходит при каждом переборе портов.
      if (opened) this.onClose?.();
      this.scheduleReconnect();
    };
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.timer !== null) return;

    // Приложение могло занять другой порт из диапазона — перебираем по кругу.
    this.portIndex = (this.portIndex + 1) % this.ports.length;

    const delay = this.delays[Math.min(this.attempt, this.delays.length - 1)];
    this.attempt += 1;

    this.timer = setTimeout(() => {
      this.timer = null;
      this.connect();
    }, delay);
  }
}
