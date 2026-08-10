from flask import Flask, request, jsonify
import logging
import time
import sys
from datetime import datetime

app = Flask(__name__)
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


def _load_bge_m3(model_path):
    logger.info(f"Loading embedding model: {model_path}")
    tokenizer = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True, local_files_only=True)
    backbone = AutoModel.from_pretrained(
        model_path, trust_remote_code=True, torch_dtype=torch.float16, local_files_only=True
    ).to("cuda")
    backbone.eval()
    return BgeM3Encoder(backbone, tokenizer)


def _load_minicpm_embedding(model_path):
    logger.info(f"Loading embedding model: {model_path}")
    tokenizer = LlamaTokenizer.from_pretrained(model_path, trust_remote_code=True, local_files_only=True)
    model = AutoModel.from_pretrained(
        model_path, trust_remote_code=True, torch_dtype=torch.float16, local_files_only=True
    ).to("cuda")
    model.eval()
    return model


def _load_embedding_models():
    loaders = {
        "bge-m3": _load_bge_m3,
        "minicpm-embedding": _load_minicpm_embedding,
    }
    models = {}
    for key, path in EMBEDDING_MODEL_PATHS.items():
        models[key] = loaders[key](path)
        logger.info(f"Embedding model loaded successfully: {key}")
    return models


embedding_models = _load_embedding_models()


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

        # Use encode_corpus for document embeddings (OpenAI doesn't distinguish query/doc)
        # If you need query-specific encoding, you could check a custom parameter or use encode_query
        with torch.no_grad():
            embeddings_dense, embeddings_sparse = embedding_model.encode_corpus(texts, return_sparse_vectors=True)

        # Convert to numpy array if needed
        if isinstance(embeddings_dense, torch.Tensor):
            embeddings_dense = embeddings_dense.cpu().numpy()

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
        total_tokens = sum(len(text.split()) * 1.3 for text in texts)  # Rough token estimate

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

        return {"dense_embeddings": embeddings_dense.tolist(), "sparse_embeddings": embeddings_sparse}

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"Error: {str(e)}, processing time: {processing_time:.3f}s")
        return {"error": str(e)}, 500


rerank_model_name = "/workspace/models/MiniCPM-Reranker-Light"
logger.info(f"Loading reranking model: {rerank_model_name}")
rerank_tokenizer = LlamaTokenizer.from_pretrained(rerank_model_name, trust_remote_code=True, local_files_only=True)
rerank_model = AutoModelForSequenceClassification.from_pretrained(rerank_model_name, trust_remote_code=True, torch_dtype=torch.float16, local_files_only=True).to("cuda")
rerank_model.eval()
logger.info("Reranking model loaded successfully")


def warmup_rerank_model():
    """Warmup the reranking model to avoid slow first requests."""
    logger.info("Warming up reranking model...")
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

        return rerank_score.tolist()

    except Exception as e:
        processing_time = time.time() - start_time
        logger.error(f"Error: {str(e)}, processing time: {processing_time:.3f}s")
        return {"error": str(e)}, 500


bcepath = "/workspace/models/bce-reranker-base_v1"
logger.info(f"Loading BCE reranker model: {bcepath}")
bce_tokenizer = AutoTokenizer.from_pretrained(bcepath, local_files_only=True)
bce_model = AutoModelForSequenceClassification.from_pretrained(bcepath, local_files_only=True)

device = "cuda"  # if no GPU, set "cpu"
bce_model.to(device)
logger.info("BCE reranker model loaded successfully")


def warmup_bce_model():
    """Warmup the BCE reranking model to avoid slow first requests."""
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
        query: str = request.json["query"]
        passages: list[str] = request.json["passages"]
        logger.info(f"BCE rerank request - query length: {len(query)}, passages count: {len(passages)}")

        # get inputs
        sentence_pairs = [[query, passage] for passage in passages]
        inputs = bce_tokenizer(sentence_pairs, padding=True, truncation=True, max_length=512, return_tensors="pt")
        inputs_on_device = {k: v.to(device) for k, v in inputs.items()}

        # calculate scores
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
    logger.info("  POST /v1/embeddings - OpenAI-compatible embeddings endpoint")
    logger.info("    models: bge-m3, minicpm-embedding (aliases: text-embedding-ada-002 -> bge-m3)")
    logger.info("  POST /embedding - Legacy embeddings endpoint (optional model field)")
    logger.info("  POST /rerank - Rerank passages using MiniCPM model")
    logger.info("  POST /rerankbce - Rerank passages using BCE model")
    logger.info("Server will run on host=0.0.0.0, port=20002")

    # Block only on embedding warmup so /v1/embeddings is available quickly.
    logger.info("=" * 50)
    logger.info("Warming up embedding models before server start...")
    logger.info("=" * 50)

    try:
        warmup_embedding_models()
        logger.info("✓ embeddings model warmup completed")
    except Exception as e:
        logger.warning(f"✗ embeddings model warmup failed: {e}")

    logger.info("=" * 50)
    logger.info("Embedding models ready. Starting server...")
    logger.info("(Rerank models load lazily on first /rerank request)")
    logger.info("=" * 50)

    try:
        app.run(host="0.0.0.0", port=20002, debug=True, use_reloader=False, threaded=True)
    except KeyboardInterrupt:
        logger.info("Server shutdown requested by user")
    except Exception as e:
        logger.error(f"Server error: {e}")
    finally:
        logger.info("Server stopped")
