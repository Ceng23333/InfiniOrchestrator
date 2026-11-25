"""CLI: python promo_loop run -c <campaign.yaml> [-n N] [--dry-run]"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from . import campaign as campaign_mod
    from . import controller as controller_mod
    from . import dashboard as dash_mod
except ImportError:
    import campaign as campaign_mod
    import controller as controller_mod
    import dashboard as dash_mod


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="promo_loop", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_run = sub.add_parser("run", help="run the campaign loop (baseline + iterations)")
    p_run.add_argument("-c", "--config", required=True)
    p_run.add_argument("-n", "--iterations", type=int, default=None)
    p_run.add_argument("--dry-run", action="store_true", help="print commands, do not execute")

    p_status = sub.add_parser("status", help="print history and best metrics")
    p_status.add_argument("-c", "--config", required=True)

    p_dash = sub.add_parser("dashboard", help="regenerate dashboard.html from history")
    p_dash.add_argument("-c", "--config", required=True)

    p_init = sub.add_parser("init", help="clone/refresh the per-host control clone")
    p_init.add_argument("--host", required=True)
    p_init.add_argument("--from", dest="src", required=True, help="canonical repo URL or path")
    p_init.add_argument("--into", required=True, help="local control clone dir")

    args = ap.parse_args(argv)

    if args.cmd == "init":
        into = Path(args.into).expanduser()
        if (into / ".git").is_dir():
            print(f"control clone already present: {into}")
            return 0
        import subprocess
        print(f"cloning {args.src} -> {into}")
        proc = subprocess.run(["git", "clone", args.src, str(into)])
        if proc.returncode != 0:
            return proc.returncode
        for key, value in (("core.autocrlf", "false"), ("user.name", "promo-loop"), ("user.email", "promo-loop@local")):
            subprocess.run(["git", "-C", str(into), "config", key, value], check=True)
        # Re-smudge the working tree with autocrlf off: the clone checkout above
        # may already have produced CRLF files when the global setting was on.
        subprocess.run(["git", "-C", str(into), "rm", "-r", "--cached", "--quiet", "."], check=True)
        subprocess.run(["git", "-C", str(into), "checkout", "-f", "HEAD"], check=True)
        print("clone ready")
        return 0

    camp = campaign_mod.load_campaign(args.config)
    if args.cmd == "status":
        ctrl = controller_mod.Controller(camp)
        history = ctrl.load_history()
        best = ctrl.best_metrics()
        for r in history:
            m = r.get("metrics") or {}
            kv = ", ".join(f"{k}={v:.4f}" for k, v in m.items())
            print(f"iter {r.get('iteration')}: {'accepted' if r.get('accepted') else 'rejected'} ({kv}) - {r.get('reason')}")
        print("best:", {k: v for k, v in best.items()})
        return 0
    if args.cmd == "dashboard":
        ctrl = controller_mod.Controller(camp)
        ctrl.refresh_dashboard()
        print(f"dashboard: {(ctrl.repo / '.autohelix' / 'output' / 'dashboard.html')}")
        return 0

    ctrl = controller_mod.Controller(camp, dry_run=args.dry_run, max_iterations=args.iterations)
    return ctrl.run()


if __name__ == "__main__":
    sys.exit(main())
