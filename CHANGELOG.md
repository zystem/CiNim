# Changelog

The format is that of [Keep a Changelog](https://keepachangelog.com). The project has made **no release yet**: everything is in `## [Unreleased]`, from the last weeks, and the history before is in git (`git log`, the first commit is of 2026-10-03). The first release will name its version and list what it holds.

## [Unreleased]

### Added
- **ThreadSanitizer mode of the tests** (`CINIM_TEST_TSAN=1 tools/test/run.sh`) with a classifier of the reports in Nim (`tools/test/tsanreport.nim`: ours, nimgrpc, tests, GuildenStern, other, runtime; only the first three fail a file); the pipeline parameter `TSAN`. It showed three errors of tests, which are fixed.
- **`j:image` returns `digest` and `ref_digest`** of the image it built or found (Kaniko's `--digest-file`, `crane digest`), the input of a signing step.
- **Answers `500` carry a `request_id`** (`src/core/apifailure.nim`); the log of the core has the line for it.
- `tools/deps/lock.sh` and **`cinim.lock`**: the exact versions and commits of the nimble packages.
- `SECURITY.md`, `CONTRIBUTING.md`, `GOVERNANCE.md`, `CODE_OF_CONDUCT.md`, `DCO.md` (a sign-off on every commit of a pull request, checked by the workflow `DCO`) and the templates of issues and pull requests.

### Changed
- **nimgrpc 0.6.0** (`>= 0.6.0`), **nghttp2 1.71.0**, **blobgate 0.7.0** (the chart dependency and the image of the tests; it adds columns to its tables at its start, a downgrade is not supported).
- **What a build takes from outside is pinned**: the base images by digest, the sources that scripts cloned by a tag or a head by commit, the archives of nghttp2 and rqlite by SHA-256, the nimble packages by `cinim.lock`; `tests/unit/trepository.nim` refuses what is not.
- `onRequest` of the core, one procedure of 2550 lines, is the dispatch of 50 procedures, one for each group of routes; the text of the bodies is unchanged.
- `-d:QueueSize=20000` for every build: a slow request kept its connection only while fewer than 200 others were handled (GuildenStern 9.0.2; the cure is in the library, the issue is olliNiinivaara/GuildenStern#39).
- The soak (NFR-013) runs from Woodpecker, not from a CronJob; its step is privileged for `CAP_SYS_PTRACE` (LeakSanitizer).

### Fixed
- A `TlsConfig` shared by several threads was freed early (ORC counts without atomics) and killed the soak with SIGSEGV in BearSSL: every connection has its own object now.
- `tests/integration/tldap.nim` took a port of the kernel's own range and stopped when another test held it; the ports are below 32768.
- `tools/test/run.sh` gave the files of `unit` and `integration` that have one name a single compiler cache, and a parallel run failed to link now and then; every file has its own.
