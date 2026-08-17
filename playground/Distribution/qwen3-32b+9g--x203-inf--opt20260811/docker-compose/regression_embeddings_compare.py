#!/usr/bin/env python3
"""Embedding regression helper: fixed pack, bge-m3 self-gate, MiniCPM vs bge ranking A/B.

Used by regression_embeddings_vs_baseline.sh. Stdlib only (no numpy/scipy).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Sequence, Tuple

# MiniCPM demo + a few EN/ZH strings; corpus includes beijing/shanghai + distractors.
FIXED_QUERIES: List[Tuple[str, str]] = [
    ("capital_zh", "中国的首都是哪里？"),
    ("hello", "hello"),
    ("ml", "machine learning"),
    ("greeting_zh", "你好世界"),
]

FIXED_CORPUS: List[Tuple[str, str]] = [
    # Descriptive passages: bare "beijing"/"shanghai" tokens reverse-rank under bge-m3
    # encode_corpus (OpenAI path); MiniCPM demo used the same ids with query instruction.
    ("beijing", "Beijing is the capital of China"),
    ("shanghai", "Shanghai is a major city in China"),
    ("tokyo", "Tokyo is the capital of Japan"),
    ("paris", "Paris is the capital of France"),
    ("neural_nets", "neural networks and deep learning"),
    ("cooking", "how to cook pasta"),
    ("weather", "today's weather forecast"),
    ("hello_doc", "hello"),
]

CAPITAL_QUERY_ID = "capital_zh"
CAPITAL_WIN_ID = "beijing"
CAPITAL_LOSE_ID = "shanghai"
SELF_COSINE_TEXT_ID = "hello"  # query id whose text also appears as hello_doc
SELF_COSINE_DOC_ID = "hello_doc"

EXPECTED_BGE_DIM = 1024
L2_TOL = 0.05
SELF_COSINE_MIN = 0.99
DEFAULT_AGREE_THRESHOLD = 0.75
DEFAULT_TOP_K = 3


def _http_json(method: str, url: str, body: Optional[dict] = None, timeout: float = 120.0) -> Any:
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    # Bypass proxies for localhost regression.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else None


def l2_norm(vec: Sequence[float]) -> float:
    return math.sqrt(sum(x * x for x in vec))


def cosine(a: Sequence[float], b: Sequence[float]) -> float:
    if len(a) != len(b):
        raise ValueError(f"dim mismatch: {len(a)} vs {len(b)}")
    na, nb = l2_norm(a), l2_norm(b)
    if na == 0.0 or nb == 0.0:
        return 0.0
    return sum(x * y for x, y in zip(a, b)) / (na * nb)


def embed_texts(base_url: str, model: str, texts: List[str], timeout: float = 600.0) -> List[List[float]]:
    url = base_url.rstrip("/") + "/v1/embeddings"
    payload = {"model": model, "input": texts}
    resp = _http_json("POST", url, payload, timeout=timeout)
    if not isinstance(resp, dict) or "data" not in resp:
        raise RuntimeError(f"bad embeddings response from {url}: {resp!r}")
    items = sorted(resp["data"], key=lambda x: x.get("index", 0))
    if len(items) != len(texts):
        raise RuntimeError(f"expected {len(texts)} embeddings, got {len(items)}")
    out: List[List[float]] = []
    for item in items:
        emb = item.get("embedding")
        if not isinstance(emb, list):
            raise RuntimeError(f"missing embedding in item: {item!r}")
        out.append([float(x) for x in emb])
    return out


def list_embedding_model_ids(base_url: str) -> List[str]:
    health = None
    try:
        health = _http_json("GET", base_url.rstrip("/") + "/health", timeout=30.0)
    except Exception:
        pass
    models_resp = _http_json("GET", base_url.rstrip("/") + "/v1/models", timeout=30.0)
    ids: List[str] = []
    if isinstance(models_resp, dict):
        for row in models_resp.get("data") or []:
            mid = row.get("id")
            if isinstance(mid, str):
                ids.append(mid)
    if isinstance(health, dict):
        for mid in health.get("embeddings") or []:
            if isinstance(mid, str) and mid not in ids:
                ids.append(mid)
    return ids


def resolve_request_model(requested: str, available: List[str]) -> str:
    """Map OpenAI alias / requested id onto a loaded embedding id."""
    if requested in available:
        return requested
    if requested == "text-embedding-ada-002":
        if "bge-m3" in available:
            return "bge-m3"
        if "minicpm-embedding" in available:
            return "minicpm-embedding"
    raise RuntimeError(f"model {requested!r} not available in {available}")


def capture_pack(base_url: str, model: str, role: str) -> Dict[str, Any]:
    ids = list_embedding_model_ids(base_url)
    resolve_model = resolve_request_model(model, ids)
    q_texts = [t for _, t in FIXED_QUERIES]
    c_texts = [t for _, t in FIXED_CORPUS]

    q_embs = embed_texts(base_url, resolve_model, q_texts)
    c_embs = embed_texts(base_url, resolve_model, c_texts)

    dump: Dict[str, Any] = {
        "role": role,
        "base_url": base_url.rstrip("/"),
        "requested_model": model,
        "resolved_model": resolve_model,
        "available_models": ids,
        "queries": {
            qid: {"text": text, "embedding": emb}
            for (qid, text), emb in zip(FIXED_QUERIES, q_embs)
        },
        "corpus": {
            cid: {"text": text, "embedding": emb}
            for (cid, text), emb in zip(FIXED_CORPUS, c_embs)
        },
    }

    # Optional BCE rerank sanity (candidate only; ignore failures).
    if role == "candidate":
        try:
            capital_text = dict(FIXED_QUERIES)[CAPITAL_QUERY_ID]
            passages = [dict(FIXED_CORPUS)[CAPITAL_WIN_ID], dict(FIXED_CORPUS)[CAPITAL_LOSE_ID]]
            scores = _http_json(
                "POST",
                base_url.rstrip("/") + "/rerankbce",
                {"query": capital_text, "passages": passages},
                timeout=60.0,
            )
            if isinstance(scores, list) and len(scores) == 2:
                dump["rerankbce"] = {
                    "query_id": CAPITAL_QUERY_ID,
                    "passages": [CAPITAL_WIN_ID, CAPITAL_LOSE_ID],
                    "scores": [float(scores[0]), float(scores[1])],
                    "beijing_above_shanghai": float(scores[0]) > float(scores[1]),
                }
        except Exception as e:
            dump["rerankbce"] = {"skipped": True, "reason": str(e)}

    return dump


def rank_corpus(query_emb: Sequence[float], corpus: Dict[str, Dict[str, Any]]) -> List[Tuple[str, float]]:
    scored = [(cid, cosine(query_emb, row["embedding"])) for cid, row in corpus.items()]
    scored.sort(key=lambda x: (-x[1], x[0]))
    return scored


def spearman_rho(ranks_a: List[int], ranks_b: List[int]) -> float:
    """Spearman correlation for two rank vectors (1..n)."""
    n = len(ranks_a)
    if n < 2:
        return 1.0
    d2 = sum((a - b) ** 2 for a, b in zip(ranks_a, ranks_b))
    return 1.0 - (6.0 * d2) / (n * (n * n - 1))


def self_check_candidate(dump: Dict[str, Any]) -> Dict[str, Any]:
    checks: List[Dict[str, Any]] = []
    ok = True

    def add(name: str, passed: bool, detail: Any) -> None:
        nonlocal ok
        checks.append({"name": name, "pass": passed, "detail": detail})
        if not passed:
            ok = False

    resolved = dump.get("resolved_model")
    add("resolved_model_is_bge_m3", resolved == "bge-m3", {"resolved_model": resolved})

    all_vecs: List[Tuple[str, List[float]]] = []
    for qid, row in dump["queries"].items():
        all_vecs.append((f"query:{qid}", row["embedding"]))
    for cid, row in dump["corpus"].items():
        all_vecs.append((f"corpus:{cid}", row["embedding"]))

    finite = all(math.isfinite(x) for _, v in all_vecs for x in v)
    add("all_finite", finite, {"vectors": len(all_vecs)})

    dims = {len(v) for _, v in all_vecs}
    add("dim_1024", dims == {EXPECTED_BGE_DIM}, {"dims": sorted(dims)})

    l2_ok = True
    l2_samples = []
    for name, v in all_vecs:
        nrm = l2_norm(v)
        l2_samples.append({"name": name, "l2": nrm})
        if abs(nrm - 1.0) > L2_TOL:
            l2_ok = False
    add("l2_near_1", l2_ok, {"tol": L2_TOL, "samples": l2_samples[:4], "count": len(l2_samples)})

    q_hello = dump["queries"][SELF_COSINE_TEXT_ID]["embedding"]
    d_hello = dump["corpus"][SELF_COSINE_DOC_ID]["embedding"]
    self_cos = cosine(q_hello, d_hello)
    add(
        "same_text_self_cosine",
        self_cos >= SELF_COSINE_MIN,
        {"cosine": self_cos, "min": SELF_COSINE_MIN},
    )

    capital_ranks = rank_corpus(dump["queries"][CAPITAL_QUERY_ID]["embedding"], dump["corpus"])
    score_map = {cid: sc for cid, sc in capital_ranks}
    beijing_above = score_map[CAPITAL_WIN_ID] > score_map[CAPITAL_LOSE_ID]
    add(
        "capital_beijing_above_shanghai",
        beijing_above,
        {
            "beijing": score_map[CAPITAL_WIN_ID],
            "shanghai": score_map[CAPITAL_LOSE_ID],
            "top1": capital_ranks[0][0],
        },
    )

    rerank = dump.get("rerankbce")
    if isinstance(rerank, dict) and rerank.get("beijing_above_shanghai") is True:
        add("rerankbce_beijing_above_shanghai", True, rerank)
    elif isinstance(rerank, dict) and "scores" in rerank:
        add("rerankbce_beijing_above_shanghai", bool(rerank.get("beijing_above_shanghai")), rerank)
    # If BCE skipped/unavailable, do not fail the gate.

    return {"pass": ok, "checks": checks}


def compare_dumps(
    baseline: Dict[str, Any],
    candidate: Dict[str, Any],
    agree_threshold: float = DEFAULT_AGREE_THRESHOLD,
    top_k: int = DEFAULT_TOP_K,
) -> Dict[str, Any]:
    per_query: List[Dict[str, Any]] = []
    top1_hits = 0
    pairwise_agree = 0
    pairwise_total = 0
    spearman_vals: List[float] = []

    corpus_ids = [cid for cid, _ in FIXED_CORPUS]

    for qid, _ in FIXED_QUERIES:
        b_ranks = rank_corpus(baseline["queries"][qid]["embedding"], baseline["corpus"])
        c_ranks = rank_corpus(candidate["queries"][qid]["embedding"], candidate["corpus"])
        b_order = [cid for cid, _ in b_ranks]
        c_order = [cid for cid, _ in c_ranks]
        b_score = {cid: sc for cid, sc in b_ranks}
        c_score = {cid: sc for cid, sc in c_ranks}

        top1_match = b_order[0] == c_order[0]
        if top1_match:
            top1_hits += 1

        # Pairwise preference on corpus ids (fixed order of pairs).
        q_pair_agree = 0
        q_pair_total = 0
        for i, a in enumerate(corpus_ids):
            for b in corpus_ids[i + 1 :]:
                b_pref = b_score[a] - b_score[b]
                c_pref = c_score[a] - c_score[b]
                # Ties (exact 0) count as agreement only if both tie.
                b_sign = (b_pref > 0) - (b_pref < 0)
                c_sign = (c_pref > 0) - (c_pref < 0)
                q_pair_total += 1
                if b_sign == c_sign:
                    q_pair_agree += 1
        pairwise_agree += q_pair_agree
        pairwise_total += q_pair_total

        # Spearman on ranks over the shared corpus id set.
        b_rank_pos = {cid: i + 1 for i, cid in enumerate(b_order)}
        c_rank_pos = {cid: i + 1 for i, cid in enumerate(c_order)}
        rho = spearman_rho([b_rank_pos[cid] for cid in corpus_ids], [c_rank_pos[cid] for cid in corpus_ids])
        spearman_vals.append(rho)

        per_query.append(
            {
                "query_id": qid,
                "baseline_top_k": b_order[:top_k],
                "candidate_top_k": c_order[:top_k],
                "top1_match": top1_match,
                "pairwise_agreement": (q_pair_agree / q_pair_total) if q_pair_total else 1.0,
                "spearman": rho,
                "baseline_scores": b_score,
                "candidate_scores": c_score,
            }
        )

    nq = len(FIXED_QUERIES)
    top1_rate = top1_hits / nq if nq else 0.0
    pair_rate = pairwise_agree / pairwise_total if pairwise_total else 0.0
    mean_spearman = sum(spearman_vals) / len(spearman_vals) if spearman_vals else 0.0

    gate = self_check_candidate(candidate)
    ranking_pass = pair_rate >= agree_threshold
    overall = bool(gate["pass"] and ranking_pass)

    return {
        "pass": overall,
        "agree_threshold": agree_threshold,
        "metrics": {
            "top1_agreement": top1_rate,
            "pairwise_agreement": pair_rate,
            "mean_spearman": mean_spearman,
            "pairwise_agree": pairwise_agree,
            "pairwise_total": pairwise_total,
        },
        "self_check": gate,
        "ranking_pass": ranking_pass,
        "baseline_model": baseline.get("resolved_model"),
        "candidate_model": candidate.get("resolved_model"),
        "per_query": per_query,
    }


def _write_json(path: str, obj: Any) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_cap = sub.add_parser("capture", help="Dump fixed pack embeddings from a live server")
    p_cap.add_argument("--base-url", required=True)
    p_cap.add_argument("--model", required=True)
    p_cap.add_argument("--role", choices=["baseline", "candidate"], required=True)
    p_cap.add_argument("--out", required=True)

    p_gate = sub.add_parser("gate", help="Run bge-m3 self-checks on a candidate dump")
    p_gate.add_argument("--candidate", required=True)
    p_gate.add_argument("--out", help="Optional report JSON path")

    p_cmp = sub.add_parser("compare", help="Compare baseline vs candidate rankings")
    p_cmp.add_argument("--baseline", required=True)
    p_cmp.add_argument("--candidate", required=True)
    p_cmp.add_argument("--out", required=True)
    p_cmp.add_argument("--agree-threshold", type=float, default=DEFAULT_AGREE_THRESHOLD)
    p_cmp.add_argument("--top-k", type=int, default=DEFAULT_TOP_K)

    args = parser.parse_args(argv)

    if args.cmd == "capture":
        dump = capture_pack(args.base_url, args.model, args.role)
        _write_json(args.out, dump)
        print(f"Wrote {args.out} role={args.role} model={dump.get('resolved_model')}")
        return 0

    if args.cmd == "gate":
        with open(args.candidate, encoding="utf-8") as f:
            candidate = json.load(f)
        report = self_check_candidate(candidate)
        if args.out:
            _write_json(args.out, report)
        print(json.dumps({"pass": report["pass"], "checks": [c["name"] for c in report["checks"] if not c["pass"]]}, ensure_ascii=False))
        return 0 if report["pass"] else 2

    if args.cmd == "compare":
        with open(args.baseline, encoding="utf-8") as f:
            baseline = json.load(f)
        with open(args.candidate, encoding="utf-8") as f:
            candidate = json.load(f)
        report = compare_dumps(
            baseline,
            candidate,
            agree_threshold=args.agree_threshold,
            top_k=args.top_k,
        )
        _write_json(args.out, report)
        m = report["metrics"]
        print(
            f"report={args.out} pass={report['pass']} "
            f"self_check={report['self_check']['pass']} ranking_pass={report['ranking_pass']} "
            f"pairwise={m['pairwise_agreement']:.3f} top1={m['top1_agreement']:.3f} "
            f"spearman={m['mean_spearman']:.3f} "
            f"baseline={report['baseline_model']} candidate={report['candidate_model']}"
        )
        return 0 if report["pass"] else 2

    parser.error(f"unknown cmd {args.cmd}")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.URLError as e:
        print(f"HTTP error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
