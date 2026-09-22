# Spike 5 tools (ZincSearch fork)

Measurement tools for ADR 0014. Everything runs locally against a copy of the fork (`feat/stream-replication-and-coordinator`),
nothing here is product code.

- `loadgen/main.go`: Go load generator (copy it to `<fork>/cmd/loadgen`, `go build`). Publishes CI-like log lines as `docs` messages to the
  JetStream stream; `-variant 1..9` selects the index schema, `-padid` uses `job:0000000123` ids, `-rate` limits lines/s, `-probe N` measures
  publish-to-searchable latency.
- `schema_variants.sh`, `window_bench.py` (window by id-prefix blocks), `window_bench_ln.py` (window by numeric `ln` range),
  `export_bench.py`, `search_bench.py`: disk/speed per schema variant, window latency, export and search.
- `failover.sh BINDIR`, `backup_restore.sh BINDIR`: failover, backup, verification and restore with the Go coordinator (needs `nats-server`).
- `pub_probe.c`: JetStream async publish throughput through nats.c.
