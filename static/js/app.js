'use strict';

let currentReport = null;
let currentTab = 'overview';
let logFilter = 'all';

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

  showTab('overview');
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
    case 'overview': el.innerHTML = renderOverview(); break;
    case 'load':     el.innerHTML = renderLoad();     break;
    case 'logs':     el.innerHTML = renderLogs();     break;
    case 'issues':   el.innerHTML = renderIssues();   break;
    case 'events':   el.innerHTML = renderEvents();   break;
    case 'upload':   el.innerHTML = renderUpload(); bindUpload(); break;
  }
}

function updateNsBadge(ns) {
  const el = document.getElementById('ns-badge');
  if (el) el.textContent = ns;
}

// --- Обзор ---
function renderOverview() {
  if (!currentReport) {
    return `<div class="no-data">Нет данных. Загрузите отчёт на вкладке "Загрузка".</div>`;
  }
  const r = currentReport;
  const pods   = r.cluster.pods   || [];
  const nodes  = r.cluster.nodes  || [];
  const issues = r.issues         || [];
  const hpas   = r.cluster.hpas   || [];

  const critical = issues.filter(i => i.severity === 'critical').length;
  const high     = issues.filter(i => i.severity === 'high').length;

  const alertHtml = (critical > 0 || high > 0) ? `
    <div class="alert-banner">${critical} критических, ${high} важных проблем требуют внимания</div>` : '';

  const statsHtml = `<div class="stats-grid">
    <div class="stat-card"><div class="stat-num">${pods.length}</div><div class="stat-label">Подов</div></div>
    <div class="stat-card"><div class="stat-num">${nodes.length}</div><div class="stat-label">Узлов</div></div>
    <div class="stat-card"><div class="stat-num">${issues.length}</div><div class="stat-label">Проблем</div></div>
    <div class="stat-card"><div class="stat-num">${hpas.length}</div><div class="stat-label">HPA</div></div>
  </div>`;

  const topIssues = issues.slice(0, 5);
  const issuesHtml = topIssues.length === 0
    ? `<p class="muted">Проблем не обнаружено</p>`
    : topIssues.map(issueCard).join('');

  const meta = r.meta.collected_at
    ? `<p class="muted" style="margin-top:16px;font-size:12px">Собрано: ${esc(r.meta.collected_at)}</p>` : '';

  return `${statsHtml}${alertHtml}<div class="section-title">Топ проблем</div>${issuesHtml}${meta}`;
}

// --- Нагрузка ---
function renderLoad() {
  if (!currentReport) return `<div class="no-data">Нет данных</div>`;
  const r = currentReport;
  const hpas = r.cluster.hpas || [];
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

  const hpaBody = hpas.length === 0
    ? `<tr><td colspan="6" class="no-data">HPA не настроены</td></tr>`
    : hpas.map(h => `<tr>
        <td>${esc(h.name)}</td><td>${esc(h.target)}</td>
        <td>${h.min}</td><td>${h.max}</td><td>${h.current}</td>
        <td>${h.desired !== h.current
          ? `<span style="color:var(--yellow)">${h.desired}</span>` : h.desired}</td>
      </tr>`).join('');

  const podBody = rows.length === 0
    ? `<tr><td colspan="6" class="no-data">Нет данных о подах</td></tr>`
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
    <div class="section-title">HPA — автомасштабирование</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Имя</th><th>Цель</th><th>Min</th><th>Max</th><th>Текущие</th><th>Желаемые</th></tr></thead>
      <tbody>${hpaBody}</tbody>
    </table></div>
    <div class="section-title">Поды (сортировка по CPU)</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Pod</th><th>Container</th><th>CPU now</th><th>Mem now</th><th>CPU req/lim</th><th>Mem req/lim</th></tr></thead>
      <tbody>${podBody}</tbody>
    </table></div>`;
}

// --- Логи ---
function renderLogs() {
  if (!currentReport) return `<div class="no-data">Нет данных</div>`;
  const entries = currentReport.logs.entries || [];

  const filtered = logFilter === 'all'
    ? entries
    : entries.filter(e => logFilter === 'error'
        ? (e.level === 'error' || e.level === 'fatal')
        : e.level === logFilter);

  const count = (lvl) => lvl === 'all' ? entries.length
    : lvl === 'error' ? entries.filter(e => e.level === 'error' || e.level === 'fatal').length
    : entries.filter(e => e.level === lvl).length;

  const filterBtns = [
    ['all',  'Все'],
    ['error','Ошибки'],
    ['warn', 'Предупреждения'],
  ].map(([f, label]) =>
    `<button class="filter-btn ${logFilter === f ? 'active' : ''}" onclick="setLogFilter('${f}')">${label} (${count(f)})</button>`
  ).join('');

  const rows = filtered.length === 0
    ? `<tr><td colspan="5" class="no-data">Нет записей</td></tr>`
    : filtered.map(e => `<tr>
        <td><span class="badge badge-${esc(e.level)}">${esc(e.level)}</span></td>
        <td>${esc(e.pod)}</td>
        <td>${esc(e.service)}</td>
        <td class="cell-trunc">${esc(e.msg)}</td>
        <td class="cell-trunc" style="color:var(--red);font-size:11px">${esc(e.error)}</td>
      </tr>`).join('');

  return `
    <div class="log-filters">${filterBtns}</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Уровень</th><th>Pod</th><th>Сервис</th><th>Сообщение</th><th>Ошибка</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>`;
}

function setLogFilter(f) {
  logFilter = f;
  if (currentTab === 'logs') renderTab('logs');
}

// --- Проблемы ---
function renderIssues() {
  if (!currentReport) return `<div class="no-data">Нет данных</div>`;
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

// --- События ---
function renderEvents() {
  if (!currentReport) return `<div class="no-data">Нет данных</div>`;
  const events = currentReport.cluster.events || [];
  if (events.length === 0) return `<div class="no-data">Событий нет</div>`;

  const rows = events.map(e => `<tr>
    <td style="white-space:nowrap;font-size:12px">${esc(e.last_seen)}</td>
    <td>${esc(e.reason)}</td>
    <td>${esc(e.object)}</td>
    <td>${esc(e.kind)}</td>
    <td>${e.count > 1 ? e.count : ''}</td>
    <td class="cell-trunc">${esc(e.message)}</td>
  </tr>`).join('');

  return `<div class="table-wrap"><table>
    <thead><tr><th>Время</th><th>Причина</th><th>Объект</th><th>Тип</th><th>Кол-во</th><th>Сообщение</th></tr></thead>
    <tbody>${rows}</tbody>
  </table></div>`;
}

// --- Загрузка ---
function renderUpload() {
  return `
    <div class="upload-zone" id="upload-zone">
      <input type="file" id="file-input" accept=".json,.gz">
      <div class="upload-label">Перетащите elma-diag-*.json.gz или нажмите для выбора</div>
      <div class="upload-hint">Создайте архив скриптом: ./diag_collector.sh</div>
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
      const podCount   = (currentReport.cluster.pods   || []).length;
      const issueCount = (currentReport.issues          || []).length;
      statusEl.innerHTML = `<div class="upload-status ok">
        Файл загружен. Namespace: ${esc(currentReport.meta.namespace)},
        подов: ${podCount}, проблем: ${issueCount}.
      </div>`;
    }
    setTimeout(() => showTab('overview'), 1000);
  } catch (e) {
    if (statusEl) {
      statusEl.innerHTML = `<div class="upload-status err">Ошибка: ${esc(e.message)}</div>`;
    }
  }
}

// --- Вспомогательные ---
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
