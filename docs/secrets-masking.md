# Secret masking

Secret values of a step are masked in the shim **before** the text goes anywhere: the spool, the core and VictoriaLogs only ever see
`***`, the core never sees the plain value. The build's output does not reach the Pod's log (`kubectl logs`) at all: it holds only the
shim's events (`CICD-SHIM {...}`), so there is no way for a secret to get there.

## What is masked

Every value (at least 4 characters, `mask.min_length`) is masked in these forms:

| Form | Example for `p@ss w/rd` |
|---|---|
| as is | `p@ss w/rd` |
| base64 at any of the three alignments, standard and URL-safe alphabet | the value inside a longer base64 string (for example in an `Authorization: Basic ...` header) |
| URL encoding, upper- and lower-case hex, space as `%20` and as `+` | `p%40ss%20w%2Frd` |
| JSON escaping | `"p@ss \"x\\y"` |

For base64 the stable part is masked: characters that depend on the neighbouring bytes are cut off, and the rest is the same wherever the
value occurs. If the stable part is shorter than 8 characters (a value shorter than about 6 bytes), no base64 forms are created: such a
short fragment would match ordinary text by chance. For such values only "as is", URL and JSON apply.

Multi-line values (PEM) are masked line by line. At most 256 masks per step.

## Values found at run time

A build can report a value that must be hidden (a token issued by a service during the step) by appending it to the file `$CICD_MASK`,
one value per line:

```sh
TOKEN=$(vault-login ...)
echo "$TOKEN" >> "$CICD_MASK"
echo "token is $TOKEN"        # in the log: token is ***
```

This applies to the lines that come **after** the registration (the shim reads the file before processing every portion of output, so a
line printed right after `echo >> $CICD_MASK` is already protected; the reverse also holds: a line in the same portion of output as the
write is masked even if it was printed earlier). Lines that have already gone cannot be corrected. The file is limited to 64 KiB. As with
GitHub's `::add-mask::`, this is up to the pipeline author.

## Configuration in Lua

```lua
ci.job({ image = "alpine", mask = { min_length = 8 } }, function(job)      -- default for the job
  job:sh("deploy.sh")                                                       -- runtime = true, variants = true
  job:sh("noisy.sh", { mask = { variants = false } })                       -- only "as is" values and $CICD_MASK
  job:sh("trusted.sh", { mask = false })                                    -- no $CICD_MASK and no variants
end)
```

`mask.runtime` turns on `$CICD_MASK`, `mask.variants` turns on the forms of a value, `mask.min_length` sets the minimum length (4..64).
`mask = false` turns both off. The secret values themselves never reach Lua (the script works only with opaque handles); the setting
affects only the way of masking.

## Secrets of an organisation

A step asks for the secrets it needs by name, on the job or on the step (the two lists are added together):

```lua
ci.job({ image = "alpine", secrets = { "REGISTRY_PASSWORD" } }, function(job)
  job:sh("login.sh")                                         -- $REGISTRY_PASSWORD is in the environment of the command
  job:sh("deploy.sh", { secrets = { "DEPLOY_KEY" } })        -- this step also gets $DEPLOY_KEY
end)
```

The administrator sets the value for the organisation (`PUT /api/v1/organizations/{slug}/secrets/{NAME}` with `{"value": "..."}`; `GET .../secrets` lists the
names and versions, `DELETE .../secrets/{NAME}` removes one). The value is sealed in the shard's database (XChaCha20-Poly1305, a data key per organisation
wrapped by a master key that is not in the database, D-45), so it is backed up and restored with the database; Lua sees the name only. When the step starts, its
shim asks core for the values over the authenticated channel, with a credential bound to that run, step and attempt, and puts them into the environment of the
command only. The Pod's specification holds a placeholder (`NAME=cinim-secret:NAME`) per secret and never a value, and nothing is left in Kubernetes. The shim
masks the values in the log like any other secret (raw, base64, URL, JSON; every line of a multi-line value) before it reads a byte of the command's output. If the
values cannot be fetched the command is not started: the step ends with the reason `secrets_unavailable` (exit code 73). A step that asks for a secret the
organisation does not have is refused when it is submitted, before anything runs. A changed value is a new version: a step that starts after the change gets it.
The name follows the rules of an environment variable (capital letters, digits, `_`; not `PATH`, `LD_*`, `CICD_*`...), the value is at most 8 KiB. A secret is for
a run of an organisation; a run of the shard's default tenant has none.

The master key can also be kept on a hardware token (a SmartCard-HSM); how to prepare the card and the key is in docs/hardware-key.md, the provider that uses it is not built yet.

The master key is a file of 64 hexadecimal digits (`secrets.keySecret` in the chart, `CINIM_SECRETS_KEY_FILE`), or, when none is given, derived from the core's CURVE
key. **Keep it apart from the database backup** and back it up too: a database restored without it holds nothing readable (GitLab and Drone say the same of their
keys). The core stores a check value and refuses to serve secrets when started with another key, instead of writing new secrets next to ones it cannot read.

## What is not covered

- A value split by a line break is masked only line by line: it is not recognised across the boundary of two lines.
- Other encodings (hex, gzip+base64, encryption) are not recognised: this protects against accidental leaks, not deliberate ones.
- A value the build did not register and that was not among the step's secrets cannot be masked.
- The plain shim without ZeroMQ (a test build) reads the build's output and discards it: without the pipeline logs are not stored anywhere.
