# Webhooks: telling an address what happens to the runs (D-111)

A webhook is an address that the core calls when something happens to a run of an organisation or of a project. It is for a person or a tool that follows runs without asking for them again and
again, and, in time, for the status of a build in a pull request (`core/prstatus.nim`, D-96, already does that for the hosts of repositories: this is the general mechanism).

## The events

| `event` | When | What is in the body besides the common part |
|:--|:--|:--|
| `run.started` | the run is no longer queued or waiting (it runs, or it ended before the core looked) | `run.state` is `RUNNING` |
| `step.failed` | a step ended in `FAILED` (a code other than 0, a timeout, ...); once for each step and attempt | `step`: `number`, `job_id`, `step_id` (the words of the log, D-77), `attempt`, `exit_code`, `termination` |
| `run.finished` | the run is in a final state (`OK`, `FAILED`, `ABORTED`, `TIMED_OUT`, `INFRASTRUCTURE_ERROR`, `SKIPPED`) | `failure`: `code`, `message`, for a run that did not end well |
| `ping` | a person asked for one (`POST .../webhooks/{id}:test`) | nothing but the organisation |

The common part: `event`, `delivery` (the id of this delivery, also the header `X-CiNim-Delivery`), `time` (seconds), `organization`, `project`, and `run`: `id`, `state`, `commit`, `ref` (the branch or
tag the run was asked for), `repository`, `trigger_id`, `created_at`, and `link` (`<CINIM_UI_URL>/runs/<id>`, when the shard has an address for its pages).

```json
{"event":"step.failed","delivery":"s1_1jzk…","time":1793929210,"organization":"selfci","project":"cinim",
 "run":{"id":"s1_1jzhzaebhc2","state":"RUNNING","commit":"c0ade58…","ref":"main","repository":"https://github.com/zystem/CiNim.git","trigger_id":"s1_1jzhzaa0bne","created_at":1793921212},
 "step":{"number":28311556,"job_id":"0v","step_id":"0004","attempt":1,"exit_code":124,"termination":"timeout"}}
```

## How it is sent

The core sends, in the shape of `prstatus.nim` (no module of its own): each beat of the loop of the triggers (every 20 seconds) it looks at the runs of the webhooks that are on and **writes down, once**,
each event that has happened (a row of `webhook_deliveries`, unique by webhook, run, event and key, so looking again writes nothing; a run seen only when it had ended still gives `run.started` and
`run.finished`), and sends the rows that are due: `POST` of the body, `Content-Type: application/json`, the headers `X-CiNim-Event` and `X-CiNim-Delivery`, a timeout of 10 seconds.

* **Signature.** A webhook may name a secret of the organisation (`"secret": "NAME"`, the name only, set with `PUT .../secrets/NAME`): the body is then signed, `X-CiNim-Signature: sha256=<HMAC-SHA256 of the body
  under the value>`, as GitHub signs its own. A secret that cannot be had now (the key service does not answer) is not a reason to send unsigned: the delivery waits and is tried again.
* **A refusal** (any answer but 2xx, no answer) is written down with its reason and tried again after 30 s, then twice as long each time, at most an hour, **8 times in all**; then the row stays for a person
  to see (`webhook_deliveries.last_error`) and is removed after three days. A receiver that is down never holds a run, and a run does not wait for a delivery.
* **The addresses are the shard's to allow.** The core must not be made to call what is inside the cluster by whoever sets a webhook: only the hosts of `CINIM_WEBHOOK_HOSTS` (chart: `webhooks.allowedHosts`;
  `host` for any port, `host:port` for one; comma separated) are called, over `http` or `https`, with no login in the address. A shard that lists none sends nothing and refuses to make a webhook. An address that
  stopped being allowed is given up at once.
* **Which runs.** Those made after the webhook was, not older than three days, of the whole organisation or (with `project`) of that project and the groups under it.

## The API

**A name is unique within its scope** (2026-11-10): the organisation may have a webhook `ops` and each project too; a second one in the same scope is `409 name_taken`.

All under `/api/v1/organizations/{slug}/webhooks`; the permissions `webhook.read` (every role that reads) and `webhook.write` (an administrator and `rw`), in the project of the webhook.

```
POST   .../webhooks            {"name": "mine", "url": "http://ci.lan:18999/in", "project": "ci/cinim", "secret": "HOOK_KEY", "events": ["run.finished"], "enabled": true}
GET    .../webhooks            the list, and the hosts the shard allows
GET    .../webhooks/{id}
PATCH  .../webhooks/{id}       {"url", "secret" ("" takes the signature off), "events", "enabled"}: the name and the project do not change (make a new webhook)
DELETE .../webhooks/{id}       with the deliveries written for it
POST   .../webhooks/{id}:test  a ping, sent at the next beat
```

`name` is 1 to 64 characters (lowercase letters, digits, `- _ .`); at most 50 webhooks to an organisation; `events` default to all three.

## A receiver to follow runs

`tools/test/webhook-listen.py [port]` (Python 3, no packages) prints one line for each event, checks the signature when `WEBHOOK_SECRET` is set, and keeps the bodies in `WEBHOOK_LOG`:

```
22:03:39 run.finished selfci/cinim run=s1_x state=FAILED ref=main commit=0123456 https://ci/runs/s1_x failure=script_error: tests failed signature=ok
```

## Not built

The status of a build in a pull request through this mechanism (the hosts of repositories are told by `prstatus.nim` as before); filters by ref or by state; the payload of GitLab's or GitHub's own format;
a separate sender (when the load needs one); a view of the deliveries in the UI (the table is `webhook_deliveries`).
