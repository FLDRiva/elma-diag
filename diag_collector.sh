#!/bin/bash

# Скрипт сбора диагностической информации для ELMA365 в Kubernetes
# Расширенная версия с интеллектуальным анализом

set -e

OUTPUT_DIR="diag_data_$(date +%Y%m%d_%H%M%S)"
ARCHIVE_NAME="${OUTPUT_DIR}.tar.gz"
JSON_FILE="diag_report.json"

echo "🔍 Начало сбора диагностики ELMA365..."
mkdir -p "$OUTPUT_DIR"/{logs,describes,events,resources,analysis}

# 1. Основная информация о кластере и namespace
echo "📊 Сбор общей информации..."
kubectl get namespace elma365 -o yaml > "$OUTPUT_DIR/resources/namespace.yaml" 2>/dev/null || echo "NS not found"
kubectl get all -n elma365 -o wide > "$OUTPUT_DIR/resources/all_resources.txt" 2>/dev/null
kubectl get hpa -n elma365 -o wide > "$OUTPUT_DIR/resources/hpa.txt" 2>/dev/null
kubectl get ingress -n elma365 -o wide > "$OUTPUT_DIR/resources/ingress.txt" 2>/dev/null
kubectl get configmaps -n elma365 -o wide > "$OUTPUT_DIR/resources/configmaps.txt" 2>/dev/null
kubectl get secrets -n elma365 -o wide > "$OUTPUT_DIR/resources/secrets.txt" 2>/dev/null
kubectl get pvc -n elma365 -o wide > "$OUTPUT_DIR/resources/pvc.txt" 2>/dev/null
kubectl get pv -o wide > "$OUTPUT_DIR/resources/pv.txt" 2>/dev/null
kubectl get nodes -o wide > "$OUTPUT_DIR/resources/nodes.txt" 2>/dev/null
kubectl top nodes > "$OUTPUT_DIR/resources/top_nodes.txt" 2>/dev/null || echo "Metrics server unavailable"
kubectl top pods -n elma365 --containers > "$OUTPUT_DIR/resources/top_pods.txt" 2>/dev/null || echo "Metrics server unavailable"

# 2. Pod'ы и их описание
echo "📦 Сбор информации о Pod'ах..."
kubectl get pods -n elma365 -o wide > "$OUTPUT_DIR/resources/pods.txt" 2>/dev/null
for pod in $(kubectl get pods -n elma365 -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl describe pod "$pod" -n elma365 > "$OUTPUT_DIR/describes/pod_${pod}.txt" 2>/dev/null
done

# 3. События (Events)
echo "🔔 Сбор событий..."
kubectl get events -n elma365 --sort-by='.lastTimestamp' > "$OUTPUT_DIR/events/events_all.txt" 2>/dev/null
kubectl get events -n elma365 --field-selector type=Warning --sort-by='.lastTimestamp' > "$OUTPUT_DIR/events/events_warnings.txt" 2>/dev/null

# 4. Логи контейнеров
echo "📝 Сбор логов..."
for pod in $(kubectl get pods -n elma365 -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    mkdir -p "$OUTPUT_DIR/logs/$pod"
    for container in $(kubectl get pod "$pod" -n elma365 -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
        kubectl logs "$pod" -c "$container" -n elma365 --tail=1000 > "$OUTPUT_DIR/logs/$pod/${container}.log" 2>/dev/null || echo "No logs" > "$OUTPUT_DIR/logs/$pod/${container}.log"
        # Логи предыдущего экземпляра (если был перезапуск)
        kubectl logs "$pod" -c "$container" -n elma365 --previous --tail=500 > "$OUTPUT_DIR/logs/$pod/${container}_previous.log" 2>/dev/null || true
    done
done

# 5. Анализ проблем (интеллектуальный слой)
echo "🧠 Анализ проблем..."
ANALYSIS_FILE="$OUTPUT_DIR/analysis/issues.json"
echo '{"issues": []}' > "$ANALYSIS_FILE"

# Поиск ошибок в логах
ERROR_PATTERNS=("Exception" "Error" "Fatal" "Panic" "OOMKilled" "CrashLoopBackOff" "ImagePullBackOff")
ISSUES_FOUND=()

for log_file in "$OUTPUT_DIR"/logs/*/*.log; do
    if [ -f "$log_file" ]; then
        pod_name=$(basename "$(dirname "$log_file")")
        container_name=$(basename "$log_file" .log)

        for pattern in "${ERROR_PATTERNS[@]}"; do
            if grep -q "$pattern" "$log_file" 2>/dev/null; then
                count=$(grep -c "$pattern" "$log_file" 2>/dev/null || echo 0)
                ISSUES_FOUND+=("{\"type\": \"log_error\", \"severity\": \"high\", \"pod\": \"$pod_name\", \"container\": \"$container_name\", \"pattern\": \"$pattern\", \"count\": $count, \"message\": \"Обнаружены ошибки типа '$pattern' в логах\"}")
            fi
        done
    fi
done

# Проверка статусов подов
for pod in $(kubectl get pods -n elma365 -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    status=$(kubectl get pod "$pod" -n elma365 -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$status" != "Running" ] && [ "$status" != "Succeeded" ]; then
        reason=$(kubectl get pod "$pod" -n elma365 -o jsonpath='{.status.reason}' 2>/dev/null || echo "Unknown")
        ISSUES_FOUND+=("{\"type\": \"pod_status\", \"severity\": \"critical\", \"pod\": \"$pod\", \"status\": \"$status\", \"reason\": \"$reason\", \"message\": \"Pod находится в состоянии $status ($reason)\"}")
    fi
done

# Проверка Warning событий
warning_count=$(wc -l < "$OUTPUT_DIR/events/events_warnings.txt" 2>/dev/null || echo 0)
if [ "$warning_count" -gt 0 ]; then
    ISSUES_FOUND+=("{\"type\": \"k8s_events\", \"severity\": \"medium\", \"count\": $warning_count, \"message\": \"Обнаружено $warning_count предупреждений в событиях Kubernetes\"}")
fi

# Формирование JSON анализа
if [ ${#ISSUES_FOUND[@]} -gt 0 ]; then
    issues_json=$(printf "%s\n" "${ISSUES_FOUND[@]}" | paste -sd "," -)
    echo "{\"timestamp\": \"$(date -Iseconds)\", \"namespace\": \"elma365\", \"issues\": [$issues_json]}" > "$ANALYSIS_FILE"
else
    echo "{\"timestamp\": \"$(date -Iseconds)\", \"namespace\": \"elma365\", \"issues\": [], \"status\": \"healthy\"}" > "$ANALYSIS_FILE"
fi

# 6. Создание итогового JSON отчета
echo "📄 Генерация JSON отчета..."
cat > "$OUTPUT_DIR/$JSON_FILE" <<EOF
{
  "report_version": "1.0",
  "generated_at": "$(date -Iseconds)",
  "namespace": "elma365",
  "cluster_info": {
    "nodes_count": $(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo 0),
    "pods_count": $(kubectl get pods -n elma365 --no-headers 2>/dev/null | wc -l || echo 0),
    "hpa_count": $(kubectl get hpa -n elma365 --no-headers 2>/dev/null | wc -l || echo 0)
  },
  "analysis_file": "analysis/issues.json",
  "archive_name": "$ARCHIVE_NAME"
}
EOF

# 7. Архивация
echo "📦 Архивация данных..."
tar -czf "$ARCHIVE_NAME" "$OUTPUT_DIR"

echo "✅ Диагностика завершена!"
echo "   Архив: $ARCHIVE_NAME"
echo "   JSON отчет: $OUTPUT_DIR/$JSON_FILE"
echo ""
echo "Для запуска анализатора:"
echo "  cat $ARCHIVE_NAME | docker run -i rivasr/elma365-diagnostics:latest analyze"
echo "  или разверните deployment diagnostics-elma365-diagnostics"