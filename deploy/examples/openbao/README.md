# CiNim with an OpenBao (or a Vault) for the key of the step secrets

A minimal example of the second way to give the shard its key (D-106): not the hsmgate of the release but an **OpenBao** (a Vault does the same) with the Transit engine. One Pod, TLS from the CA of the shard, the key
made by hand. **It is an example that this is supported and how to switch it on; it is not a production recipe.** How to run OpenBao properly (storage, several nodes, auto-unseal, backups) is OpenBao's own
documentation: <https://openbao.org/docs/>. The unseal here is manual, as that documentation describes it, and has to be repeated after every restart of the Pod.

What the core needs from the service, and what is tried at its start:

* the Transit engine and a key **made with `derived=true`**. The core binds every sealed text to its organisation by the `context` of the call; a key that is not derived *ignores* the context, a text sealed for one organisation then
  opens for another, and the core refuses such a key at its start and says why (tried on OpenBao 2.7.2: a plain key opens a text with a wrong context, a derived one answers `message authentication failed`);
* a token that may `update` `transit/encrypt/<key>`, `transit/decrypt/<key>` and `transit/rewrap/<key>` and `read` `transit/keys/<key>`, nothing else (`policy.hcl`);
* **the token does not expire during the life of the shard:** the core sends it and does not renew it, and does not log in (no AppRole, no Kubernetes auth). The example makes a token of 10 years (`setup.sh` raises the limit of the token
  engine to that); a token that lapses stops the core at its next start and the secrets cannot be opened until a new one is in the Secret. Renewal and a login by the core are not built.

**A service that unseals itself** with a cloud KMS (AWS, Google Cloud, Azure; OpenBao or Vault) instead of the manual unseal: `autounseal/README.md`.

## The order

The release of CiNim goes first, with the key service named in `cinim-values.yaml`: it makes the CA of the shard (the Issuer `cinim-ca`) that OpenBao's certificate is issued by. The core waits for the key service and restarts until it answers
(`CrashLoopBackOff` with a growing pause is how it waits), so it may be installed first.

```bash
NS=cinim-001
helm install cinim-001 deploy/charts/cinim-shard -n $NS --create-namespace -f deploy/examples/openbao/cinim-values.yaml \
  --set-string shard=001 --set image.repository=<registry>/cinim --set domain=ci.example.com

kubectl apply -n $NS -f deploy/examples/openbao/openbao-tls.yaml          # the certificate of OpenBao, from the CA of the shard
helm repo add openbao https://openbao.github.io/openbao-helm
helm install openbao openbao/openbao -n $NS -f deploy/examples/openbao/openbao-values.yaml

# init and unseal, as <https://openbao.org/docs/platform/k8s/helm/run/> describes (one key share here: keep what it prints, and unseal again after every restart of the Pod)
kubectl -n $NS exec openbao-0 -- bao operator init -key-shares=1 -key-threshold=1
kubectl -n $NS exec openbao-0 -- bao operator unseal <the unseal key>

# the engine, the key, the policy, the token, and the two Secrets that the core takes (bao-ca, bao-token); the root token that init printed
BAO_TOKEN=<the root token> sh deploy/examples/openbao/setup.sh
```

The core starts when the key service answers; the line `core: the master secret is kept in the database, sealed by the key transit:cinim-shard` in its log is the proof. The master secret of the core is sealed by this key like the step secrets
are, so a backup of the database and the key of the service is everything there is to back up.

## What to know

* **Back up OpenBao as OpenBao says** (its storage and the unseal key). A shard whose service has lost the key cannot read its secrets.
* The example does not give OpenBao a NetworkPolicy; do, when the cluster has them: only the core needs to reach port 8200.
* A Vault is the same with its own chart and `vault` for `bao`.
* The key is named `cinim-shard` (`secrets.keyService.keyName`) and the engine `transit` (`secrets.keyService.mount`, empty is `transit`).
