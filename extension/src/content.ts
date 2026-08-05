import { CONTROL_MESSAGE, LEVEL_MESSAGE } from './levelChannel';
import { observeMic, readSnapshot, setMuted } from './micButton';
import type { MicSnapshot } from './protocol';

/// Содержимое вкладки: следит за кнопкой и выполняет команды.
/// Разговаривает только с service worker — сеть целиком его забота.
const pathname = () => location.pathname;

// Воркер в MV3 усыпает — это штатное поведение, а не сбой. SaluteJazz при
// этом не перезагружает страницу (SPA), так что канал переподключаем сами:
// растущая пауза, чтобы не молотить впустую, если воркер долго не поднимается.
const RECONNECT_DELAYS = [300, 600, 1200, 2500, 5000];

let port: chrome.runtime.Port | null = null;
let reconnectAttempt = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

const report = (snapshot: MicSnapshot) => {
  if (!port) return;
  try {
    port.postMessage({ kind: 'snapshot', snapshot });
  } catch {
    // Порт уже мёртв, просто onDisconnect ещё не долетел — переподключение
    // запустит его же обработчик.
  }
};

/// Уровень меряет скрипт главного мира (`level.ts`) — сюда он приходит
/// обычным `postMessage`. Значение целиком косметическое: страница может
/// прислать любое, поэтому его достаточно проверить на диапазон.
const sendLevel = (level: number) => {
  if (!port) return;
  try {
    port.postMessage({ kind: 'level', level });
  } catch {
    // Порт уже мёртв — переподключение запустит onDisconnect.
  }
};

function handleWindowMessage(event: MessageEvent): void {
  if (event.source !== window) return;
  const data = event.data as { source?: string; level?: unknown } | null;
  if (!data || data.source !== LEVEL_MESSAGE) return;
  if (typeof data.level !== 'number' || !Number.isFinite(data.level)) return;
  sendLevel(Math.min(1, Math.max(0, data.level)));
}

/// Замер нужен только в звонке — предзвонок не в счёт: там ещё нет разговора,
/// а клон дорожки держал бы микрофон открытым.
function publish(snapshot: MicSnapshot): void {
  window.postMessage(
    { source: CONTROL_MESSAGE, active: snapshot.context === 'in-call' },
    location.origin,
  );
  report(snapshot);
}

function handleMessage(message: { kind: string; id?: string; muted?: boolean }): void {
  if (message.kind === 'setMuted' && typeof message.muted === 'boolean') {
    const applied = setMuted(document, pathname(), message.muted);
    // Состояние всё равно придёт через MutationObserver — здесь только
    // честный ответ на случай, если кнопки не оказалось.
    if (!applied) publish(readSnapshot(document, pathname()));
  }
  if (message.kind === 'poll') {
    publish(readSnapshot(document, pathname()));
  }
}

function handleDisconnect(): void {
  port = null;
  scheduleReconnect();
}

function connect(): void {
  try {
    port = chrome.runtime.connect({ name: 'sordio-tab' });
  } catch {
    // Расширение перезагружается или контекст уже инвалидирован — страница
    // не наша, ронять её нельзя. Пробуем снова по таймеру.
    port = null;
    scheduleReconnect();
    return;
  }

  port.onMessage.addListener(handleMessage);
  port.onDisconnect.addListener(handleDisconnect);
  reconnectAttempt = 0;

  // Воркер мог проспать эту вкладку и забыть её состояние — сразу шлём
  // актуальный снапшот, не дожидаясь следующего изменения кнопки.
  publish(readSnapshot(document, pathname()));
}

function scheduleReconnect(): void {
  if (reconnectTimer !== null) return;
  const delay = RECONNECT_DELAYS[Math.min(reconnectAttempt, RECONNECT_DELAYS.length - 1)];
  reconnectAttempt += 1;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

// Наблюдение живёт весь срок жизни страницы — оно не зависит от состояния
// порта: report() сам не отправляет ничего, пока порт не поднят.
observeMic(document, pathname, publish);

// SaluteJazz — SPA: переход между экранами не перезагружает страницу.
window.addEventListener('popstate', () => publish(readSnapshot(document, pathname())));

window.addEventListener('message', handleWindowMessage);

connect();
