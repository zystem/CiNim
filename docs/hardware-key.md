# The master key of the step secrets on a SmartCard-HSM

The step secrets of an organisation are sealed in the shard's database (D-45, docs/secrets-masking.md). A data key per organisation seals them, and a **master
key** wraps the data keys. By default the master key is a file or is derived from the core's CURVE key. This page is about keeping it on a hardware token, so
that the key that opens everything is on a device that cannot give it away.

What exists today and what does not:

| | State |
|---|---|
| Master key from a file (`CINIM_SECRETS_KEY_FILE`) or derived from the CURVE key | built |
| `KekProvider` seam in `core/kekprovider.nim` (wrap, unwrap, key id, "may pass or final" failures) | built |
| The core's client of a key service next to the token (`CINIM_KEYSERVICE_URL`, the Transit API, mutual TLS, retry, cache, a component in `/api/v1/components`) | built, tested against a stand-in and against the real service with a software token (sections 9 and 10) |
| The service itself, **hsmgate** (a project of its own, section 9), with ECDH on the card | built; run on this card by the owner (the unwrap, the audit); the core on it in a cluster: not yet |
| Wrapping a data key for two cards at once (a spare), rotation of the master key | not built |

The commands of sections 4 and 5 (`pkcs11-tool` for the key pair, the public key and the ECDH, and `tools/hsm/card-check.sh`) were run against SoftHSM2, a software
token, with the OpenSC 0.25 tools; the options of `sc-hsm-tool` were checked against that tool's own help. What depends on the card is marked [U] (unverified).

**Run on a card (2026-10-19, SmartCard-HSM 4K, firmware 4.1, OMNIKEY 3x21 reader, initialised with `--dkek-shares 2` and one key domain in use):** `tools/hsm/card-check.sh` passes: `ECDH1-DERIVE` is
offered, the token's shared secret equals OpenSSL's, 391 ms per call including the start of `pkcs11-tool` and the login (the card itself is about 60 ms). Things that were different from this page:
the card is initialised and its shares imported and the key made with the *Smart Card Shell* key manager (CardContact), which gives the key its own label and an ID that is a SHA-1 in hex (not `01`), so
`KEY_ID=<that id> tools/hsm/card-check.sh`; `sc-hsm-tool` without arguments shows `DKEK shares` and the key check value of the DKEK (compare them on the second card), but it does not see key domains
and says "Data object not found" for a card that uses them until the shares are imported; the key reference of the key is 1 (`pkcs15-tool --list-keys`). The backup (`--wrap-key`) and the restore on a
second card are not yet tried.

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
- **User PIN**: what the key service (hsmgate) uses. Choose a long one; the card blocks it after wrong tries (`--pin-retry` sets the number; the factory number is
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
- The key service runs on a machine that nobody else uses, with the reader in a place that is not reachable by people who should not take the card.

## 8. What goes wrong, and what it costs

| | Result |
|---|---|
| The card is lost or broken, there is no backup | the data keys wrapped for it cannot be opened: **every secret of every organisation is lost** (they are entered again with `PUT .../secrets/{NAME}` after a new master key; the pipelines are not lost) |
| The user PIN is blocked | released with the SO-PIN |
| The SO-PIN is blocked | assume the card is lost [U] |
| The reader or the machine is down | the core cannot open data keys it has not cached; running steps that already have their secrets go on; steps that start within the cache time (`CINIM_SECRETS_DEK_CACHE`) still get theirs; later ones wait and then fail with `secrets_unavailable` |
| Someone takes the card and knows the PIN | they can ask it for ECDH, that is, open the secrets that are wrapped for it; they cannot take the key away. Change the master key and the secrets |

Because losing the card loses the secrets, the second card of section 5 is not optional in a setup that matters.

## 9. The key service: hsmgate

The service that holds the card and answers the core is a project of its own, **hsmgate** (github.com/zystem/hsmgate; its documentation: the Transit API, the operations guide, the threat model, the page of the SmartCard-HSM). It speaks the
**Transit API** of Vault and OpenBao, so that the core's client (`core/transitclient.nim`), OpenBao (`seal "transit"`) and `vault-kubernetes-kms` (etcd encryption) use the same service. What it does for the core, and what the core needs from it:

- **The door.** TLS 1.3 with a **client certificate required**, identified by a URI SAN, a pin or a CN that the service's policy maps to a client (the service no longer sits behind a TLS front and believes a header). A client may use only the keys and
  operations (`encrypt`, `decrypt`, `rewrap`) that its policy lists, with the contexts it lists, at the rates it lists; everything else is refused and written to the audit. The ZeroMQ links of the platform do not check which client is on the
  other side and the address of a Pod is not an identity, so neither is used for this. A token that a Vault client presents is never an authentication.
- **The key.** The shard's master key is a key of the service under a name (`cinim-shard` by default: `secrets.keyService.keyName`). It must let the core use the contexts **`cinim/dek/v1|<tenant>`** (the additional data of an organisation's data key) and
  **`cinim/kek-check/v1`** (the check text of the vault): `aad: {mode: context, allow: ["cinim/dek/v1|", "cinim/kek-check/v1"]}`. The service seals with the master public key (it needs no PIN to wrap) and opens with the card; the card does only the ECDH,
  so a card without AES works.
- **Failures.** The service says in `X-Hsmgate-Retryable` whether a failure may pass (a locked card, a rate limit, a card that is out: yes; a wrong key, a wrong context, a key that is not granted: no). The core reads it, and, for a service that does not say
  (Vault, OpenBao), takes 429, 5xx and no answer as passing and the other statuses as final. A failure that may pass leaves `secrets_unavailable` for the shims to wait out; a final one stops the core's secret store and a person must look.
- **What the core cannot do against it**: a core that is taken over can ask for every data key it has. The limits and the audit are there so that it cannot do it unnoticed or all at once; the answer to such an incident is a new master key and new secrets.

## 10. What is built on the core's side

- `core/transitclient.nim` (the provider of `core/kekprovider.nim` over the Transit API: `GET keys/<name>` once, `PUT encrypt/<name>` and `decrypt/<name>` with the context), `core/vaultsetup.nim` (the choice of the master key at start: the key service, a key file, or derived from
  the CURVE key; the core does not wait for the service, a thread asks every 15 s; a component `keyservice` in `/api/v1/components` and `/metrics`; an organisation's opened data key is kept for `CINIM_SECRETS_DEK_CACHE` seconds, so that steps that
  start while the service is down still get their secrets; a service whose key is not the one that sealed the database is refused for good with the reason, and nothing new is written).
- Settings: `CINIM_KEYSERVICE_URL`, `_KEY_NAME`, `_MOUNT`, `_CA`, `_CERT`, `_KEY`, `_TOKEN_FILE`, `_PROXY`, `_TIMEOUT_MS` (docs/settings.md; the proxy, a CONNECT one such as tinyproxy, is for a cluster with no road to the service: the TLS runs through it, from the core to the service; the core makes the CONNECT itself, `common/connecthttp.nim`, because the `std/httpclient` of Nim 2.2.6 writes a wrong request line inside the tunnel, and the proxy is told to allow one host and port only: `ConnectPort`, a `Filter` of `host:port` with `FilterURLs On` and `FilterDefaultDeny Yes`, so that a plain HTTP request to the host is refused too); the chart value `secrets.keyService` (the address, the key's name, a Secret with `ca.crt`, `tls.crt`, `tls.key`).
- Tests: `tests/unit/ttransitclient.nim` (the client against a stand-in with faults: `tests/support/transitemu.nim`: locked, throttled, down, slow, another key put in, a service that does not say whether a failure may pass; a proxy that refuses CONNECT: `tests/support/connectproxy.nim`), and, with the real service when
  `HSMGATE_BIN=<path>` is set (they are skipped without it): `thsmgate.nim` (the core's contexts accepted, other ones refused, the audit), `tests/integration/tkeyservice.nim` (the secrets store as at the core's start, with rqlite: the check text, a tenant's data key, a secret put and read, a restarted service, another key refused for good, no service: waits) and `thsmgate_tls.nim` (mutual TLS: the right pair works; a client certificate of a CA the service does not trust, a
  name the policy does not know, and no certificate are refused; a service with a certificate of another CA is refused by the core; a core with no CA refuses the right service; certificates made by `tests/support/mkcerts.sh`; and the whole thing through a CONNECT proxy).
- **Run (2026-10-19)**: both real-service test files pass against hsmgate with a software token (plain HTTP and mTLS). **Not run**: the core against hsmgate on the card in a cluster (the cluster behaviours below were seen with the earlier emulator, over
  a protocol that is gone, and are to be repeated), a core restart while the service is away, a rotation of the master key (`rewrap` of every organisation's data key, not built in the core).
- Seen earlier on a cluster with the emulator, and expected to hold: a data key opened through the service; a step that starts while the service is down gets its secrets from the cache; a core that starts while it is down answers `secrets_unavailable`, a
  step started then waits in its shim and runs when the service is back; a service with another key than the one that sealed the database is refused.

## 11. Other uses of the same card

The card holds the key of hsmgate (EC P-256, ECDH). Other things can use it through hsmgate's Transit face without another key: OpenBao unsealed by the card (`seal "transit"`, with or without a network between them) and the encryption of Kubernetes' etcd by
`vault-kubernetes-kms`; both were run (see the hsmgate documentation). OpenBao's own PKCS#11 seal (the card in the OpenBao machine, no service) needs an **RSA** key on the card: the seal takes `RSA_PKCS_OAEP` or `AES_GCM` only, and the card has no AES-GCM
(its AES is CBC and CMAC). `tools/hsm/rsa-oaep-check.sh` (with `PIN_FILE=...` when there is no terminal) encrypts in software and decrypts on the card with OAEP SHA-256: it worked on a 4096-bit key made with the algorithms
`RSA_DECRYPT_RAW,RSA_DECRYPT_OAEP` (OpenSC does the OAEP padding in software over the raw decryption); OpenBao v2.6.1 with the `kms-pkcs11` plugin unsealed by itself after a restart. The token's label for OpenSC is `cinim (UserPIN)`
(`pkcs11-tool -L`), not `cinim`. Two programs that log in to the same card at once did not disturb each other.
