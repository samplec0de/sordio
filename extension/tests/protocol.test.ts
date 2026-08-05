import { describe, expect, it } from 'vitest';
import { PROTOCOL_VERSION, parseInbound, stateMessage } from '../src/protocol';

describe('stateMessage', () => {
  it('переносит контекст и состояние микрофона', () => {
    expect(stateMessage({ context: 'in-call', muted: true })).toEqual({
      v: PROTOCOL_VERSION,
      type: 'state',
      context: 'in-call',
      muted: true,
    });
  });

  it('не выдумывает muted, когда состояние неизвестно', () => {
    // «Кнопки нет» и «кнопка есть, микрофон открыт» — разные новости:
    // отсутствие поля приложение трактует как «управлять нечем».
    expect(stateMessage({ context: 'no-call' })).toEqual({
      v: PROTOCOL_VERSION,
      type: 'state',
      context: 'no-call',
    });
    expect('muted' in stateMessage({ context: 'button-not-found' })).toBe(false);
  });

  it('сохраняет muted: false, а не выбрасывает его как ложное значение', () => {
    expect(stateMessage({ context: 'in-call', muted: false })).toEqual({
      v: PROTOCOL_VERSION,
      type: 'state',
      context: 'in-call',
      muted: false,
    });
  });
});

describe('parseInbound', () => {
  const encode = (obj: unknown) => JSON.stringify(obj);

  it('разбирает welcome', () => {
    expect(parseInbound(encode({ v: 1, type: 'welcome' }))).toEqual({ v: 1, type: 'welcome' });
  });

  it('разбирает paired с секретом', () => {
    expect(parseInbound(encode({ v: 1, type: 'paired', secret: 's3' }))).toEqual({
      v: 1,
      type: 'paired',
      secret: 's3',
    });
  });

  it('разбирает команду setMuted', () => {
    expect(parseInbound(encode({ v: 1, type: 'command', action: 'setMuted', id: 'c1', muted: false }))).toEqual({
      v: 1,
      type: 'command',
      action: 'setMuted',
      id: 'c1',
      muted: false,
    });
  });

  it('возвращает null на мусоре вместо исключения', () => {
    expect(parseInbound('не json')).toBeNull();
    expect(parseInbound('null')).toBeNull();
    expect(parseInbound('42')).toBeNull();
    expect(parseInbound('[]')).toBeNull();
  });

  it('отвергает чужую версию протокола', () => {
    expect(parseInbound(encode({ v: 2, type: 'welcome' }))).toBeNull();
    expect(parseInbound(encode({ type: 'welcome' }))).toBeNull();
  });

  it('отвергает неизвестный тип', () => {
    expect(parseInbound(encode({ v: 1, type: 'levitate' }))).toBeNull();
  });

  it('отвергает ack: подтверждений в протоколе нет', () => {
    expect(parseInbound(encode({ v: 1, type: 'ack', id: 'c1', ok: true }))).toBeNull();
  });

  it('отвергает неполную или неправильно типизированную команду', () => {
    expect(parseInbound(encode({ v: 1, type: 'command', action: 'setMuted', id: 'c1' }))).toBeNull();
    expect(parseInbound(encode({ v: 1, type: 'command', action: 'setMuted', muted: true }))).toBeNull();
    expect(
      parseInbound(encode({ v: 1, type: 'command', action: 'setMuted', id: 'c1', muted: 'да' })),
    ).toBeNull();
    expect(parseInbound(encode({ v: 1, type: 'command', action: 'selfDestruct', id: 'c1', muted: true }))).toBeNull();
  });

  it('отвергает paired без секрета', () => {
    expect(parseInbound(encode({ v: 1, type: 'paired' }))).toBeNull();
  });
});
