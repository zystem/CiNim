# OpenBao or Vault that unseals itself with a cloud KMS (AWS, Google Cloud, Azure)

An addition to `../README.md` (read it first: the order of the installation, what the core needs from the service, the Transit key made with `derived=true`, the token). There the unseal is manual and has to be repeated after every restart of the
Pod. Here the **seal** of the service is a key in the cloud KMS of your account: the Pod asks the KMS to open its root key when it starts, nobody types a key, and a restart of the Pod (a node drain, an upgrade) ends with an unsealed service.
**It is an example that this is supported and how to switch it on, not a production recipe**; the service's own documentation is the authority on seals: <https://openbao.org/docs/configuration/seal/>,
<https://developer.hashicorp.com/vault/docs/configuration/seal>.

## What the KMS protects, and what it does not

* The cloud key wraps only the **root key of the service** (the "seal"). The Transit key `cinim-shard`, the one that seals the master secret of the core, still lives in the storage of OpenBao/Vault, wrapped by that root key. The core does not
  talk to the KMS and the KMS does not see the secrets of CiNim.
* So two things are to be kept: **the storage of the service** (its volume, a snapshot of it) *and* **the cloud key**. A service whose cloud key is gone cannot be opened: turn on the deletion protection of the key (a waiting period for AWS KMS and
  Key Vault, a scheduled destruction for Cloud KMS) and give the account that may destroy it as few people as you can.
* The recovery keys that `operator init` prints are not unseal keys any more (the service unseals itself); they are needed for the rare operations that used to need the unseal keys (generating a new root token, changing the seal). Keep them
  as you kept the unseal key.
* A seal that cannot reach its KMS keeps the service sealed (and the core, at its start, waits for the key service). The KMS is in the path of every restart of the service, not of every request of the core.

## The files

| | OpenBao (`openbao/openbao`) | Vault (`hashicorp/vault`) |
|:--|:--|:--|
| AWS KMS | `openbao-aws.yaml` | `vault-aws.yaml` |
| Google Cloud KMS | `openbao-gcp.yaml` | `vault-gcp.yaml` |
| Azure Key Vault | `openbao-azure.yaml` | `vault-azure.yaml` |

Each is the whole `values` of the chart: the listener with the certificate of the shard's CA (`../openbao-tls.yaml`, or `vault-tls.yaml` here), storage, the `seal` stanza with `<placeholders>`, and the way the Pod proves who it is to the cloud
(a Secret with an access key, and in a comment the keyless way of the cloud: IRSA on EKS, Workload Identity on GKE, the managed identity on AKS).

**The difference between the two products.** A Vault has the three seals built in (it is under the BUSL licence; its documentation lists them). An **OpenBao 2.7 has not**: its cloud seals are *plugins* (`openbao/openbao-plugins`, `kms/*`), which the
config names in a `plugin "kms" "<seal name>"` block as an OCI image pinned by digest, and which OpenBao downloads into `plugin_directory` at its start. That needs `ghcr.io` from the Pod; without the network, copy the image to your registry
and name it there. A plugin of the `kms` type can be given in the config only (it must be there while the service is sealed). The stanza of the seal is the same as for a Vault.

## The order

As in `../README.md`, with these changes: the values file of this directory instead of `../openbao-values.yaml`, the Secret with the identity before the Pod, and **init without the unseal**.

```bash
NS=cinim-001
# the release of CiNim, the certificate and the repository of the chart: as in ../README.md (for a Vault, add --set secrets.keyService.url=https://vault:8200 to the release)

# the cloud identity: pick the one of your cloud (or none, on EKS/GKE/AKS with the keyless way named in the file)
kubectl -n $NS create secret generic aws-kms --from-literal=access_key=<id> --from-literal=secret_key=<secret>
# kubectl -n $NS create secret generic gcp-kms --from-file=credentials.json=<the key of the service account>
# kubectl -n $NS create secret generic azure-kms --from-literal=client_id=<id> --from-literal=client_secret=<secret>

helm install openbao openbao/openbao -n $NS -f deploy/examples/openbao/autounseal/openbao-aws.yaml    # edit the <placeholders> first
kubectl -n $NS exec openbao-0 -- bao operator init -recovery-shares=1 -recovery-threshold=1             # prints a recovery key and the root token; there is no unseal step
BAO_TOKEN=<the root token> sh deploy/examples/openbao/setup.sh                                          # as in ../README.md
```

For a Vault the Pod is `vault-0`, the chart `hashicorp/vault` and the Service `vault`:

```bash
kubectl apply -n $NS -f deploy/examples/openbao/autounseal/vault-tls.yaml
helm install vault hashicorp/vault -n $NS -f deploy/examples/openbao/autounseal/vault-aws.yaml
kubectl -n $NS exec vault-0 -- vault operator init -recovery-shares=1 -recovery-threshold=1
POD=vault-0 CLI=vault BAO_TOKEN=<the root token> sh deploy/examples/openbao/setup.sh
```

Then delete the Pod once and see that it comes back unsealed (`status` says `Sealed false` and the `Seal Type` of the cloud); that is the check that the identity and the key are right. A Pod that stays sealed says why in its log
(`kubectl logs openbao-0`): a credential that was not found, a key that the identity may not use, a region.

## What each cloud needs

* **AWS KMS**: a symmetric key (`ENCRYPT_DECRYPT`) and an identity with `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` on it. `kms_key_id` is the key id, its ARN or `alias/<name>`. A cluster that is not in AWS uses the access key of an IAM user
  limited to that one key.
* **Google Cloud KMS**: a key ring and a symmetric key; the service account has `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key and the permission `cloudkms.cryptoKeys.get` (`roles/cloudkms.viewer`).
* **Azure Key Vault**: an RSA key (the seal wraps the root key with it) and an identity that has the operations `get`, `wrapKey`, `unwrapKey` on it (the role "Key Vault Crypto Service Encryption User" with RBAC, or an access policy).
  The seal takes `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` from the environment, or the managed identity of the node.

## What was checked, and what was not

* **AWS** (OpenBao 2.7.2 with the `kms-aws` plugin v0.1.1, and Vault 2.2.1) against `moto`, an emulator of the AWS API: the plugin is downloaded by its digest and loaded, `operator init` with recovery shares, and after a restart of the
  process the service was unsealed by itself (`Seal Type awskms`, `Sealed false`; the emulator counted the calls to the KMS). Not against a real AWS account, and not with IRSA.
* **Google Cloud and Azure** with OpenBao 2.7.2: the images of the plugins `kms-gcp` and `kms-azure` v0.1.1 are downloaded by the digests in the files, the plugins are loaded and the stanzas are accepted; the service then
  stops at the first call to the cloud (no credentials, no such Key Vault). **No real Cloud KMS or Key Vault was used**; the Vault variants of both clouds were not run at all.
* The six `values` files and `vault-tls.yaml` render with the real charts (`helm template` of `openbao/openbao` and `hashicorp/vault`); **none was installed in a cluster** (the plugin directory as an `emptyDir` that the Pod can write,
  cert-manager's certificate, the identities of EKS/GKE/AKS are not tried).
* The core was not run against these services here; what it needs from a Vault/OpenBao is in `../README.md` (tried there on OpenBao 2.7.2).
