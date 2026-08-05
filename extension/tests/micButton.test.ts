import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { findMicButton, observeMic, readSnapshot, setMuted } from '../src/micButton';

const fixture = (name: string) =>
  readFileSync(join(__dirname, 'fixtures', `${name}.html`), 'utf8');

const load = (name: string) => {
  document.body.innerHTML = fixture(name);
  return document;
};

describe('findMicButton', () => {
  it('находит кнопку внутри звонка', () => {
    const found = findMicButton(load('in-call'), '/calls/2wp3jh');
    expect(found?.context).toBe('in-call');
    expect(found?.el.getAttribute('data-testid')).toBe('microphone');
  });

  it('находит кнопку на экране предзвонка', () => {
    const found = findMicButton(load('pre-call'), '/calls/create');
    expect(found?.context).toBe('pre-call');
    expect(found?.el.getAttribute('data-testid')).toBe('micButton');
  });

  it('не путает кнопку микрофона с кнопкой его настроек', () => {
    const found = findMicButton(load('in-call'), '/calls/2wp3jh');
    expect(found?.el.getAttribute('data-testid')).not.toBe('micSelect');
  });

  it('возвращает null, когда кнопки нет', () => {
    expect(findMicButton(load('no-call'), '/calls')).toBeNull();
  });
});

describe('findMicButton — запасной путь по aria-label', () => {
  it('находит кнопку в звонке, если data-testid переименовали', () => {
    const doc = load('in-call');
    const button = doc.querySelector('[data-testid="microphone"]')!;
    button.removeAttribute('data-testid');

    const found = findMicButton(doc, '/calls/2wp3jh');
    expect(found?.context).toBe('in-call');
    expect(found?.el).toBe(button);
  });

  it('находит кнопку на экране предзвонка, если data-testid переименовали', () => {
    const doc = load('pre-call');
    const button = doc.querySelector('[data-testid="micButton"]')!;
    button.removeAttribute('data-testid');

    const found = findMicButton(doc, '/calls/create');
    expect(found?.context).toBe('pre-call');
    expect(found?.el).toBe(button);
  });

  it('читает состояние через запасной путь так же, как через data-testid', () => {
    const doc = load('in-call');
    const button = doc.querySelector('[data-testid="microphone"]')!;
    button.removeAttribute('data-testid');

    expect(readSnapshot(doc, '/calls/2wp3jh')).toEqual({ context: 'in-call', muted: true });
  });

  it('не подставляет ложный pre-call для адреса списка встреч', () => {
    const doc = load('no-call');
    const stray = doc.createElement('button');
    stray.setAttribute('aria-label', 'Enable audio');
    stray.setAttribute('data-muted', 'true');
    doc.body.appendChild(stray);

    const found = findMicButton(doc, '/calls');
    expect(found?.context).toBe('in-call');
    expect(found?.context).not.toBe('pre-call');
  });
});

describe('readSnapshot', () => {
  it('читает выключенный микрофон из data-muted', () => {
    expect(readSnapshot(load('in-call'), '/calls/2wp3jh')).toEqual({
      context: 'in-call',
      muted: true,
    });
  });

  it('читает включённый микрофон', () => {
    const doc = load('in-call');
    doc.querySelector('[data-testid="microphone"]')!.setAttribute('data-muted', 'false');
    expect(readSnapshot(doc, '/calls/2wp3jh')).toEqual({ context: 'in-call', muted: false });
  });

  it('падает обратно на aria-label, если data-muted пропал', () => {
    const doc = load('in-call');
    const button = doc.querySelector('[data-testid="microphone"]')!;
    button.removeAttribute('data-muted');
    button.setAttribute('aria-label', 'Disable audio');
    expect(readSnapshot(doc, '/calls/2wp3jh')).toEqual({ context: 'in-call', muted: false });
  });

  it('сообщает button-not-found, если состояние прочитать нечем', () => {
    const doc = load('in-call');
    const button = doc.querySelector('[data-testid="microphone"]')!;
    button.removeAttribute('data-muted');
    button.setAttribute('aria-label', 'что-то незнакомое');
    expect(readSnapshot(doc, '/calls/2wp3jh')).toEqual({ context: 'button-not-found' });
  });

  it('сообщает button-not-found, если мы в звонке, а кнопки нет', () => {
    expect(readSnapshot(load('no-call'), '/calls/2wp3jh')).toEqual({
      context: 'button-not-found',
    });
  });

  it('сообщает no-call на списке встреч', () => {
    expect(readSnapshot(load('no-call'), '/calls')).toEqual({ context: 'no-call' });
  });
});

describe('setMuted', () => {
  it('кликает кнопку, когда нужное состояние отличается', () => {
    const doc = load('in-call');
    const button = doc.querySelector('[data-testid="microphone"]') as HTMLButtonElement;
    const click = vi.spyOn(button, 'click');

    expect(setMuted(doc, '/calls/2wp3jh', false)).toBe(true);
    expect(click).toHaveBeenCalledOnce();
  });

  it('ничего не делает, когда состояние уже нужное', () => {
    const doc = load('in-call');
    const button = doc.querySelector('[data-testid="microphone"]') as HTMLButtonElement;
    const click = vi.spyOn(button, 'click');

    expect(setMuted(doc, '/calls/2wp3jh', true)).toBe(true);
    expect(click).not.toHaveBeenCalled();
  });

  it('возвращает false, когда кнопки нет', () => {
    expect(setMuted(load('no-call'), '/calls', false)).toBe(false);
  });

  it('возвращает false и не кликает, когда состояние кнопки прочитать нечем', () => {
    const doc = load('in-call');
    const button = doc.querySelector('[data-testid="microphone"]') as HTMLButtonElement;
    button.removeAttribute('data-muted');
    button.setAttribute('aria-label', 'что-то незнакомое');
    const click = vi.spyOn(button, 'click');

    expect(setMuted(doc, '/calls/2wp3jh', false)).toBe(false);
    expect(click).not.toHaveBeenCalled();
  });
});

describe('observeMic', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('сообщает об изменении, сделанном мимо нас', async () => {
    const doc = load('in-call');
    const changes: unknown[] = [];
    const stop = observeMic(doc, () => '/calls/2wp3jh', (snapshot) => changes.push(snapshot));

    doc.querySelector('[data-testid="microphone"]')!.setAttribute('data-muted', 'false');
    await vi.waitFor(() => expect(changes.length).toBeGreaterThan(0));

    expect(changes.at(-1)).toEqual({ context: 'in-call', muted: false });
    stop();
  });

  it('замечает появление кнопки при входе в звонок', async () => {
    document.body.innerHTML = fixture('no-call');
    const changes: unknown[] = [];
    let pathname = '/calls';
    const stop = observeMic(document, () => pathname, (snapshot) => changes.push(snapshot));

    pathname = '/calls/2wp3jh';
    document.body.innerHTML = fixture('in-call');
    await vi.waitFor(() => expect(changes.at(-1)).toEqual({ context: 'in-call', muted: true }));

    stop();
  });

  it('перестаёт сообщать после остановки', async () => {
    const doc = load('in-call');
    const changes: unknown[] = [];
    const stop = observeMic(doc, () => '/calls/2wp3jh', (snapshot) => changes.push(snapshot));
    stop();

    doc.querySelector('[data-testid="microphone"]')!.setAttribute('data-muted', 'false');
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(changes).toHaveLength(0);
  });
});
