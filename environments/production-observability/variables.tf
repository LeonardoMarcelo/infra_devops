# ---------------------------------------------------------------------------
# VARIÁVEIS DA CAMADA DE OBSERVABILIDADE
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "Região da AWS onde o cluster está."
  type        = string
  nullable    = false
}

variable "cluster_name" {
  description = <<-EOT
    Nome do cluster EKS onde instalar a stack.

    Precisa bater com `cluster_name` de environments/production. É lido por
    data source: o cluster tem de existir antes de rodar esta camada.
  EOT
  type        = string
  nullable    = false
}

variable "project_tags" {
  description = "Tags aplicadas aos recursos AWS criados por esta camada."
  type        = map(string)
  nullable    = false
}

# --- Descoberta automática de bancos -------------------------------------

variable "descobrir_bancos" {
  description = <<-EOT
    Lê `monitoring_targets` da camada de dados e monitora os bancos
    automaticamente.

    Com `true`, declarar um banco em environments/production-data faz o
    exporter dele aparecer aqui sozinho — credencial incluída, lida do
    Secrets Manager e convertida em Secret do Kubernetes.

    Desligue se a camada de dados ainda não existir.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "state_bucket" {
  description = <<-EOT
    Bucket S3 onde ficam os states.

    Vem por `TF_VAR_state_bucket`, preenchido pela pipeline a partir do
    secret AWS_BUCKET_NAME. Localmente:

      export TF_VAR_state_bucket="$TF_BACKEND_BUCKET"
  EOT
  type        = string
  default     = ""
  nullable    = false
}

variable "state_key_data" {
  description = "Key do state da camada de dados."
  type        = string
  default     = "producao/data.tfstate"
  nullable    = false
}

# --- Stack ----------------------------------------------------------------

variable "namespace" {
  description = "Namespace do monitoramento."
  type        = string
  default     = "monitoring"
  nullable    = false
}

variable "kube_prometheus_stack_version" {
  description = "Versão do chart kube-prometheus-stack. `null` = última (fixe antes de produção)."
  type        = string
  default     = null
}

variable "blackbox_exporter_version" {
  description = "Versão do chart do blackbox exporter. `null` = última."
  type        = string
  default     = null
}

variable "database_exporter_versions" {
  description = "Versão do chart de exporter por engine."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "storage_class" {
  description = "StorageClass dos volumes. Exige o addon aws-ebs-csi-driver no cluster."
  type        = string
  default     = "gp3"
  nullable    = false
}

variable "prometheus_retention" {
  description = "Janela de retenção das métricas no Prometheus."
  type        = string
  default     = "15d"
  nullable    = false
}

variable "prometheus_storage_size" {
  description = "Tamanho do volume do Prometheus."
  type        = string
  default     = "50Gi"
  nullable    = false
}

# --- Grafana --------------------------------------------------------------

variable "grafana_enabled" {
  description = "Instala o Grafana."
  type        = bool
  default     = true
  nullable    = false
}

variable "grafana_admin_password" {
  description = "Senha do admin do Grafana. `null` gera uma aleatória."
  type        = string
  default     = null
  sensitive   = true
}

variable "install_community_dashboards" {
  description = "Importa dashboards públicos do grafana.com para os bancos."
  type        = bool
  default     = false
  nullable    = false
}

# --- Alvos ----------------------------------------------------------------

variable "api_targets" {
  description = "APIs que expõem /metrics. Ver modules/observability/README.md."
  type = map(object({
    namespace      = string
    service_labels = map(string)
    port           = optional(string, "http")
    path           = optional(string, "/metrics")
    interval       = optional(string, "30s")
    scrape_timeout = optional(string, "10s")
    scheme         = optional(string, "http")
    honor_labels   = optional(bool, false)
  }))
  default  = {}
  nullable = false
}

variable "http_probes" {
  description = "URLs sondadas de fora, sem exigir instrumentação."
  type = map(object({
    targets  = list(string)
    module   = optional(string, "http_2xx")
    interval = optional(string, "30s")
    timeout  = optional(string, "10s")
    labels   = optional(map(string), {})
  }))
  default  = {}
  nullable = false
}

variable "database_targets" {
  description = "Bancos a monitorar. Ver modules/observability/README.md."
  type = map(object({
    engine   = string
    host     = string
    port     = optional(number)
    username = optional(string)
    credentials_secret = optional(object({
      name = string
      key  = string
    }))
    extra_values = optional(any, {})
    resources = optional(object({
      requests = optional(object({
        cpu    = optional(string, "50m")
        memory = optional(string, "64Mi")
      }), {})
      limits = optional(object({
        cpu    = optional(string)
        memory = optional(string, "256Mi")
      }), {})
    }), {})
  }))
  default  = {}
  nullable = false
}

variable "alertmanager_config" {
  description = "Rotas e receivers do Alertmanager. `null` = padrão do chart (não notifica ninguém)."
  type        = any
  default     = null
}
