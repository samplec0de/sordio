export const PROTOCOL_VERSION = 1;

export type MicContext = 'in-call' | 'pre-call' | 'no-call' | 'button-not-found';

export interface MicSnapshot {
  context: MicContext;
  muted?: boolean;
}

/// Подтверждения команды в протоколе нет намеренно: источник истины один —
/// состояние страницы, и оно приезжает обычным `state`.
export type OutboundMessage =
  | { v: number; type: 'hello'; extensionId: string; secret?: string }
  | { v: number; type: 'state'; context: MicContext; muted?: boolean }
  | { v: number; type: 'level'; level: number };

export type InboundMessage =
  | { v: number; type: 'welcome' }
  | { v: number; type: 'paired'; secret: string }
  | { v: number; type: 'command'; action: 'setMuted'; id: string; muted: boolean };

export function stateMessage(snapshot: MicSnapshot): OutboundMessage {
  const message: OutboundMessage = {
    v: PROTOCOL_VERSION,
    type: 'state',
    context: snapshot.context,
  };
  if (snapshot.muted !== undefined) {
    message.muted = snapshot.muted;
  }
  return message;
}

/// Уровень сигнала, 0…1. Округляем до сотых: шлём десять раз в секунду, а
/// делений на индикаторе восемь — лишние знаки только раздувают трафик.
export function levelMessage(level: number): OutboundMessage {
  const clamped = Number.isFinite(level) ? Math.min(1, Math.max(0, level)) : 0;
  return { v: PROTOCOL_VERSION, type: 'level', level: Math.round(clamped * 100) / 100 };
}

export function parseInbound(raw: string): InboundMessage | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null) return null;

  const message = parsed as Record<string, unknown>;
  if (message.v !== PROTOCOL_VERSION) return null;

  if (message.type === 'welcome') {
    return { v: PROTOCOL_VERSION, type: 'welcome' };
  }
  if (message.type === 'paired' && typeof message.secret === 'string') {
    return { v: PROTOCOL_VERSION, type: 'paired', secret: message.secret };
  }
  if (
    message.type === 'command' &&
    message.action === 'setMuted' &&
    typeof message.id === 'string' &&
    typeof message.muted === 'boolean'
  ) {
    return {
      v: PROTOCOL_VERSION,
      type: 'command',
      action: 'setMuted',
      id: message.id,
      muted: message.muted,
    };
  }
  return null;
}
