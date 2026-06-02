'use strict';

let currentReport = null;
let currentTab = 'load';
let logFilter = 'error';

document.addEventListener('DOMContentLoaded', async () => {
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => showTab(btn.dataset.tab));
  });

  try {
    const res = await fetch('/api/report');
    const data = await res.json();
    if (data && data.meta && data.meta.namespace) {
      currentReport = data;
      updateNsBadge(data.meta.namespace);
    }
  } catch (_) {}

  showTab(currentReport ? 'load' : 'upload');
});

function showTab(tab) {
  currentTab = tab;
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.tab === tab);
  });
  renderTab(tab);
}

function renderTab(tab) {
  const el = document.getElementById('content');
  switch (tab) {
    case 'load':   el.innerHTML = renderLoad();   break;
    case 'logs':   el.innerHTML = renderLogs();   break;
    case 'issues': el.innerHTML = renderIssues(); break;
    case 'events': el.innerHTML = renderEvents(); break;
    case 'database': el.innerHTML = renderDatabase(); break;
    case 'upload': el.innerHTML = renderUpload(); bindUpload(); break;
    case 'nodes': el.innerHTML = renderNodes(); break;

  }
}

function updateNsBadge(ns) {
  const el = document.getElementById('ns-badge');
  if (el) el.textContent = ns;
}

// Нагрузка
function renderLoad() {
  if (!currentReport) return noData();
  const r = currentReport;
  const pods  = r.cluster.pods || [];

  const rows = [];
  for (const pod of pods) {
    for (const c of (pod.containers || [])) {
      rows.push({
        pod: pod.name, ctr: c.name,
        cpuNow: c.cpu_now, memNow: c.mem_now,
        cpuReq: c.cpu_req, cpuLim: c.cpu_lim,
        memReq: c.mem_req, memLim: c.mem_lim,
        noLimits: !c.cpu_lim && !c.mem_lim,
      });
    }
  }
  rows.sort((a, b) => parseCPU(b.cpuNow) - parseCPU(a.cpuNow));

  const podBody = rows.length === 0
    ? `<tr><td colspan="6" class="no-data">Нет данных</td></tr>`
    : rows.map(row => `<tr class="${row.noLimits ? 'row-warn' : ''}">
        <td>${esc(row.pod)}</td>
        <td>${esc(row.ctr)}</td>
        <td>${esc(row.cpuNow) || '—'}</td>
        <td>${esc(row.memNow) || '—'}</td>
        <td>${esc(row.cpuReq) || '—'} / ${row.cpuLim
          ? esc(row.cpuLim) : '<span style="color:var(--red)">не задан</span>'}</td>
        <td>${esc(row.memReq) || '—'} / ${row.memLim
          ? esc(row.memLim) : '<span style="color:var(--red)">не задан</span>'}</td>
      </tr>`).join('');

  return `
    <div class="section-title">Поды, сортировка по CPU</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Pod</th><th>Container</th><th>CPU now</th><th>Mem now</th><th>CPU req/lim</th><th>Mem req/lim</th></tr></thead>
      <tbody>${podBody}</tbody>
    </table></div>`;
}

// Логи
const LOG_FILTERS = [
  { key: 'error', label: 'Ошибки',         match: e => e.level === 'error' || e.level === 'fatal' },
  { key: 'warn',  label: 'Предупреждения', match: e => e.level === 'warn' },
  { key: 'info',  label: 'Инфо',           match: e => e.level === 'info' },
  { key: 'debug', label: 'Дебаг',          match: e => e.level === 'debug' },
];

function renderLogs() {
  if (!currentReport) return noData();
  const entries = currentReport.logs.entries || [];

  const filterDef = LOG_FILTERS.find(f => f.key === logFilter) || LOG_FILTERS[0];
  const filtered = entries.filter(filterDef.match);

  const btns = LOG_FILTERS.map(f => {
    const cnt = entries.filter(f.match).length;
    return `<button class="filter-btn ${logFilter === f.key ? 'active' : ''}" onclick="setLogFilter('${f.key}')">${f.label} (${cnt})</button>`;
  }).join('');

  const rows = filtered.length === 0
    ? `<tr><td colspan="4" class="no-data">Нет записей</td></tr>`
    : filtered.map((e, i) => {
        const hasDetail = e.msg || e.error;
        return `
          <tr class="log-row ${hasDetail ? 'expandable' : ''}" onclick="toggleDetail('log-${i}')">
            <td><span class="badge badge-${esc(e.level)}">${esc(e.level)}</span></td>
            <td>${esc(e.pod)}</td>
            <td>${esc(e.service)}</td>
            <td class="cell-trunc">${esc(e.msg)}</td>
          </tr>
          ${hasDetail ? `<tr id="log-${i}" class="detail-row">
            <td colspan="4">
              <div class="detail-content">
                ${e.msg   ? `<div><span class="detail-label">Сообщение</span><pre class="detail-pre">${esc(e.msg)}</pre></div>` : ''}
                ${e.error ? `<div><span class="detail-label">Ошибка</span><pre class="detail-pre detail-err">${esc(e.error)}</pre></div>` : ''}
                ${e.time  ? `<div class="detail-meta">Время: ${esc(e.time)}</div>` : ''}
              </div>
            </td>
          </tr>` : ''}`;
      }).join('');

  return `
    <div class="log-filters">${btns}</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Уровень</th><th>Pod</th><th>Сервис</th><th>Сообщение</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
    <p class="muted" style="font-size:12px;margin-top:8px">Клик выведит полный пул</p>`;
}

function setLogFilter(f) {
  logFilter = f;
  if (currentTab === 'logs') renderTab('logs');
}

// Проблемы
function renderIssues() {
  if (!currentReport) return noData();
  const issues = currentReport.issues || [];
  return issues.length === 0
    ? `<div class="no-data">Проблем не обнаружено</div>`
    : issues.map(issueCard).join('');
}

function issueCard(issue) {
  const podLine = issue.pod
    ? `<div class="issue-detail">Pod: ${esc(issue.pod)}${issue.container ? ' / ' + esc(issue.container) : ''}</div>`
    : '';
  const rec = issue.recommendation
    ? `<div class="issue-rec">${esc(issue.recommendation)}</div>` : '';
  return `<div class="issue-card sev-${esc(issue.severity)}">
    <div class="issue-header">
      <span class="badge badge-${esc(issue.severity)}">${esc(issue.severity)}</span>
      <span class="muted" style="font-size:11px">${esc(issue.type)}</span>
    </div>
    <div class="issue-msg">${esc(issue.message)}</div>
    ${podLine}${rec}
  </div>`;
}

// События
function renderEvents() {
  if (!currentReport) return noData();
  const events = currentReport.cluster.events || [];
  if (events.length === 0) return `<div class="no-data">Событий нет</div>`;

  const rows = events.map((e, i) => `
    <tr class="log-row expandable" onclick="toggleDetail('ev-${i}')">
      <td style="white-space:nowrap;font-size:12px">${esc(e.last_seen)}</td>
      <td>${esc(e.reason)}</td>
      <td>${esc(e.object)}</td>
      <td>${esc(e.kind)}</td>
      <td>${e.count > 1 ? e.count : ''}</td>
      <td class="cell-trunc">${esc(e.message)}</td>
    </tr>
    <tr id="ev-${i}" class="detail-row">
      <td colspan="6">
        <div class="detail-content">
          <pre class="detail-pre">${esc(e.message)}</pre>
        </div>
      </td>
    </tr>`).join('');

  return `
    <div class="table-wrap"><table>
      <thead><tr><th>Время</th><th>Причина</th><th>Объект</th><th>Тип</th><th>Кол-во</th><th>Сообщение</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
    <p class="muted" style="font-size:12px;margin-top:8px">Клик выведит полный пул</p>`;
}

function renderDatabase() {
  if (!currentReport) return noData();
  const db = currentReport.database?.postgresql || [];
  if (db.length === 0) return `<div class="no-data">Данные базы не спарсились</div>`;

  return db.map(conn => {
    const st = conn.stats || {};
    const si = conn.server_info;
    const cfg = conn.config || [];
    const owners = (conn.owners && conn.owners.length > 0)
      ? conn.owners.map(esc).join(', ')
      : '<span class="muted">—</span>';

    // Шапка карточки
    const header = `
      <div class="db-card-header">
        <span class="db-card-host">${esc(conn.host)}</span>
        <span class="muted">user: <strong>${esc(conn.user)}</strong></span>
        <span class="muted">db: <strong>${esc(conn.database)}</strong></span>
        ${conn.connection ? `<span class="ns-badge">${esc(conn.connection)}</span>` : ''}
        <span class="ns-badge">${esc(conn.secret)}</span>
      </div>`;

    // Статистика
    const connPct = (st.max_connections > 0)
      ? Math.round(st.active_connections / st.max_connections * 100) : null;
    const chPct = st.cache_hit_ratio || 0;
    const chClass = chPct >= 95 ? 'ok' : chPct >= 80 ? 'warn' : 'err';
    const connClass = connPct !== null ? (connPct > 80 ? 'err' : connPct > 60 ? 'warn' : 'ok') : 'ok';

    const statsSection = (st.version || st.db_size_pretty || st.active_connections) ? `
      <div class="db-section">
        <div class="section-title">Статистика</div>
        <div class="db-stats-row">
          ${st.version ? `<div class="db-stat"><span class="db-stat-label">Версия</span><span class="db-stat-val">${esc(st.version)}</span></div>` : ''}
          ${st.uptime ? `<div class="db-stat"><span class="db-stat-label">Аптайм</span><span class="db-stat-val">${esc(st.uptime)}</span></div>` : ''}
          ${st.db_size_pretty ? `<div class="db-stat"><span class="db-stat-label">Размер БД</span><span class="db-stat-val">${esc(st.db_size_pretty)}</span></div>` : ''}
          ${st.max_connections > 0 ? `
            <div class="db-stat">
              <span class="db-stat-label">Коннекты</span>
              <span class="db-stat-val">${st.active_connections} / ${st.max_connections}</span>
              <div class="metric-bar"><div class="fill ${connClass}" style="width:${Math.min(connPct,100)}%"></div></div>
            </div>` : ''}
          ${chPct > 0 ? `
            <div class="db-stat">
              <span class="db-stat-label">Cache Hit</span>
              <span class="db-stat-val">${chPct}%</span>
              <div class="metric-bar"><div class="fill ${chClass}" style="width:${Math.min(chPct,100)}%"></div></div>
            </div>` : ''}
        </div>
      </div>` : '';

    // Серверные метрики (только если собрались)
    const serverSection = si ? `
      <div class="db-section">
        <div class="section-title">Сервер</div>
        <div class="db-stats-row">
          ${si.cpu_count ? `<div class="db-stat"><span class="db-stat-label">CPU</span><span class="db-stat-val">${si.cpu_count} cores</span></div>` : ''}
          ${si.total_ram_mb ? `
            <div class="db-stat">
              <span class="db-stat-label">RAM</span>
              <span class="db-stat-val">${(si.total_ram_mb/1024).toFixed(1)} GB${si.free_ram_mb ? ` / свободно ${(si.free_ram_mb/1024).toFixed(1)} GB` : ''}</span>
              ${si.free_ram_mb ? `<div class="metric-bar"><div class="fill ${((si.total_ram_mb-si.free_ram_mb)/si.total_ram_mb*100)>80?'err':((si.total_ram_mb-si.free_ram_mb)/si.total_ram_mb*100)>60?'warn':'ok'}" style="width:${Math.min((si.total_ram_mb-si.free_ram_mb)/si.total_ram_mb*100,100).toFixed(0)}%"></div></div>` : ''}
            </div>` : ''}
          ${si.load_avg ? `<div class="db-stat"><span class="db-stat-label">Load Avg</span><span class="db-stat-val">${esc(si.load_avg)}</span></div>` : ''}
        </div>
      </div>` : '';

    // Конфиг
    const configSection = cfg.length > 0 ? `
      <div class="db-section">
        <div class="section-title">Конфиг PostgreSQL</div>
        <div class="config-grid">
          ${cfg.map(p => `
            <div class="config-item">
              <span class="config-name">${esc(p.name)}</span>
              <span class="config-val">${esc(p.setting)}${p.unit ? ' ' + esc(p.unit) : ''}</span>
            </div>`).join('')}
        </div>
      </div>` : '';

    // Роли
    const ownersSection = `
      <div class="db-section">
        <div class="section-title">Роли (login)</div>
        <div style="font-size:13px;color:var(--blue)">${owners}</div>
      </div>`;

    return `<div class="db-card">${header}${statsSection}${serverSection}${configSection}${ownersSection}</div>`;
  }).join('');
}

//Ноды

function renderNodes() {
 if (!currentReport) return noData();
  const nodes = currentReport.cluster.nodes || [];
  
  if (nodes.length === 0) return `<div class="no-data">Нет данных о нодах</div>`;

  const rows = nodes.map(n => {

    let cpuPct = null;
    if (n.cpu_capacity && n.cpu_used) {
      let usedVal = parseFloat(n.cpu_used);
      if (usedVal > 100) usedVal = usedVal / 1000;
      cpuPct = Math.round((usedVal / n.cpu_capacity) * 100);
    }
    
    let memPct = null;
    if (n.memory_capacity_kb && n.mem_used) {
      let capMiB = n.memory_capacity_kb / 1024;
      let usedVal = parseFloat(n.mem_used);
      memPct = Math.round((usedVal / capMiB) * 100);
    }

    const capMemGB = n.memory_capacity_kb ? (n.memory_capacity_kb / 1024 / 1024).toFixed(1) : '—';
    
    return `<tr>
      <td>
        <strong>${esc(n.name)}</strong><br>
        <span class="muted" style="font-size:11px">${esc(n.os || '').split('(')[0]}</span>
      </td>
      <td>
        <div>${n.cpu_capacity} vCPU</div>
        ${cpuPct !== null ? `
          <div class="metric-bar" style="margin-top:4px">
            <div class="fill ${cpuPct > 80 ? 'err' : cpuPct > 60 ? 'warn' : 'ok'}" style="width:${Math.min(cpuPct, 100)}%"></div>
          </div>
          <small>${cpuPct}% used (${n.cpu_used || 0})</small>
        ` : '<small class="muted">Нет метрик</small>'}
      </td>
      <td>
        <div>${capMemGB} GB</div>
        ${memPct !== null ? `
          <div class="metric-bar" style="margin-top:4px">
            <div class="fill ${memPct > 80 ? 'err' : memPct > 60 ? 'warn' : 'ok'}" style="width:${Math.min(memPct, 100)}%"></div>
          </div>
          <small>${memPct}% used (${n.mem_used || 0} Mi)</small>
        ` : '<small class="muted">Нет метрик</small>'}
      </td>
      <td>${esc(n.load_avg || '—')}</td>
      <td>${esc(n.disk_iops || '—')}</td>
      <td><span class="badge ${n.ready ? 'ok' : 'err'}">${n.ready ? 'Ready' : 'NotReady'}</span></td>
    </tr>`;
  }).join('');

  return `
    <div class="section-title">Ноды кластера</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Node</th><th>CPU</th><th>Memory</th><th>Load Avg</th><th>Disk IOPS</th><th>Status</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>`;
}

// Загрузка
function renderUpload() {
  return `
    <div class="upload-zone" id="upload-zone">
      <input type="file" id="file-input" accept=".json,.gz">
      <div class="upload-label">Перетащите или нажмите для выбора, принимает только формат json.gz</div>
    </div>
    <div id="upload-status"></div>`;
}

function bindUpload() {
  const zone  = document.getElementById('upload-zone');
  const input = document.getElementById('file-input');
  if (!zone || !input) return;

  zone.addEventListener('click', () => input.click());
  input.addEventListener('change', e => { if (e.target.files[0]) doUpload(e.target.files[0]); });
  zone.addEventListener('dragover',  e => { e.preventDefault(); zone.classList.add('drag-over'); });
  zone.addEventListener('dragleave', () => zone.classList.remove('drag-over'));
  zone.addEventListener('drop', e => {
    e.preventDefault();
    zone.classList.remove('drag-over');
    if (e.dataTransfer.files[0]) doUpload(e.dataTransfer.files[0]);
  });
}

async function doUpload(file) {
  const statusEl = document.getElementById('upload-status');
  if (statusEl) statusEl.innerHTML = '<p class="muted">Загрузка...</p>';

  const fd = new FormData();
  fd.append('file', file);

  try {
    const res  = await fetch('/api/upload', { method: 'POST', body: fd });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Ошибка сервера');

    currentReport = data.report;
    updateNsBadge(currentReport.meta.namespace);

    if (statusEl) {
      statusEl.innerHTML = `<div class="upload-status ok">
        Файл загружен. Namespace: ${esc(currentReport.meta.namespace)},
        подов: ${(currentReport.cluster.pods || []).length},
        проблем: ${(currentReport.issues || []).length}.
      </div>`;
    }
    setTimeout(() => showTab('load'), 1000);
  } catch (e) {
    if (statusEl) {
      statusEl.innerHTML = `<div class="upload-status err">Ошибка: ${esc(e.message)}</div>`;
    }
  }
}

// Раскрытие строк
function toggleDetail(id) {
  const el = document.getElementById(id);
  if (el) el.classList.toggle('open');
}

// Вспомогательные
function parseCPU(s) {
  if (!s) return 0;
  if (s.endsWith('m')) return parseInt(s, 10);
  return Math.round(parseFloat(s) * 1000);
}

function esc(s) {
  if (!s && s !== 0) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function noData() {
  return `<div class="no-data">Ничего нет, жду загрузки.</div>`;
}
