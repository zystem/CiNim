# Spike: rqlite state backup/restore via S3, VictoriaLogs RPO at total loss

Not a script suite (the test was interactive, against throwaway Kubernetes resources: namespaces `rqlite-bkp-test`,
`minio-bench` on `admin@home`, deleted after the run). Findings recorded in `docs/adr/0019-backup-restore-s3.md`.

Reusable pieces if repeated:
- rqlite: native `-auto-backup`/`-auto-restore` flags with a JSON config (`type: s3`, `interval`, `sub: {access_key_id,
  secret_access_key, endpoint, region, bucket, path, force_path_style}`). No custom backup tool needed (rqlite docs,
  https://rqlite.io/docs/guides/backup/).
- VictoriaLogs: `POST /internal/partition/snapshot/create`, then copy the snapshot directory to S3 with any S3 client
  (tested with `mc mirror`); restore by placing the same tree under `<-storageDataPath>/partitions/<name>/` before the
  node starts (an init container in the test).
- MinIO as the S3-compatible target: the current `bitnami/minio` chart pulls images that need a paid subscription
  (`ErrImagePull`, HTTP 500 from the registry); used the official `quay.io/minio/minio` image directly instead (no
  standalone chart is published by MinIO any more, only the heavier Operator+Tenant chart).

## Update: use s3proxy, not MinIO

Owner feedback (2026-09-22): MinIO is overkill for a test S3 endpoint. Re-verified locally with
`andrewgaul/s3proxy` (`docker run -e S3PROXY_AUTHORIZATION=aws-v2-or-v4 -e S3PROXY_IDENTITY=... -e S3PROXY_CREDENTIAL=... -e JCLOUDS_PROVIDER=transient -p PORT:80 andrewgaul/s3proxy`):
rqlite `-auto-backup` uploaded (24 ms) and `-auto-restore` downloaded and restored (63 ms) against it exactly like
against MinIO; `mc` also works unchanged. s3proxy needs the bucket created (plain signed `PUT /<bucket>`) before the
first backup attempt — its `transient` backend starts empty every run, unlike a persistent MinIO volume. Prefer
s3proxy for future S3-target spikes: one process, no operator/PVC, in-memory backend available.
