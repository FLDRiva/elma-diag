package analyzer

import (
	"fmt"

	"elma-diag/models"
)

// Analyze проверяет отчёт и возвращает список найденных проблем.
func Analyze(report *models.DiagnosticReport) []models.Issue {
	var issues []models.Issue
	issues = append(issues, checkPods(report.Cluster.Pods)...)
	issues = append(issues, checkEvents(report.Cluster.Events)...)
	issues = append(issues, checkLogs(report.Logs.Entries)...)
	for i := range issues {
		if issues[i].Recommendation == "" {
			issues[i].Recommendation = recommend(issues[i])
		}
	}
	return issues
}

func checkPods(pods []models.Pod) []models.Issue {
	var issues []models.Issue
	for _, pod := range pods {
		if pod.Phase != "Running" && pod.Phase != "Succeeded" && pod.Phase != "" {
			issues = append(issues, models.Issue{
				Type:     "pod_status",
				Severity: "critical",
				Pod:      pod.Name,
				Message:  fmt.Sprintf("Pod в состоянии %s", pod.Phase),
			})
		}
		for _, c := range pod.Containers {
			if c.LastState == "OOMKilled" {
				issues = append(issues, models.Issue{
					Type:      "oom",
					Severity:  "critical",
					Pod:       pod.Name,
					Container: c.Name,
					Message:   "Контейнер убит OOMKiller",
				})
			}
			if c.Restarts > 5 {
				issues = append(issues, models.Issue{
					Type:      "crashloop",
					Severity:  "high",
					Pod:       pod.Name,
					Container: c.Name,
					Message:   fmt.Sprintf("Контейнер перезапущен %d раз", c.Restarts),
				})
			}
			if c.CPULim == "" && c.MemLim == "" {
				issues = append(issues, models.Issue{
					Type:      "no_limits",
					Severity:  "medium",
					Pod:       pod.Name,
					Container: c.Name,
					Message:   "Не заданы resource limits",
				})
			}
		}
	}
	return issues
}

func checkEvents(events []models.Event) []models.Issue {
	var issues []models.Issue
	for _, e := range events {
		switch e.Reason {
		case "OOMKilling", "OOMKilled":
			issues = append(issues, models.Issue{
				Type:     "event",
				Severity: "critical",
				Pod:      e.Object,
				Message:  fmt.Sprintf("OOM: %s", e.Message),
			})
		case "BackOff", "CrashLoopBackOff":
			issues = append(issues, models.Issue{
				Type:     "event",
				Severity: "high",
				Pod:      e.Object,
				Message:  fmt.Sprintf("CrashLoop: %s", e.Message),
			})
		case "FailedScheduling":
			issues = append(issues, models.Issue{
				Type:     "event",
				Severity: "high",
				Pod:      e.Object,
				Message:  fmt.Sprintf("Не удалось запустить pod: %s", e.Message),
			})
		}
	}
	return issues
}

func checkLogs(entries []models.LogEntry) []models.Issue {
	errorCount := 0
	for _, e := range entries {
		if e.Level == "error" || e.Level == "fatal" {
			errorCount++
		}
	}
	if errorCount == 0 {
		return nil
	}
	severity := "medium"
	if errorCount > 50 {
		severity = "high"
	}
	return []models.Issue{{
		Type:     "log_errors",
		Severity: severity,
		Message:  fmt.Sprintf("В логах найдено %d ошибок", errorCount),
	}}
}

func recommend(issue models.Issue) string {
	switch issue.Type {
	case "oom":
		return "Увеличьте limits.memory в deployment"
	case "crashloop":
		return "Проверьте логи предыдущего запуска: kubectl logs " + issue.Pod + " --previous"
	case "no_limits":
		return "Добавьте resources.limits.cpu и resources.limits.memory"
	case "pod_status":
		return "kubectl describe pod " + issue.Pod
	case "event":
		return "kubectl describe pod " + issue.Pod
	case "log_errors":
		return "Откройте вкладку Логи для деталей"
	}
	return "Требуется ручной анализ"
}
