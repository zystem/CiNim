# 0002. Стенд M0 в кластере admin@home

- Статус: accepted (стенд); результаты spike 1 в ADR 0004
- Связанные ID: D-02, D-03, 7.2 `[M0-CHECK]`

## Стенд

- Кластер `admin@home`: Talos, Kubernetes v1.34.1, 6 узлов, StorageClass `directpv-min-io` (RWO, WaitForFirstConsumer).
  RWX нет: для STO-001 действует вариант RWO с закреплением Pod run за узлом (Q-11).
- rqlite: `deploy/m0/helmfile.yaml` (чарт `rqlite/rqlite` 2.0.0, namespace `rqlite`, 3 узла, PVC 10Gi).
  Чарт заявляет 9.1.3, но `image.tag: latest` тянет rqlite v10.3.5 (SQLite 3.53.4). Для воспроизводимости тег надо пинить.
- NATS JetStream: `deploy/m0/helmfile.yaml` (официальный чарт `nats/nats` 2.14.6, namespace `nats`, 1 узел, JetStream, PVC 10Gi). Мой самописный манифест заменен чартом.
- Самописный манифест rqlite (namespace cinim-m0, удален) не заработал: образ сам добавляет каталог данных, тома directpv принадлежат root
  (нужен `fsGroup`). Заменен рабочим чартом.

## Результаты spike 1

См. [ADR 0004](0004-spike1-rqlite-state-store.md).
