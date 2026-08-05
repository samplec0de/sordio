import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FakeSocket, fakePort, installFakeChrome, installFakeSocket } from './fakeChrome';
import type { FakeChrome, FakePort } from './fakeChrome';

/// Воркер — единственная часть расширения, которая решает, какой вкладкой
/// управлять, и единственная, кто разговаривает с приложением. Он выполняет
/// работу на импорте, поэтому каждый тест поднимает его заново.

let chrome: FakeChrome;
let socket: FakeSocket;

async function loadWorker(stored: Record<string, unknown> = {}): Promise<void> {
  chrome = installFakeChrome(stored);
  installFakeSocket();
  await import('../src/worker');
  // Секрет поднимается из chrome.storage — мост стартует уже после промиса.
  await new Promise((resolve) => setTimeout(resolve, 0));
  socket = FakeSocket.instances[0];
  socket.open();
}

/// Подключить вкладку и сразу сообщить её состояние.
function attachTab(tabId: number, snapshot: { context: string; muted?: boolean }): FakePort {
  const port = fakePort('sordio-tab', tabId);
  chrome.runtime.onConnect.emit(port);
  port.onMessage.emit({ kind: 'snapshot', snapshot });
  return port;
}

/// Последнее состояние, отправленное приложению.
function lastState(): Record<string, unknown> | undefined {
  return socket.messages.filter((message) => message.type === 'state').at(-1);
}

beforeEach(() => {
  vi.resetModules();
  // Воркер различает вкладки по времени последнего изменения, а тест успевает
  // сделать всё в пределах одной миллисекунды — часы двигаем сами.
  let clock = 1_700_000_000_000;
  vi.spyOn(Date, 'now').mockImplementation(() => {
    clock += 1000;
    return clock;
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  delete (globalThis as unknown as { chrome?: unknown }).chrome;
});

describe('worker: связь с приложением', () => {
  it('представляется и сразу сообщает состояние', async () => {
    await loadWorker();

    expect(socket.messages[0]).toMatchObject({ type: 'hello', extensionId: chrome.runtime.id });
    expect(lastState()).toMatchObject({ type: 'state', context: 'no-call' });
  });

  it('предъявляет секрет, поднятый из хранилища', async () => {
    await loadWorker({ pairingSecret: 'известный' });

    expect(socket.messages[0]).toMatchObject({ type: 'hello', secret: 'известный' });
  });

  it('сохраняет выданный секрет', async () => {
    await loadWorker();

    socket.deliver({ v: 1, type: 'paired', secret: 'свежий' });

    expect(chrome.storage.local.set).toHaveBeenCalledWith({ pairingSecret: 'свежий' });
  });
});

describe('worker: выбор вкладки', () => {
  it('вкладка со звонком выигрывает у предзвонка', async () => {
    await loadWorker();

    attachTab(1, { context: 'pre-call', muted: true });
    attachTab(2, { context: 'in-call', muted: false });

    expect(lastState()).toMatchObject({ context: 'in-call', muted: false });
  });

  it('вкладка со звонком выигрывает, даже если менялась раньше других', async () => {
    await loadWorker();

    attachTab(1, { context: 'in-call', muted: true });
    attachTab(2, { context: 'button-not-found' });
    attachTab(3, { context: 'no-call' });

    expect(lastState()).toMatchObject({ context: 'in-call', muted: true });
  });

  it('предзвонок выигрывает у «кнопка не найдена»', async () => {
    await loadWorker();

    attachTab(1, { context: 'button-not-found' });
    attachTab(2, { context: 'pre-call', muted: true });

    expect(lastState()).toMatchObject({ context: 'pre-call' });
  });

  it('при равном ранге выигрывает та вкладка, где менялось последним', async () => {
    await loadWorker();

    attachTab(1, { context: 'in-call', muted: true });
    const second = attachTab(2, { context: 'in-call', muted: true });
    second.onMessage.emit({ kind: 'snapshot', snapshot: { context: 'in-call', muted: false } });

    expect(lastState()).toMatchObject({ context: 'in-call', muted: false });
  });

  it('без подходящих вкладок приложение получает честное «звонка нет»', async () => {
    await loadWorker();

    attachTab(1, { context: 'no-call' });

    expect(lastState()).toMatchObject({ context: 'no-call' });
    expect('muted' in (lastState() ?? {})).toBe(false);
  });

  it('закрытие вкладки возвращает состояние «звонка нет», а не молчание', async () => {
    await loadWorker();

    const port = attachTab(1, { context: 'in-call', muted: false });
    expect(lastState()).toMatchObject({ context: 'in-call' });

    port.onDisconnect.emit();

    expect(lastState()).toMatchObject({ context: 'no-call' });
  });

  it('игнорирует чужие подключения к воркеру', async () => {
    await loadWorker();
    const before = socket.messages.length;

    chrome.runtime.onConnect.emit(fakePort('кто-то-другой', 7));
    // И вкладку без sender.tab — такое приходит, например, из popup.
    chrome.runtime.onConnect.emit(fakePort('sordio-tab'));

    expect(socket.messages).toHaveLength(before);
  });

  it('игнорирует сообщения не того вида', async () => {
    await loadWorker();
    const port = attachTab(1, { context: 'in-call', muted: false });
    const before = socket.messages.length;

    port.onMessage.emit({ kind: 'привет' });
    port.onMessage.emit({ kind: 'snapshot' });

    expect(socket.messages).toHaveLength(before);
  });
});

describe('worker: маршрутизация команды', () => {
  const command = { v: 1, type: 'command', action: 'setMuted', id: 'c1', muted: true };

  it('отправляет команду во вкладку со звонком', async () => {
    await loadWorker();
    const idle = attachTab(1, { context: 'no-call' });
    const active = attachTab(2, { context: 'in-call', muted: false });

    socket.deliver(command);

    expect(active.postMessage).toHaveBeenCalledWith({ kind: 'setMuted', id: 'c1', muted: true });
    expect(idle.postMessage).not.toHaveBeenCalled();
  });

  it('без подходящей вкладки отвечает состоянием, а не молчанием', async () => {
    await loadWorker();
    const before = socket.messages.length;

    socket.deliver(command);

    expect(socket.messages.length).toBeGreaterThan(before);
    expect(lastState()).toMatchObject({ context: 'no-call' });
  });

  it('не падает, если порт вкладки уже мёртв', async () => {
    await loadWorker();
    const port = attachTab(1, { context: 'in-call', muted: false });
    port.postMessage.mockImplementation(() => {
      throw new Error('Attempting to use a disconnected port object');
    });

    expect(() => socket.deliver(command)).not.toThrow();
  });

  it('не реагирует на сообщения, которые не команда', async () => {
    await loadWorker();
    const port = attachTab(1, { context: 'in-call', muted: false });

    socket.deliver({ v: 1, type: 'welcome' });

    expect(port.postMessage).not.toHaveBeenCalled();
  });
});

describe('worker: сон service worker', () => {
  it('заводит будильник, чтобы проснуться после сна', async () => {
    await loadWorker();

    expect(chrome.alarms.create).toHaveBeenCalledWith('sordio-keepalive', {
      periodInMinutes: 1,
    });
  });

  it('будильник при живом соединении не плодит сокеты', async () => {
    await loadWorker();

    chrome.alarms.onAlarm.emit();

    expect(FakeSocket.instances).toHaveLength(1);
  });
});

describe('воркер: уровень микрофона', () => {
  function levels(): number[] {
    return socket.messages
      .filter((message) => message.type === 'level')
      .map((message) => message.level as number);
  }

  it('передаёт уровень приложению', async () => {
    await loadWorker();
    const call = attachTab(1, { context: 'in-call', muted: false });

    call.onMessage.emit({ kind: 'level', level: 0.42 });

    expect(levels()).toEqual([0.42]);
  });

  it('не берёт уровень у вкладки, которой не управляет', async () => {
    await loadWorker();
    const idle = attachTab(1, { context: 'no-call' });
    attachTab(2, { context: 'in-call', muted: false });

    idle.onMessage.emit({ kind: 'level', level: 0.9 });

    expect(levels()).toEqual([]);
  });

  it('молчит, когда звонка нет вовсе', async () => {
    await loadWorker();
    const idle = attachTab(1, { context: 'no-call' });

    idle.onMessage.emit({ kind: 'level', level: 0.5 });

    expect(levels()).toEqual([]);
  });
});
