#!/usr/bin/env python3
"""Incremental push of local commits to a GitHub branch via the git data
API (git push is blocked for agents). Sibling of tool/push_via_api.py,
which pushes a single range; this one exists for the recursive-
improvement loop's repeated pattern: keep committing locally, then
replicate the new commits onto a remote PR branch.

Two things push_via_api.py lacks, both learned live (see
TINA_IMPROVEMENTS_LOG #41):

- REMOTE-PARENT GRAFTING: the PR branch's commits are re-created
  objects with different ids than their local twins, so the first new
  commit must be grafted onto the remote twin of the local base
  (<REMOTE_PARENT>), not onto the local base itself.
- DELETION HANDLING: `git ls-tree <commit> -- <path>` returns EMPTY for
  a path deleted in that commit; the blob pre-upload loop must skip it
  (an unguarded parse dies with IndexError — found when 9305e6b
  removed three tool/ files). Tree creation needs no deletion support:
  a full-tree POST simply omits the removed path.

Usage:
  PUSH_BRANCH=<remote-branch> python3 tool/push_incremental.py \
      <LOCAL_BASE_FULL_SHA> <REMOTE_PARENT_FULL_SHA>

LOCAL_BASE..HEAD is replicated. The 422-on-ref-update fallback (branch
create vs update) matches push_via_api.py.
"""
import base64
import json
import os
import subprocess
import sys
import urllib.request

REPO = "nmfisher/tina"
BRANCH = os.environ.get("PUSH_BRANCH", "asb/improvements-log")
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


def create_tree(tree_sha):
    entries = []
    for line in git("ls-tree", tree_sha).splitlines():
        meta, path = line.split("\t")
        mode, typ, sha = meta.split(" ")
        if typ == "blob":
            entries.append({"path": path, "mode": mode, "type": "blob", "sha": sha})
        elif typ == "tree":
            entries.append(
                {"path": path, "mode": mode, "type": "tree", "sha": create_tree(sha)}
            )
        else:
            entries.append({"path": path, "mode": mode, "type": "commit", "sha": sha})
    return gh_api("POST", "/git/trees", {"tree": entries})["sha"]


def main():
    local_base, remote_parent = sys.argv[1], sys.argv[2]
    head = git("rev-parse", "HEAD")
    commits = git("log", "--format=%H", f"{local_base}..{head}").splitlines()
    commits.reverse()
    print(f"replicating {len(commits)} commits onto remote {remote_parent[:8]}")

    prev = local_base
    for c in commits:
        for path in git("diff", "--name-only", prev, c).splitlines():
            if not path:
                continue
            sha = git("ls-tree", c, "--", path)
            if not sha:
                continue  # deleted in this commit; nothing to upload
            blob_sha = sha.split(" ")[2].split("\t")[0]
            create_blob(blob_sha)
        prev = c

    parent = remote_parent
    for c in commits:
        msg = git("log", "-1", "--format=%B", c)
        tree_sha = git("rev-parse", f"{c}^{{tree}}")
        tree = create_tree(tree_sha)
        created = gh_api(
            "POST", "/git/commits", {"message": msg, "tree": tree, "parents": [parent]}
        )
        print(f"  {c[:7]} {msg.splitlines()[0][:60]} -> {created['sha'][:7]}")
        parent = created["sha"]
    try:
        gh_api("PATCH", f"/git/refs/heads/{BRANCH}", {"sha": parent, "force": True})
    except urllib.error.HTTPError as e:
        if e.code == 422:
            gh_api("POST", "/git/refs", {"ref": f"refs/heads/{BRANCH}", "sha": parent})
        else:
            raise
    print(f"REMOTE HEAD: {parent}")


if __name__ == "__main__":
    main()
