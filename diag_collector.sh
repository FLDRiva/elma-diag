#!/bin/bash
# Скрипт сбора диагностики ELMA365.
# Создаёт два архива:
#   ELMA365-TIMESTAMP.tar.gz   — обычный архив
#   elma-diag-TIMESTAMP.json.gz — json для отдачи в ui
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%)
WORK_DIR="ELMA365-${TIMESTAMP}"
TEXT_ARCHIVE="${WORK_DIR}.tar.gz"
JSON_ARCHIVE="elma-diag-${TIMESTAMP}.json.gz"
LOG_TAIL=2000
MAX_ERROR=200
MAX_INFO=50
MAX_DEBUG=20
NAMESPACE=""

# Парсит log_file и добавляет записи с нужным уровнем в entries_file
parse_log_level() {
  local log_file="$1" pod="$2" pattern="$3" limit="$4"
  grep -E "\"level\"\s*:\s*\"(${pattern})\"" "${log_file}" 2>/dev/null | \
    head -n "${limit}" | \
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
}

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
  echo "Не удалось определить namespace ELMA365. В таком случае передай явно: $0 elma365" >&2
  exit 1
}

main() {
  check_deps
  detect_namespace "${1:-}"
  echo "Namespace: ${NAMESPACE}"

  mkdir -p "${WORK_DIR}/pod_logs"
  local entries_file="${WORK_DIR}/.log_entries.ndjson"
  > "${entries_file}"

  
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

  
  local pods_raw
  pods_raw=$(kubectl get pods -n "${NAMESPACE}" -o json 2>/dev/null)

  
  local top_json="{}"
  if top_raw=$(kubectl top pod -n "${NAMESPACE}" --containers --no-headers 2>/dev/null); then
    top_json=$(echo "${top_raw}" | \
      awk '{printf "{\"pod\":\"%s\",\"ctr\":\"%s\",\"cpu\":\"%s\",\"mem\":\"%s\"}\n", $1, $2, $3, $4}' | \
      jq -s 'map({"key": (.pod + "/" + .ctr), "value": {cpu: .cpu, mem: .mem}}) | from_entries' 2>/dev/null || echo "{}")
  fi

  
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

      parse_log_level "${log_file}" "${pod}" "error|warn|fatal" "${MAX_ERROR}"
      parse_log_level "${log_file}" "${pod}" "info"            "${MAX_INFO}"
      parse_log_level "${log_file}" "${pod}" "debug"           "${MAX_DEBUG}"
    done <<< "${ctrs}"
  done <<< "${pod_names}"


  echo "Формирование JSON отчёта..."
  local tmp="${WORK_DIR}/.tmp"
  mkdir -p "${tmp}"

  # top_json в файл для передачи в jq через --slurpfile спасибо qwen
  echo "${top_json}" > "${tmp}/top.json"

  # pods
  echo "${pods_raw}" | jq --slurpfile top "${tmp}/top.json" '[.items[] |
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
          cpu_now: ($top[0][$pod.metadata.name + "/" + $spec.name].cpu // ""),
          mem_now: ($top[0][$pod.metadata.name + "/" + $spec.name].mem // "")
        }
      ]
    }
  ]' > "${tmp}/pods.json" || echo "[]" > "${tmp}/pods.json"

  # hpas
  kubectl get hpa -n "${NAMESPACE}" -o json 2>/dev/null | jq '[.items[] | {
    name: .metadata.name,
    target: (.spec.scaleTargetRef.name // ""),
    min: (.spec.minReplicas // 1),
    max: .spec.maxReplicas,
    current: (.status.currentReplicas // 0),
    desired: (.status.desiredReplicas // 0)
  }]' > "${tmp}/hpas.json" || echo "[]" > "${tmp}/hpas.json"

  # events
  kubectl get events -n "${NAMESPACE}" -o json 2>/dev/null | jq '[.items[] | {
    reason: (.reason // ""),
    message: (.message // ""),
    object: (.involvedObject.name // ""),
    kind: (.involvedObject.kind // ""),
    count: (.count // 1),
    last_seen: (.lastTimestamp // "")
  }]' > "${tmp}/events.json" || echo "[]" > "${tmp}/events.json"

  # nodes
  kubectl get nodes -o json 2>/dev/null | jq '[.items[] | {
    name: .metadata.name,
    ready: ((.status.conditions // []) | map(select(.type == "Ready")) | if length > 0 then .[0].status == "True" else false end),
    cpu: (.status.capacity.cpu // ""),
    memory: (.status.capacity.memory // ""),
    version: (.status.nodeInfo.kubeletVersion // "")
  }]' > "${tmp}/nodes.json" || echo "[]" > "${tmp}/nodes.json"

  # log entries
  if [ -s "${entries_file}" ]; then
    jq -s '.[0:2000]' "${entries_file}" > "${tmp}/entries.json" || echo "[]" > "${tmp}/entries.json"
  else
    echo "[]" > "${tmp}/entries.json"
  fi

  # Сборка итогового JSON через --slurpfile (без передачи данных как аргументов)
  jq -n \
    --arg ns "${NAMESPACE}" \
    --arg ts "$(date -Iseconds)" \
    --slurpfile pods    "${tmp}/pods.json" \
    --slurpfile hpas    "${tmp}/hpas.json" \
    --slurpfile events  "${tmp}/events.json" \
    --slurpfile nodes   "${tmp}/nodes.json" \
    --slurpfile entries "${tmp}/entries.json" \
    '{
      meta: {namespace: $ns, collected_at: $ts, version: "1.0"},
      cluster: {pods: $pods[0], hpas: $hpas[0], events: $events[0], nodes: $nodes[0]},
      logs: {entries: $entries[0]}
    }' | gzip > "${JSON_ARCHIVE}"

  # Текстовый архив
  rm -f "${entries_file}"
  tar -czf "${TEXT_ARCHIVE}" "${WORK_DIR}"
  rm -rf "${WORK_DIR}"

  echo ""
  echo "Готово!"
  echo "  Обычный архив:  ${TEXT_ARCHIVE}"
  echo "  JSON для ui:       ${JSON_ARCHIVE}"
}

main "$@"
