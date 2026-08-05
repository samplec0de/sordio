import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { Bridge } from '../src/bridge';
import { PROTOCOL_VERSION, levelMessage, parseInbound, stateMessage } from '../src/protocol';
import type { MicSnapshot } from '../src/protocol';

/// Зеркало протокола: обе половины (Swift и TypeScript) обязаны одинаково
/// понимать один и тот же набор эталонных строк.
///
/// Протокол объявлен дважды, а половины тестируются порознь — расхождение
/// между ними не поймал бы ни один существующий тест. Парный тест лежит в
/// app/Tests/SordioCoreTests/ProtocolMirrorTests.swift и читает тот же файл.

interface Fixture {
  name: string;
  json: string;
  message: Record<string, unknown>;
}

// Путь от корня проекта расширения: в jsdom-окружении import.meta.url — не
// файловый URL, а vitest всегда запускается из extension/.
const fixtures = JSON.parse(
  readFileSync(resolve(process.cwd(), '../shared/protocol-fixtures.json'), 'utf8'),
) as {
  version: number;
  extensionToApp: Fixture[];
  appToExtension: Fixture[];
};

/// Хватает первое сообщение, отправленное мостом, — hello строит именно он.
class CapturingSocket {
  static last: CapturingSocket | null = null;
  sent: string[] = [];
  readyState = 0;
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;

  constructor() {
    CapturingSocket.last = this;
  }

  open() {
    this.readyState = 1;
    this.onopen?.();
  }

  send(data: string) {
    this.sent.push(data);
  }

  close() {
    this.readyState = 3;
  }
}

describe('зеркало протокола', () => {
  it('версия фикстур совпадает с версией расширения', () => {
    expect(fixtures.version).toBe(PROTOCOL_VERSION);
  });

  it('строки фикстур соответствуют объявленным сообщениям', () => {
    expect(fixtures.extensionToApp.length).toBeGreaterThan(0);
    expect(fixtures.appToExtension.length).toBeGreaterThan(0);

    for (const fixture of [...fixtures.extensionToApp, ...fixtures.appToExtension]) {
      expect(JSON.parse(fixture.json), fixture.name).toEqual({
        v: PROTOCOL_VERSION,
        ...fixture.message,
      });
    }
  });

  it('разбирает всё, что отправляет приложение', () => {
    for (const fixture of fixtures.appToExtension) {
      expect(parseInbound(fixture.json), fixture.name).toEqual({
        v: PROTOCOL_VERSION,
        ...fixture.message,
      });
    }
  });

  it('отправляет ровно то, что приложение умеет разбирать', () => {
    const states = fixtures.extensionToApp.filter((f) => f.message.type === 'state');
    expect(states.length).toBeGreaterThan(0);

    for (const fixture of states) {
      const snapshot = { context: fixture.message.context } as MicSnapshot;
      if (fixture.message.muted !== undefined) {
        snapshot.muted = fixture.message.muted as boolean;
      }
      expect(stateMessage(snapshot), fixture.name).toEqual(JSON.parse(fixture.json));
    }
  });

  it('шлёт уровень ровно так, как записано в фикстуре', () => {
    const levels = fixtures.extensionToApp.filter((f) => f.message.type === 'level');
    expect(levels.length).toBeGreaterThan(0);

    for (const fixture of levels) {
      expect(levelMessage(fixture.message.level as number), fixture.name).toEqual(
        JSON.parse(fixture.json),
      );
    }
  });

  it('представляется ровно так, как записано в фикстуре', () => {
    const hellos = fixtures.extensionToApp.filter((f) => f.message.type === 'hello');
    expect(hellos.length).toBeGreaterThan(0);

    for (const fixture of hellos) {
      const bridge = new Bridge({
        ports: [8765],
        extensionId: fixture.message.extensionId as string,
        secret: (fixture.message.secret as string | undefined) ?? null,
        createSocket: () => new CapturingSocket() as unknown as WebSocket,
      });
      bridge.start();
      CapturingSocket.last!.open();

      expect(JSON.parse(CapturingSocket.last!.sent[0]), fixture.name).toEqual(
        JSON.parse(fixture.json),
      );
      bridge.stop();
    }
  });
});
