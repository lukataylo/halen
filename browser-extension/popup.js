// Quick liveness check for the Halen WebSocket bridge plus the token-pairing
// UI. Runs every time the user clicks the toolbar action.

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

// Ask the single background connection for liveness; the popup never creates
// a second WebSocket (and therefore never consumes an extra server slot).
chrome.runtime.sendMessage({ type: "halen:status" }, (reply) => {
  if (chrome.runtime.lastError || !reply) return resolve("fail", "Halen status unavailable");
  if (reply.status === "connected") return resolve("ok", "Connected to Halen");
  if (reply.status === "unpaired") return resolve("warn", "Pairing token required");
  if (reply.status === "connecting") return resolve("warn", "Connecting to Halen…");
  resolve("fail", "Halen not reachable");
});

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
  chrome.storage.local.set({ [STORAGE_KEY]: token }, () => {
    chrome.runtime.sendMessage({ type: "halen:reconnect" });
    showSaved();
  });
});

clearButton.addEventListener("click", () => {
  tokenInput.value = "";
  chrome.storage.local.remove([STORAGE_KEY], () => {
    chrome.runtime.sendMessage({ type: "halen:reconnect" });
    showSaved();
  });
});
