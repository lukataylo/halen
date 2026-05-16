// Quick liveness check for the Halen WebSocket bridge — runs every time the
// user clicks the toolbar action. Opens a one-shot connection, reports the
// outcome, then closes.

const HALEN_HOST = "ws://127.0.0.1:50765/";
const TIMEOUT_MS = 1500;

const dot = document.getElementById("dot");
const text = document.getElementById("text");

let resolved = false;
function resolve(state, msg) {
  if (resolved) return;
  resolved = true;
  dot.className = "dot " + state;
  text.textContent = msg;
}

let socket;
try {
  socket = new WebSocket(HALEN_HOST);
} catch (e) {
  resolve("fail", "Halen not reachable");
}

if (socket) {
  socket.addEventListener("open", () => {
    resolve("ok", "Connected to Halen");
    socket.close();
  });
  socket.addEventListener("error", () => {
    resolve("fail", "Halen not reachable");
  });

  setTimeout(() => {
    if (!resolved) {
      resolve("warn", "Halen didn't respond in time");
      try { socket.close(); } catch (_) {}
    }
  }, TIMEOUT_MS);
}
