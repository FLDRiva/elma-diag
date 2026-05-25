package models

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

// LogEntry представляет запись лога
type LogEntry struct {
	Pod       string `json:"pod"`
	Container string `json:"container"`
	Content   string `json:"content"`
	Errors    int    `json:"errors"`
	Warnings  int    `json:"warnings"`
	Timestamp string `json:"timestamp,omitempty"`
}

// HPAInfo информация о Horizontal Pod Autoscaler
type HPAInfo struct {
	Name            string `json:"name"`
	MinReplicas     int    `json:"min_replicas"`
	MaxReplicas     int    `json:"max_replicas"`
	CurrentReplicas int    `json:"current_replicas"`
	TargetCPU       string `json:"target_cpu"`
	Ready           string `json:"ready,omitempty"`
}

// PodMetrics метрики пода
type PodMetrics struct {
	Name      string `json:"name"`
	Container string `json:"container"`
	CPU       string `json:"cpu"`
	Memory    string `json:"memory"`
}

// NodeMetrics метрики узла
type NodeMetrics struct {
	Name   string `json:"name"`
	CPU    string `json:"cpu"`
	Memory string `json:"memory"`
}

// PVCInfo информация о Persistent Volume Claim
type PVCInfo struct {
	Name      string `json:"name"`
	Status    string `json:"status"`
	Volume    string `json:"volume"`
	Capacity  string `json:"capacity,omitempty"`
	Namespace string `json:"namespace,omitempty"`
}

// ResourceSummary сводка по ресурсам
type ResourceSummary struct {
	HPA       []HPAInfo    `json:"hpa"`
	TopPods   []PodMetrics `json:"top_pods"`
	TopNodes  []NodeMetrics `json:"top_nodes"`
	PVCStatus []PVCInfo    `json:"pvc_status"`
}

// ClusterInfo информация о кластере
type ClusterInfo struct {
	NodesCount int `json:"nodes_count"`
	PodsCount  int `json:"pods_count"`
	HPACount   int `json:"hpa_count"`
}

// DiagnosticReport полный отчет диагностики
type DiagnosticReport struct {
	ReportVersion string              `json:"report_version"`
	GeneratedAt   string              `json:"generated_at"`
	Namespace     string              `json:"namespace"`
	ClusterInfo   ClusterInfo         `json:"cluster_info"`
	AnalysisFile  string              `json:"analysis_file"`
	ArchiveName   string              `json:"archive_name"`
	Issues        []Issue             `json:"issues,omitempty"`
	Logs          map[string][]LogEntry `json:"logs,omitempty"`
	Resources     ResourceSummary     `json:"resources,omitempty"`
	Events        []K8sEvent          `json:"events,omitempty"`
}

// K8sEvent событие Kubernetes
type K8sEvent struct {
	LastTimestamp string `json:"last_timestamp"`
	Type          string `json:"type"`
	Reason        string `json:"reason"`
	Object        string `json:"object"`
	Message       string `json:"message"`
	Count         int    `json:"count,omitempty"`
}

// API Response типы
type HealthResponse struct {
	Status  string `json:"status"`
	Service string `json:"service"`
	Version string `json:"version,omitempty"`
}

type UploadResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
	Report  *DiagnosticReport `json:"report,omitempty"`
}

type LogsFilter struct {
	Pod       string `json:"pod,omitempty"`
	Container string `json:"container,omitempty"`
	Search    string `json:"search,omitempty"`
	ShowErrors bool  `json:"show_errors,omitempty"`
}
