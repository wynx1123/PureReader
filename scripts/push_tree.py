#!/usr/bin/env python3
"""Push entire workspace to GitHub via Git Data API (no git push)."""
import subprocess, json, base64, time, sys
from pathlib import Path

REPO = "wynx1123/PureReader"
ROOT = Path(__file__).resolve().parent.parent
BRANCHES = ["main", "develop"]
MSG = sys.argv[1] if len(sys.argv) > 1 else "feat: AI rewrite, vector index, book sources"


def gh_api(method, path, payload=None, retries=10):
    last = ""
    for i in range(retries):
        cmd = ["gh", "api", "-X", method, path]
        if payload is not None:
            cmd += ["--input", "-"]
            r = subprocess.run(
                cmd, input=json.dumps(payload), capture_output=True, text=True
            )
        else:
            r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode == 0:
            return json.loads(r.stdout) if r.stdout.strip() else {}
        last = (r.stderr or "") + (r.stdout or "")
        print(f"  retry {i+1}/{retries} {method} {path.split('/')[-1]}: {last[:100]}")
        time.sleep(min(30, 2 + i * 1.5))
    raise RuntimeError(last[:600])


def main():
    files = [
        (p.relative_to(ROOT).as_posix(), p)
        for p in ROOT.rglob("*")
        if p.is_file()
        and ".git" not in p.parts
        and not p.name.endswith(".gitkeep")
        and "scripts/push_tree.py" not in p.as_posix()  # optional keep
    ]
    # include push script too
    files = [
        (p.relative_to(ROOT).as_posix(), p)
        for p in ROOT.rglob("*")
        if p.is_file() and ".git" not in p.parts and not p.name.endswith(".gitkeep")
    ]
    print(f"files={len(files)}")

    parent = gh_api("GET", f"/repos/{REPO}/git/ref/heads/main")["object"]["sha"]
    print(f"parent={parent}")

    blobs = {}
    for i, (rel, p) in enumerate(files, 1):
        b64 = base64.b64encode(p.read_bytes()).decode()
        for attempt in range(5):
            try:
                blobs[rel] = gh_api(
                    "POST",
                    f"/repos/{REPO}/git/blobs",
                    {"content": b64, "encoding": "base64"},
                    retries=3,
                )["sha"]
                break
            except Exception as e:
                print(f"  blob fail {rel}: {e}")
                time.sleep(3 + attempt)
        else:
            raise RuntimeError(f"blob failed: {rel}")
        if i % 10 == 0 or i == len(files):
            print(f"[{i}/{len(files)}] {rel[:50]}")

    tree = gh_api(
        "POST",
        f"/repos/{REPO}/git/trees",
        {
            "tree": [
                {"path": r, "mode": "100644", "type": "blob", "sha": s}
                for r, s in blobs.items()
            ]
        },
    )["sha"]
    print(f"tree={tree}")

    commit = gh_api(
        "POST",
        f"/repos/{REPO}/git/commits",
        {"message": MSG, "tree": tree, "parents": [parent]},
    )["sha"]
    print(f"commit={commit}")

    gh_api(
        "PATCH",
        f"/repos/{REPO}/git/refs/heads/main",
        {"sha": commit},
    )
    print("main ok")
    try:
        gh_api(
            "PATCH",
            f"/repos/{REPO}/git/refs/heads/develop",
            {"sha": commit, "force": True},
        )
        print("develop ok")
    except Exception as e:
        print("develop", e)
    print("DONE", commit)


if __name__ == "__main__":
    main()
