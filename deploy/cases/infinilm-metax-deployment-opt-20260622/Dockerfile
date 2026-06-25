# Thin scaffold for commit-based offline deployment (hpcc ai3.1.0.7 / torch2.6).
# Full install runs in a live container via setup-in-container.sh, then docker commit.

FROM cr.metax-tech.com/public-ai-release-wb/hpcc/vllm:hpcc.ai3.1.0.7-torch2.6-py310-kylin2309a-arm64

WORKDIR /app

RUN mkdir -p /app /workspace /InfiniCore /InfiniLM /InfiniCore/python/infinicore/lib \
    /InfiniLM/python/infinilm/lib logs config

COPY env-set.sh /app/env-set.sh

# Placeholder entrypoint; replaced after InfiniLM-SVC is copied during build-image.sh
ENTRYPOINT ["/bin/bash", "/app/docker_entrypoint.sh"]

LABEL org.opencontainers.image.description="InfiniLM-SVC scaffold on HPCC ai3.1.0.7 (commit-based build)"
