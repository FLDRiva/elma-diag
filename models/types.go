package models

// DiagnosticReport — полный отчёт, хранится в памяти после загрузки.
// Поля Meta/Cluster/Logs приходят из скрипта, после загрузки в интерфейс.
type DiagnosticReport struct {
	Meta    Meta    `json:"meta"`
	Cluster Cluster `json:"cluster"`
	Logs    Logs    `json:"logs"`
	Issues  []Issue `json:"issues,omitempty"`
	Database Database `json:"database,omitempty"`
}

type Meta struct {
	Namespace   string `json:"namespace"`
	CollectedAt string `json:"collected_at"`
	Version     string `json:"version"`
}

type Cluster struct {
	Pods   []Pod   `json:"pods"`
	HPAs   []HPA   `json:"hpas"`
	Events []Event `json:"events"`
	Nodes  []Node  `json:"nodes"`
}

type Pod struct {
	Name       string      `json:"name"`
	Phase      string      `json:"phase"`
	Ready      bool        `json:"ready"`
	Restarts   int         `json:"restarts"`
	Node       string      `json:"node"`
	Containers []Container `json:"containers"`
}

type Container struct {
	Name      string `json:"name"`
	Ready     bool   `json:"ready"`
	Restarts  int    `json:"restarts"`
	LastState string `json:"last_state"`
	CPUReq    string `json:"cpu_req"`
	CPULim    string `json:"cpu_lim"`
	MemReq    string `json:"mem_req"`
	MemLim    string `json:"mem_lim"`
	CPUNow    string `json:"cpu_now"`
	MemNow    string `json:"mem_now"`
}

type HPA struct {
	Name    string `json:"name"`
	Target  string `json:"target"`
	Min     int    `json:"min"`
	Max     int    `json:"max"`
	Current int    `json:"current"`
	Desired int    `json:"desired"`
}

type Event struct {
	Reason   string `json:"reason"`
	Message  string `json:"message"`
	Object   string `json:"object"`
	Kind     string `json:"kind"`
	Count    int    `json:"count"`
	LastSeen string `json:"last_seen"`
}

type Node struct {
	Name    string `json:"name"`
	Ready   bool   `json:"ready"`
	CPU     string `json:"cpu"`
	Memory  string `json:"memory"`
	Version string `json:"version"`
}

type Logs struct {
	Entries []LogEntry `json:"entries"`
}

type LogEntry struct {
	Pod     string `json:"pod"`
	Level   string `json:"level"`
	Time    string `json:"time"`
	Service string `json:"service"`
	Msg     string `json:"msg"`
	Error   string `json:"error"`
}

type Issue struct {
	Type           string `json:"type"`
	Severity       string `json:"severity"`
	Pod            string `json:"pod,omitempty"`
	Container      string `json:"container,omitempty"`
	Message        string `json:"message"`
	Recommendation string `json:"recommendation,omitempty"`
}

type Database struct {
	PostgreSQL []DBConnection `json:"database,omitempty"`
}

type DBConnection struct {
	Secret string `json:"secret"`
	Hosts string `json:"host"`
	User string `json:"user"`
	Database string `json:"databse"`
	Owners []string `json:"owners"`
}