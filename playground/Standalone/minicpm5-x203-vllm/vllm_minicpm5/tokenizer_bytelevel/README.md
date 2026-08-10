# tokenizer_bytelevel

Sidecar tokenizer for MiniCPM5 when serving with vLLM.

The checkpoint ships `tokenizer_class=LlamaTokenizerFast`. Loading that class
**replaces** the `tokenizer.json` ByteLevel pre-tokenizer with Metaspace, which
drops Chinese / other non-ASCII text (user content becomes empty; the model
then hallucinates).

This directory keeps `tokenizer.json` as-is and sets
`tokenizer_class=PreTrainedTokenizerFast` (no `tokenizer.model`).

Use: `vllm serve … --tokenizer <this-dir>`
