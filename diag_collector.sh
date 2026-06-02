#!/bin/bash
# Скрипт сбора диагностики ELMA365.
# Создаёт JSON архив для веб-интерфейса:
#   elma-diag-TIMESTAMP.json.gz
set -euo pipefail

TIMESTAMP=$(date +%Y.%m.%d_%H-%M)
WORK_DIR="ELMA365-${TIMESTAMP}"
JSON_ARCHIVE="elma-diag-${TIMESTAMP}.json.gz"
LOG_TAIL=1000
MAX_ERROR=200
MAX_INFO=50
MAX_DEBUG=50
NAMESPACE=""

parse_log_level() {
  local log_file="$1" pod="$2" pattern="$3" limit="$4"
  
  grep -E "\"level\"\s*:\s*\"(${pattern})\"" "${log_file}" 2>/dev/null | \
    head -n "${limit}" | \
    jq -R -c --arg pod "${pod}" '
      fromjson? // empty |
      select(.level != null and .msg != null) |
      {
        pod: $pod,
        level: .level,
        time: (.timestamp // ""),
        service: (.logger // "" | ltrimstr("elma365.") | split(".") | .[0]),
        msg: .msg,
        error: (.error // "")
      }
    ' 2>/dev/null >> "${entries_file}" || true
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
  
  trap 'rm -rf "${WORK_DIR}"' EXIT
  
  mkdir -p "${WORK_DIR}/pod_logs"
  local entries_file="${WORK_DIR}/.log_entries.ndjson"
  > "${entries_file}"

  echo "Сбор данных кластера..."

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

  echo "${top_json}" > "${tmp}/top.json"
 
  local nodes_json
  nodes_json=$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')
  
  
  local nodes_usage="{}"
  if kubectl top nodes --no-headers 2>/dev/null | grep -q .; then
    nodes_usage=$(kubectl top nodes --no-headers 2>/dev/null | awk '{
      cpu=$2; mem=$3;
      # Нормализуем CPU: 500m -> 500, 2 -> 2000 (в millicores для единообразия)
      if (cpu ~ /m$/) { gsub("m", "", cpu) } 
      else { cpu = cpu * 1000 }
      # Нормализуем память: всегда в MiB
      if (mem ~ /Gi$/) { gsub("Gi", "", mem); mem = mem * 1024 }
      else { gsub("Mi", "", mem) }
      printf "{\"%s\":{\"cpu_used\":\"%s\",\"mem_used\":\"%s\"}}\n", $1, cpu, mem
    }' | jq -s 'add // {}' 2>/dev/null || echo "{}")
  fi

  # Формируем итоговый массив нод 
  echo "${nodes_json}" | jq --argjson usage "${nodes_usage}" '[.items[] | {
    name: .metadata.name,
    ready: ((.status.conditions // []) | map(select(.type == "Ready")) | if length > 0 then .[0].status == "True" else false end),
    cpu: (.status.capacity.cpu // ""),
    memory: (.status.capacity.memory // ""),
    version: (.status.nodeInfo.kubeletVersion // ""),
    os: .status.nodeInfo.osImage,
    kernel: .status.nodeInfo.kernelVersion,
    kubelet: .status.nodeInfo.kubeletVersion,
    container_runtime: .status.nodeInfo.containerRuntimeVersion,
    cpu_capacity: (.status.capacity.cpu | 
      if type == "string" then 
        (if test("m$") then (. | gsub("m$"; "") | tonumber) else (. | tonumber * 1000) end)
      else . end // 0),
    cpu_allocatable: (.status.allocatable.cpu | 
      if type == "string" then 
        (if test("m$") then (. | gsub("m$"; "") | tonumber) else (. | tonumber * 1000) end)
      else . end // 0),
    memory_capacity_kb: (.status.capacity.memory | 
      if type == "string" then
        (if test("Gi$") then (. | gsub("Gi$"; "") | tonumber * 1024 * 1024)
         elif test("Mi$") then (. | gsub("Mi$"; "") | tonumber * 1024)
         elif test("Ki$") then (. | gsub("Ki$"; "") | tonumber)
         else (. | gsub("[a-zA-Z]"; "") | tonumber) end)
      else . end // 0),
    memory_allocatable_kb: (.status.allocatable.memory | 
      if type == "string" then
        (if test("Gi$") then (. | gsub("Gi$"; "") | tonumber * 1024 * 1024)
         elif test("Mi$") then (. | gsub("Mi$"; "") | tonumber * 1024)
         elif test("Ki$") then (. | gsub("Ki$"; "") | tonumber)
         else (. | gsub("[a-zA-Z]"; "") | tonumber) end)
      else . end // 0),
    cpu_used: ($usage[.metadata.name].cpu_used // ""),
    mem_used: ($usage[.metadata.name].mem_used // ""),
    load_avg: "N/A",
    disk_iops: "N/A"
  }]' > "${tmp}/nodes.json" 2>/dev/null || echo "[]" > "${tmp}/nodes.json"

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

  # log entries
  if [ -s "${entries_file}" ]; then
    jq -s '.[0:2000]' "${entries_file}" > "${tmp}/entries.json" || echo "[]" > "${tmp}/entries.json"
  else
    echo "[]" > "${tmp}/entries.json"
  fi

  local pg_secrets
  pg_secrets=$(kubectl get secrets -n "${NAMESPACE}" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name == "elma365-db-connections" or (.metadata.name | test("-pg$|-postgres$|app-postgres"))) | .metadata.name' 2>/dev/null || echo "")

  local dbinfo="[]"

  if [ -n "${pg_secrets}" ]; then
    local tmp_dbinfo="${tmp}/.dbinfo_tmp.ndjson"
    > "${tmp_dbinfo}"

    while IFS= read -r secret_name; do
      [ -z "${secret_name}" ] && continue

      local secret_json
      secret_json=$(kubectl get secret "${secret_name}" -n "${NAMESPACE}" -o json 2>/dev/null) || continue

      local secret_keys
      secret_keys=$(echo "${secret_json}" | jq -r '.data | keys[]' 2>/dev/null || echo "")

      local url_keys
      url_keys=$(echo "${secret_keys}" | grep -E '^(PSQL_URL|ELMA365_POOL_POSTGRES_URL|RO_POSTGRES_URL|POSTGRES_URL)$' || echo "")

      if [ -n "${url_keys}" ]; then
        while IFS= read -r url_key; do
          [ -z "${url_key}" ] && continue

          local psql_url
          psql_url=$(echo "${secret_json}" | jq -r --arg k "${url_key}" '.data[$k] // empty | @base64d' 2>/dev/null || echo "")
          [ -z "${psql_url}" ] && continue

          local user host port dbname pass
          user=$(echo "${psql_url}" | sed -n 's|^postgresql://\([^:]*\):.*|\1|p')
          pass=$(echo "${psql_url}" | sed -n 's|^postgresql://[^:]*:\([^@]*\)@.*|\1|p')
          host=$(echo "${psql_url}" | sed -n 's|^postgresql://[^@]*@\([^:/]*\).*|\1|p')
          port=$(echo "${psql_url}" | sed -n 's|^postgresql://[^@]*@[^:]*:\([0-9]*\).*|\1|p')
          dbname=$(echo "${psql_url}" | sed -n 's|^postgresql://[^@]*@[^/]*\/\([^?]*\).*|\1|p')

          [ -z "${host}" ] || [ -z "${user}" ] || [ -z "${pass}" ] && continue

          local owners_raw
          owners_raw=$(PGPASSWORD="${pass}" psql \
            -h "${host}" \
            -p "${port:-5432}" \
            -U "${user}" \
            -d "${dbname:-postgres}" \
            -t -A \
            --connect-timeout=3 \
            -c "set statement_timeout=2000;" \
            -c "SELECT rolname FROM pg_roles WHERE rolcanlogin = true ORDER BY rolname;" \
            2>/dev/null || echo "")

          local owners_arr="[]"
          if [ -n "${owners_raw}" ]; then
            owners_arr=$(echo "${owners_raw}" | jq -R -s 'split("\n") | map(select(length > 0))')
          fi

          jq -n --arg secret "${secret_name}" \
                --arg key "${url_key}" \
                --arg host "${host}" \
                --arg user "${user}" \
                --arg dbname "${dbname:-postgres}" \
                --argjson owners "${owners_arr}" \
                '{secret: $secret, connection: $key, host: $host, user: $user, database: $dbname, owners: $owners}' >> "${tmp_dbinfo}"
        done <<< "${url_keys}"
        [ -s "${tmp_dbinfo}" ] && continue
      fi

      local host="" user="" pass="" dbname=""
      read -r host user pass dbname < <(echo "${secret_json}" | jq -r '
        [
          (.data.host // "" | @base64d),
          (.data.username // .data.user // "" | @base64d),
          (.data.password // .data.pass // "" | @base64d),
          (.data.dbname // .data.database // .data.db // "" | @base64d)
        ] | @tsv
      ' 2>/dev/null || echo -e "\t\t\t")

      if [ -z "${host}" ] || [ -z "${user}" ]; then
        local prefixes
        prefixes=$(echo "${secret_keys}" | sed 's/-host$//; s/-username$//; s/-user$//; s/-password$//; s/-pass$//; s/-dbname$//; s/-database$//; s/-db$//' | sort -u | grep -v '^$' || echo "")

        while IFS= read -r prefix; do
          [ -z "${prefix}" ] && continue

          local p_host p_user p_pass p_dbname
          read -r p_host p_user p_pass p_dbname < <(echo "${secret_json}" | jq -r --arg pfx "${prefix}" '
            [
              (.data[($pfx + "-host")] // "" | @base64d),
              (.data[($pfx + "-username")] // .data[($pfx + "-user")] // "" | @base64d),
              (.data[($pfx + "-password")] // .data[($pfx + "-pass")] // "" | @base64d),
              (.data[($pfx + "-dbname")] // .data[($pfx + "-database")] // .data[($pfx + "-db")] // "" | @base64d)
            ] | @tsv
          ' 2>/dev/null || echo -e "\t\t\t")

          [ -z "${p_host}" ] || [ -z "${p_user}" ] && continue

          local owners_raw
          owners_raw=$(PGPASSWORD="${p_pass}" psql \
            -h "${p_host}" \
            -U "${p_user}" \
            -d "${p_dbname:-postgres}" \
            -t -A \
            --connect-timeout=3 \
            -c "set statement_timeout=2000;" \
            -c "SELECT rolname FROM pg_roles WHERE rolcanlogin = true ORDER BY rolname;" \
            2>/dev/null || echo "")

          local owners_arr="[]"
          if [ -n "${owners_raw}" ]; then
            owners_arr=$(echo "${owners_raw}" | jq -R -s 'split("\n") | map(select(length > 0))')
          fi

          jq -n --arg secret "${secret_name}" \
                --arg prefix "${prefix}" \
                --arg host "${p_host}" \
                --arg user "${p_user}" \
                --arg dbname "${p_dbname:-postgres}" \
                --argjson owners "${owners_arr}" \
                '{secret: $secret, connection: $prefix, host: $host, user: $user, database: $dbname, owners: $owners}' >> "${tmp_dbinfo}"
        done <<< "${prefixes}"
        [ -s "${tmp_dbinfo}" ] && continue
      fi

      [ -z "${host}" ] || [ -z "${user}" ] || [ -z "${pass}" ] && continue

      local owners_raw
      owners_raw=$(PGPASSWORD="${pass}" psql \
        -h "${host}" \
        -U "${user}" \
        -d "${dbname:-postgres}" \
        -t -A \
        --connect-timeout=3 \
        -c "set statement_timeout=2000;" \
        -c "SELECT rolname FROM pg_roles WHERE rolcanlogin = true ORDER BY rolname;" \
        2>/dev/null || echo "")

      local owners_arr="[]"
      if [ -n "${owners_raw}" ]; then
        owners_arr=$(echo "${owners_raw}" | jq -R -s 'split("\n") | map(select(length > 0))')
      fi

      jq -n --arg secret "${secret_name}" \
            --arg host "${host}" \
            --arg user "${user}" \
            --arg dbname "${dbname:-postgres}" \
            --argjson owners "${owners_arr}" \
            '{secret: $secret, host: $host, user: $user, database: $dbname, owners: $owners}' >> "${tmp_dbinfo}"
    done <<< "${pg_secrets}"

    if [ -s "${tmp_dbinfo}" ]; then
      dbinfo=$(jq -s '.' "${tmp_dbinfo}" 2>/dev/null || echo "[]")
    fi
  fi

  echo "${dbinfo}" > "${tmp}/dbinfo.json"

  
  echo "Сборка финального отчёта..."
  
  jq -n \
    --arg ns "${NAMESPACE}" \
    --arg ts "$(date -Iseconds)" \
    --slurpfile pods    "${tmp}/pods.json" \
    --slurpfile hpas    "${tmp}/hpas.json" \
    --slurpfile events  "${tmp}/events.json" \
    --slurpfile nodes   "${tmp}/nodes.json" \
    --slurpfile entries "${tmp}/entries.json" \
    --slurpfile dbinfo  "${tmp}/dbinfo.json" \
    '{
      meta: {namespace: $ns, collected_at: $ts, version: "1.0"},
      cluster: {
        pods: $pods[0],
        hpas: $hpas[0],
        events: $events[0],
        nodes: $nodes[0]
      },
      logs: {entries: $entries[0]},
      database: {postgresql: ($dbinfo[0] // [])}
    }' | gzip > "${JSON_ARCHIVE}"

  rm -rf "${WORK_DIR}"

  echo ""
  echo "Готово!"
  echo "  JSON для UI:  ${JSON_ARCHIVE}"
}

main "$@"