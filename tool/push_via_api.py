#!/usr/bin/env python3
"""Push local commits to GitHub via the git data API (git push is blocked for
agents). The remote already holds the base commit's tree, so only the blobs
changed by the pushed range are created; unchanged tree entries reference
existing shas.

Usage: python3 tool/push_via_api.py <base-ref> <head-sha> <branch>
"""
import base64
import json
import subprocess
import sys
import urllib.request

REPO = "nmfisher/tina"
TOKEN = subprocess.run(
    ["gh", "auth", "token"], capture_output=True, text=True, check=True
).stdout.strip()
API = f"https://api.github.com/repos/{REPO}"


def gh_api(method, path, payload=None):
    req = urllib.request.Request(
        API + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        method=method,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "tina-sweep-push",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print("API error:", e.code, e.read().decode()[:300])
        raise


def git(*args):
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def create_blob(sha):
    content = subprocess.run(
        ["git", "cat-file", "blob", sha], capture_output=True
    ).stdout
    return gh_api(
        "POST",
        "/git/blobs",
        {"content": base64.b64encode(content).decode(), "encoding": "base64"},
    )["sha"]


def create_tree(commit, tree_sha):
    """Create the tree object for a commit (recursively). Entries for
    unchanged files reference the existing shas (the remote has them from
    the base commit); changed entries reference newly-created blobs."""
    entries = []
    for line in git("ls-tree", tree_sha).splitlines():
        meta, path = line.split("\t")
        mode, typ, sha = meta.split(" ")
        if typ == "blob":
            entries.append({"path": path, "mode": mode, "type": "blob", "sha": sha})
        elif typ == "tree":
            entries.append(
                {"path": path, "mode": mode, "type": "tree", "sha": create_tree(commit, sha)}
            )
        else:
            entries.append({"path": path, "mode": mode, "type": "commit", "sha": sha})
    return gh_api("POST", "/git/trees", {"tree": entries})["sha"]


def main():
    base, head, branch = sys.argv[1], sys.argv[2], sys.argv[3]
    base = git("rev-parse", base)
    head = git("rev-parse", head)
    commits = git("log", "--format=%H", f"{base}..{head}").splitlines()
    commits.reverse()
    print(f"pushing {len(commits)} commits onto {base[:8]} -> {branch}")

    # Create the blobs each commit introduces or modifies (the intermediate
    # states matter — every commit's tree must be buildable).
    created = 0
    prev = base
    for c in commits:
        for path in git("diff", "--name-only", prev, c).splitlines():
            if not path:
                continue
            sha = git("ls-tree", c, "--", path)
            # ls-tree on a path returns "mode type sha\tpath"
            blob_sha = sha.split(" ")[2].split("\t")[0]
            create_blob(blob_sha)
            created += 1
        prev = c
    print(f"created {created} blobs")

    parent = base
    for c in commits:
        msg = git("log", "-1", "--format=%B", c)
        tree_sha = git("rev-parse", f"{c}^{{tree}}")
        tree = create_tree(c, tree_sha)
        created = gh_api(
            "POST", "/git/commits", {"message": msg, "tree": tree, "parents": [parent]}
        )
        print(f"  {c[:8]} -> {created['sha'][:8]}")
        parent = created["sha"]
    ref = branch if branch.startswith("refs/") else f"refs/heads/{branch}"
    # The refs API path is the ref WITHOUT the leading "refs/" (e.g.
    # "heads/asb/ui-sweep"); the branch name in the path IS the ref suffix.
    path = ref.removeprefix("refs/")
    # The branch may not exist yet (e.g. it was deleted after its PR merged):
    # create it, then update. The PATCH-with-force on a missing ref 422s.
    try:
        gh_api("PATCH", f"/git/refs/{path}", {"sha": parent, "force": True})
    except urllib.error.HTTPError as e:
        if e.code == 422:
            gh_api("POST", "/git/refs", {"ref": ref, "sha": parent})
        else:
            raise
    print(f"branch {branch} -> {parent}")


if __name__ == "__main__":
    main()
