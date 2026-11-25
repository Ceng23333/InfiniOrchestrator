# Promotion loop: local controller + SSH measure plane

Status: plan (not implemented). Target repo: InfiniOrchestrator.
Reference campaign: metax-49 `suite-c550-i128` (ITW
`InfiniTensorWorktree-2026.11.24-infinilm-showroom-eager-catchup`, protocol
`autohelix/promo-c550-metax49.yaml`, commits `1f90d7e..c9c511e`).

## 1. Goals

1. The promotion-loop controller (agent + git worktrees + dashboard) runs on the
   operator PC; the GPU host is reached only over SSH. Agent API availability
   becomes uniform: whatever agent CLI works on the PC is used unchanged, no
   per-host proxy workarounds.
2. The SSH host is a first-class, validated part of the campaign config
   (alias, workspace, suite dir, staging dir, env), aligned with the existing
   `harness/adapters/promo_facts/hosts_promo.yaml` inventory format.
3. `dashboard.html` is regenerated after every iteration **on the PC** and
   published to a local review location immediately (file copy and/or a tiny
   HTTP server).
4. (Optional, deferred — decision D1) Cursor becomes an additional agent
   backend behind the same backend interface, owned by InfiniOrchestrator as
   a custom loop entry instead of patching the pip-installed AutoHelix
   package.

Non-goals: changing the Observe->Parse measure contract (`promo-facts-1`,
`run-promotion-loop-step`), changing gate semantics (best-so-far + surpass),
parallel peer campaigns (decision D3), Cursor integration (deferred, decision
D1), pushing accepted commits to a shared remote (decision D2: a local commit
is enough), or replacing AutoHelix for purely local campaigns (it stays
usable as-is).

## 2. Evidence from the metax-49 campaign (why)

- Agent API from lab hosts is unreliable: `codex exec` failed on every prompt
  with `Connection failed: error sending request` while plain HTTP/1.1 requests
  to the same gateway succeeded. The working mitigation (commit `c9c511e`)
  routes the agent through a local HTTP/1.1 proxy, which only exists because
  the controller was on the host. Running the controller on the PC removes the
  problem class instead of patching it.
- Iteration results were correct only because the metrics script
  (`deployment/infinilm-prod/observe_metrics_metax49.py`) was invoked by
  absolute path from the main checkout, outside the agent's editable scope.
  The measure/lever ownership split must be explicit in the new design.
- `dashboard.html` was written per iteration to
  `<host>:<workspace>/.autohelix/output/dashboard.html`, invisible to the
  operator unless they shell in.
- Editing the pip-installed `autohelix` package (0.1.1,
  `~/.local/lib/python3.12/site-packages/autohelix`, ~6.3k lines) is not a
  maintainable extension path; goal 4 explicitly wants an InfiniOrchestrator
  entry.

## 3. AutoHelix 0.1.1 mechanics we keep (facts)

Verified by reading the installed package:

- Iteration flow (`harness.py: run_iteration`): create git worktree ->
  seed notes/observations -> build prompt -> run agent (cwd = worktree) ->
  constraints (`shell=True`, timeouts kill the process group) -> observables
  (`checks.run_observable`, `build_worktree_env` remaps project PYTHONPATH to
  the worktree) -> metric gates vs best-so-far -> `merge_worktree` (stages only
  `editable` paths, commits, ff-merges into the main branch) or
  `discard_worktree`. Resume = `history.jsonl` + `get_last_iteration()`.
- Dashboard: regenerated after the baseline and after **every** iteration
  (`harness.py:988` and `:1039`) into `.autohelix/output/dashboard.html`.
- Agent interface: `agents/runner.py::run_process(cmd, cwd, log_path,
  line_callback, heartbeat_seconds, timeout_seconds, env)`; backends
  `codex` / `claudecode` / `opencode` / `mock`; the codex backend builds
  `codex exec --json --dangerously-bypass-approvals-and-sandbox` plus
  `-c` overrides from `AgentConfig`.
- Config schema (`config.py`): `goal`, `constraints[{command,timeout}]`,
  `observables[{command,values,capture,capture_stdout,timeout}]`,
  `acceptance.metric_gates[{metric,max_regression_pct}]`, `agent{...}`,
  `reviewer`, `editable[]`, `frozen[]`, budget fields. **No host concept**;
  everything executes locally.

Implication: goals 1-3 are a port of this state machine to InfiniOrchestrator
with an execution-context abstraction; goal 4 slots into the same backend
interface.

## 4. Target architecture

Two planes, one controller:

- **Control plane (PC)**: loop controller, local git repo + worktrees, agent
  subprocess (codex today, cursor later), metric parsing, gates, history,
  dashboard + publish.
- **Measure plane (GPU host, via SSH)**: restart/bring-up of the candidate,
  wall measure (evalscope/AIPerf), profiler attach, suite compare.json and
  promo-facts-1 emission. Reuses the existing IO bins unchanged:
  `harness/bin/run-promotion-loop-step`, `scripts/promo/*`, and campaign
  scripts such as `deployment/infinilm-prod/metax49_restart.sh`.

New InfiniOrchestrator component (no AutoHelix changes):

```text
harness/adapters/promo_loop/
  config.py        # campaign yaml loader: AutoHelix-compatible + run/hosts/dashboard extensions
  hosts.py         # host spec resolution, ssh exec, file push/pull, dry-run rendering
  sync.py          # editable-scope staging to the host (scp/tar; rsync when available)
  agents/          # backend interface + codex backend + mock; cursor deferred
  controller.py    # iteration state machine, gates, history, resume
  dashboard.py     # regenerate + publish (+ optional --serve)
harness/bin/run-promotion-loop   # shim: exec python3 -m adapters.promo_loop
```

Ownership rule preserved from the metax-49 campaign: measure scripts are
invoked by absolute path from the host workspace checkout (operator-owned,
agent-unreachable); lever files travel through the staged editable scope only.

### 4.1 Repo topology: one control clone per host

- The PC holds **one control clone per GPU host**, e.g.
  `D:/ws/promo/metax-49/`, `D:/ws/promo/c610/`. Each clone is fully
  independent: own git dir, own `.autohelix/` state, own worktrees, own
  dashboard and publish dir. This is what makes parallel promotion across
  identical hosts practical: campaigns running on the PC at the same time
  never share git refs, index locks, history files, or dashboards. Within
  one clone the loop is serial; the host-side lockfile remains the guard
  that allows exactly one campaign per GPU host.
- A one-time setup subcommand creates the per-host clone
  (`run-promotion-loop init --host metax-49 --from <canonical repo or bare
  seed>`); re-init is a no-op when the clone already exists.
- The GPU host keeps its existing operator checkout untouched.
- Worktrees are created locally: `.autohelix/worktrees/iter-N` (branch
  `autohelix-iter-N`), exactly like AutoHelix.
- Per iteration, after the agent finishes, the controller syncs the
  **editable scope** (and only that) to a dedicated host staging dir
  `$HOST:workspace/.promo-loop/staging/` with `--delete` semantics on that
  dir (it is loop-owned, so deletion is safe and keeps state deterministic).
  Transport: `scp -r` / `tar | ssh tar` (always available on Windows);
  `rsync -a --delete` when present.
- Host-side commands receive `PROMO_STAGING=<abs staging path>` plus the
  campaign env. Campaign scripts gain tiny env overrides instead of new
  scripts, e.g. `metax49_restart.sh` reads
  `OVERLAY_DIR="${OVERLAY_DIR:-$HERE/serve_overlay/infinilm}"` and
  `ENV_FILE="${ENV_FILE:-$HERE/metax49_env.sh}"` so the staged copy is used
  when `$PROMO_STAGING` is set.
- Accept: commit in the worktree (editable paths only) and ff-merge into the
  control clone's branch; the commit stays local on the PC (decision D2, no
  push). Same merge semantics as `merge_worktree`. Reject: discard worktree +
  branch. The host never receives git state; the staged copy is refreshed
  fully on the next iteration, so rejected changes disappear from the host
  automatically.

### 4.2 Platform split (Windows / Unix)

The controller core is platform-neutral Python; everything that spawns a
shell exists in two variants, selected by `sys.platform` with a
`--shell powershell|bash` override:

| Concern | Windows (primary PC) | Unix (PC) |
|---------|----------------------|-----------|
| Loop entrypoint | `harness/bin/run-promotion-loop.ps1` (PowerShell) | `harness/bin/run-promotion-loop.sh` |
| Dashboard serve | `run-promotion-loop-dashboard.ps1` | `run-promotion-loop-dashboard.sh` |
| Local constraints | native process or `powershell -NoProfile -File` | `bash -lc` |
| Sync transport | `scp.exe` / `tar | ssh.exe` (bsdtar ships with Windows) | `rsync -a --delete` when present, else scp/tar |
| ssh binary | Windows OpenSSH `ssh.exe` or Git ssh | `/usr/bin/ssh` |
| Path rules | local Windows paths, all remote paths POSIX | POSIX everywhere |

Host-side campaign scripts (restart, env, observe, measure bins) stay
bash-only: GPU hosts are Linux and the existing metax-49 campaign scripts are
already bash. The Windows loop path never depends on a POSIX emulator (no
MSYS/Cygwin requirement); Unix PCs get native variants of the same
entrypoints so the controller is operable from either.

### 4.3 Command routing (`where`)

Every constraint/observable gets an execution context. Default comes from
`defaults.where`; per-entry override:

```yaml
constraints:
  - command: python3 -m py_compile deployment/infinilm-prod/metax49_restart.sh
    where: local            # runs in the local worktree
  - command: bash "$PROMO_STAGING/metax49_restart.sh"
    timeout: 900            # host (default where)
observables:
  - command: >-
      env SUITE_DIR=... python3
      /abs/path/deployment/infinilm-prod/observe_metrics_metax49.py
    timeout: 900
    values: {primary_wall_ratio: higher, ttft_p95_ratio: lower, success_rate: higher}
    capture: [walls/unprofiled_compare.json]
```

Semantics kept identical to AutoHelix: stdout+stderr are scanned for
`##autohelix[name=value]`; `capture` files are pulled back into
`.autohelix/observations/iter-N/` (via scp); timeout kills the process group
(local) or the remote command's process group via `ssh -t` + `pkill -g`
fallback (documented limitation: best-effort on the host).

## 5. SSH host spec (goal 2)

New file `harness/adapters/promo_loop/hosts.yaml` (repo-level inventory), with
the campaign yaml able to reference or extend it. Format deliberately extends
the existing `hosts_promo.yaml` fields (`ssh` alias, `remote_roots`):

```yaml
defaults:
  connect_timeout: 10
  keepalive: 30
hosts:
  metax-49:
    ssh: metax-49                 # ~/.ssh/config alias (HostName/User/Port/IdentityFile/ProxyJump win)
    # explicit alternative:
    # user: zenghua
    # hostname: 172.22.162.49
    # port: 22
    # key: ~/.ssh/id_ed25519_cursor
    # jump: pc34                  # rendered as -J
    workspace: /home/zenghua/workspace/InfiniTensorWorktree-2026.11.24-infinilm-showroom-eager-catchup
    suite_dir: artifacts/promo/suite-c550-i128   # relative to workspace
    staging: .promo-loop/staging  # loop-owned, wiped per sync
    env: {DEVICE_TRACK: metax, HOST_ID: metax-49}
    shell: bash -lc
    max_concurrent_campaigns: 1
```

Validation at startup (fail fast): `ssh -o BatchMode=yes alias true`,
`test -d workspace`, `test -f workspace/<suite_dir>/compare.json` (or create),
lockfile check `mkdir workspace/.promo-loop/lock` (one campaign per host).
`--dry-run` prints the exact local and remote command lines without executing.

## 6. Dashboard (goal 3)

- Controller regenerates `dashboard.html` after baseline and every iteration
  (same as AutoHelix), on the PC.
- `dashboard:` config block:
  - `publish_dir: <path>`: copy `dashboard.html` + `history.jsonl` +
    `events.jsonl` there after each iteration (atomic write + rename).
  - `serve_port: <port>`: `--serve` runs `python -m http.server` on the
    publish dir and prints `http://127.0.0.1:<port>/dashboard.html`.
- `events.jsonl` (new, append-only): one line per phase transition
  (`iter_start`, `agent_done`, `constraint`, `metrics`, `gate`, `iter_end`)
  so the InfiniOrchestrator panel can subscribe later without parsing HTML.

## 7. Agent backends (goal 4)

Backend interface (mirrors AutoHelix's runner contract, owned by IO):

```python
class AgentBackend(Protocol):
    def build_command(self, prompt: str) -> list[str]: ...
    def handle_line(self, line: str) -> AgentEvent | None: ...   # JSON event parse
    def validate(self) -> str | None: ...                        # version/flags precheck
```

- `codex`: port of AutoHelix's codex backend (`exec --json`,
  `--dangerously-bypass-approvals-and-sandbox`, model/reasoning/settings/
  extra_args), notes + `commit_summary.txt` contract, timeout.
- `mock`: scripted lever + notes for controller tests.
- `cursor`: **deferred** (decision D1, priority lowered). The backend seam
  above stays so it can be added without touching the controller. Notes-file
  and wall-clock enforcement would live outside the backend either way
  (prompt contract + subprocess timeout). Revisit only after a full codex
  campaign completes on this controller.
- Model/API availability becomes a PC-side concern: no per-host proxies, no
  `CODEX_HOME` tricks on GPU hosts. The metax-49 proxy stays as a documented
  fallback for running AutoHelix on-host, not a dependency of this design.

## 8. Campaign yaml (full example, metax-49)

```yaml
# autohelix-compatible protocol + promo_loop extensions
goal: |
  Close the InfiniLM vs frozen vLLM wall gap on metax-49 ... (unchanged)
run:
  repo: D:/ws/promo/metax-49                      # per-host control clone (4.1)
  hosts: metax-49
  protocol: autohelix/promo-c550-metax49.yaml     # self when inline
hosts: metax-49            # key into hosts.yaml, or inline map
defaults:
  where: host              # constraints/observables default to the host plane
editable: [deployment/infinilm-prod/, InfiniLM/]
constraints: [...]
observables: [...]
acceptance: {metric_gates: [{metric: primary_wall_ratio, max_regression_pct: 2}]}
stop: {surpass_metric: primary_wall_ratio, surpass_threshold: 1.0}
dashboard: {publish_dir: D:/promodash/c550/metax-49, serve_port: 8619}
agent: {type: codex, model: glm-5.3, timeout_seconds: 2700}
budget: {iterations: 5}
```

Loader rules: unknown keys rejected (like AutoHelix), AutoHelix-only files
load fine with `run`/`hosts`/`dashboard` absent (all-local behavior).

## 9. Files to add/change

InfiniOrchestrator (new):
`harness/adapters/promo_loop/{__init__,config,hosts,sync,agents/*,controller,dashboard}.py`,
`harness/adapters/promo_loop/hosts.yaml`,
`harness/bin/run-promotion-loop.ps1` + `.sh` (subcommands: init, run, status,
dashboard serve),
`docs/design/promotion-loop-local-controller.md` (this file),
tests under `harness/tests/promo_loop/`.

Reference campaign (ITW metax-49, tiny):
`deployment/infinilm-prod/metax49_restart.sh`: add `OVERLAY_DIR`/`ENV_FILE`
env overrides; `deployment/infinilm-prod/metax49_env.sh`: no change.

## 10. Phases

- **Phase 0.5 - minimal slice (delivered 2026-11-25)**: the metax-49
  graph-mode case is running on this slice, ahead of the full MVP. Delivered:
  `harness/adapters/promo_loop/` (single-codex-backend controller: per-host
  control clone, local worktrees, editable-scope staging over tar|ssh,
  staged restart via `$PROMO_STAGING`, `##autohelix` parsing, best-so-far
  gates, surpass stop, `history.jsonl` resume, per-iteration dashboard +
  publish), Windows/Unix entry shims, and the campaign yaml
  `autohelix/promo-c550-metax49.pc.yaml` living in the metax-49 control clone
  (`D:/ws/promo/metax-49`, branch `promo/metax-49`, PC side). Not yet in this
  slice: capture-file pull-back, reviewer, mock backend for unit tests,
  host-side stale-worktree watcher, `--serve` dashboard.
- **Phase 0 - spike (0.5d)**: `hosts.py` exec/sync primitives + dry-run
  rendering; manually run one remote measure from the PC against metax-49
  using the existing suite. Exit criteria: metric JSON round-trips, staging
  sync verified, host lockfile works.
- **Phase 1 - controller MVP (2-3d)**: full state machine with `codex` and
  `mock` backends, gates, history resume, dashboard + publish_dir. Tests:
  mock-agent end-to-end (scripted lever, fake local host), gate math, resume
  after kill. Exit criteria: one real metax-49 iteration (no-op lever,
  measure-only) accepted as baseline-equivalent.
- **Phase 2 - hardening (1d)**: host lockfile + stale-staging cleanup,
  `--serve` dashboard, `events.jsonl`, failure taxonomy (agent timeout vs
  constraint fail vs metric gate vs ssh error), docs.
- **Phase 3 (optional, deferred)**: multi-campaign convenience — a per-host
  launcher table and an aggregate dashboard across clones. Cursor backend is
  deferred by decision D1; parallel peers and shared-remote push are out of
  scope by decisions D3 and D2.

## 11. Risks and mitigations

- Long host commands (candidate restart ~2-5 min, measure ~1 min) over SSH:
  per-command timeouts, `ServerAliveInterval`, logs streamed to the suite dir;
  a dropped SSH connection marks the iteration failed, not accepted (resume is
  always safe: baseline re-measure is cheap and deterministic).
- PC sleep/lid close stalls the loop: controller resume is the mitigation;
  document "run on a machine that stays awake" in the README.
- Parallel campaigns on one PC: isolated by per-host control clones (4.1).
  Two campaigns for the same host key are rejected at startup via the clone
  lock; one campaign per GPU host is enforced by the host-side `mkdir`
  lockfile + startup check.
- Secrets: `auth.json`/keys stay on the PC; host commands receive explicit
  env; the proxy never logs Authorization (already the case).
- Windows quirks: `core.autocrlf=false` in the control clone; scp/tar as the
  default transport; all remote paths POSIX.
- Scope drift between local worktree and host staging: staging is wiped and
  re-synced per iteration from the scoped diff, so the host never accumulates
  state; a post-sync checksum diff is logged.

## 12. Decisions (2026-11-25)

- **D1 Cursor integration: priority lowered, deferred.** The backend seam
  (section 7) is kept; when picked up, the Cursor CLI JSON surface on the PC
  must be verified first (binary name, event schema, notes enforcement).
- **D2 Acceptance = local commit** on the per-host control clone; no push to
  a shared remote. Team visibility comes from warehouse facts emission
  (`promo_facts`) and the published dashboard.
- **D3 Parallel peers (AutoHelix `parallel/core.py` parity): out of scope.**
  Parallelism is achieved by running one campaign per host control clone.
- **D4 Reviewer: keep the current design** (AutoHelix-style optional
  `reviewer:` block). Panel-driven review decisions may become an option in
  the future.
