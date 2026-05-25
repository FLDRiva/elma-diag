--- README.md 
# Автономный проект написанные с помощью Vue, Vuetifix. Написанны свои API Go, используется виртуальная СУБД Postgre.
Проект является демонстрацией знаний написания и применения hard-skill.

+++ README.md 
# ELMA365 Diagnostics - Инструкция по использованию

## 📋 Обзор

Система диагностики ELMA365 для Kubernetes состоит из двух компонентов:
1. **diag_collector.sh** - скрипт сбора данных
2. **diag-server** - Go-сервис с веб-интерфейсом для анализа

---

## 🚀 Быстрый старт

### 1. Сбор данных диагностики

```bash
# Сделайте скрипт исполняемым
chmod +x diag_collector.sh

# Запустите сбор данных
./diag_collector.sh
```

После выполнения вы получите:
- Архив с данными (например, `diag_data_20250101_120000.tar.gz`)
- JSON отчет в папке с данными

### 2. Локальный запуск сервера (для тестирования)

```bash
cd diag-server

# Установка зависимостей
go mod download

# Запуск сервера
go run main.go

# Откройте браузер: http://localhost:8080
```

### 3. Сборка Docker образа

```bash
cd diag-server

# Сборка образа
docker build -t rivasr/elma365-diagnostics:1.5.4 .

# Пуш в registry
docker push rivasr/elma365-diagnostics:1.5.4
```

### 4. Деплой в Kubernetes

```bash
# Применить манифесты
kubectl apply -f k8s-deployment.yaml

# Обновить образ (если нужно)
kubectl set image deployment/diagnostics-elma365-diagnostics \
  diagnostics=rivasr/elma365-diagnostics:1.5.4 \
  -n elma365-diagnostics

# Отследить статус rollout
kubectl rollout status deployment/diagnostics-elma365-diagnostics -n elma365-diagnostics

# Проверить поды
kubectl get pods -n elma365-diagnostics
```

### 5. Доступ к интерфейсу

После деплоя интерфейс доступен по адресу:
- **https://diag.riva.elewise.local**

Или через port-forward для локального доступа:
```bash
kubectl port-forward svc/diagnostics-elma365-service 8080:80 -n elma365-diagnostics
# Откройте: http://localhost:8080
```

---

## 📊 Как использовать

### Шаг 1: Сбор данных
Запустите скрипт на сервере с доступом к кластеру:
```bash
./diag_collector.sh
```

### Шаг 2: Загрузка в UI
1. Откройте веб-интерфейс диагностики
2. Перейдите на вкладку **"Загрузка"**
3. Перетащите архив `.tar.gz` или выберите файл
4. Система автоматически проанализирует данные

### Шаг 3: Анализ проблем
- **Обзор** - общая сводка и статистика
- **Логи сервисов** - логи всех контейнеров с подсветкой ошибок
- **Нагрузка** - HPA, потребление CPU/Memory подами и узлами
- **Проблемы** - автоматически найденные проблемы с рекомендациями
- **События** - события Kubernetes (Warning/Normal)
- **Хранилище** - статус PVC и PV

---

## 🔍 Что собирает скрипт

### Ресурсы Kubernetes
- Namespace, Deployments, Pods, Services
- HPA (автомасштабирование)
- ConfigMaps, Secrets
- Ingress, PVC, PV
- Nodes и их метрики

### Логи
- Логи всех контейнеров (последние 1000 строк)
- Логи предыдущих экземпляров (при перезапуске)

### События
- Все события namespace
- Warning события отдельно

### Анализ проблем
- Ошибки в логах (Exception, Error, Fatal, Panic)
- Проблемные статусы подов (CrashLoopBackOff, Pending и др.)
- Корреляция событий и логов
- Рекомендации по устранению

---

## 🛠️ Команды для управления

### Скачать изменения на локальный компьютер
```bash
git pull origin <branch-name>
```

### Закоммитить и запушить изменения
```bash
git add .
git commit -m "Описание изменений"
git push origin <branch-name>
```

### Сборка Docker образа
```bash
cd diag-server
docker build -t rivasr/elma365-diagnostics:<version> .
docker push rivasr/elma365-diagnostics:<version>
```

### Деплой на сервер
```bash
# Обновление образа
kubectl set image deployment/diagnostics-elma365-diagnostics \
  diagnostics=rivasr/elma365-diagnostics:<version> \
  -n elma365-diagnostics

# Отслеживание rollout
kubectl rollout status deployment/diagnostics-elma365-diagnostics -n elma365-diagnostics

# При необходимости откат
kubectl rollout undo deployment/diagnostics-elma365-diagnostics -n elma365-diagnostics
```

### Проверка статуса
```bash
kubectl get pods -n elma365-diagnostics
kubectl describe pod <pod-name> -n elma365-diagnostics
kubectl logs -f deployment/diagnostics-elma365-diagnostics -n elma365-diagnostics
```

---

## 📁 Структура проекта

```
/workspace/
├── diag_collector.sh          # Скрипт сбора данных
└── diag-server/
    ├── main.go                # Основной сервер
    ├── go.mod                 # Go модуль
    ├── Dockerfile             # Docker образ
    ├── k8s-deployment.yaml    # Kubernetes манифесты
    ├── analyzer/
    │   └── analyzer.go        # Анализ проблем
    ├── api/
    │   └── handlers.go        # API обработчики
    ├── models/                # Модели данных
    └── static/
        └── index.html         # Веб-интерфейс
```

---

## 💡 Советы для новичков

1. **HPA (Horizontal Pod Autoscaler)** - автоматически увеличивает количество копий приложения при росте нагрузки
2. **PVC (PersistentVolumeClaim)** - запрос на место для хранения данных
3. **Events** - хронология событий в кластере, помогают понять что произошло
4. **CrashLoopBackOff** - под постоянно перезапускается, проверьте логи
5. **OOMKilled** - не хватило памяти, увеличьте лимиты

Каждая вкладка интерфейса содержит подсказки "ℹ️ Что здесь?" для понимания назначения раздела.

---

## 🆘 Troubleshooting

### Образ не пушится
```bash
docker login
docker push rivasr/elma365-diagnostics:<version>
```

### Поды не запускаются
```bash
kubectl describe pod <pod-name> -n elma365-diagnostics
kubectl logs <pod-name> -n elma365-diagnostics
```

### Ingress не работает
```bash
kubectl get ingress -n elma365-diagnostics
kubectl describe ingress diagnostics-elma365-ingress -n elma365-diagnostics
```

### Metrics server недоступен
Если `kubectl top` не работает - установите metrics-server в кластер.