# Offline dependency bundles for Phase 1.5
#
# Produce on a **networked** host, then ship with the offline pack.
# Install inside the image with setup-phase1_5-offline-deps.sh only
# (`pip --no-index`, cargo vendor / `--offline`). See:
#   docs/IMAGE_BUILD_PHASES.md
#
# Layout:
#
#   offline-deps/
#     README.md          (this file)
#     pip/
#       requirements.lock
#       wheels/          # pip download -r requirements.lock -d wheels
#     cargo/
#       config.toml      # [source.crates-io] replace-with = "vendored-sources"
#       vendor/          # cargo vendor vendor
#     optional/          # InfiniCore / InfiniLM-SVC caches if needed
#
# Example (networked):
#
#   mkdir -p offline-deps/pip/wheels offline-deps/cargo
#   pip download -r offline-deps/pip/requirements.lock -d offline-deps/pip/wheels
#   (cd /path/to/InfiniLM-SVC && cargo vendor offline-deps/cargo/vendor)
#
# Phase 1.5 invocation:
#
#   RUNTIME_BASE_TAG=$(cat .runtime_base_tag) \
#   OFFLINE_DEPS_ROOT=$PWD/offline-deps \
#     ./build-image-phase1_5.sh
