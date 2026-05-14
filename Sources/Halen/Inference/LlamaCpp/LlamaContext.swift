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
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    /// Load a GGUF model from disk. Slow (seconds, GBs of RAM) — call once and
    /// keep the returned context warm.
    static func load(modelPath: String, contextLength: Int32 = 4096) throws -> LlamaContext {
        llama_backend_init()
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
    func generate(prompt: String, maxTokens: Int, temperature: Double, stop: [String]) -> String {
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

        // Prefill.
        llama_batch_clear(&batch)
        for (i, token) in tokens.enumerated() {
            llama_batch_add(&batch, token, Int32(i), [0], i == tokens.count - 1)
        }
        guard llama_decode(context, batch) == 0 else { return "" }

        var output = ""
        var pendingCChars: [CChar] = []
        var nCur = batch.n_tokens
        var generated: Int32 = 0

        while generated < maxNew {
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
                    break
                }
            }

            llama_batch_clear(&batch)
            llama_batch_add(&batch, newToken, nCur, [0], true)
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
        let count = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(capacity), addBOS, false)
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

private func llama_batch_add(_ batch: inout llama_batch,
                             _ id: llama_token,
                             _ pos: llama_pos,
                             _ seqIDs: [llama_seq_id],
                             _ logits: Bool) {
    let i = Int(batch.n_tokens)
    batch.token[i] = id
    batch.pos[i] = pos
    batch.n_seq_id[i] = Int32(seqIDs.count)
    for (j, seqID) in seqIDs.enumerated() {
        batch.seq_id[i]![j] = seqID
    }
    batch.logits[i] = logits ? 1 : 0
    batch.n_tokens += 1
}
