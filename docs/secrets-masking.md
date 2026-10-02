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

## What is not covered

- A value split by a line break is masked only line by line: it is not recognised across the boundary of two lines.
- Other encodings (hex, gzip+base64, encryption) are not recognised: this protects against accidental leaks, not deliberate ones.
- A value the build did not register and that was not among the step's secrets cannot be masked.
- The plain shim without ZeroMQ (a test build) reads the build's output and discards it: without the pipeline logs are not stored anywhere.
