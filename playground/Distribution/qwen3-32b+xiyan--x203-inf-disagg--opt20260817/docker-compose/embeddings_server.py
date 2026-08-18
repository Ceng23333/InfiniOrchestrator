from flask import Flask, request, jsonify
import logging
import os
import time
import sys
from datetime import datetime

app = Flask(__name__)


def _install_transformers_tf5_compat_shim():
    """MiniCPM remote code imports is_torch_fx_available (removed in Transformers 5)."""
    try:
        import transformers.utils.import_utils as import_utils
    except Exception as e:
        logging.getLogger(__name__).warning(f"Could not import transformers.utils.import_utils: {e}")
        return
    if hasattr(import_utils, "is_torch_fx_available"):
        return
    # Safe stub: skip FX wrap paths in MiniCPM modeling_*.py (inference does not need them).
    import_utils.is_torch_fx_available = lambda: False
    logging.getLogger(__name__).info(
        "Installed TF5 compat shim: transformers.utils.import_utils.is_torch_fx_available -> False"
    )


_install_transformers_tf5_compat_shim()

from transformers import AutoModel, AutoModelForSequenceClassification, AutoTokenizer, LlamaTokenizer
import torch
import numpy as np

# Configure logging
log_file = f"embeddings_server_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


@app.before_request
def log_request_info():
    logger.info(f"Request: {request.method} {request.url} from {request.remote_addr}")


@app.after_request
def log_response_info(response):
    logger.info(f"Response: {response.status_code}")
    return response


DEFAULT_EMBEDDING_MODEL = "bge-m3"
EMBEDDING_MODEL_PATHS = {
    "bge-m3": "/workspace/models/bge-m3",
    "minicpm-embedding": "/workspace/models/MiniCPM-Embedding-Light",
}
EMBEDDING_MODEL_ALIASES = {
    "bge-m3": "bge-m3",
    "BAAI/bge-m3": "bge-m3",
    "minicpm-embedding": "minicpm-embedding",
    "MiniCPM-Embedding-Light": "minicpm-embedding",
    "openbmb/MiniCPM-Embedding-Light": "minicpm-embedding",
    # OpenAI-compatible default used by validate.sh; keep routing to bge-m3.
    "text-embedding-ada-002": "bge-m3",
    # UltraRAG development configurations use this legacy model name.
    "qwen-embedding": "bge-m3",
}

MINICPM_RERANK_PATH = "/workspace/models/MiniCPM-Reranker-Light"
BCE_RERANK_PATH = "/workspace/models/bce-reranker-base_v1"

# Populated at startup; used by /v1/models and /health.
loaded_rerank_ids = []
rerank_model = None
rerank_tokenizer = None
bce_model = None
bce_tokenizer = None
device = "cuda"


class BgeM3Encoder:
    """Thin wrapper: BGE-M3 uses XLM-RoBERTa + CLS pooling, not MiniCPM-style encode_corpus."""

    def __init__(self, model, tok, device="cuda"):
        self.model = model
        self.tokenizer = tok
        self.device = device

    def _encode(self, texts):
        inputs = self.tokenizer(texts, padding=True, truncation=True, return_tensors="pt").to(self.device)
        with torch.no_grad():
            hidden = self.model(**inputs).last_hidden_state[:, 0]
            return torch.nn.functional.normalize(hidden, p=2, dim=1)

    def encode_corpus(self, texts, return_sparse_vectors=True):
        dense = self._encode(texts)
        sparse = {} if return_sparse_vectors else None
        return dense, sparse

    def encode_query(self, texts, return_sparse_vectors=True):
        return self.encode_corpus(texts, return_sparse_vectors=return_sparse_vectors)


def _dense_to_numpy(dense):
    if isinstance(dense, torch.Tensor):
        return dense.detach().float().cpu().numpy()
    return np.asarray(dense, dtype=np.float32)


def _numeric_smoke_ok(dense, label):
    arr = _dense_to_numpy(dense)
    if arr.size == 0:
        logger.warning(f"Numeric smoke failed for {label}: empty embedding")
        return False
    if not np.isfinite(arr).all() or np.isnan(arr).any():
        logger.warning(f"Numeric smoke failed for {label}: NaN/Inf in embeddings")
        return False
    return True


def _load_bge_m3(model_path):
    logger.info(f"Loading embedding model: {model_path}")
    tokenizer = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True, local_files_only=True)
    backbone = AutoModel.from_pretrained(
        model_path, trust_remote_code=True, torch_dtype=torch.float16, local_files_only=True
    ).to("cuda")
    backbone.eval()
    encoder = BgeM3Encoder(backbone, tokenizer)
    with torch.no_grad():
        dense, _ = encoder.encode_corpus(["hello"], return_sparse_vectors=False)
    if not _numeric_smoke_ok(dense, "bge-m3"):
        raise RuntimeError("bge-m3 numeric smoke failed")
    return encoder


def _load_minicpm_embedding(model_path):
    """Load MiniCPM under product TF5; raise on import/load/NaN so caller can skip."""
    logger.info(f"Loading embedding model (MiniCPM, TF5-compat path): {model_path}")
    _install_transformers_tf5_compat_shim()
    tokenizer = LlamaTokenizer.from_pretrained(model_path, trust_remote_code=True, local_files_only=True)
    model = AutoModel.from_pretrained(
        model_path, trust_remote_code=True, torch_dtype=torch.float16, local_files_only=True
    ).to("cuda")
    model.eval()
    with torch.no_grad():
        dense, _ = model.encode_corpus(["hello"], return_sparse_vectors=False)
    if not _numeric_smoke_ok(dense, "minicpm-embedding"):
        raise RuntimeError("minicpm-embedding numeric smoke failed (NaN/Inf); skipping MiniCPM")
    # Keep tokenizer ref on model for debugging; encode_* live on remote-code model.
    model._compat_tokenizer = tokenizer
    return model


def _load_embedding_models():
    loaders = {
        "bge-m3": _load_bge_m3,
        "minicpm-embedding": _load_minicpm_embedding,
    }
    # Prefer bge-m3 first so TF5 MiniCPM failure still yields a working server.
    load_order = ["bge-m3", "minicpm-embedding"]
    models = {}
    for key in load_order:
        path = EMBEDDING_MODEL_PATHS[key]
        if not os.path.isdir(path):
            logger.warning(f"Skipping embedding model {key}: path missing ({path})")
            continue
        try:
            models[key] = loaders[key](path)
            logger.info(f"Embedding model loaded successfully: {key}")
        except Exception as e:
            logger.warning(f"Skipping embedding model {key}: {e}")
    if not models:
        raise RuntimeError(
            "No embedding models loaded; expected at least one of: "
            + ", ".join(EMBEDDING_MODEL_PATHS.values())
            + " (MiniCPM may be disabled on TF5 when numeric smoke fails)"
        )
    return models


embedding_models = _load_embedding_models()

# validate.sh probes text-embedding-ada-002 → bge-m3; fall back when bge-m3 absent.
if "bge-m3" not in embedding_models and "minicpm-embedding" in embedding_models:
    EMBEDDING_MODEL_ALIASES["text-embedding-ada-002"] = "minicpm-embedding"
    EMBEDDING_MODEL_ALIASES["qwen-embedding"] = "minicpm-embedding"
    logger.info("Aliasing text-embedding-ada-002 / qwen-embedding → minicpm-embedding (bge-m3 absent)")
elif "minicpm-embedding" not in embedding_models:
    logger.info(
        "MiniCPM embedding disabled (missing or TF5 numeric smoke failed); "
        "serving bge-m3 (+ BCE rerank if present). InfiniLM native embed API not used here."
    )


def resolve_embedding_model(requested_name):
    model_key = EMBEDDING_MODEL_ALIASES.get(requested_name, requested_name)
    if model_key not in embedding_models:
        available = ", ".join(sorted(embedding_models))
        raise ValueError(f"Unknown embedding model '{requested_name}'. Available: {available}")
    return model_key, embedding_models[model_key]


def warmup_embedding_models():
    """Warmup all embedding models to initialize CUDA kernels."""
    warmup_texts = ["This is a warmup request."]
    for model_key, model in embedding_models.items():
        logger.info(f"Warming up embedding model: {model_key}...")
        try:
            with torch.no_grad():
                start_time = time.time()
                # MiniCPM sparse pooling is very expensive; dense-only warmup is enough.
                model.encode_corpus(warmup_texts, return_sparse_vectors=False)
                if torch.cuda.is_available():
                    torch.cuda.synchronize()
                warmup_time = time.time() - start_time
                logger.info(f"{model_key} warmup completed in {warmup_time:.3f}s")
        except Exception as e:
            logger.warning(f"Warmup failed for {model_key} (non-fatal): {e}")


def _load_rerank_models():
    """Load MiniCPM rerank (optional on TF5) and BCE rerank when present."""
    global rerank_model, rerank_tokenizer, bce_model, bce_tokenizer, loaded_rerank_ids

    if os.path.isdir(MINICPM_RERANK_PATH):
        try:
            logger.info(f"Loading MiniCPM reranking model: {MINICPM_RERANK_PATH}")
            _install_transformers_tf5_compat_shim()
            rerank_tokenizer = LlamaTokenizer.from_pretrained(
                MINICPM_RERANK_PATH, trust_remote_code=True, local_files_only=True
            )
            candidate = AutoModelForSequenceClassification.from_pretrained(
                MINICPM_RERANK_PATH,
                trust_remote_code=True,
                torch_dtype=torch.float16,
                local_files_only=True,
            ).to("cuda")
            candidate.eval()
            with torch.no_grad():
                scores = candidate.rerank(
                    "test query",
                    ["test passage"],
                    query_instruction="Query:",
                    batch_size=1,
                    max_length=512,
                )
            score_arr = _dense_to_numpy(scores)
            if not np.isfinite(score_arr).all():
                raise RuntimeError("MiniCPM rerank numeric smoke failed (NaN/Inf)")
            rerank_model = candidate
            loaded_rerank_ids.append("minicpm-reranker")
            logger.info("MiniCPM reranking model loaded successfully")
        except Exception as e:
            rerank_model = None
            rerank_tokenizer = None
            logger.warning(f"Skipping MiniCPM reranker: {e}")
    else:
        logger.warning(f"MiniCPM reranker path missing: {MINICPM_RERANK_PATH}")

    if os.path.isdir(BCE_RERANK_PATH):
        try:
            logger.info(f"Loading BCE reranker model: {BCE_RERANK_PATH}")
            bce_tokenizer = AutoTokenizer.from_pretrained(BCE_RERANK_PATH, local_files_only=True)
            bce_model = AutoModelForSequenceClassification.from_pretrained(
                BCE_RERANK_PATH, local_files_only=True
            )
            bce_model.to(device)
            bce_model.eval()
            loaded_rerank_ids.append("bce-reranker-base_v1")
            logger.info("BCE reranker model loaded successfully")
        except Exception as e:
            bce_model = None
            bce_tokenizer = None
            logger.warning(f"Skipping BCE reranker: {e}")
    else:
        logger.warning(f"BCE reranker path missing: {BCE_RERANK_PATH}")


_load_rerank_models()


@app.route("/health", methods=["GET"])
def health():
    return jsonify(
        {
            "status": "ok",
            "embeddings": sorted(embedding_models.keys()),
            "rerank": list(loaded_rerank_ids),
        }
    )


@app.route("/v1/models", methods=["GET"])
def list_models():
    """OpenAI-style discovery used by entrypoint before registering openai-api instance."""
    data = []
    for model_id in sorted(embedding_models.keys()):
        data.append({"id": model_id, "object": "model", "owned_by": "local"})
    for model_id in loaded_rerank_ids:
        data.append({"id": model_id, "object": "model", "owned_by": "local"})
    return jsonify({"object": "list", "data": data})


@app.route("/v1/embeddings", methods=["POST"])
def embeddings():
    """
    OpenAI-compatible embeddings endpoint.
    Accepts: {"model": "model-name", "input": "text" or ["text1", "text2"], "encoding_format": "float" (optional)}
    Returns: OpenAI-compatible response format
    """
    start_time = time.time()
    try:
        if not request.json:
            return jsonify({"error": {"message": "Request body must be JSON", "type": "invalid_request_error"}}), 400

        # Parse OpenAI-compatible request
        model_name = request.json.get("model", DEFAULT_EMBEDDING_MODEL)
        input_data = request.json.get("input")
        encoding_format = request.json.get("encoding_format", "float")

        if input_data is None:
            return jsonify({"error": {"message": "Missing required parameter: input", "type": "invalid_request_error"}}), 400

        # Handle both string and list inputs
        if isinstance(input_data, str):
            texts = [input_data]
        elif isinstance(input_data, list):
            texts = input_data
        else:
            return jsonify({"error": {"message": "input must be a string or array of strings", "type": "invalid_request_error"}}), 400

        model_key, embedding_model = resolve_embedding_model(model_name)
        logger.info(f"Embedding request - model: {model_name} -> {model_key}, texts count: {len(texts)}")

        # OpenAI response is dense-only; skip MiniCPM sparse pooling (very expensive / cold-start).
        with torch.no_grad():
            embeddings_dense, embeddings_sparse = embedding_model.encode_corpus(
                texts, return_sparse_vectors=False
            )

        embeddings_dense = _dense_to_numpy(embeddings_dense)

        processing_time = time.time() - start_time
        logger.info(f"Processing time: {processing_time:.3f}s")

        # Build OpenAI-compatible response
        response_data = []
        for idx, embedding in enumerate(embeddings_dense):
            embedding_list = embedding.tolist()
            response_data.append({
                "object": "embedding",
                "embedding": embedding_list,
                "index": idx
            })

        # Estimate token usage (rough approximation)
        total_tokens = sum(len(text.split()) * 1.3 for text in texts)

        response = {
            "object": "list",
            "data": response_data,
            "model": model_key,
            "usage": {
                "prompt_tokens": int(total_tokens),
                "total_tokens": int(total_tokens)
            }
        }

        return jsonify(response)

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"Error processing embedding request: {str(e)}, processing time: {processing_time:.3f}s")
        return jsonify({"error": {"message": str(e), "type": "server_error"}}), 500


# Keep the old endpoint for backward compatibility
@app.route("/embedding", methods=["GET", "POST"])
def emb():
    start_time = time.time()
    try:
        embedding_type: str = request.json["embedding_type"]
        texts: list[str] = request.json["texts"]
        requested_model = request.json.get("model", DEFAULT_EMBEDDING_MODEL)
        model_key, embedding_model = resolve_embedding_model(requested_model)
        logger.info(
            f"Embedding request - model: {requested_model} -> {model_key}, "
            f"type: {embedding_type}, texts count: {len(texts)}"
        )

        if embedding_type == "query":
            embeddings_dense, embeddings_sparse = embedding_model.encode_query(texts, return_sparse_vectors=True)
        elif embedding_type == "doc":
            embeddings_dense, embeddings_sparse = embedding_model.encode_corpus(texts, return_sparse_vectors=True)
        else:
            logger.error(f"Invalid embedding type: {embedding_type}")
            return {"error": "Invalid embedding type"}, 400

        processing_time = time.time() - start_time
        logger.info(f"Processing time: {processing_time:.3f}s")

        embeddings_dense = _dense_to_numpy(embeddings_dense)
        return {"dense_embeddings": embeddings_dense.tolist(), "sparse_embeddings": embeddings_sparse}

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"Error: {str(e)}, processing time: {processing_time:.3f}s")
        return {"error": str(e)}, 500


def warmup_rerank_model():
    """Warmup the MiniCPM reranking model to avoid slow first requests."""
    if rerank_model is None:
        return
    logger.info("Warming up MiniCPM reranking model...")
    try:
        with torch.no_grad():
            test_query = "test query"
            test_passages = ["test passage 1", "test passage 2"]
            rerank_model.rerank(test_query, test_passages, query_instruction="Query:", batch_size=32, max_length=8000)
            if torch.cuda.is_available():
                torch.cuda.synchronize()
        logger.info("Reranking model warmup completed successfully")
    except Exception as e:
        logger.warning(f"Rerank warmup failed (non-fatal): {e}")


@app.route("/rerank", methods=["GET", "POST"])
def rerank():
    start_time = time.time()
    try:
        if rerank_model is None:
            return {"error": "MiniCPM reranker not loaded (disabled on TF5 or missing)"}, 503
        payload = request.get_json(silent=True) or {}
        query = payload.get("query")
        passages = payload.get("passages")
        if passages is None:
            passages = payload.get("documents")
        if not isinstance(query, str) or not isinstance(passages, list):
            return {"error": "query and passages/documents are required"}, 400
        logger.info(f"Rerank request - query length: {len(query)}, passages count: {len(passages)}")

        rerank_score = rerank_model.rerank(query, passages, query_instruction="Query:", batch_size=32, max_length=8000)

        processing_time = time.time() - start_time
        logger.info(f"Processing time: {processing_time:.3f}s")

        return _dense_to_numpy(rerank_score).tolist()

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"Error: {str(e)}, processing time: {processing_time:.3f}s")
        return {"error": str(e)}, 500


def warmup_bce_model():
    """Warmup the BCE reranking model to avoid slow first requests."""
    if bce_model is None or bce_tokenizer is None:
        return
    logger.info("Warming up BCE reranking model...")
    try:
        test_query = "test query"
        test_passages = ["test passage"]
        sentence_pairs = [[test_query, passage] for passage in test_passages]
        inputs = bce_tokenizer(sentence_pairs, padding=True, truncation=True, max_length=512, return_tensors="pt")
        inputs_on_device = {k: v.to(device) for k, v in inputs.items()}
        with torch.no_grad():
            scores = bce_model(**inputs_on_device, return_dict=True).logits.view(-1,).float()
            scores = torch.sigmoid(scores)
            if torch.cuda.is_available():
                torch.cuda.synchronize()
        logger.info("BCE reranking model warmup completed successfully")
    except Exception as e:
        logger.warning(f"BCE warmup failed (non-fatal): {e}")


@app.route("/rerankbce", methods=["GET", "POST"])
def rerankbce():
    start_time = time.time()
    try:
        if bce_model is None or bce_tokenizer is None:
            return {"error": "BCE reranker not loaded"}, 503
        query: str = request.json["query"]
        passages: list[str] = request.json["passages"]
        logger.info(f"BCE rerank request - query length: {len(query)}, passages count: {len(passages)}")

        sentence_pairs = [[query, passage] for passage in passages]
        inputs = bce_tokenizer(sentence_pairs, padding=True, truncation=True, max_length=512, return_tensors="pt")
        inputs_on_device = {k: v.to(device) for k, v in inputs.items()}

        scores = bce_model(**inputs_on_device, return_dict=True).logits.view(-1,).float()
        scores = torch.sigmoid(scores)

        processing_time = time.time() - start_time
        logger.info(f"Processing time: {processing_time:.3f}s")

        return scores.tolist()

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"Error: {str(e)}, processing time: {processing_time:.3f}s")
        return {"error": str(e)}, 500


if __name__ == "__main__":
    logger.info("Starting Flask server...")
    logger.info("Available endpoints:")
    logger.info("  GET  /health - liveness")
    logger.info("  GET  /v1/models - OpenAI-compatible model list (entrypoint discovery)")
    logger.info("  POST /v1/embeddings - OpenAI-compatible embeddings endpoint")
    logger.info(f"    loaded embeddings: {sorted(embedding_models.keys())}")
    logger.info(f"    loaded rerank: {loaded_rerank_ids}")
    logger.info("  POST /embedding - Legacy embeddings endpoint (optional model field)")
    logger.info("  POST /rerank - Rerank passages using MiniCPM model (if loaded)")
    logger.info("  POST /rerankbce - Rerank passages using BCE model (if loaded)")
    logger.info("Server will run on host=0.0.0.0, port=20002")

    logger.info("=" * 50)
    logger.info("Warming up embedding models before server start...")
    logger.info("=" * 50)

    try:
        warmup_embedding_models()
        logger.info("✓ embeddings model warmup completed")
    except Exception as e:
        logger.warning(f"✗ embeddings model warmup failed: {e}")

    try:
        warmup_bce_model()
    except Exception as e:
        logger.warning(f"BCE warmup skipped: {e}")

    logger.info("=" * 50)
    logger.info("Embedding models ready. Starting server...")
    logger.info("=" * 50)

    try:
        app.run(host="0.0.0.0", port=20002, debug=False, use_reloader=False, threaded=True)
    except KeyboardInterrupt:
        logger.info("Server shutdown requested by user")
    except Exception as e:
        logger.error(f"Server error: {e}")
    finally:
        logger.info("Server stopped")
