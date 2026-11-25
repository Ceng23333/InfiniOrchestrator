"""SSH host execution, lock, and editable-scope staging."""

from __future__ import annotations

import shlex
import subprocess
from pathlib import Path


class HostError(RuntimeError):
    pass


class Host:
    def __init__(self, key: str, spec: dict, dry_run: bool = False):
        self.key = key
        self.dry_run = dry_run
        self.ssh = spec.get("ssh")
        if not self.ssh and spec.get("hostname"):
            self.ssh = (spec.get("user") + "@" if spec.get("user") else "") + spec["hostname"]
        if not self.ssh:
            raise HostError(f"hosts.{key}: 'ssh' alias or hostname required")
        self.workspace = str(spec["workspace"]).rstrip("/")
        self.suite_dir = str(spec.get("suite_dir", "")).strip("/")
        staging_rel = str(spec.get("staging", ".promo-loop/staging")).strip("/")
        self.staging = f"{self.workspace}/{staging_rel}"
        self.lock_dir = f"{self.workspace}/.promo-loop/lock"
        self.env = {k: str(v) for k, v in (spec.get("env") or {}).items()}

    def _argv(self) -> list[str]:
        return [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30", self.ssh,
        ]

    def run(self, command: str, timeout: int = 600, label: str = "") -> tuple[int, str]:
        exports = f"export PROMO_STAGING={shlex.quote(self.staging)};"
        exports += " ".join(f"export {k}={shlex.quote(v)};" for k, v in self.env.items())
        remote = f"cd {shlex.quote(self.workspace)} && mkdir -p .promo-loop && {exports} {command}"
        if self.dry_run:
            print(f"[dry-run ssh {label}] {remote}")
            return 0, ""
        proc = subprocess.run(
            self._argv() + [remote], capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, out[-20000:]

    def check(self) -> None:
        rc, out = self.run("test -d .git && test -d . && echo ok", timeout=30, label="host-check")
        if rc != 0:
            raise HostError(f"host {self.key} not ready: {out[-300:]}")

    def lock(self) -> None:
        rc, out = self.run(
            f"mkdir {shlex.quote(self.lock_dir)} 2>/dev/null || {{ echo locked; exit 9; }}",
            timeout=60, label="lock",
        )
        if rc != 0:
            raise HostError(f"host {self.key} locked by another campaign: {out.strip()[-120:]}")

    def unlock(self) -> None:
        if self.dry_run:
            return
        try:
            subprocess.run(
                self._argv() + [f"rm -rf {shlex.quote(self.lock_dir)}"],
                capture_output=True, timeout=60,
            )
        except subprocess.TimeoutExpired:
            pass

    def stage_scope(self, worktree: Path, paths: list[str]) -> None:
        rc, out = self.run(
            f"rm -rf {shlex.quote(self.staging)} && mkdir -p {shlex.quote(self.staging)}",
            timeout=120, label="stage-wipe",
        )
        if rc != 0:
            raise HostError(f"staging wipe failed: {out[-300:]}")
        for rel in paths:
            rel_posix = rel.replace("\\", "/").rstrip("/")
            src = worktree / rel
            if not src.exists():
                print(f"[stage] skip missing {rel}")
                continue
            dest = f"{self.staging}/{rel_posix}"
            if self.dry_run:
                print(f"[dry-run stage] tar -C {src} -cf - . | ssh {self.key} 'tar -C {dest} -xf -'")
                continue
            mkdir = f"mkdir -p {shlex.quote(dest)} && tar -C {shlex.quote(dest)} -xf -"
            tar = subprocess.Popen(["tar", "-C", str(src), "-cf", "-", "."], stdout=subprocess.PIPE)
            ssh = subprocess.Popen(self._argv() + [mkdir], stdin=tar.stdout, stderr=subprocess.PIPE)
            try:
                tar.stdout.close()  # type: ignore[union-attr]
                ssh_err = ssh.communicate(timeout=300)[1]
                tar.wait(timeout=300)
            finally:
                if tar.poll() is None:
                    tar.kill()
            if ssh.returncode != 0 or tar.returncode != 0:
                err = (ssh_err or b"").decode("utf-8", "replace")[-300:]
                raise HostError(f"staging {rel} failed (tar={tar.returncode} ssh={ssh.returncode}): {err}")
