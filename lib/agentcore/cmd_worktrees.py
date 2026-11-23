import subprocess
from pathlib import Path

from agentcore import config, gitwt

HELP = "Worktree upkeep. 'prune' lists merged, clean worktrees; --yes removes them."


def register(parser) -> None:
    parser.add_argument("action", choices=["prune"])
    parser.add_argument("--yes", action="store_true", help="actually remove (default is a dry run)")
    parser.set_defaults(func=run)


def run(args) -> int:
    project = config.load_project(".")
    main = config.main_root(".")
    if project is None or main is None:
        print("not inside a git repository")
        return 1
    cfg = project.config
    integ, prod = cfg["branches"]["integration"], cfg["branches"]["production"]
    protected = {
        main.resolve(),
        Path(cfg["branches"]["integration_worktree"].format(root=str(main), integration=integ)).resolve(),
        Path(cfg["branches"]["production_worktree"].format(root=str(main), production=prod)).resolve(),
    }
    tip = gitwt.git(main, "rev-parse", integ).stdout.strip()
    victims = []
    for w in gitwt.worktrees(main):
        branch = w["branch"]
        if w["path"].resolve() in protected or not branch or branch in (integ, prod):
            continue
        merged = gitwt.git(main, "merge-base", "--is-ancestor", branch, integ).returncode == 0
        own = gitwt.git(main, "rev-parse", branch).stdout.strip() != tip
        if merged and own and not gitwt.dirty_files(w["path"]):
            victims.append(w)
    if not victims:
        print("nothing to prune")
        return 0
    for w in victims:
        print(f"{'remove' if args.yes else 'would remove'}: {w['branch']}  {w['path']}")
        if not args.yes:
            continue
        done = gitwt.git(main, "worktree", "remove", "--force", str(w["path"]))
        if done.returncode != 0:
            print(f"  failed: {done.stderr.strip()}")
            continue
        gitwt.git(main, "branch", "-D", w["branch"])
        drop = cfg["env"]["db_drop"]
        if drop:
            name = cfg["env"]["db_prefix"] + gitwt.sanitize(w["path"].name)
            subprocess.run(drop.replace("{name}", name), shell=True, cwd=str(main))
    if not args.yes:
        print("dry run; pass --yes to remove")
    return 0
