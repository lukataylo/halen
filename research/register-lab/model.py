"""Thin wrapper over a causal LM exposing exactly two views of next-token
prediction:

1. `generate` — sample full continuations (what the user sees as "the answer").
2. `next_token` — the raw probability distribution over the *very next* token
   (the mechanism: word choice reshapes this distribution before any text is
   emitted).

Defaults to GPT-2, which is a fitting subject: its WebText training corpus was
scraped from Reddit-outbound links, so its register priors are unusually legible
and its "use a Reddit word, get a Reddit answer" behaviour is real, not an
artefact of instruction-tuning.
"""

from __future__ import annotations

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

torch.manual_seed(0)


class LM:
    def __init__(self, model_name: str = "gpt2", dtype: str = "float32"):
        self.name = model_name
        torch_dtype = {"float32": torch.float32,
                       "bfloat16": torch.bfloat16,
                       "float16": torch.float16}[dtype]
        self.tok = AutoTokenizer.from_pretrained(model_name)
        self.model = AutoModelForCausalLM.from_pretrained(
            model_name, dtype=torch_dtype, low_cpu_mem_usage=True
        )
        self.model.eval()
        if self.tok.pad_token_id is None:
            self.tok.pad_token = self.tok.eos_token

    @torch.no_grad()
    def generate(
        self,
        prompt: str,
        max_new_tokens: int = 48,
        samples: int = 4,
        temperature: float = 0.8,
        top_p: float = 0.95,
        base_seed: int = 1234,
    ) -> list[str]:
        """Return `samples` continuations (the generated tail only, prompt
        stripped). Each sample uses a distinct seed for reproducibility."""
        ids = self.tok(prompt, return_tensors="pt")
        out: list[str] = []
        for i in range(samples):
            torch.manual_seed(base_seed + i)
            gen = self.model.generate(
                **ids,
                do_sample=True,
                temperature=temperature,
                top_p=top_p,
                max_new_tokens=max_new_tokens,
                pad_token_id=self.tok.eos_token_id,
                repetition_penalty=1.3,
            )
            tail = gen[0][ids["input_ids"].shape[1]:]
            out.append(self.tok.decode(tail, skip_special_tokens=True).strip())
        return out

    @torch.no_grad()
    def next_token(self, prompt: str, k: int = 40) -> dict[str, float]:
        """Top-k next-token distribution as {token_text: probability}.

        Token texts keep their leading space (GPT-2 BPE) so 'Ġfurthermore'
        renders as ' furthermore' — useful when eyeballing which continuations
        a word makes likely."""
        ids = self.tok(prompt, return_tensors="pt")
        logits = self.model(**ids).logits[0, -1]
        probs = torch.softmax(logits, dim=-1)
        top = torch.topk(probs, k)
        return {
            self.tok.decode([tid]): float(p)
            for tid, p in zip(top.indices.tolist(), top.values.tolist())
        }

    @torch.no_grad()
    def full_next_token_logprobs(self, prompt: str) -> torch.Tensor:
        """Log-probabilities over the entire vocab for the next token. Used to
        contrast one variant's distribution against a cluster baseline."""
        ids = self.tok(prompt, return_tensors="pt")
        logits = self.model(**ids).logits[0, -1]
        # Cast to float32 before the softmax: a bf16/fp16 model returns low-
        # precision logits, and the downstream mass sums / topk want stable
        # full-precision values.
        return torch.log_softmax(logits.float(), dim=-1)

    def token_text(self, token_id: int) -> str:
        return self.tok.decode([token_id])
