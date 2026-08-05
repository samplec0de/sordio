import { describe, expect, it, vi } from 'vitest';
import { Bridge } from '../src/bridge';
import { PROTOCOL_VERSION } from '../src/protocol';

class FakeSocket {
  static instances: FakeSocket[] = [];
  sent: string[] = [];
  readyState = 0;
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;

  constructor(public url: string) {
    FakeSocket.instances.push(this);
  }

  open() {
    this.readyState = 1;
    this.onopen?.();
  }

  fail() {
    this.readyState = 3;
    this.onerror?.();
    this.onclose?.();
  }

  close() {
    this.readyState = 3;
    this.onclose?.();
  }

  send(data: string) {
    this.sent.push(data);
  }

  deliver(data: string) {
    this.onmessage?.({ data });
  }
}

const makeBridge = (overrides: Partial<ConstructorParameters<typeof Bridge>[0]> = {}) => {
  FakeSocket.instances = [];
  const bridge = new Bridge({
    ports: [8765, 8766, 8767],
    extensionId: 'abcdefghijklmnop',
    createSocket: (url) => new FakeSocket(url) as unknown as WebSocket,
    delays: [10, 20],
    ...overrides,
  });
  return bridge;
};

describe('Bridge', () => {
  it('начинает с первого порта диапазона', () => {
    const bridge = makeBridge();
    bridge.start();
    expect(FakeSocket.instances[0].url).toBe('ws://127.0.0.1:8765/');
  });

  it('повторный вызов start() не теряет уже установленное соединение', () => {
    const bridge = makeBridge();
    bridge.start();
    FakeSocket.instances[0].open();

    // Например, service worker расширения проснулся и снова инициализирует
    // мост поверх уже подключённого экземпляра — второй сокет создаваться
    // не должен, а уже открытое соединение — теряться.
    bridge.start();

    expect(FakeSocket.instances).toHaveLength(1);
    expect(bridge.isConnected).toBe(true);
  });

  it('повторный вызов start() во время подключения не плодит лишние сокеты', () => {
    const bridge = makeBridge();
    bridge.start();
    bridge.start();

    expect(FakeSocket.instances).toHaveLength(1);
  });

  it('перебирает порты, пока не найдёт живой', () => {
    vi.useFakeTimers();
    const bridge = makeBridge();
    bridge.start();

    FakeSocket.instances[0].fail();
    vi.advanceTimersByTime(50);
    expect(FakeSocket.instances[1].url).toBe('ws://127.0.0.1:8766/');

    FakeSocket.instances[1].fail();
    vi.advanceTimersByTime(50);
    expect(FakeSocket.instances[2].url).toBe('ws://127.0.0.1:8767/');
    vi.useRealTimers();
  });

  it('возвращается к первому порту, обойдя весь диапазон', () => {
    vi.useFakeTimers();
    const bridge = makeBridge();
    bridge.start();

    for (let i = 0; i < 3; i += 1) {
      FakeSocket.instances[i].fail();
      vi.advanceTimersByTime(50);
    }
    expect(FakeSocket.instances[3].url).toBe('ws://127.0.0.1:8765/');
    vi.useRealTimers();
  });

  it('представляется после подключения', () => {
    const bridge = makeBridge();
    bridge.start();
    FakeSocket.instances[0].open();

    expect(JSON.parse(FakeSocket.instances[0].sent[0])).toEqual({
      v: PROTOCOL_VERSION,
      type: 'hello',
      extensionId: 'abcdefghijklmnop',
    });
  });

  it('предъявляет ранее выданный секрет', () => {
    const bridge = makeBridge({ secret: 'known-secret' });
    bridge.start();
    FakeSocket.instances[0].open();

    expect(JSON.parse(FakeSocket.instances[0].sent[0])).toEqual({
      v: PROTOCOL_VERSION,
      type: 'hello',
      extensionId: 'abcdefghijklmnop',
      secret: 'known-secret',
    });
  });

  it('запоминает выданный секрет и предъявляет его при переподключении', () => {
    vi.useFakeTimers();
    const onPaired = vi.fn();
    const onMessage = vi.fn();
    const bridge = makeBridge({ onPaired, onMessage });
    bridge.start();
    FakeSocket.instances[0].open();

    FakeSocket.instances[0].deliver(JSON.stringify({ v: 1, type: 'paired', secret: 'fresh' }));
    expect(onPaired).toHaveBeenCalledWith('fresh');
    expect(onMessage).not.toHaveBeenCalled();

    FakeSocket.instances[0].close();
    vi.advanceTimersByTime(50);
    FakeSocket.instances[1].open();

    expect(JSON.parse(FakeSocket.instances[1].sent[0]).secret).toBe('fresh');
    vi.useRealTimers();
  });

  it('сообщает о подключении и отключении', () => {
    // Подменённый таймер: close() планирует переподключение через
    // реальный setTimeout, а тесты не должны зависеть от реального времени.
    vi.useFakeTimers();
    const onOpen = vi.fn();
    const onClose = vi.fn();
    const bridge = makeBridge({ onOpen, onClose });
    bridge.start();

    FakeSocket.instances[0].open();
    expect(onOpen).toHaveBeenCalledOnce();
    expect(bridge.isConnected).toBe(true);

    FakeSocket.instances[0].close();
    expect(onClose).toHaveBeenCalledOnce();
    expect(bridge.isConnected).toBe(false);

    // Останавливаем клиент, чтобы отменить запланированное переподключение
    // и не оставлять висящий таймер после теста.
    bridge.stop();
    vi.useRealTimers();
  });

  it('разбирает входящие команды', () => {
    const onMessage = vi.fn();
    const bridge = makeBridge({ onMessage });
    bridge.start();
    FakeSocket.instances[0].open();

    FakeSocket.instances[0].deliver(
      JSON.stringify({ v: 1, type: 'command', action: 'setMuted', id: 'c1', muted: true }),
    );

    expect(onMessage).toHaveBeenCalledWith({
      v: 1,
      type: 'command',
      action: 'setMuted',
      id: 'c1',
      muted: true,
    });
  });

  it('игнорирует мусор вместо падения', () => {
    const onMessage = vi.fn();
    const bridge = makeBridge({ onMessage });
    bridge.start();
    FakeSocket.instances[0].open();

    FakeSocket.instances[0].deliver('не json');
    FakeSocket.instances[0].deliver(JSON.stringify({ v: 99, type: 'command' }));

    expect(onMessage).not.toHaveBeenCalled();
  });

  it('не отправляет в неподключённый сокет', () => {
    const bridge = makeBridge();
    bridge.start();

    bridge.send({ v: PROTOCOL_VERSION, type: 'state', context: 'no-call' });
    expect(FakeSocket.instances[0].sent).toHaveLength(0);
  });

  it('после stop не переподключается', () => {
    vi.useFakeTimers();
    const bridge = makeBridge();
    bridge.start();
    bridge.stop();

    FakeSocket.instances[0].close();
    vi.advanceTimersByTime(1000);
    expect(FakeSocket.instances).toHaveLength(1);
    vi.useRealTimers();
  });

  it('растит паузу между попытками и сбрасывает её после успеха', () => {
    vi.useFakeTimers();
    const bridge = makeBridge({ delays: [10, 100] });
    bridge.start();

    FakeSocket.instances[0].fail();
    vi.advanceTimersByTime(9);
    expect(FakeSocket.instances).toHaveLength(1);
    vi.advanceTimersByTime(1);
    expect(FakeSocket.instances).toHaveLength(2);

    FakeSocket.instances[1].fail();
    vi.advanceTimersByTime(99);
    expect(FakeSocket.instances).toHaveLength(2);
    vi.advanceTimersByTime(1);
    expect(FakeSocket.instances).toHaveLength(3);

    FakeSocket.instances[2].open();
    FakeSocket.instances[2].close();
    vi.advanceTimersByTime(10);
    expect(FakeSocket.instances).toHaveLength(4);
    vi.useRealTimers();
  });
});
