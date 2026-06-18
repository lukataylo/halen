#!/usr/bin/env python3
"""Minimal client for Halen's local WebSocket bridge (127.0.0.1:50765).

The bridge speaks JSON-RPC 2.0 over RFC-6455 WebSocket text frames — the same
surface Halen's stdio plugins use, exposed to loopback clients. This module
implements just enough of a WebSocket client (pure stdlib — no `websockets`
dependency) to authenticate with the on-disk bridge token and make a single
`inference/complete` round-trip, so the compaction hook can run Halen's local
model without the cloud.

Trust model: the bridge binds loopback-only and gates the `subscribe`
handshake on a 64-hex-char token written 0600 to Halen's Application Support
dir. We read that token and authenticate with it (forward-compatible even
though `inference/complete` requests are not token-gated today).

Everything that does I/O lives in `request()`. The frame codec
(`encode_frame` / `decode_frames`) is pure and unit-tested.
"""
from __future__ import annotations

import os
import base64
import json
import socket
import struct

DEFAULT_PORT = 50765
_TOKEN_PATH = os.path.expanduser(
    "~/Library/Application Support/Halen/bridge-token"
)

# RFC 6455 opcodes
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA


class BridgeError(Exception):
    """Any failure talking to Halen — not running, bad handshake, model
    unavailable. The hook catches this and degrades to a no-op."""


def read_token(path: str = _TOKEN_PATH) -> str | None:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            tok = fh.read().strip()
        return tok or None
    except OSError:
        return None


# --- frame codec (pure) ------------------------------------------------------

def encode_frame(payload: bytes, opcode: int = OP_TEXT) -> bytes:
    """Encode one masked client→server frame (FIN=1). Clients MUST mask
    (RFC 6455 §5.3)."""
    b0 = 0x80 | (opcode & 0x0F)
    header = bytearray([b0])
    length = len(payload)
    mask_bit = 0x80
    if length < 126:
        header.append(mask_bit | length)
    elif length < (1 << 16):
        header.append(mask_bit | 126)
        header += struct.pack(">H", length)
    else:
        header.append(mask_bit | 127)
        header += struct.pack(">Q", length)
    mask = os.urandom(4)
    header += mask
    masked = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
    return bytes(header) + masked


def decode_frames(buffer: bytes) -> tuple[list[tuple[int, bytes]], bytes]:
    """Decode as many complete frames as `buffer` holds. Returns
    (frames, remaining) where each frame is (opcode, payload) and `remaining`
    is the trailing bytes of an incomplete frame to carry over. Tolerates
    server-side masking even though the bridge never masks."""
    frames: list[tuple[int, bytes]] = []
    pos = 0
    n = len(buffer)
    while True:
        if n - pos < 2:
            break
        b0 = buffer[pos]
        b1 = buffer[pos + 1]
        opcode = b0 & 0x0F
        masked = bool(b1 & 0x80)
        length = b1 & 0x7F
        idx = pos + 2
        if length == 126:
            if n - idx < 2:
                break
            length = struct.unpack(">H", buffer[idx:idx + 2])[0]
            idx += 2
        elif length == 127:
            if n - idx < 8:
                break
            length = struct.unpack(">Q", buffer[idx:idx + 8])[0]
            idx += 8
        mask = b""
        if masked:
            if n - idx < 4:
                break
            mask = buffer[idx:idx + 4]
            idx += 4
        if n - idx < length:
            break
        payload = buffer[idx:idx + length]
        if masked:
            payload = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
        frames.append((opcode, payload))
        pos = idx + length
    return frames, buffer[pos:]


# --- handshake + request -----------------------------------------------------

def _handshake(sock: socket.socket, port: int) -> None:
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    req = (
        "GET / HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode("ascii"))
    # Read the HTTP response head (up to the blank line).
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(1024)
        if not chunk:
            raise BridgeError("bridge closed during handshake")
        buf += chunk
        if len(buf) > 65536:
            raise BridgeError("handshake response too large")
    status_line = buf.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    if "101" not in status_line:
        raise BridgeError(f"unexpected handshake status: {status_line!r}")
    # Any bytes after the header blank line are the start of frames; the
    # bridge does not send any before our first request, so we discard them.


def request(method: str, params: dict, *, port: int = DEFAULT_PORT,
            timeout: float = 45.0, token_path: str = _TOKEN_PATH) -> dict:
    """Make one JSON-RPC request to the bridge and return its `result` object.
    Raises BridgeError on any failure (caller degrades to a no-op)."""
    token = read_token(token_path)
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    except OSError as exc:
        raise BridgeError(f"Halen not reachable on 127.0.0.1:{port} — {exc}")
    sock.settimeout(timeout)
    try:
        _handshake(sock, port)
        # Authenticate (forward-compatible; requests are ungated today).
        if token:
            sub = json.dumps({
                "jsonrpc": "2.0",
                "method": "subscribe",
                "params": {"token": token, "topics": []},
            }).encode("utf-8")
            sock.sendall(encode_frame(sub))
        req = json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        }).encode("utf-8")
        sock.sendall(encode_frame(req))

        buffer = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                raise BridgeError("bridge closed before responding")
            buffer += chunk
            frames, buffer = decode_frames(buffer)
            for opcode, payload in frames:
                if opcode == OP_PING:
                    sock.sendall(encode_frame(payload, OP_PONG))
                    continue
                if opcode == OP_CLOSE:
                    raise BridgeError("bridge closed the connection")
                if opcode not in (OP_TEXT, OP_BINARY):
                    continue
                try:
                    msg = json.loads(payload.decode("utf-8"))
                except ValueError:
                    continue
                if not isinstance(msg, dict) or msg.get("id") != 1:
                    continue  # an event or stray frame — keep waiting
                if "error" in msg and msg["error"]:
                    err = msg["error"]
                    detail = err.get("message") if isinstance(err, dict) else str(err)
                    raise BridgeError(f"host error: {detail}")
                result = msg.get("result")
                if not isinstance(result, dict):
                    raise BridgeError("malformed result from host")
                return result
    finally:
        try:
            sock.close()
        except OSError:
            pass


def complete(prompt: str, *, tier: str = "medium", max_tokens: int = 1024,
             temperature: float = 0.3, port: int = DEFAULT_PORT,
             timeout: float = 45.0, token_path: str = _TOKEN_PATH) -> str:
    """Run one on-device completion through Halen and return the text."""
    result = request(
        "inference/complete",
        {
            "prompt": prompt,
            "tier": tier,
            "maxTokens": max_tokens,
            "temperature": temperature,
            "taskKind": "generation",
        },
        port=port, timeout=timeout, token_path=token_path,
    )
    text = result.get("text")
    if not isinstance(text, str):
        raise BridgeError("host returned no text")
    return text
