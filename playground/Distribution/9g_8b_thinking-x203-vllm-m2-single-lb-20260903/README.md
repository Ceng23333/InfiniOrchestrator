# M2 vLLM single-backend-behind-LB case

This case validates one vLLM OpenAI backend behind one InfiniOrchestrator
router. Use a dedicated router port, `29910` by default, and point its static
service configuration at the single vLLM endpoint on `VLLM_BACKEND_PORT`.

The case is intentionally separate from the two-replica M2 InfiniLM case and
the two-replica vLLM M6 baseline. It is a single-backend routing contract, not a
round-robin distribution test.
