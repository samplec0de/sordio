/// Измерение уровня микрофона в главном мире страницы.
///
/// Уровень берётся у браузера, а не у macOS: страница уже держит устройство
/// ради звонка, так что приложению не нужно ни своё разрешение на микрофон,
/// ни второй захват.
///
/// Считать по той самой дорожке, которую сайт отдаёт в звонок, нельзя:
/// SaluteJazz глушит микрофон через `track.enabled = false`, и тогда уровень
/// был бы нулевым ровно в том случае, ради которого индикатор и задуман, —
/// когда человек говорит в выключенный микрофон. Поэтому дорожка клонируется:
/// у клона собственный `enabled` при общем источнике.
///
/// Скрипт живёт в главном мире и с `chrome.*` не разговаривает — только
/// `postMessage` в своё же окно, откуда сообщение забирает content script.

import { CONTROL_MESSAGE, LEVEL_MESSAGE } from './levelChannel';

/// Десять замеров в секунду: чаще незаметно на восьми делениях, реже —
/// индикатор начинает дёргаться.
export const TICK_MS = 100;

/// -50 dBFS считаем тишиной, 0 dBFS — максимумом. Шкала та же, что была у
/// прежнего нативного замера, — плашка не должна изменить поведение.
export function rmsToLevel(rms: number): number {
  if (!Number.isFinite(rms) || rms <= 0) return 0;
  const db = 20 * Math.log10(rms);
  return Math.min(1, Math.max(0, (db + 50) / 50));
}

/// Подъём быстрый, спад медленный — иначе индикатор мерцает на каждом слоге.
/// Постоянными времени, а не долей на шаг: шаг задаёт таймер, и привязка к
/// нему сделала бы скорость зависимой от того, как часто он реально срабатывает.
export class Smoother {
  private value = 0;

  constructor(
    private readonly attackTau = 0.05,
    private readonly releaseTau = 0.4,
  ) {}

  update(target: number, dt: number): number {
    const tau = target > this.value ? this.attackTau : this.releaseTau;
    const coefficient = 1 - Math.exp(-dt / tau);
    this.value += (target - this.value) * coefficient;
    return this.value;
  }

  reset(): void {
    this.value = 0;
  }
}

export interface LevelMeter {
  /// Мгновенный RMS дорожки, 0…1 в линейной шкале.
  read(): number;
  stop(): void;
}

export type MeterFactory = (track: MediaStreamTrack) => LevelMeter | null;

/// Клоны, сделанные нами. Нужны, чтобы не принять собственный клон за
/// дорожку сайта: мы сами включаем ему `enabled`, а за этим свойством следим.
const ownClones = new WeakSet<MediaStreamTrack>();

export function isOwnClone(track: MediaStreamTrack): boolean {
  return ownClones.has(track);
}

/// Клон для замера. Включать его обязательно и явно: `clone()` копирует
/// `enabled` на момент клонирования, а в звонок SaluteJazz входит с
/// выключенным микрофоном — унаследовав `false`, клон остался бы немым
/// навсегда, потому что дальше сайт трогает только свою дорожку.
export function cloneForMetering(track: MediaStreamTrack): MediaStreamTrack {
  const clone = track.clone();
  ownClones.add(clone);
  clone.enabled = true;
  return clone;
}

/// Следит за `track.enabled` и подбирает дорожки, которые прошли мимо
/// `getUserMedia`.
///
/// Второй раз `getUserMedia` SaluteJazz не вызывает никогда: микрофон он
/// переключает через `enabled`. Значит, расширение, поставленное или
/// обновлённое при уже открытой вкладке, иначе не узнало бы о дорожке до
/// перезагрузки страницы. А так её отдаёт первое же переключение микрофона.
export function watchEnabled(
  prototype: object,
  adopt: (track: MediaStreamTrack) => void,
): void {
  const descriptor = Object.getOwnPropertyDescriptor(prototype, 'enabled');
  if (!descriptor?.get || !descriptor.set) return;
  const original = descriptor;

  Object.defineProperty(prototype, 'enabled', {
    configurable: true,
    enumerable: descriptor.enumerable,
    get(this: MediaStreamTrack) {
      return original.get!.call(this);
    },
    set(this: MediaStreamTrack, value: boolean) {
      original.set!.call(this, value);
      // Своей ошибкой ломать сайту переключение микрофона нельзя.
      try {
        if (this.kind === 'audio' && !ownClones.has(this)) adopt(this);
      } catch {
        // Замер — не та задача, ради которой стоит ронять страницу.
      }
    },
  });
}

/// Хранит дорожки, найденные у `getUserMedia`, и меряет уровень, пока идёт звонок.
export class LevelProbe {
  private readonly tracks = new Set<MediaStreamTrack>();
  private readonly meters = new Map<MediaStreamTrack, LevelMeter>();
  private readonly smoother = new Smoother();
  private active = false;
  private lastSent: number | null = null;

  constructor(
    private readonly makeMeter: MeterFactory,
    private readonly post: (level: number) => void,
  ) {}

  /// Новый поток от `getUserMedia`.
  track(stream: MediaStream): void {
    for (const track of stream.getAudioTracks()) this.adopt(track);
  }

  /// Дорожка, найденная любым путём.
  adopt(track: MediaStreamTrack): void {
    if (track.readyState === 'ended' || this.tracks.has(track)) return;
    this.tracks.add(track);
    if (this.active) this.openMeters();
  }

  /// Для диагностики: видно ли расширению дорожку и меряет ли оно.
  describe(): { active: boolean; tracks: number; meters: number; level: number | null } {
    return {
      active: this.active,
      tracks: this.tracks.size,
      meters: this.meters.size,
      level: this.lastSent,
    };
  }

  /// Звонок идёт или нет. Вне звонка клон не держим вовсе: он продлевал бы
  /// захват устройства ровно в том случае, когда это никому не нужно.
  setActive(active: boolean): void {
    if (active === this.active) return;
    this.active = active;
    if (active) {
      this.openMeters();
    } else {
      this.closeMeters();
      this.smoother.reset();
      this.send(0);
    }
  }

  tick(dtSeconds: number): void {
    this.forgetEndedTracks();
    if (!this.active) return;
    this.openMeters();

    let peak = 0;
    for (const meter of this.meters.values()) {
      peak = Math.max(peak, rmsToLevel(meter.read()));
    }
    this.send(this.smoother.update(peak, dtSeconds));
  }

  private openMeters(): void {
    for (const track of this.tracks) {
      if (this.meters.has(track) || track.readyState === 'ended') continue;
      const meter = this.makeMeter(track);
      if (meter) this.meters.set(track, meter);
    }
  }

  private closeMeters(): void {
    for (const meter of this.meters.values()) meter.stop();
    this.meters.clear();
  }

  /// Сайт может закончить звонок, остановив дорожку: тогда клон тоже пора
  /// закрыть, иначе он один продолжит держать микрофон открытым.
  private forgetEndedTracks(): void {
    for (const track of this.tracks) {
      if (track.readyState !== 'ended') continue;
      this.meters.get(track)?.stop();
      this.meters.delete(track);
      this.tracks.delete(track);
    }
  }

  private send(level: number): void {
    const rounded = Math.round(level * 100) / 100;
    if (rounded === this.lastSent) return;
    this.lastSent = rounded;
    this.post(rounded);
  }
}

function createAudioMeter(track: MediaStreamTrack): LevelMeter | null {
  const Ctx = window.AudioContext;
  if (!Ctx) return null;

  const clone = cloneForMetering(track);
  const context = new Ctx();
  const source = context.createMediaStreamSource(new MediaStream([clone]));
  const analyser = context.createAnalyser();
  analyser.fftSize = 2048;
  source.connect(analyser);
  const samples = new Float32Array(analyser.fftSize);

  return {
    read() {
      // Без жеста пользователя контекст создаётся приостановленным.
      if (context.state === 'suspended') void context.resume();
      analyser.getFloatTimeDomainData(samples);
      let sum = 0;
      for (let i = 0; i < samples.length; i += 1) sum += samples[i] * samples[i];
      return Math.sqrt(sum / samples.length);
    },
    stop() {
      clone.stop();
      source.disconnect();
      void context.close();
    },
  };
}

export function install(target: Window = window): void {
  const probe = new LevelProbe(createAudioMeter, (level) => {
    target.postMessage({ source: LEVEL_MESSAGE, level }, target.location.origin);
  });

  const devices = target.navigator?.mediaDevices;
  if (devices?.getUserMedia) {
    const original = devices.getUserMedia.bind(devices);
    devices.getUserMedia = async (constraints?: MediaStreamConstraints) => {
      const stream = await original(constraints);
      probe.track(stream);
      return stream;
    };
  }

  const trackPrototype = (target as unknown as { MediaStreamTrack?: { prototype: object } })
    .MediaStreamTrack?.prototype;
  if (trackPrototype) watchEnabled(trackPrototype, (track) => probe.adopt(track));

  // Точка для диагностики из консоли страницы: `__sordio.state`.
  Object.defineProperty(target, '__sordio', {
    configurable: true,
    value: {
      get state() {
        return probe.describe();
      },
    },
  });

  target.addEventListener('message', (event: MessageEvent) => {
    if (event.source !== target) return;
    const data = event.data as { source?: string; active?: boolean } | null;
    if (!data || data.source !== CONTROL_MESSAGE) return;
    probe.setActive(data.active === true);
  });

  target.setInterval(() => probe.tick(TICK_MS / 1000), TICK_MS);
}
