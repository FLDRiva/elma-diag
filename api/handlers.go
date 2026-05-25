package api

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"elma365-diagnostics/analyzer"
	"elma365-diagnostics/models"
)

var (
	currentReport *models.DiagnosticReport
	workDir       string
	mu            sync.RWMutex
)

func HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(models.HealthResponse{
		Status:  "healthy",
		Service: "elma365-diagnostics",
		Version: "1.5.4",
	})
}

func GetReportHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	mu.RLock()
	defer mu.RUnlock()
	
	if currentReport == nil {
		json.NewEncoder(w).Encode(map[string]string{"status": "no_data", "message": "Загрузите данные диагностики"})
		return
	}
	json.NewEncoder(w).Encode(currentReport)
}

func GetLogsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	pod := r.URL.Query().Get("pod")
	container := r.URL.Query().Get("container")
	search := r.URL.Query().Get("search")
	showErrors := r.URL.Query().Get("errors") == "true"

	mu.RLock()
	defer mu.RUnlock()

	if currentReport == nil || currentReport.Logs == nil {
		json.NewEncoder(w).Encode([]interface{}{})
		return
	}

	var result []models.LogEntry
	for podName, entries := range currentReport.Logs {
		if pod != "" && !strings.Contains(podName, pod) {
			continue
		}
		for _, entry := range entries {
			if container != "" && !strings.Contains(entry.Container, container) {
				continue
			}
			if search != "" && !strings.Contains(strings.ToLower(entry.Content), strings.ToLower(search)) {
				continue
			}
			if showErrors && entry.Errors == 0 {
				continue
			}
			result = append(result, entry)
		}
	}

	json.NewEncoder(w).Encode(result)
}

func GetResourcesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	mu.RLock()
	defer mu.RUnlock()

	if currentReport == nil {
		json.NewEncoder(w).Encode(map[string]interface{}{"status": "no_data"})
		return
	}
	json.NewEncoder(w).Encode(currentReport.Resources)
}

func GetIssuesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	mu.RLock()
	defer mu.RUnlock()

	if currentReport == nil {
		json.NewEncoder(w).Encode([]interface{}{})
		return
	}
	json.NewEncoder(w).Encode(currentReport.Issues)
}

func GetEventsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	eventType := r.URL.Query().Get("type") // all, warning, normal

	mu.RLock()
	defer mu.RUnlock()

	if currentReport == nil || currentReport.Events == nil {
		json.NewEncoder(w).Encode([]interface{}{})
		return
	}

	var result []models.K8sEvent
	for _, event := range currentReport.Events {
		if eventType == "warning" && event.Type != "Warning" {
			continue
		}
		if eventType == "normal" && event.Type != "Normal" {
			continue
		}
		result = append(result, event)
	}

	json.NewEncoder(w).Encode(result)
}

func UploadHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, `{"error": "Не удалось получить файл"}`, http.StatusBadRequest)
		return
	}
	defer file.Close()

	fmt.Printf("📥 Загрузка файла: %s\n", header.Filename)

	// Создание временной директории
	tmpDir, err := os.MkdirTemp("", "diag_upload_*")
	if err != nil {
		http.Error(w, `{"error": "Ошибка создания временной директории"}`, http.StatusInternalServerError)
		return
	}
	defer os.RemoveAll(tmpDir)

	// Распаковка архива
	if err := extractArchive(file, tmpDir); err != nil {
		http.Error(w, fmt.Sprintf(`{"error": "Ошибка распаковки: %v"}`, err), http.StatusBadRequest)
		return
	}

	// Анализ данных
	report, err := analyzeData(tmpDir)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error": "Ошибка анализа: %v"}`, err), http.StatusInternalServerError)
		return
	}

	// Сохранение отчета
	mu.Lock()
	currentReport = report
	workDir = tmpDir
	mu.Unlock()

	fmt.Printf("✅ Данные успешно проанализированы. Найдено проблем: %d\n", len(report.Issues))

	json.NewEncoder(w).Encode(models.UploadResponse{
		Status:  "success",
		Message: fmt.Sprintf("Архив обработан. Найдено %d проблем, %d подов, %d событий", len(report.Issues), report.ClusterInfo.PodsCount, len(report.Events)),
		Report:  report,
	})
}

func extractArchive(reader io.Reader, dest string) error {
	gzr, err := gzip.NewReader(reader)
	if err != nil {
		return err
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		target := filepath.Join(dest, header.Name)
		if header.Typeflag == tar.TypeDir {
			os.MkdirAll(target, 0755)
		} else {
			os.MkdirAll(filepath.Dir(target), 0755)
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY, os.FileMode(header.Mode))
			if err != nil {
				return err
			}
			io.Copy(f, tr)
			f.Close()
		}
	}
	return nil
}

func analyzeData(dir string) (*models.DiagnosticReport, error) {
	report := &models.DiagnosticReport{
		Logs: make(map[string][]models.LogEntry),
	}

	// Чтение основного JSON отчета
	jsonFiles, _ := filepath.Glob(filepath.Join(dir, "*diag_report.json"))
	if len(jsonFiles) > 0 {
		data, _ := os.ReadFile(jsonFiles[0])
		json.Unmarshal(data, report)
	}

	// Анализ проблем
	analyzerIssues, err := analyzer.AnalyzeIssues(dir)
	if err == nil {
		// Конвертация типов
		for _, issue := range analyzerIssues {
			report.Issues = append(report.Issues, models.Issue{
				Type:           issue.Type,
				Severity:       issue.Severity,
				Pod:            issue.Pod,
				Container:      issue.Container,
				Pattern:        issue.Pattern,
				Count:          issue.Count,
				Status:         issue.Status,
				Reason:         issue.Reason,
				Message:        issue.Message,
				Correlation:    issue.Correlation,
				Recommendation: issue.Recommendation,
			})
		}
	}

	// Парсинг логов
	report.Logs = parseLogs(dir)

	// Парсинг ресурсов
	report.Resources = parseResources(dir)

	// Парсинг событий
	report.Events = parseEvents(dir)

	return report, nil
}

func parseLogs(dir string) map[string][]models.LogEntry {
	logs := make(map[string][]models.LogEntry)
	logsDir := filepath.Join(dir, "logs")

	pods, _ := os.ReadDir(logsDir)
	for _, podEntry := range pods {
		if !podEntry.IsDir() {
			continue
		}
		podName := podEntry.Name()
		podPath := filepath.Join(logsDir, podName)

		containers, _ := os.ReadDir(podPath)
		for _, contEntry := range containers {
			if !strings.HasSuffix(contEntry.Name(), ".log") || strings.Contains(contEntry.Name(), "_previous") {
				continue
			}
			containerName := strings.TrimSuffix(contEntry.Name(), ".log")
			content, _ := os.ReadFile(filepath.Join(podPath, contEntry.Name()))

			errors := strings.Count(string(content), "Error") + strings.Count(string(content), "Exception") + strings.Count(string(content), "Fatal")
			warnings := strings.Count(string(content), "Warning") + strings.Count(string(content), "WARN")

			logs[podName] = append(logs[podName], models.LogEntry{
				Pod:       podName,
				Container: containerName,
				Content:   string(content),
				Errors:    errors,
				Warnings:  warnings,
			})
		}
	}
	return logs
}

func parseResources(dir string) models.ResourceSummary {
	resources := models.ResourceSummary{}

	// Парсинг HPA
	hpaFile := filepath.Join(dir, "resources", "hpa.txt")
	if data, err := os.ReadFile(hpaFile); err == nil {
		lines := strings.Split(string(data), "\n")
		for i, line := range lines {
			if i == 0 || strings.TrimSpace(line) == "" {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 6 {
				resources.HPA = append(resources.HPA, models.HPAInfo{
					Name:            fields[0],
					MinReplicas:     parseInt(fields[1]),
					MaxReplicas:     parseInt(fields[2]),
					CurrentReplicas: parseInt(fields[3]),
					TargetCPU:       fields[5],
				})
			}
		}
	}

	// Парсинг top pods
	topPodsFile := filepath.Join(dir, "resources", "top_pods.txt")
	if data, err := os.ReadFile(topPodsFile); err == nil {
		lines := strings.Split(string(data), "\n")
		for i, line := range lines {
			if i == 0 || strings.TrimSpace(line) == "" {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 4 {
				resources.TopPods = append(resources.TopPods, models.PodMetrics{
					Name:      fields[0],
					Container: fields[1],
					CPU:       fields[2],
					Memory:    fields[3],
				})
			}
		}
	}

	// Парсинг top nodes
	topNodesFile := filepath.Join(dir, "resources", "top_nodes.txt")
	if data, err := os.ReadFile(topNodesFile); err == nil {
		lines := strings.Split(string(data), "\n")
		for i, line := range lines {
			if i == 0 || strings.TrimSpace(line) == "" {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 3 {
				resources.TopNodes = append(resources.TopNodes, models.NodeMetrics{
					Name:   fields[0],
					CPU:    fields[1],
					Memory: fields[2],
				})
			}
		}
	}

	// Парсинг PVC
	pvcFile := filepath.Join(dir, "resources", "pvc.txt")
	if data, err := os.ReadFile(pvcFile); err == nil {
		lines := strings.Split(string(data), "\n")
		for i, line := range lines {
			if i == 0 || strings.TrimSpace(line) == "" {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 5 {
				resources.PVCStatus = append(resources.PVCStatus, models.PVCInfo{
					Name:   fields[1],
					Status: fields[3],
					Volume: fields[4],
				})
			}
		}
	}

	return resources
}

func parseEvents(dir string) []models.K8sEvent {
	var events []models.K8sEvent

	eventsFile := filepath.Join(dir, "events", "events_all.txt")
	data, err := os.ReadFile(eventsFile)
	if err != nil {
		return events
	}

	lines := strings.Split(string(data), "\n")
	for i, line := range lines {
		if i == 0 || strings.TrimSpace(line) == "" {
			continue
		}
		// Формат: LAST SEEN TYPE REASON OBJECT MESSAGE
		fields := strings.Fields(line)
		if len(fields) >= 6 {
			event := models.K8sEvent{
				LastTimestamp: fields[0],
				Type:          fields[1],
				Reason:        fields[2],
				Object:        fields[3],
				Message:       strings.Join(fields[4:], " "),
			}
			events = append(events, event)
		}
	}

	return events
}

func parseInt(s string) int {
	var n int
	fmt.Sscanf(s, "%d", &n)
	return n
}
