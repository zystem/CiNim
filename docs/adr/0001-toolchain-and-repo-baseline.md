# 0001. Toolchain и базовая структура репозитория

- Статус: accepted (частично: spike'и M0 не выполнены)
- Связанные ID: D-01, E-003, E-004, Q-04

## Контекст

Спека v1.7 требует Nim 2.x с ORC, статические бинарники, метрики RSS/`getOccupiedMem`
и вариант сборки с AddressSanitizer/LeakSanitizer для CI (E-004). Версии Nim и C-toolchain
фиксируются в M0 (Q-04).

## Решение

- Nim 2.2.4, `--mm:orc`, `--threads:on` (`config.nims`), gcc 13.3 на Ubuntu 24.04.
- Каркас каталогов повторяет раздел «Рекомендуемая структура репозитория».
- `src/common/bounded.nim`: единственный примитив очереди, ограниченный по размеру (E-003).
- `src/common/memstats.nim`: RSS и `getOccupiedMem` в формате Prometheus (E-004).
- `nimble testsan` собирает юнит-тесты с `-fsanitize=address`; LeakSanitizer включен в ASan на Linux.
  Проверено: тесты `common` проходят под ASan/LSan без отчетов.

## Не проверено (остается `[M0-CHECK]`)

- musl-статическая линковка (`musl-gcc` в системе есть, сборка не пробовалась).
- Lua 5.4: заголовков в системе нет; нужен vendored-исходник (spike 3).
- rqlite, NATS JetStream, kind/k3d в окружении отсутствуют (spike 1, 4, 5).
- Лицензия (Q-01) не выбрана: в `cinim.nimble` стоит значение по умолчанию Apache-2.0 из Q-01.

## Условия пересмотра

Soak-тест M0 не проходит NFR-013 либо нет рабочего mTLS/HTTP2 (D-01).
