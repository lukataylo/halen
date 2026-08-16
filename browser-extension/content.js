// Halen for Web — content script.
//
// Bridges DOM-side typing events into Halen's WebSocket so its native plugins
// (SnippetExpander, TypoFixer, SentimentGuard, Ask Halen) work in browser
// text fields that macOS Accessibility can't see — Slack, Discord, Gmail,
// Google Docs, Notion, ChatGPT.app's own input, anything Chromium-based.
//
// Architecture:
//   * Send DOM events to the extension's background service worker.
//   * The worker owns the sole WS connection to Halen on 127.0.0.1:50765.
//   * Listen for `input`/`focusin` on inputs/textareas/contenteditables.
//   * After a 600 ms debounce, send `event/text.pause` upstream — same shape
//     Halen's native CaretObserver emits.
//   * On a Halen text-write, the host's clipboard fallback (Bet 4a) lands
//     the result in the focused field via a synthesized ⌘V. The extension
//     does not need its own write path — that's the whole point of the
//     fallback existing.
//
// Connection lifecycle is centralized in background.js, avoiding one native
// bridge client per tab and surviving ordinary tab navigation/reloads.

(() => {
  const PAUSE_DEBOUNCE_MS = 600;
  const MAX_TEXT_UTF16 = 32 * 1024;

  let pauseTimer = null;
  let lastSent = null;   // last { text, caretOffset } we sent — for dedup

  function send(method, params) {
    chrome.runtime.sendMessage({ type: "halen:event", method, params }, () => {
      // Reading lastError prevents a noisy console warning if an extension
      // update momentarily restarts the service worker.
      void chrome.runtime.lastError;
    });
  }

  // --- DOM helpers ----------------------------------------------------------

  // Sensitive input-name / autocomplete patterns we never ship upstream.
  // Halen's plugins have no business seeing credit cards, OTP codes, SSNs or
  // freshly-typed passwords just because they're in an `<input type="text">`.
  const SENSITIVE_AUTOCOMPLETE = [
    "cc-", "current-password", "new-password",
    "one-time-code", "otp"
  ];
  const SENSITIVE_NAME_PATTERN =
    /(^|[-_.])(cc|card|cardnum|ccnum|cvv|cvc|otp|ssn|sin|pin|password|passcode)([-_.]|$|number)/i;

  function isSensitiveInput(el) {
    const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
    if (SENSITIVE_AUTOCOMPLETE.some(p => ac.startsWith(p) || ac.includes(p))) return true;
    const name = el.getAttribute("name") || el.id || "";
    if (SENSITIVE_NAME_PATTERN.test(name)) return true;
    // Inputs inside `<form autocomplete="off">` are explicitly opting out of
    // any cross-form text capture — respect that signal.
    if (el.form && (el.form.getAttribute("autocomplete") || "").toLowerCase() === "off") return true;
    return false;
  }

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
      if (isSensitiveInput(el)) return null;
      return { text: el.value || "", caretOffset: el.selectionStart || 0 };
    }
    if (tag === "TEXTAREA") {
      if (isSensitiveInput(el)) return null;
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
      appBundleId: ("web/" + location.hostname).slice(0, 255),
      appName: (document.title || location.hostname).slice(0, 512)
    };
  }

  function windowAroundCaret(field) {
    const text = field.text;
    const caret = Math.max(0, Math.min(field.caretOffset, text.length));
    if (text.length <= MAX_TEXT_UTF16) return { text, caretOffset: caret };
    let start = Math.max(0, caret - Math.floor(MAX_TEXT_UTF16 / 2));
    let end = Math.min(text.length, start + MAX_TEXT_UTF16);
    start = Math.max(0, end - MAX_TEXT_UTF16);
    // JavaScript indices are UTF-16 units; never cut a surrogate pair.
    if (start > 0 && /[\uDC00-\uDFFF]/.test(text[start])) start += 1;
    if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) end -= 1;
    return { text: text.slice(start, end), caretOffset: caret - start };
  }

  function emitPause() {
    const fullField = readEditable(document.activeElement);
    if (!fullField) return;
    const field = windowAroundCaret(fullField);
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

})();
