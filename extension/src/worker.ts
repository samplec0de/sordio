import { Bridge } from './bridge';
import { levelMessage, stateMessage } from './protocol';
import type { MicSnapshot } from './protocol';

const PORTS = [8765, 8766, 8767, 8768, 8769, 8770, 8771, 8772, 8773, 8774, 8775];

interface Tab {
  port: chrome.runtime.Port;
  snapshot: MicSnapshot;
  updatedAt: number;
}

const tabs = new Map<number, Tab>();

const SECRET_KEY = 'pairingSecret';

const bridge = new Bridge({
  ports: PORTS,
  extensionId: chrome.runtime.id,
  onPaired: (secret) => {
    void chrome.storage.local.set({ [SECRET_KEY]: secret });
  },
  onOpen: () => publish(),
  onMessage: (message) => {
    if (message.type !== 'command') return;
    const target = pickTab();
    if (!target) {
      publish();
      return;
    }
    try {
      target.port.postMessage({ kind: 'setMuted', id: message.id, muted: message.muted });
    } catch {
      // Порт вкладки уже мёртв, а её onDisconnect ещё не долетел до
      // обработчика — не даём исключению вылететь из обработчика сообщений моста.
    }
  },
});

// Секрет мог быть выдан в прошлой жизни воркера — поднимаем его до старта,
// иначе приложение снова покажет диалог спаривания.
void chrome.storage.local.get(SECRET_KEY).then((stored) => {
  const secret = stored[SECRET_KEY];
  if (typeof secret === 'string') bridge.useSecret(secret);
  bridge.start();
});

/// Управляем той вкладкой, где действительно идёт звонок.
/// Если таких несколько — последней, где что-то менялось.
function pickTab(): Tab | null {
  const ranked = [...tabs.values()].sort((a, b) => rank(b) - rank(a) || b.updatedAt - a.updatedAt);
  const best = ranked[0];
  if (!best) return null;
  return rank(best) > 0 ? best : null;
}

function rank(tab: Tab): number {
  switch (tab.snapshot.context) {
    case 'in-call':
      return 3;
    case 'pre-call':
      return 2;
    case 'button-not-found':
      return 1;
    default:
      return 0;
  }
}

function publish(): void {
  const best = [...tabs.values()].sort((a, b) => rank(b) - rank(a) || b.updatedAt - a.updatedAt)[0];
  bridge.send(stateMessage(best ? best.snapshot : { context: 'no-call' }));
}

chrome.runtime.onConnect.addListener((port) => {
  const tabId = port.sender?.tab?.id;
  if (port.name !== 'sordio-tab' || tabId === undefined) return;

  tabs.set(tabId, { port, snapshot: { context: 'no-call' }, updatedAt: Date.now() });

  port.onMessage.addListener((message: { kind: string; snapshot?: MicSnapshot; level?: number }) => {
    const tab = tabs.get(tabId);
    if (!tab) return;

    if (message.kind === 'level' && typeof message.level === 'number') {
      // Уровень принимаем только от той вкладки, которой сейчас управляем:
      // иначе вторая открытая вкладка SaluteJazz дёргала бы индикатор.
      if (pickTab() === tab) bridge.send(levelMessage(message.level));
      return;
    }

    if (message.kind !== 'snapshot' || !message.snapshot) return;
    tab.snapshot = message.snapshot;
    tab.updatedAt = Date.now();
    publish();
  });

  port.onDisconnect.addListener(() => {
    tabs.delete(tabId);
    publish();
  });

  publish();
});

// Service worker в MV3 засыпает. Активность сокета продлевает ему жизнь,
// а будильник поднимает его, если сон всё же случился.
chrome.alarms.create('sordio-keepalive', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(() => {
  if (!bridge.isConnected) bridge.start();
});
