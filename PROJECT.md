# elma-diag

Инструмент диагностики ELMA365 в Kubernetes.

## Репозитории

- GitHub: https://github.com/FLDRiva/elma-diag
- Docker Hub: https://hub.docker.com/r/rivasr/elma-diag
- Веб-интерфейс: http://diag.riva.elewise.local

## Архитектура

```
diag_collector.sh                      Go-сервис (elma-diag)
───────────────────                    ──────────────────────────────
kubectl → pods/events/nodes/hpas  →   POST /api/upload  (json.gz)
kubectl logs → parse JSON          →   analyzer.Analyze()
                                   →   хранит в памяти (sync.RWMutex)
ELMA365-TIMESTAMP.tar.gz               GET  /api/report  → UI
elma-diag-TIMESTAMP.json.gz        →   GET  /api/health
```

Скрипт создаёт **два архива**:
- `ELMA365-TIMESTAMP.tar.gz` — текстовый, формат как у ELMA365-XXXXX (для поддержки)
- `elma-diag-TIMESTAMP.json.gz` — структурированный JSON, загружается в сервис

## Структура проекта

```
elma-diag/
├── main.go                  — HTTP-сервер, graceful shutdown
├── go.mod                   — модуль elma-diag, Go 1.23
├── api/
│   └── handlers.go          — HealthHandler, GetReportHandler, UploadHandler
├── analyzer/
│   └── analyzer.go          — Analyze(): checkPods, checkEvents, checkLogs
├── models/
│   └── types.go             — DiagnosticReport, Pod, Container, HPA, Event, Node, LogEntry, Issue
├── static/
│   ├── index.html           — оболочка, 6 вкладок
│   ├── css/style.css        — тёмная тема
│   └── js/app.js            — рендер вкладок из /api/report
├── diag_collector.sh        — скрипт сбора диагностики
├── Dockerfile               — golang:1.23-alpine, alpine:3.20, USER nobody
└── k8s/
    └── k8s-deployment.yaml  — Deployment + Service + Ingress
```

## JSON-формат отчёта

```json
{
  "meta": {
    "namespace": "elma365",
    "collected_at": "2026-05-25T19:00:00+03:00",
    "version": "1.0"
  },
  "cluster": {
    "pods": [
      {
        "name": "main-xxx",
        "phase": "Running",
        "ready": true,
        "restarts": 0,
        "node": "node-name",
        "containers": [
          {
            "name": "main",
            "ready": true,
            "restarts": 0,
            "last_state": "",
            "cpu_req": "100m", "cpu_lim": "500m",
            "mem_req": "128Mi", "mem_lim": "512Mi",
            "cpu_now": "45m", "mem_now": "210Mi"
          }
        ]
      }
    ],
    "hpas": [
      { "name": "main", "target": "main", "min": 1, "max": 3, "current": 1, "desired": 1 }
    ],
    "events": [
      { "reason": "OOMKilling", "message": "...", "object": "main-xxx", "kind": "Pod", "count": 2, "last_seen": "..." }
    ],
    "nodes": [
      { "name": "node-1", "ready": true, "cpu": "8", "memory": "32Gi", "version": "v1.28.0" }
    ]
  },
  "logs": {
    "entries": [
      { "pod": "main-xxx", "level": "error", "time": "...", "service": "main", "msg": "...", "error": "..." }
    ]
  },
  "database": {
    "postgresql": [
      { "host": "...", "user": "...", "database": "...", "Owners": ["..."] }
    ]
  },
  "issues": [
    { "type": "oom", "severity": "critical", "pod": "main-xxx", "container": "main", "message": "...", "recommendation": "..." }
  ]
}
```

## Анализатор

`analyzer/analyzer.go` — `Analyze(*DiagnosticReport) []Issue`:

| Тип | Условие | Severity |
|-----|---------|----------|
| `pod_status` | Phase != Running/Succeeded | critical |
| `oom` | LastState == OOMKilled | critical |
| `crashloop` | Restarts > 5 | high |
| `no_limits` | cpu_lim == "" && mem_lim == "" | medium |
| `event` | Reason: OOMKilling/OOMKilled | critical |
| `event` | Reason: BackOff/CrashLoopBackOff | high |
| `event` | Reason: FailedScheduling | high |
| `log_errors` | count error/fatal > 50 | high |
| `log_errors` | count error/fatal > 0 | medium |

## Веб-интерфейс (вкладки)

| Вкладка | Содержимое |
|---------|-----------|
| Нагрузка | Поды, сортировка по CPU, подсветка отсутствующих лимитов |
| Логи | Фильтры: Ошибки / Предупреждения / Инфо / Дебаг, клик → полный текст |
| Проблемы | Карточки с severity, pod, рекомендацией |
| События | Таблица событий, клик → полное сообщение |
| База | PostgreSQL: host, user, database, owners из `report.database.postgresql` |
| Загрузка | Drag-and-drop / выбор файла, POST /api/upload |

## Скрипт diag_collector.sh

### Зависимости
`kubectl`, `jq`, `gzip`, `awk`, `sed`

### Запуск
```bash
# Автоопределение namespace (ищет elma365, затем elma)
./diag_collector.sh

# Явный namespace
./diag_collector.sh elma365
```

### Лимиты сбора логов
- error/warn/fatal: 200 записей на контейнер
- info: 50 записей на контейнер
- debug: 20 записей на контейнер
- итог: max 2000 записей в JSON

### Структура текстового архива
```
ELMA365-TIMESTAMP/
├── general_info.txt   — kubectl get all -A -o wide
├── main_info.txt      — kubectl get all -n elma365 + kubectl describe nodes
├── describes.txt      — kubectl describe pods -n elma365
└── pod_logs/
    └── {pod}-{container}.log
```

### Обновить скрипт на сервере
```bash
curl -O https://raw.githubusercontent.com/FLDRiva/elma-diag/main/diag_collector.sh
chmod +x diag_collector.sh
```

## Kubernetes

### Применить манифест
```bash
kubectl create namespace elma-diag
curl -O https://raw.githubusercontent.com/FLDRiva/elma-diag/main/k8s/k8s-deployment.yaml
kubectl apply -f k8s-deployment.yaml
```

### Параметры деплоя
- Image: `rivasr/elma-diag:latest`
- Namespace: `elma-diag`
- Ingress host: `diag.riva.elewise.local`
- ingressClassName: `nginx`
- Resources: requests 50m/64Mi, limits 500m/256Mi

### Проверка
```bash
kubectl get pods -n elma-diag
kubectl get ingress -n elma-diag
kubectl logs -n elma-diag deployment/elma-diag
```

## Деплой изменений

```bash
# 1. Код в git
git add .
git commit -m "fix: описание"
git push origin main

# 2. Docker образ
docker build -t rivasr/elma-diag:v1.0.x -t rivasr/elma-diag:latest .
docker push rivasr/elma-diag:v1.0.x
docker push rivasr/elma-diag:latest

# 3. Обновить под
kubectl rollout restart deployment/elma-diag -n elma-diag
kubectl rollout status deployment/elma-diag -n elma-diag
```

Если менялся только `k8s-deployment.yaml`:
```bash
kubectl apply -f k8s-deployment.yaml
```

## API

| Метод | Путь | Описание |
|-------|------|----------|
| GET | /api/health | `{"status":"ok","service":"elma-diag"}` |
| GET | /api/report | Текущий отчёт (null если не загружен) |
| POST | /api/upload | Загрузка json или json.gz, поле `file` |

Лимит: 100 МБ форма, 50 МБ файл после распаковки.

## Git история

```
d2c3de0 docs: добавил PROJECT.md
93eaa8c fix: jq падал с 'Argument list too long' на больших кластерах
14b1b4c feat: убрал обзор, новые фильтры логов, раскрываемые строки
96dffea fix: скрипт падал когда grep не находил ошибок в логах пода
223de18 fix: добавил ingressClassName: nginx
dff55bd fix: убрал лишнюю аннотацию rewrite-target из ingress
2e6bc8d fix: ingress host diag.riva.elewise.local
87c4f79 рефакторинг: переписал скрипт, тёмный UI, перешёл на json.gz
```
