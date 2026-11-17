# Governance

CiNim is a small project with **one maintainer**. This file says how it is run, so that a contributor knows what to expect, a user knows what the controls are, and it is plain what happens if the maintainer cannot go on.

## Members and roles

| Member | Role | Access to sensitive resources |
|---|---|---|
| `zystem` (the owner of the repository) | maintainer: decides, reviews and merges, makes releases, answers security reports, holds the settings of the repository (security settings, Renovate, the tags) and the project's entry at bestpractices.dev | admin on the repository; the test cluster and its registry, which are the owner's and not the project's |
| contributors | anyone who sends a pull request or an issue | none |

This is the complete list of members with access to sensitive resources; it is changed in this file when a permission is granted or removed.

## How the project is run

- **Decisions** are made by the maintainer, in the open: in issues and pull requests, with the reasons in the commit message, in `docs/specification.md` (the decision log, IDs `D-xx`) or in `CLAUDE.md`. The decisions of the owner that bind later work (what is not built, what is not asked again) are written there with the date.
- **Contributions** come as pull requests and follow [CONTRIBUTING.md](CONTRIBUTING.md), with the sign-off of [DCO.md](DCO.md).
- **Review of changes**: the maintainer merges; the tests and the lint (`tools/test/run.sh`, `tools/test/lint.sh`) must pass. **There is no required second review**: with one maintainer a required approval would block every merge, and the branch `main` has no branch protection while the active phase of development with breaking changes lasts (the owner's decision of 2026-11-16, written in `CLAUDE.md`). A contribution from another person is read by the maintainer before it is merged.
- **Releases**: none yet. The first one is made by a tag of the maintainer, with the changelog ([CHANGELOG.md](CHANGELOG.md)) written first.
- **Security reports** go as in [SECURITY.md](SECURITY.md).
- **Escalated permissions** (write access, the right to publish releases or images, access to the settings) are given only to a person who has contributed accepted changes over time, and are listed above.

## If the maintainer cannot go on

**This is not met.** One person holds the repository, the settings, the releases and the test cluster; there is no second person who could create and close issues, merge and release within a week of the loss of the maintainer. What is in place:

- the sources, the documents and the decision log are in the repository, the licence (MIT) lets anyone who has them carry on, and the project keeps no secret that a person could lose (the keys of a deployment are the operator's);
- the build and the tests need nothing that is not in the repository or named in it (`tools/image`, `.ci/pipeline.lua`, `cinim.lock`).

What is missing is a second maintainer with write access, and a written arrangement for the owner's account. It is the first thing to do when someone has contributed accepted changes over time; this file is changed then.
