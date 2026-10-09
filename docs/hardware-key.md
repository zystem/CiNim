# The master key of the step secrets on a SmartCard-HSM

The step secrets of an organisation are sealed in the shard's database (D-45, docs/secrets-masking.md). A data key per organisation seals them, and a **master
key** wraps the data keys. By default the master key is a file or is derived from the core's CURVE key. This page is about keeping it on a hardware token, so
that the key that opens everything is on a device that cannot give it away.

What exists today and what does not:

| | State |
|---|---|
| Master key from a file (`CINIM_SECRETS_KEY_FILE`) or derived from the CURVE key | built |
| `KekProvider` seam in `core/kekprovider.nim` (wrap, unwrap, key id, "may pass or final" failures) | built |
| The core's side of a key service next to the token (`CINIM_KEKD_URL`, mutual TLS, retry, cache, a component in `/api/v1/components`), and an emulator of that service | built, tested on a cluster with the emulator (sections 9 and 10) |
| The service itself, `kekd`, with ECDH on the card | **not built yet**; this page prepares the hardware and the key so that it can be |
| Wrapping a data key for two cards at once (a spare), rotation of the master key | not built |

The commands of sections 4 and 5 (`pkcs11-tool` for the key pair, the public key and the ECDH, and `tools/hsm/card-check.sh`) were run against SoftHSM2, a software
token, with the OpenSC 0.25 tools; the options of `sc-hsm-tool` were checked against that tool's own help. **Nothing was run on the card itself yet**; what depends
on the card is marked [U] (unverified).

## What is bought

- **SmartCard-HSM 4K** (CardContact; Nitrokey sells the same SmartCard-HSM as its HSM 2). Key types RSA up to 4096, ECC up to 521 on GF(p) (P-256, P-384,
  brainpool), AES; ECDH; PIN, no touch; Common Criteria EAL 6+ platform, no certification of the applet (the datasheet says so). 125 KB of flash, enough for
  some tens of RSA-4096 keys or hundreds of AES keys; the master key is one EC key.
- **A reader that speaks CCID with extended APDUs**, for example the OMNIKEY 3121 (`076b:3022`; its descriptor says "Short and Extended APDU level"). The OMNIKEY
  3021 is not good for this card: the CCID project lists it with "No extended APDU", and OpenSC warns that short APDUs break RSA-2048.

## 1. Prepare the host

Any Linux machine that will sit next to the token; it is not the machine of the core.

```bash
sudo apt install pcscd libccid opensc pcsc-tools        # Debian, Ubuntu
sudo systemctl enable --now pcscd
lsusb | grep -i 076b                                     # the reader: 076b:3022 for an OMNIKEY 3121
pcsc_scan                                                # put the card in: the answer-to-reset (ATR) of a SmartCard-HSM appears
opensc-tool --list-readers                               # and the reader is listed
```

The card has a contact and a contactless interface (Dual-IF); the reader uses the contacts. Which way it goes in is printed on the reader's slot.

## 2. Initialise the card

This erases the card and sets its PINs. Do it on a quiet machine; the PINs are typed once and kept as in section 7.

```bash
sc-hsm-tool --initialize --label cinim --so-pin <SO-PIN> --pin <USER-PIN> --dkek-shares 2
```

- **SO-PIN**: the security officer's PIN. It unlocks the user PIN and re-initialises the card. Keep it **offline**, written down, apart from the card. The tool tells
  you the allowed length and characters; the SmartCard-HSM documentation asks for 16 hexadecimal digits [U, from CardContact's documentation].
- **User PIN**: what the `kekd` service will use. Choose a long one; the card blocks it after wrong tries (`--pin-retry` sets the number; the factory number is
  in the tool's output). A blocked PIN is released with the SO-PIN; what happens after wrong SO-PIN tries is in the card's documentation: assume that a blocked SO-PIN
  cannot be released [U].
- `--dkek-shares 2` makes the card ready for the backup of section 5. It is decided here, at initialisation. Without it the private key cannot be backed up at all.

Options verified against the `sc-hsm-tool` of OpenSC 0.25 (`--initialize`, `--label`, `--so-pin`, `--pin`, `--pin-retry`, `--dkek-shares`,
`--create-dkek-share`, `--import-dkek-share`, `--wrap-key`, `--unwrap-key`, `--key-reference`).

## 3. The key shares for the backup (DKEK)

The DKEK ("device key encryption key") is what lets the card export a private key **wrapped**, so that a second card can take it. It is built from shares, each
kept by a different person, each protected by a password. Two shares here:

```bash
sc-hsm-tool --create-dkek-share share-a.pbe --password <PASSWORD-A>
sc-hsm-tool --create-dkek-share share-b.pbe --password <PASSWORD-B>
sc-hsm-tool --import-dkek-share share-a.pbe --password <PASSWORD-A>
sc-hsm-tool --import-dkek-share share-b.pbe --password <PASSWORD-B>
```

Put the two files and the two passwords in **four different places** (two files on two media, two passwords in two heads or two safes). Whoever has both shares and
both passwords and an exported key file can rebuild the key on another card. Whoever has none cannot.

The order (create, then import all, then generate the key) is from the CardContact documentation [U]; run the whole cycle once on a spare card before you trust it.

## 4. Make the master key

One EC P-256 key pair on the card; the private half cannot leave it except wrapped under the DKEK.

```bash
pkcs11-tool --module /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so -l --keypairgen \
  --key-type EC:prime256v1 --usage-derive --label cinim-kek --id 01
# the PIN is asked for; do not give it with --pin on the command line
```

Check it:

```bash
pkcs11-tool --module /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so -l -O          # a private key and a public key with label cinim-kek, ID 01
pkcs11-tool --module /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so -l --read-object --type pubkey --id 01 -o cinim-kek.pub.der
openssl ec -pubin -inform DER -in cinim-kek.pub.der -noout -text            # a 256-bit EC public key
```

`cinim-kek.pub.der` is public; keep it with the deployment notes. Its SHA-256 is the **fingerprint** of the master key, the name by which the secrets will say
which key sealed them.

## 5. The check, and the backup of the key

`tools/hsm/card-check.sh` asks the token for an ECDH with a throw-away key and compares the answer with OpenSSL's own. It is what proves that the card can do the
one thing the master key needs:

```bash
read -s CARD_PIN; export CARD_PIN
tools/hsm/card-check.sh
# 1. the token and its mechanisms  ... ECDH1-DERIVE: offered
# 2. the public key 01 ... fingerprint ...
# 3. the token's shared secret equals the software one (32 bytes): OK
# 4. ... ms per call
unset CARD_PIN
```

Run it the day the card arrives. (Against SoftHSM2 it passes in 15 to 25 ms per call, including the start of `pkcs11-tool`; the card is slower, the datasheet says 60 ms
for an ECDH-256 plus the transfer.)

The backup of the private key to a second card, with the shares of section 3 imported there as well:

```bash
sc-hsm-tool --wrap-key cinim-kek.wrapped --key-reference 1      # on the first card
sc-hsm-tool --unwrap-key cinim-kek.wrapped --key-reference 1    # on the second card, after importing the same two shares
```

The key reference of the key (1 here) is the number the card gave it; `sc-hsm-tool` and `pkcs15-tool --dump` show it [U]. Test the restore on the second card with
`tools/hsm/card-check.sh`: the **fingerprint must be the same**.

## 6. What the card must not be asked for

- The token is used for one operation, ECDH with the master key. Nothing else is needed: no signing, no RSA, no AES.
- The private key is never exported in the clear, whatever the tool's options: it is `sensitive` and `never extractable`.
- The core never sees the private key or the PIN. The PIN is held by the service next to the card.

## 7. Where the PIN and the shares live

- The user PIN: a file readable by the service's user only (`chmod 0400`), or a systemd credential (`LoadCredential=`), never in a unit file, in the process's
  command line, in an environment you export in a shell, or in the shell history. `CARD_PIN` in `tools/hsm/card-check.sh` is for a single run: set it with
  `read -s CARD_PIN; export CARD_PIN` and unset it afterwards.
- The SO-PIN: offline only.
- The DKEK shares and their passwords: section 3.
- `kekd`, when it exists, will run on a machine that nobody else uses, with the reader in a place that is not reachable by people who should not take the card.

## 8. What goes wrong, and what it costs

| | Result |
|---|---|
| The card is lost or broken, there is no backup | the data keys wrapped for it cannot be opened: **every secret of every organisation is lost** (they are entered again with `PUT .../secrets/{NAME}` after a new master key; the pipelines are not lost) |
| The user PIN is blocked | released with the SO-PIN |
| The SO-PIN is blocked | assume the card is lost [U] |
| The reader or the machine is down | the core cannot open data keys it has not cached; running steps that already have their secrets go on; steps that start within the cache time (`CINIM_SECRETS_DEK_CACHE`) still get theirs; later ones wait and then fail with `secrets_unavailable` |
| Someone takes the card and knows the PIN | they can ask it for ECDH, that is, open the secrets that are wrapped for it; they cannot take the key away. Change the master key and the secrets |

Because losing the card loses the secrets, the second card of section 5 is not optional in a setup that matters.

## 9. How the key service knows it is the core that asks

The key service must not open a data key for whoever asks: whoever has a wrapped data key (a backup of the database has them all) and can reach the service could
otherwise have it opened. The private key never leaves the card, but the service is an oracle for it, so its door matters.

- **Mutual TLS, pinned on both sides.** The core trusts exactly the certificate of the key service (`CINIM_KEKD_CA` holds that certificate, or a CA that issues nothing else); the
  service accepts exactly the certificate of the core (its fingerprint is pinned), not "any certificate from our CA", and a name in a certificate proves nothing (a test
  below uses a certificate with the same name and another key). TLS 1.3 only. The core's key and certificate are in a Secret that only the core's Pod mounts (the step Pods are in other
  namespaces and cannot read it); `secrets.kekd.tlsSecret` in the chart. To change the core's certificate, change the pin on the service.
- **Not ZeroMQ.** The ZeroMQ links of the platform (the shim's, the controller's) are encrypted and the server is proven to the client, but the server does not check which client
  it is: that needs a ZAP handler that is not built, and the client key is one for all step Pods. That is acceptable for them (the step has its own credential for its secrets), not for a
  service that holds a master key.
- **Not the address.** Pods leave the cluster with the address of their node, so a filter by address does not tell the core from a step Pod; use it as an extra layer, never as the check.
- **What the service must do besides** (when it is built): open only a data key that it wrapped, for an additional data that begins `cinim/dek/v1|`; limit the operations per minute and
  per day; write down every call (time, the pinned client, the organisation, the result); and have a switch that makes it refuse all, without touching the card.
- **What this does not cover**: a core that is taken over can ask for every data key it has. The limits and the record are there so that it cannot do it unnoticed or all at once,
  and the answer to such an incident is a new master key and new secrets.

Checked with `tests/unit/tkekclient_tls.nim` (the emulator behind `tools/kekd-emu/tls-front.py`, certificates from `tools/kekd-emu/certs.py`): the right pair of certificates works; a
client certificate with the same name and another key, an expired certificate of the right key, and no certificate at all are refused by the service; a service that shows another
certificate for the same address is refused by the core; a core with no certificate to trust refuses the right service. Not yet run in a cluster, with the real `kekd`.

## 10. The emulator, and what is built on the core's side

The core's side is built and tested without the card, against an emulator of the key service (`tools/kekd-emu`, `src/kekd/emulator.nim`). The card's own service
(`kekd`: ECDH on the card, a standard ECDH-ES construction for the wrapped key) is **not built yet**; it will speak the same protocol and replace the emulator.

- **The protocol** (core/kekclient.nim, version 1): `GET /v1/info` gives the fingerprint of the master key; `POST /v1/wrap` and `POST /v1/unwrap` take and give a data key (hex)
  with additional data that binds it to its organisation. Errors that will not pass (`wrong_key`, `damaged`: 409, 422) are told from those that may (`locked`, busy,
  5xx, no answer).
- **In the core**: `CINIM_KEKD_URL` (and the certificates for `https`) selects it; the core starts without waiting and asks again every 15 s; an organisation's opened data key
  is kept for `CINIM_SECRETS_DEK_CACHE` seconds, so that steps that start while the service is down still get their secrets; the service is a component (`kekd`) in
  `/api/v1/components` and `/metrics`; a key service holding another key than the one that sealed the database is refused for good (`secrets_unavailable` with the
  reason), nothing new is written.
- **The emulator** holds the key in memory: from the Secret `--key-secret NAME` (made at the first start), from `--key-file`, or, with neither, a new one at every start, and can be told to misbehave: `POST /emu/fault` with `{"mode": "fDown"}`, `fLocked`, `fThrottle`,
  `fSlow` (with `delay_ms`) or `fNone`; `POST /emu/rekey` is "another card was put in". `deploy/examples/kekd-emu/kekd-emu.yaml` runs it in a cluster, with its key in the Secret `kekd-emu-key` (`--key-secret`: made at the first start, read at every later one, so that a restart does not lose the secrets of a shard) (the `kekd-emu` target
  of `tools/image/Dockerfile.kaniko`). It is not secure and plain HTTP: never for anything that matters.

Checked on a cluster with the emulator over plain HTTP (the mutual TLS of section 9 is tested apart, not in the cluster): a data key opened through it; a step that starts while the service is down gets its secrets from the cache; a core that starts while
it is down answers `secrets_unavailable`, a step started then waits in its shim and runs 19 s later when the service is back; a service with another key than the one that sealed
the database is refused.

Still to do, for the card: `kekd` itself; wrapping to two public keys, so that the spare card opens the secrets without the DKEK dance; rotation of the master key (the data
keys re-wrapped; the secrets themselves are not re-encrypted).
