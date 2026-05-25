// Глобальное состояние
let currentData = null;

// Переключение вкладок
function showTab(tabId) {
    document.querySelectorAll('.tab-content').forEach(tab => tab.classList.remove('active'));
    document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));

    document.getElementById(tabId).classList.add('active');
    document.querySelector(`button[onclick="showTab('${tabId}')"]`).classList.add('active');

    // Загрузка данных при переключении
    if (currentData) {
        loadTabData(tabId);
    }
}

// Загрузка данных вкладки
function loadTabData(tabId) {
    switch(tabId) {
        case 'overview':
            loadOverview();
            break;
        case 'logs':
            loadLogs();
            break;
        case 'load':
            loadResources();
            break;
        case 'issues':
            loadIssues();
            break;
        case 'events':
            loadEvents();
            break;
        case 'storage':
            loadStorage();
            break;
    }
}

// Загрузка обзора
async function loadOverview() {
    if (!currentData) return;

    document.getElementById('pods-count').textContent = currentData.cluster_info?.pods_count || 0;
    document.getElementById('nodes-count').textContent = currentData.cluster_info?.nodes_count || 0;
    document.getElementById('issues-count').textContent = currentData.issues?.length || 0;
    document.getElementById('hpa-count').textContent = currentData.resources?.hpa?.length || 0;

    // Последние проблемы
    const issuesContainer = document.getElementById('recent-issues');
    if (currentData.issues && currentData.issues.length > 0) {
        issuesContainer.innerHTML = currentData.issues.slice(0, 5).map(issue => createIssueCard(issue)).join('');
    } else {
        issuesContainer.innerHTML = '<p style="color: #28a745; font-weight: 600;">✅ Проблем не обнаружено!</p>';
    }
}

// Загрузка логов
async function loadLogs() {
    try {
        const response = await fetch('/api/logs');
        const logs = await response.json();

        const container = document.getElementById('logs-container');
        if (!logs || logs.length === 0) {
            container.innerHTML = '<p style="color: #666;">Логи отсутствуют</p>';
            return;
        }

        container.innerHTML = logs.map(log => `
            <div class="issue-card" style="margin-bottom: 10px;">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
                    <strong style="color: #667eea;">${log.pod}/${log.container}</strong>
                    <div>
                        <span class="severity-badge ${log.errors > 0 ? 'severity-critical' : 'severity-low'}">
                            Ошибок: ${log.errors}
                        </span>
                        <span class="severity-badge ${log.warnings > 0 ? 'severity-medium' : 'severity-low'}" style="margin-left: 5px;">
                            Предупреждений: ${log.warnings}
                        </span>
                    </div>
                </div>
                <div class="code-block" style="max-height: 300px; overflow-y: auto;">
                    ${escapeHtml(log.content.substring(0, 2000))}${log.content.length > 2000 ? '...' : ''}
                </div>
            </div>
        `).join('');
    } catch (e) {
        console.error('Ошибка загрузки логов:', e);
    }
}

// Загрузка ресурсов (HPA, top pods)
async function loadResources() {
    try {
        const response = await fetch('/api/resources');
        const resources = await response.json();

        // HPA таблица
        const hpaTable = document.querySelector('#hpa-table tbody');
        if (resources.hpa && resources.hpa.length > 0) {
            hpaTable.innerHTML = resources.hpa.map(hpa => `
                <tr>
                    <td>${hpa.name}</td>
                    <td>${hpa.min_replicas}</td>
                    <td>${hpa.max_replicas}</td>
                    <td>${hpa.current_replicas}</td>
                    <td>${hpa.target_cpu || 'N/A'}</td>
                </tr>
            `).join('');
        } else {
            hpaTable.innerHTML = '<tr><td colspan="5" style="text-align: center; color: #666;">Нет данных</td></tr>';
        }

        // Top pods
        const podsTable = document.querySelector('#top-pods-table tbody');
        if (resources.top_pods && resources.top_pods.length > 0) {
            podsTable.innerHTML = resources.top_pods.map(pod => `
                <tr>
                    <td>${pod.name}</td>
                    <td>${pod.container}</td>
                    <td>${pod.cpu}</td>
                    <td>${pod.memory}</td>
                </tr>
            `).join('');
        } else {
            podsTable.innerHTML = '<tr><td colspan="4" style="text-align: center; color: #666;">Нет данных</td></tr>';
        }

        // Top nodes
        const nodesTable = document.querySelector('#top-nodes-table tbody');
        if (resources.top_nodes && resources.top_nodes.length > 0) {
            nodesTable.innerHTML = resources.top_nodes.map(node => `
                <tr>
                    <td>${node.name}</td>
                    <td>${node.cpu}</td>
                    <td>${node.memory}</td>
                </tr>
            `).join('');
        } else {
            nodesTable.innerHTML = '<tr><td colspan="3" style="text-align: center; color: #666;">Нет данных</td></tr>';
        }
    } catch (e) {
        console.error('Ошибка загрузки ресурсов:', e);
    }
}

// Загрузка проблем
async function loadIssues() {
    try {
        const response = await fetch('/api/issues');
        const issues = await response.json();

        const container = document.getElementById('issues-container');
        if (!issues || issues.length === 0) {
            container.innerHTML = '<p style="color: #28a745; font-weight: 600;">✅ Проблем не обнаружено!</p>';
            return;
        }

        container.innerHTML = issues.map(issue => createIssueCard(issue)).join('');
    } catch (e) {
        console.error('Ошибка загрузки проблем:', e);
    }
}

// Создание карточки проблемы
function createIssueCard(issue) {
    const severityClass = `issue-${issue.severity.toLowerCase()}`;
    const badgeClass = `severity-${issue.severity.toLowerCase()}`;

    return `
        <div class="issue-card ${severityClass}">
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
                <span class="severity-badge ${badgeClass}">${issue.severity}</span>
                <span style="color: #666; font-size: 12px;">${issue.type}</span>
            </div>
            <h4 style="margin-bottom: 10px; color: #333;">${issue.message}</h4>
            ${issue.pod ? `<p><strong>Pod:</strong> ${issue.pod}</p>` : ''}
            ${issue.container ? `<p><strong>Container:</strong> ${issue.container}</p>` : ''}
            ${issue.pattern ? `<p><strong>Паттерн:</strong> ${issue.pattern} (${issue.count} раз)</p>` : ''}
            ${issue.status ? `<p><strong>Статус:</strong> ${issue.status}</p>` : ''}
            ${issue.recommendation ? `
                <div style="background: #e8f4fd; padding: 10px; border-radius: 5px; margin-top: 10px;">
                    <strong style="color: #0066cc;">💡 Рекомендация:</strong>
                    <p style="margin: 5px 0 0 0; color: #333;">${issue.recommendation}</p>
                </div>
            ` : ''}
        </div>
    `;
}

// Загрузка событий
async function loadEvents() {
    try {
        const showWarningsOnly = document.getElementById('show-warnings-only').checked;
        const type = showWarningsOnly ? 'warning' : 'all';

        const response = await fetch(`/api/events?type=${type}`);
        const events = await response.json();

        const table = document.querySelector('#events-table tbody');
        if (!events || events.length === 0) {
            table.innerHTML = '<tr><td colspan="5" style="text-align: center; color: #666;">Нет данных</td></tr>';
            return;
        }

        table.innerHTML = events.map(event => `
            <tr style="${event.type === 'Warning' ? 'background: #fff3cd;' : ''}">
                <td>${event.last_timestamp || '-'}</td>
                <td><span class="severity-badge ${event.type === 'Warning' ? 'severity-medium' : 'severity-low'}">${event.type}</span></td>
                <td>${event.object || '-'}</td>
                <td>${event.reason || '-'}</td>
                <td>${event.message || '-'}</td>
            </tr>
        `).join('');
    } catch (e) {
        console.error('Ошибка загрузки событий:', e);
    }
}

// Загрузка хранилища
async function loadStorage() {
    try {
        const response = await fetch('/api/resources');
        const resources = await response.json();

        const table = document.querySelector('#pvc-table tbody');
        if (resources.pvc_status && resources.pvc_status.length > 0) {
            table.innerHTML = resources.pvc_status.map(pvc => `
                <tr>
                    <td>${pvc.name}</td>
                    <td><span class="severity-badge ${pvc.status === 'Bound' ? 'severity-low' : 'severity-medium'}">${pvc.status}</span></td>
                    <td>${pvc.volume || '-'}</td>
                    <td>${pvc.capacity || '-'}</td>
                </tr>
            `).join('');
        } else {
            table.innerHTML = '<tr><td colspan="4" style="text-align: center; color: #666;">Нет данных</td></tr>';
        }
    } catch (e) {
        console.error('Ошибка загрузки хранилища:', e);
    }
}

// Обработка загрузки файла
document.getElementById('file-input')?.addEventListener('change', async (e) => {
    const file = e.target.files[0];
    if (!file) return;

    const formData = new FormData();
    formData.append('file', file);

    const uploadArea = document.querySelector('.upload-area');
    uploadArea.innerHTML = '<div style="font-size: 48px;">⏳</div><h3>Обработка...</h3>';

    try {
        const response = await fetch('/api/upload', {
            method: 'POST',
            body: formData
        });

        const result = await response.json();

        if (result.status === 'success') {
            currentData = result.report;
            uploadArea.innerHTML = `
                <div style="font-size: 48px;">✅</div>
                <h3>${result.message}</h3>
                <p class="help-text">Данные загружены. Перейдите на другие вкладки для просмотра.</p>
            `;

            // Автопереключение на обзор
            showTab('overview');
        } else {
            throw new Error(result.message || 'Ошибка загрузки');
        }
    } catch (error) {
        uploadArea.innerHTML = `
            <div style="font-size: 48px;">❌</div>
            <h3>Ошибка: ${error.message}</h3>
            <p class="help-text">Попробуйте загрузить файл снова</p>
        `;
    }
});

// Фильтр логов
document.getElementById('log-filter')?.addEventListener('input', (e) => {
    const filter = e.target.value.toLowerCase();
    document.querySelectorAll('#logs-container .issue-card').forEach(card => {
        const text = card.textContent.toLowerCase();
        card.style.display = text.includes(filter) ? 'block' : 'none';
    });
});

// Чекбокс событий
document.getElementById('show-warnings-only')?.addEventListener('change', () => {
    loadEvents();
});

// Экранирование HTML
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Проверка здоровья сервиса
async function checkHealth() {
    try {
        const response = await fetch('/api/health');
        const health = await response.json();
        console.log('Сервис здоров:', health);
    } catch (e) {
        console.error('Сервис недоступен:', e);
    }
}

// Инициализация
document.addEventListener('DOMContentLoaded', () => {
    checkHealth();
    showTab('overview');
});