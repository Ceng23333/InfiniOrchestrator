"""Iteration state machine: baseline, agent, apply, constraints, observables, gates."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

try:
    from . import agent as agent_mod
    from . import dashboard as dash_mod
    from . import hostexec as host_mod
except ImportError:  # running as a flat directory (python promo_loop)
    import agent as agent_mod
    import dashboard as dash_mod
    import hostexec as host_mod

METRIC_RE = re.compile(r"##autohelix\[([A-Za-z_][A-Za-z0-9_]*)=([-+0-9.eE]+)\]")


class Controller:
    def __init__(self, camp: dict, dry_run: bool = False, max_iterations: int | None = None):
        self.c = camp
        self.dry_run = dry_run
        self.repo: Path = camp["run"]["repo"]
        self.host_key = camp["run"]["host"]
        self.host = host_mod.Host(self.host_key, camp["hosts"][self.host_key], dry_run=dry_run)
        self.auto = self.repo / ".autohelix"
        self.max_iter = max_iterations or camp["budget"]["iterations"]
        self.agent_backend = agent_mod.CodexAgent(camp["agent"])
        self.directions = {m: d for o in camp["observables"] for m, d in o["values"].items()}

    def log(self, msg: str) -> None:
        print(f"[promo-loop {time.strftime('%H:%M:%S')}] {msg}", flush=True)

    def _git(self, *args: str, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
        proc = subprocess.run(
            ["git"] + list(args), cwd=str(cwd or self.repo),
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if check and proc.returncode != 0:
            raise RuntimeError(f"git {' '.join(args[:4])} failed: {(proc.stderr or proc.stdout)[-400:]}")
        return proc

    def ensure_ready(self) -> None:
        if not (self.repo / ".git").is_dir():
            raise RuntimeError(f"control clone missing .git: {self.repo} (run 'init' first)")
        self._git("config", "core.autocrlf", "false")
        if not self._git("config", "user.name", check=False).stdout.strip():
            self._git("config", "user.name", "promo-loop")
            self._git("config", "user.email", "promo-loop@local")
        exclude = self.repo / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        text = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
        if ".autohelix/" not in text:
            exclude.write_text(text.rstrip("\n") + "\n.autohelix/\n", encoding="utf-8")
        proc = self._git("status", "--porcelain")
        dirty = [l for l in proc.stdout.splitlines() if l.strip() and not l.startswith("??")]
        if dirty:
            raise RuntimeError("control clone has uncommitted tracked changes:\n" + "\n".join(dirty[:8]))
        if self.c["editable"]:
            proc = self._git("ls-files", "--eol", "--", *self.c["editable"], check=False)
            crlf = [l for l in (proc.stdout or "").splitlines() if "\tw/crlf" in l or " w/crlf" in l]
            if crlf:
                raise RuntimeError(
                    "editable scope has CRLF files in the worktree (Windows autocrlf "
                    "converted them at clone time). Fix once with: git config core.autocrlf false "
                    "&& git rm -r --cached -q . && git checkout -f HEAD. "
                    f"first offenders: {crlf[:3]}"
                )
        self.host.check()
        lock = self.auto / "run.lock"
        if lock.exists():
            raise RuntimeError(f"local run lock present: {lock} (stale? remove it)")
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.mkdir()
        self.host.lock()

    def release(self) -> None:
        lock = self.auto / "run.lock"
        if lock.exists():
            try:
                lock.rmdir()
            except OSError:
                pass
        self.host.unlock()

    def load_history(self) -> list[dict]:
        p = self.auto / "history.jsonl"
        if not p.is_file():
            return []
        out = []
        for line in p.read_text(encoding="utf-8").splitlines():
            if line.strip():
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        return out

    def append_history(self, entry: dict) -> None:
        if self.dry_run:
            print(f"[dry-run history] {json.dumps(entry)[:160]}")
            return
        p = self.auto / "history.jsonl"
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def best_metrics(self) -> dict[str, tuple[float, int]]:
        best: dict[str, tuple[float, int]] = {}
        for r in self.load_history():
            if not r.get("accepted"):
                continue
            for name, value in (r.get("metrics") or {}).items():
                lower = self.directions.get(name) == "lower"
                if name not in best or (lower and value < best[name][0]) or (not lower and value > best[name][0]):
                    best[name] = (float(value), int(r["iteration"]))
        return best

    def _save_output(self, tag: str, label: str, out: str) -> None:
        obs_dir = self.auto / "observations"
        obs_dir.mkdir(parents=True, exist_ok=True)
        safe = label.replace(":", "-").replace("/", "-")
        (obs_dir / f"{tag}-{safe}.log").write_text(out or "", encoding="utf-8")

    def run_commands(self, commands: list[dict], local_cwd: Path | None, tag: str) -> str | None:
        for c in commands:
            label = f"{tag}:{c['label']}"
            self.log(f"{label} where={c['where']} -> {c['command'][:90]}")
            if c["where"] == "local":
                if self.dry_run:
                    continue
                proc = subprocess.run(
                    c["command"], cwd=str(local_cwd or self.repo),
                    capture_output=True, text=True, encoding="utf-8", errors="replace",
                    timeout=c["timeout"], shell=(os.name != "nt"),
                )
                rc, out = proc.returncode, (proc.stdout or "") + (proc.stderr or "")
            else:
                rc, out = self.host.run(c["command"], timeout=c["timeout"], label=label)
            self._save_output(tag, c["label"], out)
            if rc != 0:
                return f"{c['label']} failed rc={rc}: {out[-300:]}"
        return None

    def run_observables(self, tag: str) -> dict[str, float]:
        metrics: dict[str, float] = {}
        if self.dry_run:
            print(f"[dry-run obs {tag}] skip")
            return {m: 0.0 for m in self.directions}
        for o in self.c["observables"]:
            label = f"obs:{o['label']}"
            self.log(f"{label} [{tag}] where={o['where']}")
            if o["where"] == "local":
                proc = subprocess.run(
                    o["command"], cwd=str(self.repo), capture_output=True, text=True,
                    encoding="utf-8", errors="replace", timeout=o["timeout"], shell=(os.name != "nt"),
                )
                rc, out = proc.returncode, (proc.stdout or "") + (proc.stderr or "")
            else:
                rc, out = self.host.run(o["command"], timeout=o["timeout"], label=label)
            obs_dir = self.auto / "observations" / f"iter-{tag}"
            obs_dir.mkdir(parents=True, exist_ok=True)
            (obs_dir / "stdout.txt").write_text(out or "", encoding="utf-8")
            if rc != 0:
                raise RuntimeError(f"{label} failed rc={rc}: {out[-300:]}")
            for m in METRIC_RE.finditer(out or ""):
                metrics[m.group(1)] = float(m.group(2))
        missing = set(self.directions) - set(metrics)
        if missing:
            raise RuntimeError(f"observables produced no values for: {sorted(missing)} (no defaulting)")
        return metrics

    def make_worktree(self, i: int) -> Path:
        wt = self.auto / "worktrees" / f"iter-{i}"
        if wt.exists():
            shutil.rmtree(wt, ignore_errors=True)
        self._git("worktree", "prune")
        self._git("worktree", "add", "--force", "-b", f"autohelix-iter-{i}", str(wt), "HEAD")
        return wt

    def discard_worktree(self, wt: Path, i: int) -> None:
        if self.dry_run:
            return
        self._git("worktree", "remove", "--force", str(wt), check=False)
        self._git("worktree", "prune")
        self._git("branch", "-D", f"autohelix-iter-{i}", check=False)

    def merge_worktree(self, wt: Path, i: int, summary: str) -> str:
        for rel in self.c["editable"]:
            if (wt / rel).exists():
                self._git("add", "--", rel, cwd=wt)
        if not self._git("status", "--porcelain", cwd=wt).stdout.strip():
            return ""
        self._git("commit", "-m", f"promo-loop iter {i}: {summary[:150]}", cwd=wt)
        self._git("merge", f"autohelix-iter-{i}", "--no-edit", "--ff-only")
        self._git("branch", "-D", f"autohelix-iter-{i}")
        return self._git("rev-parse", "--short", "HEAD").stdout.strip()

    def save_notes(self, wt: Path) -> None:
        src = wt / ".autohelix" / "notes"
        if not src.is_dir():
            return
        dst = self.auto / "notes"
        dst.mkdir(parents=True, exist_ok=True)
        for f in src.rglob("*"):
            if f.is_file():
                target = dst / f.relative_to(src)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, target)

    def seed_worktree(self, wt: Path) -> None:
        for d in ("notes", "observations"):
            src = self.auto / d
            dst = wt / ".autohelix" / d
            dst.mkdir(parents=True, exist_ok=True)
            if src.is_dir():
                for f in src.rglob("*"):
                    if f.is_file():
                        target = dst / f.relative_to(src)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(f, target)

    def stage_and_apply(self, wt: Path, tag: str) -> None:
        if self.c["editable"]:
            self.host.stage_scope(wt, self.c["editable"])
        fail = self.run_commands(self.c["apply"], wt, f"{tag}:apply")
        if fail:
            raise RuntimeError(fail)

    def prompt(self, i: int, wt: Path) -> str:
        c = self.c
        lines = [
            f"Goal: {c['goal']}",
            "",
            f"Your working directory is {wt}. Do not modify files outside it.",
            f"This is iteration {i}. Iteration 0 is the baseline.",
        ]
        hist = self.load_history()[-6:]
        if hist:
            lines += ["", "Recent history (gate rejects are already reverted):"]
            for r in hist:
                m = r.get("metrics") or {}
                kv = ", ".join(f"{k}={v:.4f}" for k, v in list(m.items())[:2])
                lines.append(f"- iter {r.get('iteration')}: {'accepted' if r.get('accepted') else 'rejected'} ({kv})")
        lines += [
            "",
            "How this loop runs: after you finish, the controller syncs the editable",
            "scope to the GPU host, restarts the candidate with your changes, and",
            "re-measures with evalscope. You cannot run host commands yourself and",
            "you must not edit measure scripts. Apply exactly one lever per iteration.",
            "",
            "Constraints the controller enforces after your change (failure = revert):",
        ] + [f"  {x['command']}" for x in c["constraints"]] + [
            "",
            "Metrics re-measured after you finish: "
            + ", ".join(f"{m} ({d})" for m, d in self.directions.items()),
            "",
            "Editable (only changes under these paths are kept): " + ", ".join(c["editable"]),
            "",
            "Read before starting:",
            "- .autohelix/notes/iter-*.md (notes from past iterations)",
            "- .autohelix/observations/ (captured metric outputs)",
            "- deployment/infinilm-prod/METAX49_PROMO.md (knob menu, restart contract)",
            "",
            f"When done you MUST write notes to {wt}/.autohelix/notes/iter-{i}.md:",
            "what you tried, the result, and what to try next.",
            "Do not create git commits; the controller commits accepted changes.",
            f"Write a one-line change summary to {wt}/.autohelix/commit_summary.txt",
            "Stop experimenting early enough to leave time for the notes.",
        ]
        return "\n".join(lines)

    def _emit_metrics_entry(self, metrics: dict[str, float], commit, reason: str, stop: bool = False) -> dict:
        entry = {
            "iteration": self._iter,
            "accepted": reason.startswith("accepted"),
            "metrics": metrics,
            "commit": commit or None,
            "reason": reason,
            "failure_output": None,
            "usage": {},
        }
        if stop:
            entry["stop"] = True
        self.append_history(entry)
        return entry

    _iter = 0

    def run_observable_reject(self, wt: Path, reason: str) -> dict:
        entry = {
            "iteration": self._iter, "accepted": False, "metrics": {}, "commit": None,
            "reason": reason, "failure_output": None, "usage": {},
        }
        self.append_history(entry)
        self.log(f"iter {self._iter}: REJECTED - {reason}")
        self.discard_worktree(wt, self._iter)
        return entry

    def iteration(self, i: int) -> dict:
        self._iter = i
        wt = self.make_worktree(i)
        self.seed_worktree(wt)
        try:
            t0 = time.time()
            prompt = self.prompt(i, wt)
            log_path = self.auto / "logs" / f"iter-{i}" / "agent.log"
            self.log(f"iter {i}: agent start (timeout {self.c['agent']['timeout_seconds']}s)")
            events: list[str] = []
            rc, timed_out, wall = self.agent_backend.run(
                wt, prompt, log_path, self.c["agent"]["timeout_seconds"],
                on_event=lambda m: (events.append(m), self.log(f"iter {i} {m}")) and None,
            )
            if timed_out:
                return self.run_observable_reject(wt, f"agent timeout after {self.c['agent']['timeout_seconds']}s")
            if rc != 0:
                return self.run_observable_reject(wt, f"agent exit rc={rc}")
            self.save_notes(wt)
            self.log(f"iter {i}: agent done in {wall:.0f}s; sync scope + apply on host")
            self.stage_and_apply(wt, f"iter-{i}")
            fail = self.run_commands(self.c["constraints"], wt, f"iter-{i}")
            if fail:
                return self.run_observable_reject(wt, f"constraint: {fail[:200]}")
            metrics = self.run_observables(str(i))
            reason = self.gate_reason(metrics)
            if reason:
                return self.run_observable_reject(wt, reason)
            stop = self.check_surpass(metrics)
            summary_file = wt / ".autohelix" / "commit_summary.txt"
            summary = summary_file.read_text(encoding="utf-8").strip() if summary_file.is_file() else "(no summary)"
            commit = self.merge_worktree(wt, i, summary)
            entry = self._emit_metrics_entry(metrics, commit, "accepted" + ("; surpass" if stop else ""), stop)
            self.log(f"iter {i}: ACCEPTED commit={commit or '(no diff)'} metrics={metrics}" + (" SURPASS" if stop else ""))
            self.save_notes(wt)
            if wt.exists():
                self._git("worktree", "remove", "--force", str(wt), check=False)
                self._git("worktree", "prune")
            return entry
        except Exception as exc:
            return self.run_observable_reject(wt, f"error: {type(exc).__name__}: {str(exc)[:220]}")

    def gate_reason(self, metrics: dict[str, float]) -> str | None:
        best = self.best_metrics()
        for gate in self.c["acceptance"]["metric_gates"]:
            name = gate["metric"]
            new = metrics.get(name)
            if new is None:
                return f"metric gate: {name} missing from benchmark output"
            if name not in best:
                continue
            best_val = best[name][0]
            if best_val == 0:
                continue
            lower = self.directions.get(name) == "lower"
            regression = ((new - best_val) / best_val) if lower else ((best_val - new) / best_val)
            if regression * 100 > gate["max_regression_pct"]:
                return (f"metric gate: {name} regressed {regression * 100:.1f}% "
                        f"(max allowed {gate['max_regression_pct']:.0f}%)")
        return None

    def check_surpass(self, metrics: dict[str, float]) -> bool:
        metric = self.c["stop"]["surpass_metric"]
        if not metric:
            return False
        value = metrics.get(metric)
        return bool(value is not None and value > self.c["stop"]["surpass_threshold"])

    def refresh_dashboard(self) -> None:
        if self.dry_run:
            return
        history = self.load_history()
        out_dir = self.auto / "output"
        out_dir.mkdir(parents=True, exist_ok=True)
        out = out_dir / "dashboard.html"
        out.write_text(dash_mod.render(str(self.c["path"]), self.host_key, history, self.directions), encoding="utf-8")
        try:
            dash_mod.publish(out, self.c["dashboard"]["publish_dir"], self.host_key)
        except OSError as exc:
            self.log(f"dashboard publish failed: {exc}")

    def run(self) -> int:
        self.ensure_ready()
        if self.dry_run:
            self.log("dry-run: rendering the command surface (no agent, no writes)")
            self.host.stage_scope(self.repo, self.c["editable"])
            self.run_commands(self.c["apply"], self.repo, "dry:apply")
            self.run_commands(self.c["constraints"], self.repo, "dry:constraints")
            self.run_observables("dry")
            self.release()
            self.log("dry-run complete")
            return 0
        stopped = "completed"
        try:
            history = self.load_history()
            start = (max((int(r["iteration"]) for r in history), default=-1)) + 1
            if start == 0:
                self.log("baseline: sync HEAD scope, restart candidate, measure")
                if not self.dry_run:
                    self.host.stage_scope(self.repo, self.c["editable"])
                    fail = self.run_commands(self.c["apply"], self.repo, "baseline:apply")
                    if fail:
                        raise RuntimeError(f"baseline apply failed: {fail}")
                metrics = self.run_observables("0")
                self._iter = 0
                self._emit_metrics_entry(metrics, None, "baseline")
                self.log(f"baseline metrics: {metrics}")
            else:
                self.log(f"resuming from iter {start}")
            self.refresh_dashboard()
            i = start
            while i < self.max_iter:
                if i == 0:
                    i += 1
                    continue
                entry = self.iteration(i)
                self.refresh_dashboard()
                if entry.get("stop"):
                    stopped = "surpass"
                    break
                i += 1
        finally:
            self.release()
        self.log(f"done ({stopped})")
        return 0
