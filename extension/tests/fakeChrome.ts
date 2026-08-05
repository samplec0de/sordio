import { vi } from 'vitest';

/// Минимальный `chrome.*`, которого хватает воркеру и content script.
/// Подделывается ровно так же тривиально, как FakeSocket в bridge.test.ts.

export interface FakeEvent<Args extends unknown[]> {
  addListener: (fn: (...args: Args) => void) => void;
  emit: (...args: Args) => void;
  listenerCount: () => number;
}

export function fakeEvent<Args extends unknown[]>(): FakeEvent<Args> {
  const listeners: Array<(...args: Args) => void> = [];
  return {
    addListener: (fn) => {
      listeners.push(fn);
    },
    emit: (...args) => {
      for (const fn of [...listeners]) fn(...args);
    },
    listenerCount: () => listeners.length,
  };
}

export interface FakePort {
  name: string;
  sender?: { tab?: { id: number } };
  postMessage: ReturnType<typeof vi.fn>;
  disconnect: ReturnType<typeof vi.fn>;
  onMessage: FakeEvent<[unknown]>;
  onDisconnect: FakeEvent<[]>;
}

export function fakePort(name = 'sordio-tab', tabId?: number): FakePort {
  return {
    name,
    sender: tabId === undefined ? undefined : { tab: { id: tabId } },
    postMessage: vi.fn(),
    disconnect: vi.fn(),
    onMessage: fakeEvent<[unknown]>(),
    onDisconnect: fakeEvent<[]>(),
  };
}

export interface FakeChrome {
  runtime: {
    id: string;
    connect: ReturnType<typeof vi.fn>;
    onConnect: FakeEvent<[FakePort]>;
  };
  storage: { local: { get: ReturnType<typeof vi.fn>; set: ReturnType<typeof vi.fn> } };
  alarms: { create: ReturnType<typeof vi.fn>; onAlarm: FakeEvent<[]> };
}

export function installFakeChrome(stored: Record<string, unknown> = {}): FakeChrome {
  const chrome: FakeChrome = {
    runtime: {
      id: 'abcdefghijklmnopabcdefghijklmnop',
      connect: vi.fn(() => fakePort()),
      onConnect: fakeEvent<[FakePort]>(),
    },
    storage: {
      local: {
        get: vi.fn(async () => ({ ...stored })),
        set: vi.fn(async () => undefined),
      },
    },
    alarms: { create: vi.fn(), onAlarm: fakeEvent<[]>() },
  };
  (globalThis as unknown as { chrome: FakeChrome }).chrome = chrome;
  return chrome;
}

/// Сокет-заглушка: та же, что в bridge.test.ts, но ставится глобально —
/// воркер создаёт мост сам и до подмены `createSocket` не дотянуться.
export class FakeSocket {
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

  close() {
    this.readyState = 3;
    this.onclose?.();
  }

  send(data: string) {
    this.sent.push(data);
  }

  deliver(data: unknown) {
    this.onmessage?.({ data: typeof data === 'string' ? data : JSON.stringify(data) });
  }

  /// Всё, что улетело в приложение, в разобранном виде.
  get messages(): Array<Record<string, unknown>> {
    return this.sent.map((raw) => JSON.parse(raw) as Record<string, unknown>);
  }
}

export function installFakeSocket(): void {
  FakeSocket.instances = [];
  (globalThis as unknown as { WebSocket: unknown }).WebSocket = FakeSocket;
}
