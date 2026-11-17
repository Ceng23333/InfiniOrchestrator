"""Resolve the skill promo-facts parser module."""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from types import ModuleType


def io_root() -> Path:
	env = os.environ.get("IO_ROOT", "").strip()
	if env:
		return Path(env).expanduser().resolve()
	# harness/adapters/promo_facts/ → parents[3] = InfiniOrchestrator
	return Path(__file__).resolve().parents[3]


def parser_script() -> Path:
	return (
		io_root()
		/ ".cursor"
		/ "skills"
		/ "performance-promotion-loop"
		/ "scripts"
		/ "parse_promo_facts.py"
	)


def load_parser() -> ModuleType:
	path = parser_script()
	if not path.is_file():
		raise FileNotFoundError(f"promo-facts parser missing: {path}")
	spec = importlib.util.spec_from_file_location("parse_promo_facts", path)
	if spec is None or spec.loader is None:
		raise ImportError(f"cannot load parser from {path}")
	mod = importlib.util.module_from_spec(spec)
	sys.modules.setdefault("parse_promo_facts", mod)
	spec.loader.exec_module(mod)
	return mod
