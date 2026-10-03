# Ubuntu CI

Trusted Linux jobs run on the repository's runner on `ubuntu-zhang`.
Same-repository PRs use the runner; fork PRs retain their GitHub-hosted destination.
The host rejects fork PR payloads before any workflow step executes.
Windows, macOS, ARM64, Docker service jobs, and disabled workflows retain their existing setup.

The runner uses a separate Docker container, without the host Docker socket or SSH credentials.
Across repositories, at most two jobs run concurrently; each container is limited to 1.5 CPUs and 4 GiB of memory.
The Docker restart policy starts the runners again when the host starts.

Local paths on ubuntu-zhang:

- Cache: `/home/zhang/github-actions/cache/sendai_glab/`
- Ordinary artifacts: `/home/zhang/github-actions/artifacts/sendai_glab/<run-id>/<attempt>/`
- Runner diagnostics: `/home/zhang/github-actions/runners/sendai_glab-<runtime>/_diag/`

Ordinary artifacts retain the workflow's retention period, capped at 30 days.
The maintenance service reclaims idle caches over 100 GiB and expires generated reports.
Jobs stop admitting work below 50 GiB of host free space.
Release and GitHub Pages artifacts needed by downstream jobs continue using GitHub transport.
Job workspaces and transient Xposter auth files are cleared after the job finishes.

Run `Ubuntu runner smoke test` manually to verify registration, tools, and local artifact storage.
Rollback: revert the migration commit, then stop this repository's `ci-sendai_glab-*` containers.
