# 0013. Клиент Kubernetes: сравнение официального C-клиента и тонкого клиента на `std/httpclient`

- Статус: accepted; уточняет ADR 0011
- Связанные ID: RUN-002, NFR-012, NFR-013, E-003
- Повод: ваши проекты (`~/github/k8s-image-availability-exporter`) уже содержат рабочий тонкий клиент Kubernetes на Nim.

## Как мерили

`tools/k8s/clientbench.sh`: одна нагрузка (7 списков ресурсов по всему кластеру с пагинацией `limit/continue`, разбор `yyjson`, 207 объектов), 30 циклов в свежем процессе, кластер `admin@home`.
Тонкий клиент берется **дословно** из репозитория экспортёра (`newExporterHttpClient`, `apiGet`, загрузка kubeconfig через пакет `yaml`).

| Вариант | RSS: старт, цикл 1, 10, 20, 30 (МиБ) | Время цикла |
|:---|:---|:---|
| Тонкий клиент как в экспортёре (новый `HttpClient` и `SslContext` на каждый запрос) | 5,6 → 13,5 → 18,1 → 19,8 → **21,5, растет ≈ 170 КиБ за цикл** | 1,6–2,7 с |
| Тонкий клиент, один общий `HttpClient` (keep-alive) | 5,6 → 13,5 → 16,4 → 16,4 → 16,4 | **0,32 с** |
| Официальный C-клиент (generic API), как есть | 6,6 → 10,8 → 12,0 → 12,0 → 12,0 | 1,3–1,6 с |
| Официальный C-клиент + общий кэш соединений (`enableConnectionCache`) | 6,8 → 10,8 → 11,9 → 11,9 → 11,9 | 0,42–0,56 с |

## Находки

1. **Утечка в экспортёре.** `apiGet` создает новый `SslContext` (OpenSSL `SSL_CTX`) на каждый вызов и не освобождает его: память растет линейно с числом запросов. Исправление: один переиспользуемый `HttpClient`
   на поток (память выходит на плато, цикл в 5 раз быстрее за счет keep-alive). Затронуты и клиенты реестров, если им задан `registryCaPath`.
2. **`std/httpclient` не умеет читать тело потоком** (поле `getBody` приватное): watch с `resourceVersion` им получить в реальном времени нельзя, события придут пачкой в конце `timeoutSeconds`.
   Для списков и точечных запросов клиент подходит, для контроллера CiNim (watch, RUN-002) нет.
3. **C-клиент создает easy-handle на каждый вызов**, то есть TLS-рукопожатие на каждый запрос (~200 мс). Штатный хук `curl_pre_invoke_func` с общим кэшем соединений libcurl
   это исправляет (`src/common/k8sbind.nim`, `enableConnectionCache`): цикл ускоряется втрое, память плоская.

## Решение

- **CiNim (job-контроллер):** остается официальный C-клиент (ADR 0011), потому что нужен watch; всегда включать `enableConnectionCache`; один `apiClient` на поток.
- **k8s-image-availability-exporter:** переходить на C-клиент **не стоит**. Он лучше нынешнего кода (плоские 12 МиБ против растущих 21+), но тот же выигрыш (даже быстрее) дает исправление в 5 строк
   (общий `HttpClient`), а C-клиент добавил бы нативную зависимость, сборку `libkubernetes` под Alpine (musl) и не убрал бы `std/httpclient` (он нужен для реестров).
   Код экспортёра **не менялся**; готовое исправление ниже (применить по вашему решению).

```diff
-proc apiGet(kube: KubeClient; path: string): string =
-  var client = newExporterHttpClient(token = kube.token, caPath = kube.caPath,
-    certPath = kube.certPath, keyPath = kube.keyPath, insecure = kube.insecure)
-  defer: client.close()
-  let response = client.request(kube.baseUrl & path, httpMethod = HttpGet)
+var kubeHttp {.threadvar.}: HttpClient     # one client and one SslContext per thread (keep-alive)
+
+proc apiGet(kube: KubeClient; path: string): string =
+  if kubeHttp.isNil:
+    kubeHttp = newExporterHttpClient(token = kube.token, caPath = kube.caPath,
+      certPath = kube.certPath, keyPath = kube.keyPath, insecure = kube.insecure)
+  let response = kubeHttp.request(kube.baseUrl & path, httpMethod = HttpGet)
```

Оговорка: при `-d:release` и `--threads:on` `threadvar` с `HttpClient` живет до конца потока; при смене токена (kubeconfig, ротация) клиент нужно пересоздавать.
