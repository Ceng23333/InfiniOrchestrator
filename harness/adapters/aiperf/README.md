# AIPerf run-only CI adapter

This adapter benchmarks an **already-running** OpenAI-compatible InfiniLM
endpoint. It does not manage GPUs, containers, or serving cases. Use Python
3.11-3.13 and pin `aiperf==0.13.0` in the benchmark runner environment.

```bash
python3 -m pip install 'aiperf==0.13.0'
harness/bin/run-aiperf \
  --base-url http://127.0.0.1:8000 \
  --model Qwen3.8-27B \
  --profile harness/adapters/aiperf/profiles/agentic_tool_loop.json \
  --output-dir /tmp/aiperf-agentic
```

The `agentic_tool_loop` profile replays three pre-recorded conversation turns
with tool schemas and tool results. AIPerf does not execute those tools or
insert the model's generated tool call into the next turn. The `long_prefix`
profile synthesizes 8,192 / 16,384 / 18,050 input tokens using shared 2,048-token
hash blocks. Run it only on an isolated endpoint intended to support those
lengths; contexts beyond 8,192 are still deferred in the referenced InfiniLM
deployment. To replay a sanitized product transcript, create another JSON
array of Mooncake records with each request's full `messages`, optional
`tools`, `output_length`, and `timestamp`, then point a JSON profile at it.
The runner materializes the ignored JSONL input as a run artifact.

```bash
harness/bin/run-aiperf \
  --base-url http://127.0.0.1:8000 \
  --model Qwen3.8-27B \
  --profile harness/adapters/aiperf/profiles/long_prefix.json \
  --output-dir /tmp/aiperf-long-prefix \
  --tokenizer /models/Qwen3.8-27B \
  --manifest /path/to/diagnostic-manifest.json
```

Profiles bound request count, concurrency, output length, and per-request
timeout. The runner checks AIPerf's version, successful request count, error
count, cancellation, and any configured latency/context gates. It exits nonzero
and writes `summary.json` on failure. Raw AIPerf output is under `aiperf/`,
with the process log at `aiperf.log`; an optional diagnostic manifest gains a
`bench` block without changing its probe status. Use a fresh output directory
for each run so stale exports cannot satisfy a later CI gate.
Set `gates.max_latency_p95_ms` or `gates.max_ttft_p95_ms` in a profile for
hardware-specific performance budgets; neither is set by default because
their thresholds depend on the model and GPU.

The GitHub workflow runs adapter unit tests on pull requests. Its live job
requires a dedicated Linux self-hosted runner labeled `infini-gpu` with a
reachable endpoint. It can be launched manually or enabled nightly by setting
repository variables `AIPERF_CI_ENDPOINT`, `AIPERF_CI_MODEL`, and optionally
`AIPERF_CI_PROFILE` and `AIPERF_CI_TOKENIZER`. The long-prefix profile requires
a local tokenizer path. Keep the protocol-specific idle-stream assertion in
InfiniLM: AIPerf's request timeout and aggregate TTFT cannot prove that an
SSE comment was delivered while a tool call was buffered.
