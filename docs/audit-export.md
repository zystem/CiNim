# Sending the audit log to other systems (D-97)

The audit log of the shard (`audit_log`, kept 90 days; who did what to whom and how it ended) can go to the systems that watch it. Three ways, all driven by the **cursor** of each sink: the core
sends what is newer than the last event the receiver took, so an event is delivered at least once and in order.

| Way | How |
|---|---|
| syslog over UDP or TCP | `PUT /api/v1/audit/sinks/wazuh {"url": "syslog+udp://wazuh-manager.example:514"}` (`syslog+tcp://` for TCP). One line to an event, RFC 3164, tag `cinim-audit`, the event as JSON after it. |
| HTTP | `PUT /api/v1/audit/sinks/siem {"url": "https://siem.example/in", "token_env": "CINIM_AUDIT_TOKEN_SIEM"}`: lines of JSON, `Content-Type: application/x-ndjson`, `Authorization: Bearer <the variable>`. The variable is set on the core from a Secret of Kubernetes; its name must begin `CINIM_AUDIT_TOKEN_`. |
| fetch | `GET /api/v1/audit/export?after=<id>&limit=500`: the same lines, the oldest first; the id of the last is in `X-Audit-Last-Id`. |

A new sink starts at the newest event; `"from_start": true` sends everything that is kept. `GET /api/v1/audit/sinks` shows each sink, its cursor, when it last succeeded and the last error.
`PUT` and `DELETE` need `audit.export` (the shard\'s administrators), `GET` needs `audit.read`.

One event:

```json
{"id":12,"time":"2026-10-30T09:15:04Z","at":1793351704,"source":"cinim","type":"audit","actor":"user:ann","action":"access","target":"DELETE /api/v1/runs/x","outcome":"denied","detail":"needs run.delete"}
```

`outcome` is `ok`, `failed`, `denied`, `throttled`, `no_role`... The old and the new value of a variable (`before`, `after`) are never sent; `"changed": true` says there were.

## Wazuh

Wazuh has no HTTP intake for events: its manager takes logs from agents and from its **syslog listener**. So the way is syslog.

1. On the manager, allow the core to send (in `ossec.conf`):

   ```xml
   <remote>
     <connection>syslog</connection>
     <port>514</port>
     <protocol>udp</protocol>
     <allowed-ips>10.0.0.0/8</allowed-ips>
   </remote>
   ```

2. Copy `deploy/examples/wazuh/cinim_decoders.xml` to `/var/ossec/etc/decoders/` and `cinim_rules.xml` to `/var/ossec/etc/rules/`, and restart the manager.
3. `PUT /api/v1/audit/sinks/wazuh {"url": "syslog+udp://<manager>:514"}`.

What was checked (Wazuh 4.9.2): the lines of the formatter through `wazuh-logtest`, and sent by UDP to a manager with the listener above; the alerts 100500 (every event), 100501 (denied), 100502 and 100503
(wrong password, throttled) and 100510 (access changed) were raised. Two things learned: the priority `<134>` is removed by the listener, so the pre-decoder finds the host and the program name;
`action` and `id` are static fields of Wazuh, so a rule cannot name them with `<field>`: the rules look for the action in the text of the event (`<match>"action":"login"</match>`).

Not checked: TCP to Wazuh, other collectors (Filebeat, Vector, Loki, Splunk HEC).
