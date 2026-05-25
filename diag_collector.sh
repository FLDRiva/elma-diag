#!/bin/bash
# Скрипт сбора диагностики ELMA365.
# Создаёт два архива:
#   ELMA365-TIMESTAMP.tar.gz   — текстовый, для чтения / передачи в поддержку
#   elma-diag-TIMESTAMP.json.gz — структурированный JSON для загрузки в elma-diag
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORK_DIR="ELMA365-${TIMESTAMP}"
TEXT_ARCHIVE="${WORK_DIR}.tar.gz"
JSON_ARCHIVE="elma-diag-${TIMESTAMP}.json.gz"
LOG_TAIL=2000
MAX_LOG_ENTRIES_PER_CTR=200
NAMESPACE=""

check_deps() {
  for cmd in kubectl jq gzip awk sed; do
    command -v "$cmd" &>/dev/null || { echo "Ошибка: требуется $cmd" >&2; exit 1; }
  done
}

detect_namespace() {
  local arg="${1:-}"
  if [ -n "$arg" ]; then
    NAMESPACE="$arg"
    return
  fi
  for ns in elma365 elma; do
    if kubectl get namespace "$ns" &>/dev/null; then
      NAMESPACE="$ns"
      return
    fi
  done
  echo "Не удалось определить namespace ELMA365. Передайте его аргументом: $0 elma365" >&2
  exit 1
}

main() {
  check_deps
  detect_namespace "${1:-}"
  echo "Namespace: ${NAMESPACE}"

  mkdir -p "${WORK_DIR}/pod_logs"
  local entries_file="${WORK_DIR}/.log_entries.ndjson"
  > "${entries_file}"

  # --- Текстовые файлы (формат ELMA365-XXXXX) ---
  echo "Сбор данных кластера..."

  {
    echo "### All resources in all namespaces"
    echo "$ kubectl get all -A -o wide"
    kubectl get all -A -o wide 2>/dev/null || echo "(недоступно)"
  } > "${WORK_DIR}/general_info.txt"

  {
    echo "### All resources in namespace (${NAMESPACE})"
    echo "$ kubectl get all -n ${NAMESPACE} -o wide"
    kubectl get all -n "${NAMESPACE}" -o wide 2>/dev/null || echo "(недоступно)"
    echo ""
    echo "### Node descriptions"
    echo "$ kubectl describe nodes"
    kubectl describe nodes 2>/dev/null || echo "(недоступно)"
  } > "${WORK_DIR}/main_info.txt"

  {
    echo "### Pod descriptions in namespace ${NAMESPACE}"
    echo "$ kubectl describe pods -n ${NAMESPACE}"
    kubectl describe pods -n "${NAMESPACE}" 2>/dev/null || echo "(недоступно)"
  } > "${WORK_DIR}/describes.txt"

  # --- Сбор JSON данных кластера ---
  local pods_raw
  pods_raw=$(kubectl get pods -n "${NAMESPACE}" -o json 2>/dev/null)

  # Метрики CPU/mem из kubectl top
  local top_json="{}"
  if top_raw=$(kubectl top pod -n "${NAMESPACE}" --containers --no-headers 2>/dev/null); then
    top_json=$(echo "${top_raw}" | \
      awk '{printf "{\"pod\":\"%s\",\"ctr\":\"%s\",\"cpu\":\"%s\",\"mem\":\"%s\"}\n", $1, $2, $3, $4}' | \
      jq -s 'map({"key": (.pod + "/" + .ctr), "value": {cpu: .cpu, mem: .mem}}) | from_entries' 2>/dev/null || echo "{}")
  fi

  # --- Логи подов ---
  echo "Сбор логов..."
  local pod_names
  pod_names=$(echo "${pods_raw}" | jq -r '.items[].metadata.name')

  while IFS= read -r pod; do
    local ctrs
    ctrs=$(echo "${pods_raw}" | jq -r --arg p "${pod}" \
      '.items[] | select(.metadata.name == $p) | .spec.containers[].name')

    while IFS= read -r ctr; do
      local log_file="${WORK_DIR}/pod_logs/${pod}-${ctr}.log"
      kubectl logs "${pod}" -c "${ctr}" -n "${NAMESPACE}" \
        --tail="${LOG_TAIL}" > "${log_file}" 2>/dev/null || echo "(нет логов)" > "${log_file}"

      # Парсим структурированные JSON логи ELMA365 (error/warn/fatal)
      # grep || true — чтобы set -e не прерывал скрипт при отсутствии совпадений
      grep -E '"level"\s*:\s*"(error|warn|fatal)"' "${log_file}" 2>/dev/null | \
        head -n "${MAX_LOG_ENTRIES_PER_CTR}" | \
        while IFS= read -r line; do
          local json_part
          json_part=$(echo "${line}" | sed 's/^[^{]*//')
          echo "${json_part}" | jq -c --arg pod "${pod}" \
            'select(.level != null and .msg != null) | {
              pod: $pod,
              level: .level,
              time: (.timestamp // ""),
              service: (.logger // "" | ltrimstr("elma365.") | split(".") | .[0]),
              msg: .msg,
              error: (.error // "")
            }' 2>/dev/null
        done >> "${entries_file}" || true
    done <<< "${ctrs}"
  done <<< "${pod_names}"

  # --- Формирование JSON ---
  echo "Формирование JSON отчёта..."

  local pods_data
  pods_data=$(echo "${pods_raw}" | jq --argjson top "${top_json}" '[.items[] |
    . as $pod | {
      name: .metadata.name,
      phase: (.status.phase // "Unknown"),
      ready: ((.status.conditions // []) | map(select(.type == "Ready")) | if length > 0 then .[0].status == "True" else false end),
      restarts: ([.status.containerStatuses // [] | .[].restartCount] | add // 0),
      node: (.spec.nodeName // ""),
      containers: [.spec.containers[] as $spec |
        ((.status.containerStatuses // []) | map(select(.name == $spec.name)) | .[0]) as $st | {
          name: $spec.name,
          ready: ($st.ready // false),
          restarts: ($st.restartCount // 0),
          last_state: ($st.lastState.terminated.reason // ""),
          cpu_req: ($spec.resources.requests.cpu // ""),
          cpu_lim: ($spec.resources.limits.cpu // ""),
          mem_req: ($spec.resources.requests.memory // ""),
          mem_lim: ($spec.resources.limits.memory // ""),
          cpu_now: ($top[$pod.metadata.name + "/" + $spec.name].cpu // ""),
          mem_now: ($top[$pod.metadata.name + "/" + $spec.name].mem // "")
        }
      ]
    }
  ]')

  local hpas_data
  hpas_data=$(kubectl get hpa -n "${NAMESPACE}" -o json 2>/dev/null | jq '[.items[] | {
    name: .metadata.name,
    target: (.spec.scaleTargetRef.name // ""),
    min: (.spec.minReplicas // 1),
    max: .spec.maxReplicas,
    current: (.status.currentReplicas // 0),
    desired: (.status.desiredReplicas // 0)
  }]' || echo "[]")

  local events_data
  events_data=$(kubectl get events -n "${NAMESPACE}" -o json 2>/dev/null | jq '[.items[] | {
    reason: (.reason // ""),
    message: (.message // ""),
    object: (.involvedObject.name // ""),
    kind: (.involvedObject.kind // ""),
    count: (.count // 1),
    last_seen: (.lastTimestamp // "")
  }]' || echo "[]")

  local nodes_data
  nodes_data=$(kubectl get nodes -o json 2>/dev/null | jq '[.items[] | {
    name: .metadata.name,
    ready: ((.status.conditions // []) | map(select(.type == "Ready")) | if length > 0 then .[0].status == "True" else false end),
    cpu: (.status.capacity.cpu // ""),
    memory: (.status.capacity.memory // ""),
    version: (.status.nodeInfo.kubeletVersion // "")
  }]' || echo "[]")

  local log_entries="[]"
  if [ -s "${entries_file}" ]; then
    log_entries=$(jq -s '.[0:500]' "${entries_file}" 2>/dev/null || echo "[]")
  fi

  # JSON архив
  jq -n \
    --arg ns "${NAMESPACE}" \
    --arg ts "$(date -Iseconds)" \
    --argjson pods "${pods_data}" \
    --argjson hpas "${hpas_data}" \
    --argjson events "${events_data}" \
    --argjson nodes "${nodes_data}" \
    --argjson entries "${log_entries}" \
    '{
      meta: {namespace: $ns, collected_at: $ts, version: "1.0"},
      cluster: {pods: $pods, hpas: $hpas, events: $events, nodes: $nodes},
      logs: {entries: $entries}
    }' | gzip > "${JSON_ARCHIVE}"

  # Текстовый архив
  rm -f "${entries_file}"
  tar -czf "${TEXT_ARCHIVE}" "${WORK_DIR}"
  rm -rf "${WORK_DIR}"

  echo ""
  echo "Готово!"
  echo "  Текстовый архив:  ${TEXT_ARCHIVE}"
  echo "  JSON архив:       ${JSON_ARCHIVE}"
  echo ""
  echo "Загрузка в elma-diag:"
  echo "  curl -F file=@${JSON_ARCHIVE} http://elma-diag/api/upload"
}

main "$@"
