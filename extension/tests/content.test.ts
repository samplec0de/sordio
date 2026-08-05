import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fakePort, installFakeChrome } from './fakeChrome';
import type { FakeChrome, FakePort } from './fakeChrome';

/// Content script — самая асинхронная часть расширения: service worker в MV3
/// засыпает, страница SaluteJazz при этом не перезагружается (SPA), и канал
/// приходится поднимать самому.

const RECONNECT_DELAYS = [300, 600, 1200, 2500, 5000];

let chrome: FakeChrome;
let ports: FakePort[];

/// Кнопка микрофона на странице — ровно та, которую ищет micButton.
function putMicButton(muted: boolean): HTMLButtonElement {
  document.body.innerHTML = '';
  const button = document.createElement('button');
  button.setAttribute('data-testid', 'microphone');
  button.setAttribute('data-muted', String(muted));
  document.body.appendChild(button);
  return button;
}

/// Все снапшоты, отправленные воркеру через указанный порт.
function snapshots(port: FakePort): Array<Record<string, unknown>> {
  return port.postMessage.mock.calls
    .map(([message]) => message as { kind: string; snapshot?: Record<string, unknown> })
    .filter((message) => message.kind === 'snapshot')
    .map((message) => message.snapshot ?? {});
}

async function loadContent(): Promise<void> {
  chrome = installFakeChrome();
  ports = [];
  chrome.runtime.connect.mockImplementation(() => {
    const port = fakePort();
    ports.push(port);
    return port;
  });
  await import('../src/content');
}

beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  document.body.innerHTML = '';
});

afterEach(() => {
  vi.useRealTimers();
  delete (globalThis as unknown as { chrome?: unknown }).chrome;
});

describe('content: подключение к воркеру', () => {
  it('подключается и сразу отправляет состояние', async () => {
    putMicButton(true);
    await loadContent();

    expect(chrome.runtime.connect).toHaveBeenCalledWith({ name: 'sordio-tab' });
    // Воркер мог проспать вкладку и забыть её состояние — снапшот нужен
    // сразу, а не при следующем изменении кнопки.
    expect(snapshots(ports[0])).toContainEqual({ context: 'in-call', muted: true });
  });

  it('сообщает честное состояние, когда кнопки нет', async () => {
    await loadContent();

    expect(snapshots(ports[0])).toContainEqual({ context: 'no-call' });
  });
});

describe('content: переподключение после сна воркера', () => {
  it('переподключается с растущей паузой, пока воркер не поднимется', async () => {
    // Воркер спит: chrome.runtime.connect не отдаёт порт. Пауза должна расти,
    // чтобы не молотить впустую, и упереться в последнюю, а не расти вечно.
    chrome = installFakeChrome();
    ports = [];
    let attempts = 0;
    chrome.runtime.connect.mockImplementation(() => {
      attempts += 1;
      throw new Error('Could not establish connection');
    });
    await import('../src/content');
    expect(attempts).toBe(1);

    const expectedDelays = [...RECONNECT_DELAYS, RECONNECT_DELAYS[RECONNECT_DELAYS.length - 1]];
    for (const [index, delay] of expectedDelays.entries()) {
      vi.advanceTimersByTime(delay - 1);
      expect(attempts, `попытка ${index + 2} не должна случиться раньше ${delay} мс`).toBe(
        index + 1,
      );

      vi.advanceTimersByTime(1);
      expect(attempts).toBe(index + 2);
    }
  });

  it('после переподключения сразу отправляет состояние', async () => {
    putMicButton(false);
    await loadContent();

    ports[0].onDisconnect.emit();
    vi.advanceTimersByTime(RECONNECT_DELAYS[0]);

    expect(ports).toHaveLength(2);
    expect(snapshots(ports[1])).toContainEqual({ context: 'in-call', muted: false });
  });

  it('успешное переподключение сбрасывает паузу к начальной', async () => {
    await loadContent();

    ports[0].onDisconnect.emit();
    vi.advanceTimersByTime(RECONNECT_DELAYS[0]);
    expect(ports).toHaveLength(2);

    // Второй порт живёт и снова умирает — пауза должна быть опять первой,
    // а не следующей по возрастанию.
    ports[1].onDisconnect.emit();
    vi.advanceTimersByTime(RECONNECT_DELAYS[0]);
    expect(ports).toHaveLength(3);
  });

  it('не плодит параллельные попытки, если обрывов было несколько', async () => {
    await loadContent();

    ports[0].onDisconnect.emit();
    ports[0].onDisconnect.emit();
    ports[0].onDisconnect.emit();
    vi.advanceTimersByTime(RECONNECT_DELAYS[0]);

    expect(ports).toHaveLength(2);
  });

  it('переживает инвалидированный контекст расширения, не роняя страницу', async () => {
    chrome = installFakeChrome();
    ports = [];
    let failures = 2;
    chrome.runtime.connect.mockImplementation(() => {
      if (failures > 0) {
        failures -= 1;
        throw new Error('Extension context invalidated');
      }
      const port = fakePort();
      ports.push(port);
      return port;
    });

    // Страница не наша — исключение из connect() ронять её не имеет права.
    await expect(import('../src/content')).resolves.toBeDefined();
    expect(ports).toHaveLength(0);

    vi.advanceTimersByTime(RECONNECT_DELAYS[0]);
    expect(ports).toHaveLength(0);
    vi.advanceTimersByTime(RECONNECT_DELAYS[1]);
    expect(ports).toHaveLength(1);
  });
});

describe('content: команды из воркера', () => {
  it('переключает кнопку по команде setMuted', async () => {
    const button = putMicButton(true);
    const clicked = vi.fn();
    button.addEventListener('click', clicked);
    await loadContent();

    ports[0].onMessage.emit({ kind: 'setMuted', muted: false });

    expect(clicked).toHaveBeenCalledOnce();
  });

  it('не кликает, когда состояние уже нужное', async () => {
    const button = putMicButton(true);
    const clicked = vi.fn();
    button.addEventListener('click', clicked);
    await loadContent();

    ports[0].onMessage.emit({ kind: 'setMuted', muted: true });

    expect(clicked).not.toHaveBeenCalled();
  });

  it('отвечает честным состоянием, если кнопки не оказалось', async () => {
    await loadContent();
    ports[0].postMessage.mockClear();

    ports[0].onMessage.emit({ kind: 'setMuted', muted: false });

    expect(snapshots(ports[0])).toContainEqual({ context: 'no-call' });
  });

  it('отвечает на poll текущим состоянием', async () => {
    putMicButton(true);
    await loadContent();
    ports[0].postMessage.mockClear();

    ports[0].onMessage.emit({ kind: 'poll' });

    expect(snapshots(ports[0])).toContainEqual({ context: 'in-call', muted: true });
  });

  it('не падает, когда порт умер между командой и ответом', async () => {
    await loadContent();
    ports[0].postMessage.mockImplementation(() => {
      throw new Error('Attempting to use a disconnected port object');
    });

    expect(() => ports[0].onMessage.emit({ kind: 'poll' })).not.toThrow();
  });
});

describe('content: уровень микрофона', () => {
  /// Уровень считает скрипт главного мира и присылает обычным postMessage.
  function postLevel(level: unknown): void {
    window.dispatchEvent(
      new window.MessageEvent('message', {
        data: { source: 'sordio-level', level },
        source: window,
      }),
    );
  }

  function levels(port: FakePort): unknown[] {
    return port.postMessage.mock.calls
      .map(([message]) => message as { kind: string; level?: unknown })
      .filter((message) => message.kind === 'level')
      .map((message) => message.level);
  }

  it('передаёт уровень воркеру', async () => {
    putMicButton(false);
    await loadContent();

    postLevel(0.42);

    expect(levels(ports[0])).toEqual([0.42]);
  });

  it('зажимает уровень в границах шкалы', async () => {
    putMicButton(false);
    await loadContent();

    postLevel(5);
    postLevel(-1);

    expect(levels(ports[0])).toEqual([1, 0]);
  });

  it('не пропускает не-число', async () => {
    putMicButton(false);
    await loadContent();

    postLevel('громко');
    postLevel(Number.NaN);
    postLevel(undefined);

    expect(levels(ports[0])).toEqual([]);
  });

  it('просит мерить в звонке и перестаёт, когда звонок кончился', async () => {
    const control: Array<{ source?: string; active?: boolean }> = [];
    window.addEventListener('message', (event) => {
      const data = event.data as { source?: string; active?: boolean };
      if (data?.source === 'sordio-level-control') control.push(data);
    });

    putMicButton(false);
    await loadContent();
    // window.postMessage доставляется отдельной задачей, а часы в тесте свои.
    await vi.advanceTimersByTimeAsync(1);
    expect(control.at(-1)?.active).toBe(true);

    // Звонок закончился: кнопки на странице больше нет.
    document.body.innerHTML = '';
    ports[0].onMessage.emit({ kind: 'poll' });
    await vi.advanceTimersByTimeAsync(1);

    expect(control.at(-1)?.active).toBe(false);
  });
});
