# Contributing

- **Bugs and ideas**: open an issue. **Security problems**: not in an issue; see [SECURITY.md](SECURITY.md).
- **Build and test**: the README ("Build and tests") has the system libraries and the commands. The short form: `nimble install -d --lockFile=cinim.lock`, then `tools/test/run.sh` (unit, contract and integration tests in parallel; about two minutes on a workstation with Docker) and `tools/test/lint.sh` (shellcheck, hadolint, `helm lint --strict`, kubeconform). A single test file: `nim c -r --hints:off --warnings:off --outdir:build/tests tests/unit/<file>.nim`.
- **Tests first**: a change of behaviour comes with a test that fails without it; the name of a test holds the ID of the requirement it verifies (`PIP-012`, `DAT-003`, a decision `D-xx` of [docs/specification.md](docs/specification.md)). The rules that a test can check are checked by `tests/unit/trepository.nim`.
- **Style**: the code is Nim 2.4 with ORC. Comments say why, not what. Do not share a `ref` between threads (ORC counts without atomics), do not write `pkill -f`, make HTTP servers with `newService` of `src/common/httpsrv.nim`; `CLAUDE.md` has the list of what cost time and why.
- **Documents**: English, plain, short sentences. A command comes with what it prints, a claim that was never run is written "not run", and a new setting, flag or message gets its line in its page in the same change. One kind of page: tutorial, how-to, reference or explanation; do not mix them.
- **Private details**: the repository holds no private addresses, host names, cluster names or tokens; write "the TESTING cluster".
- **Commits**: a short subject saying what changed, and a body that says why, what was run and what was not.
- **Sign-off (DCO)**: every commit carries a `Signed-off-by: Name <email>` line (`git commit -s`), which says that you have the right to submit the work under the project's license, as in [DCO.md](DCO.md). The `DCO` workflow checks every commit of a pull request (bots are exempt) and a commit without the line fails it.
- **License**: by contributing you agree that your work is under the MIT license of the project (`LICENSE`).
- **Conduct**: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). **Governance and roles**: [GOVERNANCE.md](GOVERNANCE.md). **Changes**: [CHANGELOG.md](CHANGELOG.md).

## When and how the tests run

- **By you, before a pull request**: `tools/test/run.sh` and `tools/test/lint.sh`. `CINIM_TEST_ASAN=1` and `CINIM_TEST_TSAN=1` run chosen files under AddressSanitizer and ThreadSanitizer (the README and `CLAUDE.md` say what each one needs).
- **Automatically**: the project's own pipeline (`.ci/pipeline.lua`, CiNim builds itself on a test cluster) builds and tests `main` after every push: the images, the tests, the lint, and with parameters the ASan and TSan runs and the 72 hour soak. It does not build the branch of a pull request: a maintainer can start it on the commit of the pull request before merging. GitHub runs one workflow, `DCO`, on a pull request.
- **A change of behaviour** adds or updates a test; a pull request without one is asked to add it.
