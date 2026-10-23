# The UI (UI-001, UI-009, D-65)

Pages for people, **a service of its own**, `cinim-ui` (`src/ui`): HTML rendered on the server (Nimja templates, every expression through `h()` or `raw()`, checked by `tests/unit/ttemplates.nim`), no JavaScript yet,
a few kilobytes of CSS. It keeps nothing: every page is made from what the core's API says, asked with **the token of the user**, so the UI can show a person no more than the API would. The core is not touched by it
(its process, memory and ports are the core's own), and a crash of the UI is the UI's.

## What is built (the first slice, read-only)

| Address (under `ui.path`, `/ui`) | What |
|---|---|
| `/login`, `POST /logout` | the login form and the end of the session |
| `/orgs` | the organisations the user may see, each with a link to its runs |
| `/orgs/<slug>/runs`, `/runs` | the runs of an organisation, newest first, 50 a page (`?before=<run id>` for older ones, `?state=FAILED` to filter); `/runs` is the runs the token may see in every organisation; with the time each took (from the start to the last change of a run that has ended, to now for one that goes on) |
| `/runs/<id>` | one run: state, organisation, source (repository, commit, path), parameters, the reason of a failure, the steps with their attempts, states, how long each took (from its start to its end, to now while it runs) and how they ended; how long the whole run took |
| `/runs/<id>/steps/<n>/log` | a **window** of the log of a step (200 lines, `?from=<line>`), numbered, with a way to earlier and later lines (DAT-007: a whole log is never loaded) |
| `/runs/<id>/log` | the **log of the run** (D-77): one window of 200 lines of all its steps, in the order of step, attempt and line, in one request to the core; every line starts with the label of its step (`14/0003`: the job's id and the step's, a link to that line in the step's log); the last lines of the run, with `Earlier lines`, `Later lines` and `Newest` by the cursors the core gives (`?until=`, `?from=`; DAT-007: a window, never a whole log) |
| `/status` | the components of the shard (`GET /api/v1/components`): the key service, rqlite, the controllers, the conductors, the log circuit |
| `/healthz` (outside the prefix) | the probe of the Pod |

Every address is a permanent link (UI-001): opening it in a new session gives the same page after the login. Not built yet: charts (UI-006), the run graph (UI-007), HTMX and SSE (UI-004, UI-005), saved views (UI-003),
extension points (UI-002), the actions (start, cancel, retry), administration (secrets, triggers, users), and the pages are made as strings, not streamed (UI-009 asks for a chunked response: the pages of this slice are small).

## The login, the cookie, the rights

- The form calls `POST /api/v1/login` of the core (so its throttle of a user's tries, its audit and the rule "change the password first" are the core's), and puts the token it gets (8 hours) in the cookie `cinim_ui`:
  `HttpOnly` (a script cannot read it), `SameSite=Strict` (another site cannot send it), `Path=<ui.path>`, `Secure` when `ui.cookieSecure` says the Ingress has TLS. The token is the credential and the cookie is only where it lies: there is
  no session on the server to steal or to lose, and a token that the core revokes (a changed password, a rotated token) ends the session at the next page.
- A user who has to change the password first gets no session (the UI does not change passwords): the page says which API call does.
- The rights are the user's own: a role `ro` or `dev` sees the runs of every organisation, a token of an organisation only its own (`GET /api/v1/runs` refuses another's, `runListScope`); a page the core refuses is a 403 page.
- A POST (login, logout) must come from this host (`Origin`, `Sec-Fetch-Site`); `next` after a login is a page of the UI and never another address; the parts of an address that go to the core (a slug, an id, a number, a state, a cursor)
  are checked first, so that an address cannot reach further than the page it names.
- Headers of every page: `Content-Security-Policy: default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`, `Cache-Control: no-store`.
- The list of runs shows the last six characters of a long id (the random end; its start is the time, which has a column of its own) with the whole id as the title and in the link; the page of a run shows it whole.
  The style sheet is cached for a day, so its link carries a version made from its content (`ui.css?v=<hash>`): a new one is a new address.

## What the core got for it

`GET /api/v1/runs?organization=<slug>&state=<STATE>&limit=<n>&before=<run id>` (`core/runlist.nim`): the list of runs, newest first (the ids are made in time order, so the id is the cursor and no run is missed or shown twice while new ones come), at most 200
a page, without the steps; `next` is the id to pass as `before`, or null. Reading it is open to the roles that may read the runs (RBAC: `ro`, `dev`, `rw`, `admin`); a token of an organisation lists its own runs only. The slug `ui` is reserved (an organisation's pages are
`<basePath>/<slug>`).

## Deployment

The chart value `ui.enabled` (off by default) makes a Deployment, a Service and an Ingress at `ui.path` of the domain (`deploy/charts/cinim-shard/templates/ui.yaml`); the image is `<image.repository>-ui:<image.tag>` (`tools/image/Dockerfile.ui`, a scratch image with one static
program, built by the pipeline with the other components). Settings of the program: `CINIM_UI_CORE_URL`, `CINIM_UI_PORT`, `CINIM_UI_BASE`, `CINIM_UI_COOKIE_SECURE`, `CINIM_UI_TIMEOUT_MS`, `CINIM_UI_THREADS` (docs/settings.md). A user for it is made as any user:
`POST /api/v1/users {"name", "role", "password"}`.

## Tests

`tests/unit/tui.nim` (the app against a stand-in core: the login and its cookie, the redirects, the open redirect, the cross-site POST, what each page shows and how hostile data stays text, the windows of a log, the 404, 405 and 503 pages, the prefix),
`tests/unit/ttemplates.nim` (the guard of the templates), `tests/integration/trunlist.nim` (the list of runs against rqlite: the order, the cursor, the filters, the bounds, no SQL from a parameter; who may list which runs). Run against the real core of the TESTING cluster by hand
(2026-10-20): the login (a wrong password, a good one), the cookie, the organisations, the runs of an organisation (31 rows), a run with 26 steps, a window of a log, the logout.
