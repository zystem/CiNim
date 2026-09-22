# CiNim

Self-hosted CI/CD платформа для Kubernetes на Nim по ТЗ v1.7. Статус: M0 (feasibility).

```bash
nimble test      # юнит-тесты
nimble testsan   # то же под ASan/LSan (E-004)
```

Стенд M0: `deploy/m0/helmfile.yaml` (rqlite и NATS официальными чартами). Интеграционные тесты: `nimble testint`.

Правила работы: тесты первыми, имя теста содержит ID требования, решения в `docs/adr/`.

Транспорт между сервисами: NNG (ADR 0010). Сборка зависимостей: `tools/nng/build_deps.sh $NNG_PREFIX [musl]`, затем `NNG_PREFIX=... nimble testint`.
Привязки к NNG генерируются `tools/nng/gen.sh $NNG_PREFIX/include` (нужен `c2nim`).

Kubernetes из Nim (ADR 0011): официальный C-клиент, `tools/k8s/build_client.sh $K8S_PREFIX`, привязки `tools/k8s/gen.sh $K8S_PREFIX/include/kubernetes`.
Shim: `nim c -d:release --opt:size --gcc.exe:musl-gcc --gcc.linkerexe:musl-gcc --passL:-static --passL:-s -o:build/cicd-shim src/shim/shim.nim`.

Spike 7 (ADR 0012): контракты `proto/` (`buf lint`, `nimble testcontract`), state machines `docs/state-machines.md`, Lua API `lua/stdlib/cicd.d.lua`, threat model `docs/threat-model.md`.
HTTP-слой civetweb: `tools/http/gen.sh $CIVET_PREFIX/include`, шаблоны nimja с обязательным `h()`.
