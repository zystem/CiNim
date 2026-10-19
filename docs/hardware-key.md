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
| The service itself, `kekd` (`src/kekd`, section 11), with ECDH on the card | built; the cryptography and the door are tested with a software key, the card's public part and its fingerprint are read from the real card; the login and the ECDH on the card are run by the owner with `tools/hsm/kekd-card-test.sh` |
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
- `kekd` runs on a machine that nobody else uses, with the reader in a place that is not reachable by people who should not take the card.

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
(`kekd`, section 11: ECDH on the card, a standard ECDH-ES construction for the wrapped key) speaks the same protocol and replaces the emulator.

- **The protocol** (core/kekclient.nim, version 1): `GET /v1/info` gives the fingerprint of the master key; `POST /v1/wrap` and `POST /v1/unwrap` take and give a data key (hex)
  with additional data that binds it to its organisation. Errors that will not pass (`wrong_key`, `damaged`: 409, 422) are told from those that may (`locked`, busy,
  5xx, no answer).
- **In the core**: `CINIM_KEKD_URL` (and the certificates for `https`) selects it; the core starts without waiting and asks again every 15 s; an organisation's opened data key
  is kept for `CINIM_SECRETS_DEK_CACHE` seconds, so that steps that start while the service is down still get their secrets; the service is a component (`kekd`) in
  `/api/v1/components` and `/metrics`; a key service holding another key than the one that sealed the database is refused for good (`secrets_unavailable` with the
  reason), nothing new is written.
- **The emulator** holds the key in memory: from the Secret `--key-secret NAME` (made at the first start), from `--key-file`, or, with neither, a new one at every start, and can be told to misbehave: `POST /emu/fault` with `{"mode": "fDown"}`, `fLocked`, `fThrottle`,
  `fSlow` (with `delay_ms`) or `fNone`; `POST /emu/rekey` is "another card was put in". `deploy/examples/kekd-emu/kekd-emu.yaml` runs it in a cluster, with its key in the Secret `kekd-emu-key` (`--key-secret`: made at the first start, read at every later one, so that a restart does not lose the secrets of a shard) (the `kekd-emu` target
  of `tools/image/Dockerfile.kekd-emu`). It is not secure and plain HTTP: never for anything that matters.

Checked on a cluster with the emulator over plain HTTP (the mutual TLS of section 9 is tested apart, not in the cluster): a data key opened through it; a step that starts while the service is down gets its secrets from the cache; a core that starts while
it is down answers `secrets_unavailable`, a step started then waits in its shim and runs 19 s later when the service is back; a service with another key than the one that sealed
the database is refused.

Still to do, for the card: wrapping to two public keys, so that the spare card opens the secrets without the DKEK dance; rotation of the master key (the data
keys re-wrapped; the secrets themselves are not re-encrypted).

## 11. `kekd`: the key service of the card

`src/kekd` (the program `kekd`, `src/kekd/main.nim`), the protocol of section 10.

- **The construction** (`ecies.nim`): ECDH-ES on P-256. To **wrap**, the service needs the master *public* key only (so it wraps with the card out, and a spare card needs no ceremony to
  receive new keys): it makes an ephemeral key pair in software (OpenSSL, `ossl.nim`), `Z` = ECDH(ephemeral, master public), `K` = HKDF-SHA256(`Z`, salt `cinim/kek/v1`, info
  `cinim/kek/v1|<fingerprint>|<ephemeral point, hex>` and a byte `01`), and seals the data key with XChaCha20-Poly1305 (libsodium) under `K`, the additional data being the one the core gave.
  The text is `ecies1.<fingerprint, 64 hex>.<ephemeral point, 65 bytes, hex>.<nonce 24 || ciphertext || tag, hex>`. To **unwrap**, the card does `Z` = ECDH(master private, ephemeral point)
  (PKCS#11 `C_DeriveKey`, `CKM_ECDH1_DERIVE`, no KDF: the raw 32 bytes); the rest is the same. A point that is not on the curve is refused before the card sees it; the fingerprint in the text
  is compared with the service's own first (`wrong_key`, 409, without asking the card); a tag that does not verify is `damaged` (422).
- **The fingerprint** of the master key is the SHA-256 of its DER SubjectPublicKeyInfo: the number that `tools/hsm/card-check.sh` prints, and the `key_id` of `GET /v1/info`
  (the core names its provider `kekd:<fingerprint>`).
- **The card** (`pkcs11.nim`): the PKCS#11 module of OpenSC (`opensc-pkcs11.so`) is loaded with `dlopen`, so the program is built, or at least run, on the machine whose OpenSC it will use
  (not in the static core's image); the layout of the module's function table is checked against its exported symbols at the start, and a module that does not match is refused. The
  token is found by its label (`--token-label`), the key pair by its `CKA_ID` (`--key-id`). The PIN is read from `--pin-file` once, and **tried once**: if the card refuses it the service
  answers `locked` (423) until it is started again, never retries (the card blocks after three wrong tries). A card that is taken out is `unavailable` (503, may pass) and is found again.
- **The door** (`service.nim`, section 9): only additional data that begins with `cinim/dek/v1|` is wrapped or opened (422 `bad_aad` otherwise: the service is no oracle for anything else);
  `--per-minute` and `--per-day` limits (429 `busy`); `--disable-file`: while that file exists everything is refused with 503 and the card is not touched (the switch of section 9);
  every call is a JSON line in `--audit-file` (or the standard output): time, the client that the TLS front named in `--client-header`, operation, additional data, result; never a key or the PIN.
- **Start**:  `kekd --key-id <CKA_ID> --pin-file <file> [--port 8443] [--public-key-file kek.pub.der] [--audit-file ...] [--disable-file ...] [--client-header x-client]`. With
  `--public-key-file` (DER, `pkcs11-tool --read-object --type pubkey`) it starts and wraps with the card out, and a card in the reader that holds another key is refused at the start. It
  listens on **every** address, in plain HTTP (GuildenStern has no bind option): run it behind the TLS front with client certificates of section 9 and close the port to everything else. Under systemd
  give the PIN as `LoadCredential=pin:/etc/cinim/card-pin` and `--pin-file ${CREDENTIALS_DIRECTORY}/pin`.
- **Tests**: `tests/unit/tkekdecies.nim` (a software key stands for the card: fingerprint equal to OpenSSL's, round trip, another additional data, another key, tampering, invalid points, a card that is
  not there), `tests/unit/tkekdservice.nim` (the door, the audit, the answers the core tells apart, and the core's own `httpKek` against the running service). **On the real card**: the public key
  was read and its fingerprint equals the card-check one, and `info` and `wrap` work through the program (no PIN, no login). The login and the ECDH on the card are checked by
  `tools/hsm/kekd-card-test.sh` with your PIN in a file you make yourself (the script prints the time of an unwrap, the round trip, the refusals and the audit).

## 12. OpenBao unsealed by the same card (PKCS#11 seal)

Tried with OpenBao v2.6.1 and the plugin `kms-pkcs11` v0.2.1 (openbao-plugins; the seal is built in only up to v2.6.x and a plugin from v2.7.0), the OpenSC module, on this card.
It is a second use of the card, next to `kekd`: the card unseals an OpenBao, `kekd` opens the data keys of CiNim.

- **The key**: the seal cannot use the EC key of `kekd` (it takes `RSA_PKCS_OAEP` or `AES_GCM` only) and the card has no AES-GCM (its AES is CBC and CMAC; the OpenSC module offers none). Make an RSA-4096 pair on the card, with the
  algorithms `RSA_DECRYPT_RAW,RSA_DECRYPT_OAEP` (OpenSC does the OAEP padding in software over the raw decryption), label `openbao`, in the DKEK domain as the first key was, and keep its backup like the first one's.
  `tools/hsm/rsa-oaep-check.sh` (with `PIN_FILE=...` when there is no terminal) encrypts in software and decrypts on the card with OAEP SHA-256 (and SHA-1): both worked, about 1 s with the login.
- **The configuration**: the plugin is declared and the seal is named like it (the library path is plain here; the plugin has `-alias name=path` and `BAO_PKCS11_ALIASES` to forbid plain paths):

      plugin_directory = "/path/to/plugins"
      plugin "kms" "pkcs11" { command = "openbao-plugin-kms-pkcs11"  version = "v0.2.1"  sha256sum = "<of the binary>" }
      seal "pkcs11" {
        lib           = "/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so"
        token_label   = "cinim (UserPIN)"      # OpenSC adds " (UserPIN)" to the label of the token: `pkcs11-tool -L`
        key_label     = "openbao"
        mechanism     = "RSA_PKCS_OAEP"
        rsa_oaep_hash = "sha256"
        pin           = "file:///path/to/pin-file"       # a file, not the configuration or the environment
      }

- **What was run**: `bao operator init -recovery-shares=1` unsealed the server with the card; a secret written, the server stopped and started again: it unsealed by itself (the decryption on the card) and gave the secret back.
  A `kekd` with its own login ran on the card at the same time (a wrap, an unwrap, the test of `kekd-card-test.sh`) and an OpenBao restart did not disturb it, nor it the restart.
- **Not run**: a server of several nodes (Raft), a real deployment (the plugin is a dynamically linked binary that loads the OpenSC module: it runs on the machine with the reader, not in a container without `pcscd`),
  the restore of this key from its backup on the second card, a wrong PIN (do not try: the seal and `kekd` each log in, and three wrong attempts block the card).

## 13. OpenBao unsealed through `kekd` (the Transit face), also from another machine

Section 12 needs the card on the machine of OpenBao. For OpenBao on another machine `kekd` has a **Transit face**: the two calls of the seal `transit` of OpenBao (`PUT /v1/<mount>/encrypt/<key>`,
`PUT /v1/<mount>/decrypt/<key>`), answered like the Transit engine. Nothing is installed on the OpenBao side: the seal `transit` is built in, there is no plugin. The state of the search that led here
(ready-made things first): OpenBao has the seals `kmip` (needs a KMIP server over the card: the Eviden KMS names the SmartCard-HSM, not tried), `transit` (this), and the plugins of its `openbao-plugins` collection
(AWS, Azure, GCP, Alibaba, OCI, OVH, T Cloud, Securosys, PKCS#11); the clouds' protocols need SigV4, OAuth or request signing with a key, Transit needs none; no open server of any of them stands on a PKCS#11 card.

- **Start** `kekd` with `--transit-key bao-seal` (repeatable; without it the face is off; `--transit-mount` if OpenBao's `mount_path` is not `transit`).
- **OpenBao**:

      seal "transit" {
        address         = "https://kekd.example:8443"      # the TLS front of section 9
        key_name        = "bao-seal"
        mount_path      = "transit/"
        disable_renewal = "true"                           # there is no token to renew
        tls_ca_cert     = "/etc/openbao/kekd-ca.pem"
        tls_client_cert = "/etc/openbao/client.pem"        # the client certificate that the front lets in
        tls_client_key  = "/etc/openbao/client.key"
      }

  No `token`: **the token is not looked at**; who may call is decided by the front's client certificates (section 9), and `--client-header` puts the client's name in the audit.
- **What it does**: the ciphertext is `vault:v1:` and the base64 of the wrapped text of section 11; the additional data is `openbao/seal/v1|<key name>`, so the core's door (`/v1/wrap`, `/v1/unwrap`: only `cinim/dek/v1|`) cannot open what OpenBao sealed, and
  the face cannot open the core's data keys. The switch, the limits and the audit (`transit-encrypt`, `transit-decrypt`) are the same as for the core. An unknown key name is 404; a ciphertext that does not open is 400; a locked or absent card is 503
  (the client of OpenBao tries again).
- **Run**: OpenBao v2.6.1 with this `kekd` on the card, plain HTTP on one machine: `bao operator init -recovery-shares=1` unsealed with the card, a secret was written, the server stopped and started again: it unsealed by itself (the decryption on the
  card, the audit lines `transit-decrypt`) and gave the secret back. Unit tests: `tkekdservice` (the face, the other door, the switch, the limit, the audit, the HTTP routes).
- **Not run**: the same through the TLS front with client certificates and across a network (the seal's options `tls_*` are in the config but were not tried), a server of several nodes, and what OpenBao does when `kekd` is not reachable at its start
  (it does not unseal and tries again; a restart of OpenBao while the key service or the card is away leaves it sealed until they are back).
