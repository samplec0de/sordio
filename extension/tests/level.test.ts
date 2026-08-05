import { beforeEach, describe, expect, it } from 'vitest';
import { LevelProbe, Smoother, cloneForMetering, isOwnClone, rmsToLevel, watchEnabled } from '../src/level';
import type { LevelMeter } from '../src/level';

/// Дорожка ровно в том объёме, в каком её трогает замер.
class FakeTrack {
  readyState: 'live' | 'ended' = 'live';
  constructor(public readonly name = 'mic') {}
  end() {
    this.readyState = 'ended';
  }
}

class FakeMeter implements LevelMeter {
  stopped = false;
  constructor(public rms = 0) {}
  read() {
    return this.rms;
  }
  stop() {
    this.stopped = true;
  }
}

const streamOf = (...tracks: FakeTrack[]) =>
  ({ getAudioTracks: () => tracks }) as unknown as MediaStream;

describe('rmsToLevel', () => {
  it('считает тишиной всё тише -50 dBFS', () => {
    expect(rmsToLevel(0)).toBe(0);
    expect(rmsToLevel(0.001)).toBe(0);
  });

  it('отдаёт единицу на полной шкале', () => {
    expect(rmsToLevel(1)).toBe(1);
  });

  it('кладёт -25 dBFS ровно на середину', () => {
    expect(rmsToLevel(10 ** (-25 / 20))).toBeCloseTo(0.5, 5);
  });

  it('не падает на мусорном значении', () => {
    expect(rmsToLevel(Number.NaN)).toBe(0);
    expect(rmsToLevel(-1)).toBe(0);
  });
});

describe('Smoother', () => {
  it('поднимается быстрее, чем опускается', () => {
    const up = new Smoother();
    const down = new Smoother();
    up.update(1, 0.1);
    for (let i = 0; i < 20; i += 1) down.update(1, 0.1);

    const risen = up.update(1, 0);
    const fallen = down.update(0, 0.1);
    expect(risen).toBeGreaterThan(0.8);
    expect(fallen).toBeGreaterThan(0.7);
  });

  it('сбрасывается в ноль', () => {
    const smoother = new Smoother();
    smoother.update(1, 1);
    smoother.reset();
    expect(smoother.update(0, 0)).toBe(0);
  });
});

describe('LevelProbe', () => {
  let meters: FakeMeter[];
  let sent: number[];
  let probe: LevelProbe;

  const make = (rms = 0) => {
    const meter = new FakeMeter(rms);
    meters.push(meter);
    return meter;
  };

  beforeEach(() => {
    meters = [];
    sent = [];
    probe = new LevelProbe(() => make(1), (level) => sent.push(level));
  });

  it('вне звонка не открывает дорожку вовсе', () => {
    probe.track(streamOf(new FakeTrack()));
    probe.tick(0.1);

    expect(meters).toHaveLength(0);
    expect(sent).toEqual([]);
  });

  it('начинает мерить, когда начался звонок', () => {
    probe.track(streamOf(new FakeTrack()));
    probe.setActive(true);
    probe.tick(0.1);

    expect(meters).toHaveLength(1);
    expect(sent.at(-1)).toBeGreaterThan(0);
  });

  it('подхватывает дорожку, появившуюся уже в звонке', () => {
    probe.setActive(true);
    probe.track(streamOf(new FakeTrack()));
    probe.tick(0.1);

    expect(meters).toHaveLength(1);
  });

  it('отпускает микрофон и обнуляет уровень, когда звонок кончился', () => {
    probe.track(streamOf(new FakeTrack()));
    probe.setActive(true);
    probe.tick(0.1);
    probe.setActive(false);

    expect(meters[0].stopped).toBe(true);
    expect(sent.at(-1)).toBe(0);
  });

  it('закрывает клон, когда сайт остановил свою дорожку', () => {
    const track = new FakeTrack();
    probe.track(streamOf(track));
    probe.setActive(true);
    probe.tick(0.1);

    track.end();
    probe.tick(0.1);

    expect(meters[0].stopped).toBe(true);
    // Дорожка забыта: повторный тик не открывает её заново.
    probe.tick(0.1);
    expect(meters).toHaveLength(1);
  });

  it('берёт самую громкую из нескольких дорожек', () => {
    const quiet = new FakeTrack('тихая');
    const loud = new FakeTrack('громкая');
    const byTrack = new Map<unknown, number>([
      [quiet, 10 ** (-45 / 20)],
      [loud, 10 ** (-15 / 20)],
    ]);
    probe = new LevelProbe(
      (track) => new FakeMeter(byTrack.get(track) ?? 0),
      (level) => sent.push(level),
    );

    probe.track(streamOf(quiet, loud));
    probe.setActive(true);
    for (let i = 0; i < 30; i += 1) probe.tick(0.1);

    expect(sent.at(-1)).toBeCloseTo(0.7, 1);
  });

  it('не повторяет одно и то же значение', () => {
    probe = new LevelProbe(() => make(0), (level) => sent.push(level));
    probe.track(streamOf(new FakeTrack()));
    probe.setActive(true);
    for (let i = 0; i < 5; i += 1) probe.tick(0.1);

    // Первый ноль — это первое известное значение, а не повтор.
    expect(sent).toEqual([0]);
  });
});

describe('cloneForMetering', () => {
  /// `clone()` копирует `enabled` на момент клонирования, а в звонок
  /// SaluteJazz входит с выключенным микрофоном.
  function trackWithClone(enabled: boolean) {
    const clone = { enabled, kind: 'audio', readyState: 'live' as const };
    return { clone: () => clone, enabled, kind: 'audio' } as unknown as MediaStreamTrack;
  }

  it('включает клон, снятый с заглушённой дорожки', () => {
    const clone = cloneForMetering(trackWithClone(false));
    expect(clone.enabled).toBe(true);
  });

  it('помечает клон своим, чтобы не принять его за дорожку сайта', () => {
    const clone = cloneForMetering(trackWithClone(true));
    expect(isOwnClone(clone)).toBe(true);
  });
});

describe('watchEnabled', () => {
  class Track {
    kind = 'audio';
    #enabled = true;
    get enabled() {
      return this.#enabled;
    }
    set enabled(value: boolean) {
      this.#enabled = value;
    }
  }

  it('отдаёт дорожку, когда сайт переключает микрофон', () => {
    const seen: unknown[] = [];
    watchEnabled(Track.prototype, (track) => seen.push(track));

    const track = new Track();
    track.enabled = false;

    expect(seen).toEqual([track]);
    expect(track.enabled).toBe(false);
  });

  it('не подбирает собственный клон', () => {
    const seen: unknown[] = [];
    watchEnabled(Track.prototype, (track) => seen.push(track));

    const source = { clone: () => new Track() } as unknown as MediaStreamTrack;
    cloneForMetering(source);

    expect(seen).toEqual([]);
  });

  it('не роняет сайт, если подбор бросил исключение', () => {
    watchEnabled(Track.prototype, () => {
      throw new Error('что-то пошло не так');
    });

    const track = new Track();
    expect(() => {
      track.enabled = false;
    }).not.toThrow();
    expect(track.enabled).toBe(false);
  });
});

describe('LevelProbe.adopt', () => {
  it('подбирает дорожку и начинает мерить прямо в звонке', () => {
    const made: FakeMeter[] = [];
    const probe = new LevelProbe(
      () => {
        const meter = new FakeMeter(1);
        made.push(meter);
        return meter;
      },
      () => {},
    );
    probe.setActive(true);
    probe.adopt(new FakeTrack() as unknown as MediaStreamTrack);

    expect(made).toHaveLength(1);
  });

  it('не берёт одну дорожку дважды и не берёт закрытую', () => {
    const made: FakeMeter[] = [];
    const probe = new LevelProbe(
      () => {
        const meter = new FakeMeter(1);
        made.push(meter);
        return meter;
      },
      () => {},
    );
    probe.setActive(true);

    const track = new FakeTrack() as unknown as MediaStreamTrack;
    probe.adopt(track);
    probe.adopt(track);

    const dead = new FakeTrack();
    dead.end();
    probe.adopt(dead as unknown as MediaStreamTrack);

    expect(made).toHaveLength(1);
  });
});
