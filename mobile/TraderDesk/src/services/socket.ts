/**
 * Phoenix WebSocket client for the mobile app.
 *
 * Connects to wss://host/mobile/websocket?token=<bearer_token>
 * and joins channels:
 *   - "alerts:<product_group>"   → threshold breaches + pipeline events
 *   - "variables:<product_group>" → live variable updates
 *
 * The trader must opt-in to alerts per product group.
 * When a threshold_breach event arrives and the trader has alerts enabled,
 * a local notification is fired AND the event is stored for in-app display.
 */

import {MMKV} from 'react-native-mmkv';

const storage = new MMKV({id: 'trader-desk-socket'});

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ThresholdBreachEvent {
  variable: string;
  current: number;
  baseline: number;
  delta: number;
  threshold: number;
  product_group: string;
  timestamp: string;
}

export interface PipelineEvent {
  event: string;
  run_id: string;
  product_group?: string;
  mode?: string;
  timestamp?: string;
}

export interface VariablesUpdatedEvent {
  product_group: string;
  variables: Record<string, number | boolean>;
}

type ThresholdBreachHandler = (event: ThresholdBreachEvent) => void;
type PipelineEventHandler = (event: PipelineEvent) => void;
type VariablesUpdatedHandler = (event: VariablesUpdatedEvent) => void;
type ConnectionHandler = (connected: boolean) => void;

// ─── Simple Phoenix channel protocol implementation ───────────────────────────
// (lightweight — avoids adding a full phoenix-js dependency)

const MSG_JOIN = 'phx_join';
const MSG_LEAVE = 'phx_leave';
const MSG_HEARTBEAT = 'heartbeat';
const MSG_REPLY = 'phx_reply';
const MSG_ERROR = 'phx_error';
const MSG_CLOSE = 'phx_close';

interface PhxMessage {
  join_ref: string | null;
  ref: string | null;
  topic: string;
  event: string;
  payload: unknown;
}

// ─── Socket class ─────────────────────────────────────────────────────────────

export class TradingDeskSocket {
  private ws: WebSocket | null = null;
  private token: string = '';
  private serverUrl: string = '';
  private ref = 1;
  private joinedChannels: Map<string, string> = new Map(); // topic → join_ref
  private heartbeatInterval: ReturnType<typeof setInterval> | null = null;
  private reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
  private reconnectDelay = 1000;
  private destroyed = false;

  // Event handlers
  private onThresholdBreach: ThresholdBreachHandler[] = [];
  private onPipelineEvent: PipelineEventHandler[] = [];
  private onVariablesUpdated: VariablesUpdatedHandler[] = [];
  private onConnectionChange: ConnectionHandler[] = [];

  constructor(serverUrl: string, token: string) {
    this.serverUrl = serverUrl;
    this.token = token;
  }

  // ── Connection lifecycle ──────────────────────────────────────────────────

  connect(subscribedGroups: string[]): void {
    this.destroyed = false;
    this.doConnect(subscribedGroups);
  }

  private doConnect(groups: string[]): void {
    if (this.ws) {
      try { this.ws.close(); } catch (_) {}
    }

    const wsUrl = this.serverUrl
      .replace(/^https/, 'wss')
      .replace(/^http/, 'ws');

    this.ws = new WebSocket(`${wsUrl}/mobile/websocket?token=${encodeURIComponent(this.token)}`);

    this.ws.onopen = () => {
      this.reconnectDelay = 1000;
      this.startHeartbeat();
      this.notifyConnection(true);

      // Join one channel per product group
      for (const group of groups) {
        this.joinChannel(`alerts:${group}`);
        this.joinChannel(`variables:${group}`);
      }
    };

    this.ws.onmessage = (ev: MessageEvent) => {
      try {
        const msg: PhxMessage = JSON.parse(ev.data as string);
        this.handleMessage(msg);
      } catch (_) {}
    };

    this.ws.onerror = () => {};

    this.ws.onclose = () => {
      this.stopHeartbeat();
      this.joinedChannels.clear();
      this.notifyConnection(false);

      if (!this.destroyed) {
        this.reconnectTimeout = setTimeout(() => {
          this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000);
          this.doConnect(groups);
        }, this.reconnectDelay);
      }
    };
  }

  disconnect(): void {
    this.destroyed = true;
    this.stopHeartbeat();
    if (this.reconnectTimeout) clearTimeout(this.reconnectTimeout);
    if (this.ws) { try { this.ws.close(); } catch (_) {} this.ws = null; }
    this.notifyConnection(false);
  }

  // ── Channel management ───────────────────────────────────────────────────

  private joinChannel(topic: string): void {
    const joinRef = String(this.ref++);
    this.joinedChannels.set(topic, joinRef);
    this.send({
      join_ref: joinRef,
      ref: String(this.ref++),
      topic,
      event: MSG_JOIN,
      payload: {},
    });
  }

  leaveChannel(topic: string): void {
    const joinRef = this.joinedChannels.get(topic) ?? null;
    this.send({
      join_ref: joinRef,
      ref: String(this.ref++),
      topic,
      event: MSG_LEAVE,
      payload: {},
    });
    this.joinedChannels.delete(topic);
  }

  // ── Message routing ──────────────────────────────────────────────────────

  private handleMessage(msg: PhxMessage): void {
    if (msg.event === MSG_REPLY || msg.event === MSG_HEARTBEAT ||
        msg.event === MSG_ERROR || msg.event === MSG_CLOSE) {
      return;
    }

    const payload = msg.payload as Record<string, unknown>;

    if (msg.topic.startsWith('alerts:')) {
      if (msg.event === 'threshold_breach') {
        const event = payload as unknown as ThresholdBreachEvent;
        this.onThresholdBreach.forEach(h => h(event));
        this.persistAlert(event);
      } else if (msg.event === 'pipeline_event') {
        this.onPipelineEvent.forEach(h => h(payload as unknown as PipelineEvent));
      }
    } else if (msg.topic.startsWith('variables:')) {
      if (msg.event === 'variables_updated') {
        this.onVariablesUpdated.forEach(h => h(payload as unknown as VariablesUpdatedEvent));
      }
    }
  }

  // ── Heartbeat ────────────────────────────────────────────────────────────

  private startHeartbeat(): void {
    this.heartbeatInterval = setInterval(() => {
      this.send({
        join_ref: null,
        ref: String(this.ref++),
        topic: 'phoenix',
        event: MSG_HEARTBEAT,
        payload: {},
      });
    }, 30000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatInterval) { clearInterval(this.heartbeatInterval); this.heartbeatInterval = null; }
  }

  private send(msg: PhxMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify([msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload]));
    }
  }

  // ── Event subscriptions ──────────────────────────────────────────────────

  onThresholdBreachEvent(handler: ThresholdBreachHandler): () => void {
    this.onThresholdBreach.push(handler);
    return () => { this.onThresholdBreach = this.onThresholdBreach.filter(h => h !== handler); };
  }

  onPipelineEventReceived(handler: PipelineEventHandler): () => void {
    this.onPipelineEvent.push(handler);
    return () => { this.onPipelineEvent = this.onPipelineEvent.filter(h => h !== handler); };
  }

  onVariablesUpdatedEvent(handler: VariablesUpdatedHandler): () => void {
    this.onVariablesUpdated.push(handler);
    return () => { this.onVariablesUpdated = this.onVariablesUpdated.filter(h => h !== handler); };
  }

  onConnectionChanged(handler: ConnectionHandler): () => void {
    this.onConnectionChange.push(handler);
    return () => { this.onConnectionChange = this.onConnectionChange.filter(h => h !== handler); };
  }

  // ── Alert persistence ────────────────────────────────────────────────────
  // Alerts are stored locally so the trader can review them in the app
  // even if they dismissed the notification.

  private persistAlert(event: ThresholdBreachEvent): void {
    const existing = this.loadAlerts();
    const alert = {
      id: `${event.variable}-${event.timestamp}`,
      ...event,
      seen: false,
    };
    // Keep last 50 alerts
    const updated = [alert, ...existing].slice(0, 50);
    storage.set('threshold_alerts', JSON.stringify(updated));
  }

  loadAlerts(): Array<ThresholdBreachEvent & {id: string; seen: boolean}> {
    try {
      const raw = storage.getString('threshold_alerts');
      return raw ? JSON.parse(raw) : [];
    } catch {
      return [];
    }
  }

  clearAlerts(): void {
    storage.delete('threshold_alerts');
  }

  private notifyConnection(connected: boolean): void {
    this.onConnectionChange.forEach(h => h(connected));
  }
}

// ─── Singleton ────────────────────────────────────────────────────────────────

let instance: TradingDeskSocket | null = null;

export function getSocket(): TradingDeskSocket | null {
  return instance;
}

export function initSocket(serverUrl: string, token: string): TradingDeskSocket {
  if (instance) instance.disconnect();
  instance = new TradingDeskSocket(serverUrl, token);
  return instance;
}
