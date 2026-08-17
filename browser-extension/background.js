// Halen for Web — the extension's single WebSocket owner.
// Content scripts and the popup communicate with this MV3 service worker via
// chrome.runtime messaging; tabs never connect to the native bridge directly.

const HALEN_HOST = "ws://127.0.0.1:50765/";
const STORAGE_KEY = "halenBridgeToken";
const SUBSCRIBE_TOPICS = ["text.pause"];
const RECONNECT_INITIAL_MS = 2_000;
const RECONNECT_MAX_MS = 30_000;
const KEEPALIVE_MS = 20_000;
const MAX_EVENT_BYTES = 192 * 1024;

let socket = null;
let token = "";
let reconnectDelay = RECONNECT_INITIAL_MS;
let reconnectTimer = null;
let keepaliveTimer = null;
let status = "disconnected";
let pendingEvent = null; // latest unsent typing event; deliberately bounded to one

function send(method, params) {
  if (!socket || socket.readyState !== WebSocket.OPEN || !token) return false;
  try {
    socket.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
    return true;
  } catch (_) {
    return false;
  }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, reconnectDelay);
  reconnectDelay = Math.min(RECONNECT_MAX_MS, Math.round(reconnectDelay * 1.6));
}

function disconnect() {
  clearInterval(keepaliveTimer);
  keepaliveTimer = null;
  if (socket) {
    const old = socket;
    socket = null;
    try { old.close(); } catch (_) {}
  }
  status = "disconnected";
}

function connect() {
  if (!/^[0-9a-f]{64}$/.test(token)) {
    status = "unpaired";
    return;
  }
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  status = "connecting";
  try {
    // The pairing token is a WebSocket subprotocol so Halen authenticates the
    // HTTP upgrade itself. `open` therefore doubles as the authentication ack.
    socket = new WebSocket(HALEN_HOST, [`halen.${token}`]);
  } catch (_) {
    socket = null;
    status = "disconnected";
    scheduleReconnect();
    return;
  }
  const currentSocket = socket;

  currentSocket.addEventListener("open", () => {
    if (socket !== currentSocket) return;
    reconnectDelay = RECONNECT_INITIAL_MS;
    send("subscribe", { topics: SUBSCRIBE_TOPICS });
    status = "connected";
    if (pendingEvent) {
      const event = pendingEvent;
      pendingEvent = null;
      send(event.method, event.params);
    }
    // Chrome 116+ keeps an MV3 worker alive when WebSocket traffic occurs.
    // A small notification below maintains the one shared connection. Halen
    // safely ignores it because it is outside the event namespace.
    clearInterval(keepaliveTimer);
    keepaliveTimer = setInterval(() => send("extension/keepalive", {}), KEEPALIVE_MS);
  });
  currentSocket.addEventListener("close", () => {
    if (socket !== currentSocket) return;
    socket = null;
    clearInterval(keepaliveTimer);
    keepaliveTimer = null;
    status = "disconnected";
    scheduleReconnect();
  });
  currentSocket.addEventListener("error", () => {});
  currentSocket.addEventListener("message", () => {});
}

function reloadTokenAndReconnect() {
  chrome.storage.local.get([STORAGE_KEY], (result) => {
    token = (result && typeof result[STORAGE_KEY] === "string") ? result[STORAGE_KEY] : "";
    disconnect();
    connect();
  });
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message.type !== "string") return false;
  if (message.type === "halen:event") {
    if (message.method !== "event/text.pause") {
      sendResponse({ sent: false, queued: false });
      return false;
    }
    const encodedBytes = new TextEncoder().encode(JSON.stringify({
      jsonrpc: "2.0", method: message.method, params: message.params
    })).byteLength;
    if (encodedBytes > MAX_EVENT_BYTES) {
      sendResponse({ sent: false, queued: false });
      return false;
    }
    const sent = send(message.method, message.params);
    if (!sent) pendingEvent = { method: message.method, params: message.params };
    sendResponse({ sent, queued: !sent });
    if (status === "disconnected" || status === "unpaired") connect();
    return false;
  }
  if (message.type === "halen:status") {
    sendResponse({ status, paired: Boolean(token) });
    if (status === "disconnected") connect();
    return false;
  }
  if (message.type === "halen:reconnect") {
    reloadTokenAndReconnect();
    sendResponse({ ok: true });
    return false;
  }
  return false;
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes[STORAGE_KEY]) reloadTokenAndReconnect();
});

reloadTokenAndReconnect();
