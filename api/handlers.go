package api

import (
	"compress/gzip"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"

	"elma-diag/analyzer"
	"elma-diag/models"
)

var (
	stored *models.DiagnosticReport
	mu     sync.RWMutex
)

func HealthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "service": "elma-diag"})
}

func GetReportHandler(w http.ResponseWriter, r *http.Request) {
	mu.RLock()
	defer mu.RUnlock()
	writeJSON(w, http.StatusOK, stored)
}

// UploadHandler принимает архив json, запускает анализ и сохраняет отчёт.
func UploadHandler(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(100 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "ошибка разбора формы: "+err.Error())
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "поле 'file' не найдено")
		return
	}
	defer file.Close()

	log.Printf("upload: %s (%d bytes)", header.Filename, header.Size)

	var reader io.Reader = file
	if strings.HasSuffix(header.Filename, ".gz") {
		gz, err := gzip.NewReader(file)
		if err != nil {
			writeError(w, http.StatusBadRequest, "ошибка разархивирования: "+err.Error())
			return
		}
		defer gz.Close()
		reader = gz
	}

	data, err := io.ReadAll(io.LimitReader(reader, 50<<20))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ошибка чтения: "+err.Error())
		return
	}

	var rep models.DiagnosticReport
	if err := json.Unmarshal(data, &rep); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON: "+err.Error())
		return
	}

	if rep.Meta.Namespace == "" {
		writeError(w, http.StatusBadRequest, "нет поля meta.namespace")
		return
	}

	rep.Issues = analyzer.Analyze(&rep)

	mu.Lock()
	stored = &rep
	mu.Unlock()

	log.Printf("report saved: ns=%s issues=%d pods=%d log_entries=%d",
		rep.Meta.Namespace, len(rep.Issues), len(rep.Cluster.Pods), len(rep.Logs.Entries))

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": "ok",
		"report": &rep,
	})
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("writeJSON error: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
