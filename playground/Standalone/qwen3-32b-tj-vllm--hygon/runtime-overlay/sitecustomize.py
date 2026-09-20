"""Apply the narrow X203 sampler workaround after vLLM/Mars import."""

import builtins
import sys


_original_import = builtins.__import__
_installed = False


def _install_sampler_patch():
    global _installed
    if _installed:
        return

    upstream = sys.modules.get("vllm.v1.sample.ops.topk_topp_sampler")
    mars = sys.modules.get("vllm_mars.patch.triton_support.topk_topp_sampler")
    rejection = sys.modules.get("vllm.v1.sample.rejection_sampler")
    states = sys.modules.get("vllm.v1.worker.gpu.sample.states")
    torch = sys.modules.get("torch")
    if not all((upstream, mars, rejection, states, torch)):
        return
    original = getattr(mars, "apply_top_k_top_p", None)
    if not callable(original):
        return

    def apply_top_k_top_p(logits, k, p):
        # vLLM V1 warmup uses k=vocab-1 and p=0.9. Mars 3.5.3 rejects the
        # corresponding accelerator operation even though Qwen3 has loaded.
        if k is not None and p is not None:
            is_dummy = bool(torch.all(k == logits.shape[1] - 1).item())
            is_dummy = is_dummy and bool(torch.all(p == 0.9).item())
            if is_dummy:
                return logits
        return original(logits, k, p)

    upstream.apply_top_k_top_p = apply_top_k_top_p
    mars.apply_top_k_top_p = apply_top_k_top_p
    rejection.apply_top_k_top_p = apply_top_k_top_p
    states.apply_top_k_top_p = apply_top_k_top_p
    _installed = True


def _import_with_sampler_patch(name, globals=None, locals=None, fromlist=(), level=0):
    module = _original_import(name, globals, locals, fromlist, level)
    _install_sampler_patch()
    return module


builtins.__import__ = _import_with_sampler_patch
