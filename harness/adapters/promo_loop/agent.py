"""Agent backends. Minimal: Codex CLI backend."""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path


class AgentError(RuntimeError):
    pass


def terminate_tree(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, timeout=20)
        else:
            import signal
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _event_text(line: str) -> str | None:
    try:
        d = json.loads(line)
    except Exception:
        return None
    t = d.get("type")
    if t == "item.completed":
        it = d.get("item") or {}
        kind = it.get("type")
        if kind == "agent_message":
            return "agent: " + str(it.get("text", ""))[:200]
        if kind == "command_execution":
            return "run: " + str(it.get("command", ""))[:160]
        if kind == "error":
            return "warn: " + str(it.get("message", ""))[:200]
    if t == "turn.completed":
        return "turn completed"
    return None


class CodexAgent:
    def __init__(self, cfg: dict):
        if cfg.get("type") not in (None, "codex"):
            raise AgentError(f"agent.type '{cfg.get('type')}' not supported in the minimal slice (codex only)")
        self.cfg = cfg
        self.command_path = cfg.get("command") or os.environ.get("PROMO_CODEX_CMD") or "codex"

    def build_command(self, prompt: str) -> list[str]:
        cmd = [self.command_path, "exec", "--json", "--dangerously-bypass-approvals-and-sandbox"]
        if self.cfg.get("model"):
            cmd += ["--model", str(self.cfg["model"])]
        if self.cfg.get("reasoning_effort"):
            cmd += ["-c", f'model_reasoning_effort="{self.cfg["reasoning_effort"]}"']
        cmd += [str(a) for a in self.cfg.get("extra_args", [])]
        cmd.append(prompt)
        return cmd

    def run(self, cwd: Path, prompt: str, log_path: Path, timeout: int, on_event=None) -> tuple[int, bool, float]:
        argv = self.build_command(prompt)
        started = time.time()
        timed_out = False
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "w", encoding="utf-8") as lf:
            proc = subprocess.Popen(
                argv, cwd=str(cwd), stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
            )
            try:
                assert proc.stdout is not None
                for line in proc.stdout:
                    line = line.rstrip()
                    if not line:
                        continue
                    lf.write(line + "\n")
                    lf.flush()
                    if on_event:
                        msg = _event_text(line)
                        if msg:
                            on_event(msg)
                rc = proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                timed_out = True
                terminate_tree(proc)
                try:
                    rc = proc.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    rc = -9
        return rc, timed_out, time.time() - started
