# Security policy

CiNim runs other people's commands in Pods and keeps their secrets, so a report of a weakness is welcome and is read first.

## Reporting

- Use GitHub's private vulnerability reporting for this repository (Security → Report a vulnerability). It is the security contact of the project.
- Do not put details of an unfixed problem into a public issue. If the private channel does not work for you, open a **public issue that holds no details** ("security contact request"); the maintainer then arranges another private channel with you.
- Say what you saw, on which commit, and how to see it again; a failing test is the best report.

## Coordinated disclosure, and the timeframe

- **Acknowledgement** within 7 days of a report; an assessment (confirmed, not reproducible, not a vulnerability) within 14 days.
- **Fix**: a confirmed problem is fixed and tested first; for High and Critical severity the target is a fix on `main` within 30 days, for the rest the next release. The reporter is told when the fix is ready.
- **Disclosure**: after the fix is on `main` (and in a release, once there is one), or after 90 days from the report if no fix is possible, whichever is first (earlier by agreement). The problem is then described in the changelog and in a GitHub security advisory, with the people who reported it named if they wish.

## What is supported

- **No release has been made yet** (see [CHANGELOG.md](CHANGELOG.md)). Until the first one, the supported version is the head of `main`; every fix of a security problem is made there.
- Once there are releases: the latest release gets the fixes; the release before it gets fixes of High and Critical problems for 30 days after the new one. The release notes of the release that replaces a version say that the support of it has ended.
- The project has **one maintainer** ([GOVERNANCE.md](GOVERNANCE.md)); the times above are what one person can keep, and they are the times that are promised.

## What the project does against weaknesses

- Secret scanning and push protection are on for the repository (GitHub), and `tests/unit/trepository.nim` looks for the shapes of tokens and private keys in every tracked file.
- Every dependency is pinned: the nimble packages by `cinim.lock`, the base images by digest, the sources that a build clones by commit, the downloaded archives by SHA-256 (docs/deployment.md, "Dependency updates"); Renovate proposes the updates and a person merges them after the pipeline has built and tested them.
- The tests run under AddressSanitizer and ThreadSanitizer on request (`CINIM_TEST_ASAN=1`, `CINIM_TEST_TSAN=1`, `tools/test/run.sh`; the pipeline has the parameters `ASAN` and `TSAN`).
- The threat model is in [docs/threat-model.md](docs/threat-model.md). The images are **not signed yet** and have no bill of materials; the plan is in `CLAUDE.md`, "What is open", item 2.

## What helps a reviewer

- `docs/threat-model.md`, `docs/specification.md` (requirements by ID and the decision log), `docs/deployment.md`.
- Tests are the specification: the name of a test holds the ID of the requirement it verifies; `tools/test/run.sh` runs them (the README, "Build and tests").
