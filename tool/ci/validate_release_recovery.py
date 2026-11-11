#!/usr/bin/env python3
"""Only publish recovered artifacts from successful builds of the exact tag."""

import json
import subprocess
import sys


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def validate(run, tag_sha, jobs, tag):
    if (run['head_sha'] != tag_sha or run['head_branch'] != tag
            or run['event'] != 'push' or run['path'] != '.github/workflows/release.yml'):
        raise ValueError('Recovery must use the original release run for this exact tag')
    required = {'build (macos-arm64)', 'build (linux-x64)', 'build (linux-arm64)'}
    successful = {job['name'] for job in jobs if job['conclusion'] == 'success'}
    if not required.issubset(successful):
        raise ValueError('All three release build jobs must have passed')


if __name__ == '__main__':
    repository, run_id, tag = sys.argv[1:]
    if not run_id.isdecimal() or not tag.startswith('v') or '/' in tag:
        raise ValueError('Expected a numeric run ID and a release tag')
    run = api(f'repos/{repository}/actions/runs/{run_id}')
    ref = api(f'repos/{repository}/git/ref/tags/{tag}')['object']
    while ref['type'] == 'tag':
        ref = api(f'repos/{repository}/git/tags/{ref["sha"]}')['object']
    jobs = api(f'repos/{repository}/actions/runs/{run_id}/jobs?per_page=100')['jobs']
    validate(run, ref['sha'], jobs, tag)
    print(f'Validated successful builds for {tag} at {ref["sha"]}')
