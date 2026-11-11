#!/usr/bin/env python3
"""Template parser for the converged promo-facts-1 envelope.

See ../facts.md. Stdlib only.

Examples:
  python parse_promo_facts.py validate path/to/facts.json
  python parse_promo_facts.py canonicalize path/to/facts.json
  python parse_promo_facts.py summarize path/to/facts.json
  python parse_promo_facts.py load-suite path/to/suite/facts
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Optional, Sequence, Tuple, Union

SCHEMA_ID = "promo-facts"
SCHEMA_VERSION = "promo-facts-1"

WALL_GATES = frozenset({"PASS", "PROFILE_REGRESS", "SURPASS", "NO_GO"})
WALL_SOURCES = frozenset({"aiperf", "harness", "evalscope"})
VENDOR_PROFILERS = frozenset({"dlpti", "mctracer", "aiperf", "none"})
HOST_FAMILIES = frozenset({"driver", "runtime", "command", "api", "gap", "graph"})
HOST_MAPPED_FROM = frozenset({"dlpti", "mctracer"})
SHIP_ACTIONS = frozenset({"matrix", "itw_tag", "io_case", "none"})

JsonDict = Dict[str, Any]
PathLike = Union[str, Path]


class PromoFactsError(ValueError):
	"""Schema / parse error with a dotted path."""

	def __init__(self, path: str, message: str) -> None:
		self.path = path
		super().__init__(f"{path}: {message}")


def _is_mapping(v: Any) -> bool:
	return isinstance(v, Mapping)


def _req(obj: Mapping[str, Any], key: str, path: str) -> Any:
	if key not in obj:
		raise PromoFactsError(path, f"missing required field '{key}'")
	return obj[key]


def _opt(obj: Mapping[str, Any], key: str) -> Any:
	return obj.get(key)


def _as_str(v: Any, path: str, *, allow_empty: bool = False) -> str:
	if not isinstance(v, str):
		raise PromoFactsError(path, f"expected string, got {type(v).__name__}")
	if not allow_empty and v == "":
		raise PromoFactsError(path, "string must be non-empty")
	return v


def _as_bool(v: Any, path: str) -> bool:
	if not isinstance(v, bool):
		raise PromoFactsError(path, f"expected bool, got {type(v).__name__}")
	return v


def _as_number(v: Any, path: str) -> float:
	if isinstance(v, bool) or not isinstance(v, (int, float)):
		raise PromoFactsError(path, f"expected number, got {type(v).__name__}")
	return float(v)


def _as_enum(v: Any, path: str, allowed: Iterable[str]) -> str:
	s = _as_str(v, path)
	if s not in allowed:
		raise PromoFactsError(path, f"expected one of {sorted(allowed)}, got {s!r}")
	return s


def _as_str_list(v: Any, path: str) -> List[str]:
	if v is None:
		return []
	if not isinstance(v, list):
		raise PromoFactsError(path, f"expected array, got {type(v).__name__}")
	out: List[str] = []
	for i, item in enumerate(v):
		out.append(_as_str(item, f"{path}[{i}]", allow_empty=True))
	return out


def parse_wall(obj: Any, path: str) -> JsonDict:
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	return {
		"metric": _as_str(_req(obj, "metric", path), f"{path}.metric"),
		"baseline": _as_number(_req(obj, "baseline", path), f"{path}.baseline"),
		"candidate": _as_number(_req(obj, "candidate", path), f"{path}.candidate"),
		"WALL_DECODE_RATIO": _as_number(
			_req(obj, "WALL_DECODE_RATIO", path), f"{path}.WALL_DECODE_RATIO"
		),
		"gate": _as_enum(_req(obj, "gate", path), f"{path}.gate", WALL_GATES),
		"source": _as_enum(_req(obj, "source", path), f"{path}.source", WALL_SOURCES),
	}


def parse_host_signal(obj: Any, path: str) -> JsonDict:
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	out: JsonDict = {
		"family": _as_enum(_req(obj, "family", path), f"{path}.family", HOST_FAMILIES),
		"ratio": _as_number(_req(obj, "ratio", path), f"{path}.ratio"),
		"mapped_from": _as_enum(
			_req(obj, "mapped_from", path), f"{path}.mapped_from", HOST_MAPPED_FROM
		),
	}
	if "baseline" in obj and obj["baseline"] is not None:
		out["baseline"] = _as_number(obj["baseline"], f"{path}.baseline")
	if "candidate" in obj and obj["candidate"] is not None:
		out["candidate"] = _as_number(obj["candidate"], f"{path}.candidate")
	return out


def parse_cu_bucket(obj: Any, path: str) -> JsonDict:
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	out: JsonDict = {
		"bucket": _as_str(_req(obj, "bucket", path), f"{path}.bucket"),
		"ratio": _as_number(_req(obj, "ratio", path), f"{path}.ratio"),
		"material": _as_bool(_req(obj, "material", path), f"{path}.material"),
	}
	if "us_or_ms_per_norm" in obj and obj["us_or_ms_per_norm"] is not None:
		out["us_or_ms_per_norm"] = _as_number(
			obj["us_or_ms_per_norm"], f"{path}.us_or_ms_per_norm"
		)
	return out


def parse_ranked_path(obj: Any, path: str) -> JsonDict:
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	out: JsonDict = {
		"path_id": _as_str(_req(obj, "path_id", path), f"{path}.path_id"),
	}
	if "rank" in obj and obj["rank"] is not None:
		out["rank"] = _as_number(obj["rank"], f"{path}.rank")
	if "score" in obj and obj["score"] is not None:
		out["score"] = _as_number(obj["score"], f"{path}.score")
	if "priority_rule" in obj and obj["priority_rule"] is not None:
		pr = obj["priority_rule"]
		if isinstance(pr, (int, float)) and not isinstance(pr, bool):
			out["priority_rule"] = float(pr)
		else:
			out["priority_rule"] = _as_str(pr, f"{path}.priority_rule", allow_empty=True)
	if "reasons" in obj and obj["reasons"] is not None:
		out["reasons"] = _as_str_list(obj["reasons"], f"{path}.reasons")
	if "lever" in obj and obj["lever"] is not None:
		out["lever"] = _as_str(obj["lever"], f"{path}.lever", allow_empty=True)
	if "exhausted" in obj and obj["exhausted"] is not None:
		out["exhausted"] = _as_bool(obj["exhausted"], f"{path}.exhausted")
	return out


def parse_backlog(obj: Any, path: str) -> JsonDict:
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	ranked_raw = _req(obj, "ranked", path)
	if not isinstance(ranked_raw, list):
		raise PromoFactsError(f"{path}.ranked", "expected array")
	out: JsonDict = {
		"top_path": _as_str(_req(obj, "top_path", path), f"{path}.top_path"),
		"host_first_fired": _as_bool(
			_req(obj, "host_first_fired", path), f"{path}.host_first_fired"
		),
		"ranked": [parse_ranked_path(x, f"{path}.ranked[{i}]") for i, x in enumerate(ranked_raw)],
	}
	if "exhausted" in obj and obj["exhausted"] is not None:
		out["exhausted"] = _as_str_list(obj["exhausted"], f"{path}.exhausted")
	return out


def parse_ship(obj: Any, path: str) -> JsonDict:
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	out: JsonDict = {
		"surpass": _as_bool(_req(obj, "surpass", path), f"{path}.surpass"),
		"actions": _as_enum(_req(obj, "actions", path), f"{path}.actions", SHIP_ACTIONS),
	}
	if "findings_path" in obj and obj["findings_path"] is not None:
		out["findings_path"] = _as_str(
			obj["findings_path"], f"{path}.findings_path", allow_empty=True
		)
	return out


def parse_iter(obj: Any, path: str) -> JsonDict:
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	iter_v = _req(obj, "iter", path)
	if isinstance(iter_v, bool) or not isinstance(iter_v, (int, float, str)):
		raise PromoFactsError(f"{path}.iter", "expected number or string")
	out: JsonDict = {
		"iter": iter_v if isinstance(iter_v, str) else (int(iter_v) if float(iter_v).is_integer() else float(iter_v)),
		"profiled": _as_bool(_req(obj, "profiled", path), f"{path}.profiled"),
	}
	for key in ("suite_dir", "profile_run_id"):
		if key in obj and obj[key] is not None:
			out[key] = _as_str(obj[key], f"{path}.{key}", allow_empty=True)
	# lever_applied may be explicitly null in templates
	if "lever_applied" in obj:
		if obj["lever_applied"] is None:
			out["lever_applied"] = None
		else:
			out["lever_applied"] = _as_str(
				obj["lever_applied"], f"{path}.lever_applied", allow_empty=True
			)
	if "wall" in obj and obj["wall"] is not None:
		out["wall"] = parse_wall(obj["wall"], f"{path}.wall")
	if "host_signals" in obj and obj["host_signals"] is not None:
		hs = obj["host_signals"]
		if not isinstance(hs, list):
			raise PromoFactsError(f"{path}.host_signals", "expected array")
		out["host_signals"] = [
			parse_host_signal(x, f"{path}.host_signals[{i}]") for i, x in enumerate(hs)
		]
	if "cu_buckets" in obj and obj["cu_buckets"] is not None:
		cb = obj["cu_buckets"]
		if not isinstance(cb, list):
			raise PromoFactsError(f"{path}.cu_buckets", "expected array")
		out["cu_buckets"] = [
			parse_cu_bucket(x, f"{path}.cu_buckets[{i}]") for i, x in enumerate(cb)
		]
	if "backlog" in obj and obj["backlog"] is not None:
		out["backlog"] = parse_backlog(obj["backlog"], f"{path}.backlog")
	if "ship" in obj and obj["ship"] is not None:
		out["ship"] = parse_ship(obj["ship"], f"{path}.ship")
	return out


def parse_campaign(obj: Any, path: str, *, require_iters: bool) -> JsonDict:
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	out: JsonDict = {
		"campaign_id": _as_str(_req(obj, "campaign_id", path), f"{path}.campaign_id"),
		"host": _as_str(_req(obj, "host", path), f"{path}.host"),
		"vendor_profiler": _as_enum(
			_req(obj, "vendor_profiler", path), f"{path}.vendor_profiler", VENDOR_PROFILERS
		),
		"cell": _as_str(_req(obj, "cell", path), f"{path}.cell"),
		"pin_baseline": _as_str(_req(obj, "pin_baseline", path), f"{path}.pin_baseline"),
		"pin_candidate": _as_str(_req(obj, "pin_candidate", path), f"{path}.pin_candidate"),
	}
	for key in (
		"worktree_baseline",
		"worktree_candidate",
		"itw_tag_baseline",
		"itw_tag_candidate",
	):
		if key in obj and obj[key] is not None:
			out[key] = _as_str(obj[key], f"{path}.{key}", allow_empty=True)
	if "agent_ids" in obj and obj["agent_ids"] is not None:
		out["agent_ids"] = _as_str_list(obj["agent_ids"], f"{path}.agent_ids")
	if "source_paths" in obj and obj["source_paths"] is not None:
		out["source_paths"] = _as_str_list(obj["source_paths"], f"{path}.source_paths")

	if "iters" in obj and obj["iters"] is not None:
		iters_raw = obj["iters"]
		if not isinstance(iters_raw, list):
			raise PromoFactsError(f"{path}.iters", "expected array")
		out["iters"] = [parse_iter(x, f"{path}.iters[{i}]") for i, x in enumerate(iters_raw)]
	elif require_iters:
		raise PromoFactsError(f"{path}.iters", "missing required field 'iters'")
	return out


def parse_document(obj: Any, path: str = "$") -> JsonDict:
	"""Parse a 1.1 multi-campaign document into a canonical dict."""
	if not _is_mapping(obj):
		raise PromoFactsError(path, "expected object")
	version = _as_str(_req(obj, "schema_version", path), f"{path}.schema_version")
	if version != SCHEMA_VERSION:
		raise PromoFactsError(
			f"{path}.schema_version",
			f"unsupported version {version!r}; expected {SCHEMA_VERSION!r}",
		)
	campaigns_raw = _req(obj, "campaigns", path)
	if not isinstance(campaigns_raw, list) or not campaigns_raw:
		raise PromoFactsError(f"{path}.campaigns", "expected non-empty array")
	out: JsonDict = {
		"schema_version": SCHEMA_VERSION,
		"campaigns": [
			parse_campaign(c, f"{path}.campaigns[{i}]", require_iters=True)
			for i, c in enumerate(campaigns_raw)
		],
	}
	if "generated_at" in obj and obj["generated_at"] is not None:
		out["generated_at"] = _as_str(obj["generated_at"], f"{path}.generated_at")
	if "note" in obj and obj["note"] is not None:
		out["note"] = _as_str(obj["note"], f"{path}.note", allow_empty=True)
	return out


def load_json(path: PathLike) -> Any:
	text = Path(path).read_text(encoding="utf-8-sig")
	return json.loads(text)


def load_jsonl_iters(path: PathLike) -> List[JsonDict]:
	iters: List[JsonDict] = []
	for i, line in enumerate(Path(path).read_text(encoding="utf-8-sig").splitlines()):
		line = line.strip()
		if not line:
			continue
		obj = json.loads(line)
		iters.append(parse_iter(obj, f"iters.jsonl[{i}]"))
	return iters


def load_suite_facts(facts_dir: PathLike) -> JsonDict:
	"""Load §1.2 suite layout into a §1.1 document."""
	root = Path(facts_dir)
	campaign_path = root / "campaign.json"
	if not campaign_path.is_file():
		# Allow a single campaigns.json / combined.json inside the dir
		for name in ("combined.json", "campaigns.json", "facts.json"):
			alt = root / name
			if alt.is_file():
				return parse_document(load_json(alt), f"{alt.name}")
		raise PromoFactsError(str(root), "missing campaign.json (or combined.json)")

	campaign_obj = load_json(campaign_path)
	if not _is_mapping(campaign_obj):
		raise PromoFactsError("campaign.json", "expected object")

	iters: List[JsonDict] = []
	if isinstance(campaign_obj.get("iters"), list):
		iters = [
			parse_iter(x, f"campaign.json.iters[{i}]")
			for i, x in enumerate(campaign_obj["iters"])
		]
	jsonl = root / "iters.jsonl"
	if jsonl.is_file():
		iters = load_jsonl_iters(jsonl)
	else:
		iter_files = sorted(root.glob("iter*.json"))
		for fp in iter_files:
			iters.append(parse_iter(load_json(fp), fp.name))

	# Strip iters from campaign fact before re-attach
	base = {k: v for k, v in campaign_obj.items() if k != "iters"}
	camp = parse_campaign({**base, "iters": iters}, "campaign.json", require_iters=True)
	return {
		"schema_version": SCHEMA_VERSION,
		"campaigns": [camp],
	}


def parse_path(path: PathLike) -> JsonDict:
	"""Auto-detect file vs suite directory and return a canonical document."""
	p = Path(path)
	if p.is_dir():
		return load_suite_facts(p)
	obj = load_json(p)
	if not _is_mapping(obj):
		raise PromoFactsError(str(p), "expected JSON object")
	# Single campaign without schema_version → wrap
	if "schema_version" not in obj and "campaign_id" in obj:
		camp = parse_campaign(obj, p.name, require_iters=("iters" in obj))
		if "iters" not in camp:
			raise PromoFactsError(p.name, "single campaign file must include iters[]")
		return {"schema_version": SCHEMA_VERSION, "campaigns": [camp]}
	# Host scrape wrapper {host, campaigns} without schema → add version
	if "schema_version" not in obj and "campaigns" in obj:
		obj = {**obj, "schema_version": SCHEMA_VERSION}
	return parse_document(obj, p.name)


def summarize(doc: Mapping[str, Any]) -> str:
	lines = [
		f"schema={doc.get('schema_version')} campaigns={len(doc.get('campaigns') or [])}"
	]
	for c in doc.get("campaigns") or []:
		iters = c.get("iters") or []
		last = iters[-1] if iters else {}
		wall = last.get("wall") or {}
		backlog = last.get("backlog") or {}
		lines.append(
			"  {host} · {cid} · iters={n} · last_ratio={ratio} · top_path={top} · wt={wt}".format(
				host=c.get("host"),
				cid=c.get("campaign_id"),
				n=len(iters),
				ratio=wall.get("WALL_DECODE_RATIO"),
				top=backlog.get("top_path"),
				wt=c.get("worktree_candidate") or c.get("pin_candidate"),
			)
		)
	return "\n".join(lines)


def _cmd_validate(path: str) -> int:
	doc = parse_path(path)
	print(f"OK {path} ({SCHEMA_VERSION}, {len(doc['campaigns'])} campaign(s))")
	return 0


def _cmd_canonicalize(path: str) -> int:
	doc = parse_path(path)
	json.dump(doc, sys.stdout, indent=2, ensure_ascii=False)
	sys.stdout.write("\n")
	return 0


def _cmd_summarize(path: str) -> int:
	doc = parse_path(path)
	print(summarize(doc))
	return 0


def _cmd_load_suite(path: str) -> int:
	doc = load_suite_facts(path)
	json.dump(doc, sys.stdout, indent=2, ensure_ascii=False)
	sys.stdout.write("\n")
	return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	sub = parser.add_subparsers(dest="cmd", required=True)

	for name, help_text in (
		("validate", "Parse and validate promo-facts-1"),
		("canonicalize", "Parse and print canonical JSON"),
		("summarize", "Print a one-line-per-campaign summary"),
		("load-suite", "Load suite facts/ dir into a 1.1 document"),
	):
		p = sub.add_parser(name, help=help_text)
		p.add_argument("path", help="facts.json / combined.json / suite facts directory")

	args = parser.parse_args(argv)
	try:
		if args.cmd == "validate":
			return _cmd_validate(args.path)
		if args.cmd == "canonicalize":
			return _cmd_canonicalize(args.path)
		if args.cmd == "summarize":
			return _cmd_summarize(args.path)
		if args.cmd == "load-suite":
			return _cmd_load_suite(args.path)
		parser.error(f"unknown command {args.cmd}")
		return 2
	except PromoFactsError as e:
		print(f"ERROR {e}", file=sys.stderr)
		return 1
	except json.JSONDecodeError as e:
		print(f"ERROR JSON: {e}", file=sys.stderr)
		return 1
	except OSError as e:
		print(f"ERROR IO: {e}", file=sys.stderr)
		return 1


if __name__ == "__main__":
	sys.exit(main())
