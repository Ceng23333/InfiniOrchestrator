#!/usr/bin/env bash
# Proxy helpers for offline deployment build scripts.
# Use host network in build containers so 127.0.0.1:57890 reaches the host proxy.

DEFAULT_PROXY="${DEFAULT_PROXY:-http://127.0.0.1:57890}"
DEFAULT_NO_PROXY="${DEFAULT_NO_PROXY:-localhost,127.0.0.1,0.0.0.0,cr.metax-tech.com,*.metax-tech.com}"

proxy_env_args() {
  local -n _out=$1
  _out=(
    -e "HTTP_PROXY=${DEFAULT_PROXY}"
    -e "HTTPS_PROXY=${DEFAULT_PROXY}"
    -e "http_proxy=${DEFAULT_PROXY}"
    -e "https_proxy=${DEFAULT_PROXY}"
    -e "NO_PROXY=${DEFAULT_NO_PROXY}"
    -e "no_proxy=${DEFAULT_NO_PROXY}"
  )
}

test_proxy() {
  curl -fsS --connect-timeout 3 --proxy "${DEFAULT_PROXY}" https://github.com >/dev/null 2>&1
}

# Only enable proxy when the port is actually listening.
proxy_is_listening() {
  curl -fsS --connect-timeout 2 --proxy "${DEFAULT_PROXY}" http://127.0.0.1/ >/dev/null 2>&1 || \
    (echo >/dev/tcp/127.0.0.1/57890) >/dev/null 2>&1
}

test_direct_github() {
  curl -fsS --connect-timeout 5 --noproxy '*' https://github.com >/dev/null 2>&1
}

should_use_proxy() {
  if [[ "${USE_PROXY:-}" == "1" || "${USE_PROXY:-}" == "true" ]]; then
    if proxy_is_listening; then
      return 0
    fi
    echo "[proxy] USE_PROXY=1 but ${DEFAULT_PROXY} not listening" >&2
    return 1
  fi
  if [[ "${USE_PROXY:-}" == "0" || "${USE_PROXY:-}" == "false" ]]; then
    return 1
  fi
  if test_direct_github; then
    return 1
  fi
  if proxy_is_listening && test_proxy; then
    echo "[proxy] direct GitHub unreachable; using ${DEFAULT_PROXY}" >&2
    return 0
  fi
  echo "[proxy] direct GitHub unreachable and proxy ${DEFAULT_PROXY} unavailable" >&2
  return 1
}
