# Evidence

Raw outputs of the log-store comparison summarised in Appendix A.7 of the specification: five million CI-like log lines, one candidate at a
time (`vlogs.out` VictoriaLogs, `quickwit.out`, `clickhouse.out`, `loki.out`).

A lightweight S3-compatible target for backup tests (A.11) is `s3proxy` (`andrewgaul/s3proxy` with the `transient` backend): one process, no
operator or volume; create the bucket with a signed `PUT /<bucket>` before the first backup.
