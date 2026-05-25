package analyzer

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// Issue представляет проблему в системе
type Issue struct {
	Type           string `json:"type"`
	Severity       string `json:"severity"`
	Pod            string `json:"pod,omitempty"`
	Container      string `json:"container,omitempty"`
	Pattern        string `json:"pattern,omitempty"`
	Count          int    `json:"count,omitempty"`
	Status         string `json:"status,omitempty"`
	Reason         string `json:"reason,omitempty"`
	Message        string `json:"message"`
	Correlation    string `json:"correlation,omitempty"`
	Recommendation string `json:"recommendation,omitempty"`
}

func AnalyzeIssues(dir string) ([]Issue, error) {
	var issues []Issue

	// Чтение предварительно сгенерированного анализа
	analysisFile := filepath.Join(dir, "analysis", "issues.json")
	if data, err := os.ReadFile(analysisFile); err == nil {
		var analysis struct {
			Issues []Issue `json:"issues"`
		}
		json.Unmarshal(data, &analysis)
		issues = append(issues, analysis.Issues...)
	}

	// Дополнительный анализ: корреляция событий и логов
	issues = append(issues, correlateEventsAndLogs(dir)...)

	// Добавление рекомендаций
	for i := range issues {
		issues[i].Recommendation = getRecommendation(issues[i])
	}

	return issues, nil
}

func correlateEventsAndLogs(dir string) []Issue {
	var correlated []Issue

	// Чтение warning событий
	eventsFile := filepath.Join(dir, "events", "events_warnings.txt")
	eventsData, err := os.ReadFile(eventsFile)
	if err != nil {
		return correlated
	}

	events := strings.Split(string(eventsData), "\n")
	
	// Поиск корреляций с логами
	logsDir := filepath.Join(dir, "logs")
	pods, _ := os.ReadDir(logsDir)
	
	for _, podEntry := range pods {
		if !podEntry.IsDir() {
			continue
		}
		podName := podEntry.Name()
		
		// Поиск событий для этого пода
		for _, event := range events {
			if strings.Contains(event, podName) {
				// Нашли событие связанное с подом
				if strings.Contains(event, "OOMKilled") || strings.Contains(event, "OutOfMemory") {
					correlated = append(correlated, Issue{
						Type:     "correlation",
						Severity: "critical",
						Pod:      podName,
						Message:  "Pod был завершен из-за нехватки памяти (OOM)",
						Correlation: "Событие Kubernetes + логи приложения",
						Recommendation: "Увеличьте лимиты памяти для контейнера или оптимизируйте потребление памяти",
					})
				}
				if strings.Contains(event, "CrashLoopBackOff") {
					correlated = append(correlated, Issue{
						Type:     "correlation",
						Severity: "critical",
						Pod:      podName,
						Message:  "Pod перезапускается циклически",
						Correlation: "Событие Kubernetes + проверка логов",
						Recommendation: "Проверьте логи предыдущего запуска (_previous.log) для выявления причины сбоя",
					})
				}
				if strings.Contains(event, "FailedScheduling") {
					correlated = append(correlated, Issue{
						Type:     "correlation",
						Severity: "high",
						Pod:      podName,
						Message:  "Не удалось запланировать Pod на узлы",
						Correlation: "Событие Kubernetes - ресурсы кластера",
						Recommendation: "Проверьте доступные ресурсы узлов (kubectl top nodes) и запросы ресурсов в deployment",
					})
				}
			}
		}
	}

	return correlated
}

func getRecommendation(issue Issue) string {
	if issue.Recommendation != "" {
		return issue.Recommendation
	}

	switch issue.Type {
	case "log_error":
		if issue.Pattern == "OOMKilled" {
			return "Увеличьте лимиты памяти (resources.limits.memory) в deployment"
		}
		if issue.Pattern == "Exception" || issue.Pattern == "Error" {
			return "Изучите стек ошибки в логах. Проверьте подключение к БД, внешним сервисам"
		}
		return "Проанализируйте логи вокруг времени возникновения ошибки"
		
	case "pod_status":
		if issue.Status == "CrashLoopBackOff" {
			return "Проверьте: 1) Логи предыдущего запуска 2) Liveness/readiness пробы 3) Доступность зависимостей"
		}
		if issue.Status == "ImagePullBackOff" {
			return "Проверьте: 1) Имя образа 2) Доступность registry 3) ImagePullSecrets"
		}
		if issue.Status == "Pending" {
			return "Проверьте: 1) Доступные ресурсы кластера 2) Node selectors 3) Affinity rules"
		}
		
	case "k8s_events":
		return "Изучите детали событий: kubectl describe pod <pod-name> -n elma365"
	}

	return "Требуется ручной анализ проблемы"
}
