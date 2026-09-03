# M2 vLLM direct-backend case

This case validates one vLLM OpenAI endpoint directly, without a load balancer.
On metax-9, set `VLLM_DIRECT_HOST` to the vLLM container IP and use port
`19100` unless the server was started on another port.

The vLLM server must advertise `9g_8b_thinking` and use the MetaX X203 runtime.
The case owns the diagnostic contract; the vLLM process lifecycle remains with
the selected launch script or runtime owner.
