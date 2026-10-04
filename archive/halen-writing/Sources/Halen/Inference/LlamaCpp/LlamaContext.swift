import Foundation
import llama

/// Thin Swift bridge over llama.cpp's C API for one-shot, non-streaming
/// generation. An `actor` so a single model context is never touched
/// concurrently — llama.cpp contexts are not thread-safe. Adapted from
/// llama.cpp's `examples/llama.swiftui/LibLlama.swift` (pinned tag in
/// `Vendor/LLAMA_CPP_VERSION`).
actor LlamaContext {
    enum LlamaError: Error {
        case loadFailed(String)
        case contextInitFailed
    }

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch
    private let contextLength: Int32

    private init(model: OpaquePointer, context: OpaquePointer, contextLength: Int32) {
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.batch = llama_batch_init(contextLength, 0, 1)
        self.contextLength = contextLength
    }

    deinit {
        // Deliberately no `llama_backend_free()` — see `backendInit`. This frees
        // only *this* context's resources, so the model can be evicted when idle
        // and reloaded later within the same process.
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    /// `llama_backend_init()` initialises ggml process-wide and must run exactly
    /// once per process. It is *not* paired with `llama_backend_free()` in
    /// `deinit`, because `LlamaCppBackend` loads and unloads the model context
    /// repeatedly (idle eviction) while the process lives on; tearing the
    /// backend down under a live process is unsafe. This static runs it lazily,
    /// once, and thread-safely.
    private static let backendInit: Void = {
        llama_backend_init()
    }()

    /// Load a GGUF model from disk. Slow (seconds, GBs of RAM) — call once and
    /// keep the returned context warm. `contextLength` sizes the KV cache and
    /// compute buffers; Halen's prompts are small (windowed text + short
    /// completions), so 2048 is ample and roughly halves the resident footprint
    /// versus llama.cpp's 4096 default.
    static func load(modelPath: String, contextLength: Int32 = 2048) throws -> LlamaContext {
        _ = backendInit
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999   // offload everything to Metal (clamped to actual layer count)
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.loadFailed(modelPath)
        }
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextLength)
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            throw LlamaError.contextInitFailed
        }
        return LlamaContext(model: model, context: context, contextLength: contextLength)
    }

    /// One-shot generation: tokenize `prompt`, prefill, then sample until EOG,
    /// `maxTokens`, a `stop` string, or the context window fills. Clears the KV
    /// cache afterward so successive calls don't bleed into each other.
    ///
    /// `onToken` is invoked after every flushed piece with the **cumulative**
    /// output so far — the hook the streaming backend wires to its
    /// `AsyncThrowingStream`. It defaults to a no-op, so non-streaming callers
    /// are unaffected. The final (possibly stop-truncated) text is also the
    /// return value, so a streaming caller can treat it as the authoritative
    /// last snapshot.
    func generate(prompt: String, maxTokens: Int, temperature: Double, stop: [String],
                  onToken: @Sendable (String) -> Void = { _ in }) -> String {
        defer { llama_memory_clear(llama_get_memory(context), true) }

        var tokens = tokenize(text: prompt, addBOS: true)
        guard !tokens.isEmpty else { return "" }
        // Never overflow the context window / batch.
        let promptCap = Int(contextLength) - 256
        if tokens.count > promptCap { tokens = Array(tokens.suffix(promptCap)) }
        let maxNew = max(1, min(Int32(maxTokens), contextLength - Int32(tokens.count) - 4))

        // Sampler chain built per call so temperature can vary per request.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { return "" }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(temperature)))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: .min ... .max)))

        // Prefill. `tokens` is already capped to `promptCap` (< batch capacity),
        // but guard the batch writes anyway — a llama.cpp version bump could
        // change the invariant out from under us.
        llama_batch_clear(&batch)
        for (i, token) in tokens.enumerated() {
            guard llama_batch_add(&batch, token, Int32(i), [0], i == tokens.count - 1,
                                  capacity: contextLength) else {
                Log.warn("LlamaContext: batch overflow during prefill — aborting generation")
                return ""
            }
        }
        guard llama_decode(context, batch) == 0 else { return "" }

        var output = ""
        var pendingCChars: [CChar] = []
        var nCur = batch.n_tokens
        var generated: Int32 = 0

        while generated < maxNew {
            // Streaming consumers cancel the enclosing Task when they stop
            // reading; bail promptly rather than generating tokens nobody wants.
            if Task.isCancelled { break }

            let newToken = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, newToken) { break }

            pendingCChars.append(contentsOf: tokenToPiece(token: newToken))
            // `token_to_piece` can split a multi-byte UTF-8 sequence — only flush
            // once the accumulated bytes form a valid string.
            if let piece = String(validatingUTF8: pendingCChars + [0]) {
                output += piece
                pendingCChars.removeAll()
                if let cut = stop
                    .filter({ !$0.isEmpty })
                    .compactMap({ output.range(of: $0)?.lowerBound })
                    .min() {
                    output = String(output[..<cut])
                    onToken(output)
                    break
                }
                onToken(output)
            }

            llama_batch_clear(&batch)
            guard llama_batch_add(&batch, newToken, nCur, [0], true, capacity: contextLength) else {
                Log.warn("LlamaContext: batch write failed during generation — stopping early")
                break
            }
            nCur += 1
            generated += 1
            guard llama_decode(context, batch) == 0 else { break }
        }
        return output
    }

    // MARK: - Token helpers (adapted from llama.swiftui's LibLlama.swift)

    private func tokenize(text: String, addBOS: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let capacity = utf8Count + (addBOS ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
        defer { tokens.deallocate() }
        // parse_special: true — the prompt carries Gemma chat-template control
        // tokens (`<start_of_turn>`, `<end_of_turn>`). Without this they tokenize
        // as literal text, the model never sees a real turn boundary, never hits
        // EOG, and loops the template forever.
        let count = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(capacity), addBOS, true)
        guard count > 0 else { return [] }
        return (0..<Int(count)).map { tokens[$0] }
    }

    private func tokenToPiece(token: llama_token) -> [CChar] {
        var buf = [CChar](repeating: 0, count: 8)
        let n = llama_token_to_piece(vocab, token, &buf, 8, 0, false)
        if n >= 0 { return Array(buf[0..<Int(n)]) }
        // 8 bytes wasn't enough — retry with the exact size the API asked for.
        var big = [CChar](repeating: 0, count: Int(-n))
        let n2 = llama_token_to_piece(vocab, token, &big, -n, 0, false)
        return Array(big[0..<Int(max(0, n2))])
    }
}

// MARK: - llama_batch helpers (free functions, from LibLlama.swift)

private func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

/// Appends one token to `batch`. Returns `false` — a no-op — if the batch is
/// already at `capacity` (the value passed to `llama_batch_init`) or llama.cpp
/// handed back a batch with no `seq_id` storage. `llama_batch_add` writes raw
/// into C arrays, so both conditions would otherwise corrupt the heap; callers
/// must treat `false` as fatal-for-this-request and stop.
private func llama_batch_add(_ batch: inout llama_batch,
                             _ id: llama_token,
                             _ pos: llama_pos,
                             _ seqIDs: [llama_seq_id],
                             _ logits: Bool,
                             capacity: Int32) -> Bool {
    let i = Int(batch.n_tokens)
    guard i < Int(capacity), let seqIDRow = batch.seq_id[i] else { return false }
    batch.token[i] = id
    batch.pos[i] = pos
    batch.n_seq_id[i] = Int32(seqIDs.count)
    for (j, seqID) in seqIDs.enumerated() {
        seqIDRow[j] = seqID
    }
    batch.logits[i] = logits ? 1 : 0
    batch.n_tokens += 1
    return true
}
