# M2 dual 9g round-robin case

This is a new T3 case for the M2 track: one frontend, one etcd discovery plane, and two independent `9g_8b_thinking` workers. Worker A uses GPU 2 and ports 8100/8101; worker B uses GPU 3 and ports 8110/8111 inside the container. Host ports are 28102/28103 and 28112/28113.

The case is intended for the aarch64 MetaX X203 environment on metax-9, which matches the tj-node architecture. Run `./preflight_gpu.sh` before launch: it must use `ht-smi` on metax-9. The same script uses `mx-smi` on metax-49/node2.

The active routing policy is `round_robin` only. Gate C passes only when `/services` contains both same-model workers and successive requests can be attributed to both worker server IDs.
