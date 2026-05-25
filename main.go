package main

import (
        "archive/tar"
        "compress/gzip"
        "encoding/json"
        "fmt"
        "io"
        "log"
        "net/http"
        "os"
        "path/filepath"
        "strings"

        "elma365-diagnostics/analyzer"
        "elma365-diagnostics/api"
        "elma365-diagnostics/models"
        "github.com/gorilla/mux"
)

var currentReport *models.DiagnosticReport
var workDir string

func main() {
        port := os.Getenv("PORT")
        if port == "" {
                port = "8080"
        }

        // Проверка режима работы
        if len(os.Args) > 1 && os.Args[1] == "analyze" {
                runAnalyzerMode()
                return
        }

        // Серверный режим
        r := mux.NewRouter()

        // API endpoints
        r.HandleFunc("/api/health", api.HealthHandler).Methods("GET")
        r.HandleFunc("/api/report", api.GetReportHandler).Methods("GET")
        r.HandleFunc("/api/logs", api.GetLogsHandler).Methods("GET")
        r.HandleFunc("/api/resources", api.GetResourcesHandler).Methods("GET")
        r.HandleFunc("/api/issues", api.GetIssuesHandler).Methods("GET")
        r.HandleFunc("/api/events", api.GetEventsHandler).Methods("GET")
        r.HandleFunc("/api/upload", api.UploadHandler).Methods("POST")

        // Статические файлы (UI)
        fs := http.FileServer(http.Dir("./static"))
        r.PathPrefix("/").Handler(fs)

        fmt.Printf("🚀 ELMA365 Diagnostics Server запущен на порту %s\n", port)
        fmt.Println("📊 Откройте http://localhost:" + port)
        log.Fatal(http.ListenAndServe(":"+port, r))
}

func runAnalyzerMode() {
        // Чтение архива из stdin
        workDir = "/tmp/diag_analysis"
        os.RemoveAll(workDir)
        os.MkdirAll(workDir, 0755)

        // Распаковка архива
        if err := extractArchive(os.Stdin, workDir); err != nil {
                log.Fatalf("Ошибка распаковки: %v", err)
        }

        // Анализ данных
        report, err := analyzeData(workDir)
        if err != nil {
                log.Fatalf("Ошибка анализа: %v", err)
        }

        // Вывод JSON отчета
        jsonData, _ := json.MarshalIndent(report, "", "  ")
        fmt.Println(string(jsonData))
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
                for _, issue := range analyzerIssues {
                        report.Issues = append(report.Issues, models.Issue(issue))
                }
        }

        // Парсинг логов и ресурсов (упрощенно для CLI режима)
        report.Logs = parseLogs(dir)
        report.Resources = parseResources(dir)

        currentReport = report
        workDir = dir
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

func parseInt(s string) int {
        var n int
        fmt.Sscanf(s, "%d", &n)
        return n
}