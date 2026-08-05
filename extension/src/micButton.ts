import type { MicContext, MicSnapshot } from './protocol';

/// Цепочка селекторов с деградацией: сначала машиночитаемые data-testid,
/// затем aria-label. Если не нашли ничего — сообщаем честно, а не молчим.
const CANDIDATES: Array<{ selector: string; context: Extract<MicContext, 'in-call' | 'pre-call'> }> = [
  { selector: 'button[data-testid="microphone"]', context: 'in-call' },
  { selector: 'button[data-testid="micButton"]', context: 'pre-call' },
];

const ARIA_MUTED = 'enable audio';
const ARIA_UNMUTED = 'disable audio';

export interface FoundButton {
  el: HTMLButtonElement;
  context: 'in-call' | 'pre-call';
}

export function findMicButton(root: Document, pathname: string): FoundButton | null {
  for (const { selector, context } of CANDIDATES) {
    const el = root.querySelector<HTMLButtonElement>(selector);
    if (el) return { el, context };
  }

  // Запасной путь на случай, если у кнопки поменяют data-testid.
  const byAria = Array.from(root.querySelectorAll<HTMLButtonElement>('button[aria-label]')).find(
    (button) => {
      const label = button.getAttribute('aria-label')?.toLowerCase() ?? '';
      return label === ARIA_MUTED || label === ARIA_UNMUTED;
    },
  );
  if (byAria) {
    return { el: byAria, context: isPreCall(pathname) ? 'pre-call' : 'in-call' };
  }

  return null;
}

function isPreCall(pathname: string): boolean {
  return pathname === '/calls/create';
}

/// Страницы, на которых кнопка микрофона обязана быть.
function expectsButton(pathname: string): boolean {
  if (isPreCall(pathname)) return true;
  return /^\/calls\/[^/]+$/.test(pathname);
}

function readMuted(el: HTMLButtonElement): boolean | undefined {
  const attribute = el.getAttribute('data-muted');
  if (attribute === 'true') return true;
  if (attribute === 'false') return false;

  const label = el.getAttribute('aria-label')?.toLowerCase() ?? '';
  if (label === ARIA_MUTED) return true;
  if (label === ARIA_UNMUTED) return false;

  return undefined;
}

export function readSnapshot(root: Document, pathname: string): MicSnapshot {
  const found = findMicButton(root, pathname);
  if (!found) {
    return { context: expectsButton(pathname) ? 'button-not-found' : 'no-call' };
  }

  const muted = readMuted(found.el);
  if (muted === undefined) {
    return { context: 'button-not-found' };
  }
  return { context: found.context, muted };
}

/// Возвращает false, если кнопки нет или её состояние нечем прочитать —
/// в обоих случаях вызывающий отправит честное состояние, а не рискнёт кликнуть вслепую.
export function setMuted(root: Document, pathname: string, muted: boolean): boolean {
  const found = findMicButton(root, pathname);
  if (!found) return false;

  const current = readMuted(found.el);
  if (current === undefined) return false;  // состояние нечем прочитать — кликать вслепую нельзя,
                                             // клик всегда переключает, а не устанавливает состояние
  if (current === muted) return true;   // уже в нужном состоянии, команда идемпотентна

  found.el.click();
  return true;
}

/// Следит и за изменением состояния кнопки, и за её появлением/исчезновением.
export function observeMic(
  root: Document,
  pathname: () => string,
  onChange: (snapshot: MicSnapshot) => void,
): () => void {
  let last = '';

  const report = () => {
    const snapshot = readSnapshot(root, pathname());
    const serialized = JSON.stringify(snapshot);
    if (serialized === last) return;
    last = serialized;
    onChange(snapshot);
  };

  const observer = new MutationObserver(report);
  observer.observe(root.documentElement ?? root.body, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['data-muted', 'aria-label', 'data-testid'],
  });

  return () => observer.disconnect();
}
