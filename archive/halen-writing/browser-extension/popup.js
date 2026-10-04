// Quick liveness check for the Halen WebSocket bridge plus the token-pairing
// UI. Runs every time the user clicks the toolbar action.

const HALEN_HOST = "ws://127.0.0.1:50765/";
const TIMEOUT_MS = 1500;
const STORAGE_KEY = "halenBridgeToken";

const dot = document.getElementById("dot");
const text = document.getElementById("text");
const tokenInput = document.getElementById("token");
const saveButton = document.getElementById("save");
const clearButton = document.getElementById("clear");
const savedLabel = document.getElementById("saved");

let resolved = false;
function resolve(state, msg) {
  if (resolved) return;
  resolved = true;
  dot.className = "dot " + state;
  text.textContent = msg;
}

// --- liveness ping ----------------------------------------------------------

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

// --- token pairing ----------------------------------------------------------

function showSaved() {
  savedLabel.style.display = "inline";
  setTimeout(() => { savedLabel.style.display = "none"; }, 2500);
}

chrome.storage.local.get([STORAGE_KEY], (result) => {
  if (result && typeof result[STORAGE_KEY] === "string") {
    tokenInput.value = result[STORAGE_KEY];
  }
});

saveButton.addEventListener("click", () => {
  const token = (tokenInput.value || "").trim();
  chrome.storage.local.set({ [STORAGE_KEY]: token }, showSaved);
});

clearButton.addEventListener("click", () => {
  tokenInput.value = "";
  chrome.storage.local.remove([STORAGE_KEY], showSaved);
});
