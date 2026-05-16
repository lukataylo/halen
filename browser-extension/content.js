// Halen for Web — content script.
//
// Bridges DOM-side typing events into Halen's WebSocket so its native plugins
// (SnippetExpander, TypoFixer, SentimentGuard, Ask Halen) work in browser
// text fields that macOS Accessibility can't see — Slack, Discord, Gmail,
// Google Docs, Notion, ChatGPT.app's own input, anything Chromium-based.
//
// Architecture:
//   * Connect to Halen's WS server on 127.0.0.1:50765.
//   * Listen for `input`/`focusin` on inputs/textareas/contenteditables.
//   * After a 600 ms debounce, send `event/text.pause` upstream — same shape
//     Halen's native CaretObserver emits.
//   * On a Halen text-write, the host's clipboard fallback (Bet 4a) lands
//     the result in the focused field via a synthesized ⌘V. The extension
//     does not need its own write path — that's the whole point of the
//     fallback existing.
//
// Connection lifecycle: each tab opens its own WS to Halen. If Halen isn't
// running, the connection fails and we retry with exponential backoff up to
// 30 s. Closing or reloading the tab also closes the socket — no leaks.

(() => {
  const HALEN_HOST = "ws://127.0.0.1:50765/";
  const PAUSE_DEBOUNCE_MS = 600;
  const RECONNECT_INITIAL_MS = 2_000;
  const RECONNECT_MAX_MS = 30_000;

  let socket = null;
  let reconnectDelay = RECONNECT_INITIAL_MS;
  let pauseTimer = null;
  let lastSent = null;   // last { text, caretOffset } we sent — for dedup

  // --- Connection -----------------------------------------------------------

  function connect() {
    try {
      socket = new WebSocket(HALEN_HOST);
    } catch (e) {
      scheduleReconnect();
      return;
    }
    socket.addEventListener("open", () => {
      reconnectDelay = RECONNECT_INITIAL_MS;
      console.debug("[Halen] connected");
    });
    socket.addEventListener("close", () => {
      socket = null;
      scheduleReconnect();
    });
    socket.addEventListener("error", () => {
      // The close event will fire too; rely on that for reconnect scheduling.
    });
    socket.addEventListener("message", () => {
      // The host may push events (caret.moved from other apps, etc.) — the
      // extension currently has no use for them. Drop quietly. Future work:
      // route inbound `extension/replaceSelection` calls to write back into
      // the DOM directly instead of relying on the ⌘V fallback.
    });
  }

  function scheduleReconnect() {
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(RECONNECT_MAX_MS, Math.round(reconnectDelay * 1.6));
  }

  function send(method, params) {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    try {
      socket.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
    } catch (e) {
      // Socket racing closed — let the close handler reconnect.
    }
  }

  // --- DOM helpers ----------------------------------------------------------

  /// Pull text + caret out of whatever the user is typing into. Returns null
  /// for non-editable elements (so we don't spam events for, e.g., a search
  /// field the user just clicked into).
  function readEditable(el) {
    if (!el) return null;
    const tag = el.tagName;
    if (tag === "INPUT") {
      // Skip non-text inputs (button, checkbox, hidden, etc.) and password
      // fields — never want to ship those upstream.
      const type = (el.type || "text").toLowerCase();
      if (type === "password") return null;
      if (!["text", "search", "email", "url", "tel", "number"].includes(type)) return null;
      return { text: el.value || "", caretOffset: el.selectionStart || 0 };
    }
    if (tag === "TEXTAREA") {
      return { text: el.value || "", caretOffset: el.selectionStart || 0 };
    }
    if (el.isContentEditable) {
      const text = el.innerText || el.textContent || "";
      // contenteditable caret = byte offset from start of element text. Best
      // effort via Selection API; falls back to "end of text" when the user
      // hasn't placed an explicit caret yet.
      const sel = window.getSelection();
      let caret = text.length;
      if (sel && sel.rangeCount > 0) {
        const range = sel.getRangeAt(0);
        const preCaret = range.cloneRange();
        preCaret.selectNodeContents(el);
        preCaret.setEnd(range.endContainer, range.endOffset);
        caret = preCaret.toString().length;
      }
      return { text, caretOffset: caret };
    }
    return null;
  }

  function appIdentity() {
    // Halen uses bundle ids natively; here we forge a stable "web/<host>" id
    // so its EventBus, plugin caches and cooldowns all key off something
    // sensible per site.
    return {
      appBundleId: "web/" + location.hostname,
      appName: document.title || location.hostname
    };
  }

  function emitPause() {
    const field = readEditable(document.activeElement);
    if (!field) return;
    // Cheap dedup so a focus-without-typing doesn't re-fire the event over
    // and over. The host has its own dedup too, but saving the round trip
    // is free.
    if (lastSent &&
        lastSent.text === field.text &&
        lastSent.caretOffset === field.caretOffset) {
      return;
    }
    lastSent = field;
    const { appBundleId, appName } = appIdentity();
    send("event/text.pause", {
      topic: "text.pause",
      payload: {
        appBundleId,
        appName,
        text: field.text,
        caretOffset: field.caretOffset
      }
    });
  }

  function scheduleEmit() {
    clearTimeout(pauseTimer);
    pauseTimer = setTimeout(emitPause, PAUSE_DEBOUNCE_MS);
  }

  // `true` for capture phase so we still see events on shadow-DOM components
  // (Slack uses one for its composer) and on third-party libraries that stop
  // propagation in bubble phase.
  document.addEventListener("input", scheduleEmit, true);
  document.addEventListener("focusin", scheduleEmit, true);

  connect();
})();
