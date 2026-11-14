# ---------------------------------------------------------------------------
# INTERFACE DO MÓDULO DE OBSERVABILIDADE
# ---------------------------------------------------------------------------

# --- Onde instalar --------------------------------------------------------

variable "namespace" {
  description = "Namespace onde a stack de monitoramento é instalada."
  type        = string
  default     = "monitoring"
  nullable    = false
}

variable "create_namespace" {
  description = "Cria o namespace se ele não existir."
  type        = bool
  default     = true
  nullable    = false
}

variable "common_labels" {
  description = "Labels aplicadas aos releases Helm."
  type        = map(string)
  default     = {}
  nullable    = false
}

# --- Versões dos charts ---------------------------------------------------
#
# `null` significa "última versão publicada".
#
# FIXE ESTES VALORES ANTES DE PRODUÇÃO. Com `null`, dois applies em dias
# diferentes instalam versões diferentes, e o `plan` deixa de prever o que vai
# acontecer. Para descobrir as versões disponíveis:
#
#   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#   helm repo update
#   helm search repo prometheus-community/kube-prometheus-stack --versions | head
#
# Não há valor padrão fixado aqui de propósito: um número inventado é pior que
# um `null` explícito, porque falha só na hora do apply.

variable "kube_prometheus_stack_version" {
  description = "Versão do chart kube-prometheus-stack. `null` = última."
  type        = string
  default     = null
}

variable "blackbox_exporter_version" {
  description = "Versão do chart prometheus-blackbox-exporter. `null` = última."
  type        = string
  default     = null
}

variable "database_exporter_versions" {
  description = <<-EOT
    Versão do chart de exporter por engine. `null` = última.

    Ex.: { postgres = "6.5.0", redis = "6.6.0" }
  EOT
  type        = map(string)
  default     = {}
  nullable    = false
}

# --- Prometheus -----------------------------------------------------------

variable "prometheus_retention" {
  description = <<-EOT
    Por quanto tempo as métricas ficam no Prometheus. Ex.: "15d".

    Prometheus guarda série temporal em disco local; retenção longa custa
    disco e memória. Para histórico longo, o caminho é remote write para
    Thanos, Mimir ou Amazon Managed Prometheus — não aumentar este valor.
  EOT
  type        = string
  default     = "15d"
  nullable    = false
}

variable "prometheus_storage_size" {
  description = "Tamanho do volume do Prometheus. Ex.: \"50Gi\"."
  type        = string
  default     = "50Gi"
  nullable    = false
}

variable "storage_class" {
  description = <<-EOT
    StorageClass dos volumes persistentes.

    No EKS exige o addon `aws-ebs-csi-driver` instalado. Sem ele, os PVCs
    ficam em `Pending` para sempre e nada sobe.
  EOT
  type        = string
  default     = "gp3"
  nullable    = false
}

variable "prometheus_resources" {
  description = "Requests e limits do Prometheus."
  type = object({
    requests = optional(object({
      cpu    = optional(string, "500m")
      memory = optional(string, "2Gi")
    }), {})
    limits = optional(object({
      cpu    = optional(string)
      memory = optional(string, "4Gi")
    }), {})
  })
  default  = {}
  nullable = false
}

# --- Grafana --------------------------------------------------------------

variable "grafana_enabled" {
  description = "Instala o Grafana junto com a stack."
  type        = bool
  default     = true
  nullable    = false
}

variable "grafana_admin_password" {
  description = <<-EOT
    Senha do usuário admin do Grafana.

    `null` gera uma senha aleatória, exposta como output sensível — o que a
    grava no state. O state já é criptografado no S3, mas o caminho correto
    em produção é SSO (OIDC/SAML) e esta senha servir só de quebra-galho.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "grafana_storage_size" {
  description = "Tamanho do volume do Grafana (dashboards criados pela UI)."
  type        = string
  default     = "10Gi"
  nullable    = false
}

variable "grafana_ingress" {
  description = <<-EOT
    Exposição do Grafana por Ingress.

    `enabled = false` (padrão) deixa o Grafana acessível só por
    `kubectl port-forward`. Expor dashboard de observabilidade na internet
    sem autenticação na frente é vazamento de topologia interna.
  EOT
  type = object({
    enabled         = optional(bool, false)
    ingress_class   = optional(string, "alb")
    hosts           = optional(list(string), [])
    annotations     = optional(map(string), {})
    tls_secret_name = optional(string)
  })
  default  = {}
  nullable = false
}

variable "install_community_dashboards" {
  description = <<-EOT
    Importa dashboards públicos do grafana.com para os exporters de banco.

    Exige que o pod do Grafana tenha saída para a internet. Os IDs usados
    estão em main.tf; confirme-os em grafana.com/dashboards antes de
    confiar neles — IDs e revisões mudam com o tempo.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

# --- Alertmanager ---------------------------------------------------------

variable "alertmanager_enabled" {
  description = "Instala o Alertmanager."
  type        = bool
  default     = true
  nullable    = false
}

variable "alertmanager_config" {
  description = <<-EOT
    Configuração do Alertmanager (rotas e receivers), como objeto.

    `null` mantém a configuração padrão do chart, que não notifica ninguém.
    Alerta que não chega a uma pessoa não é monitoramento, é decoração.
  EOT
  type        = any
  default     = null
}

# --- Alvos: APIs REST -----------------------------------------------------

variable "api_targets" {
  description = <<-EOT
    APIs que JÁ EXPÕEM métricas no formato Prometheus (endpoint /metrics).

    Gera um ServiceMonitor por entrada. Use quando a aplicação foi
    instrumentada (prom-client no Node, micrometer no Spring,
    prometheus_client no Python, etc.).

    Para API que NÃO expõe /metrics — inclusive API de terceiro — use
    `http_probes`.

    Exemplo:
      api_targets = {
        pedidos = {
          namespace      = "producao"
          service_labels = { "app.kubernetes.io/name" = "pedidos-api" }
          port           = "http"
          path           = "/metrics"
        }
      }
  EOT
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
  description = <<-EOT
    URLs sondadas de fora, via blackbox exporter.

    É isto que faz o módulo "encaixar em qualquer API REST": não exige
    instrumentação nenhuma. Mede disponibilidade, latência de resposta,
    código HTTP e validade do certificado TLS — de qualquer URL, interna ou
    de terceiro.

    O que NÃO mede: nada de dentro da aplicação (taxa de erro por rota,
    tamanho de fila, uso de pool de conexão). Para isso é preciso
    instrumentar e usar `api_targets`.

    Exemplo:
      http_probes = {
        pedidos-health = {
          targets = ["https://api.exemplo.com/health"]
          module  = "http_2xx"
        }
        parceiro-pagamentos = {
          targets  = ["https://api.parceiro.com/status"]
          interval = "60s"
        }
      }
  EOT
  type = map(object({
    targets  = list(string)
    module   = optional(string, "http_2xx")
    interval = optional(string, "30s")
    timeout  = optional(string, "10s")
    labels   = optional(map(string), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for p in values(var.http_probes) : length(p.targets) > 0
    ])
    error_message = "Cada probe precisa de ao menos uma URL em `targets`."
  }
}

# --- Alvos: bancos de dados ----------------------------------------------

variable "database_targets" {
  description = <<-EOT
    Bancos a monitorar. Para cada entrada sobe o exporter correspondente,
    que coleta do banco e expõe no formato Prometheus.

    Funciona com banco gerenciado (RDS, ElastiCache, DocumentDB) e com banco
    rodando no próprio cluster: o exporter roda dentro do cluster e conecta
    no `host` informado.

    CREDENCIAL NUNCA VEM EM TEXTO. Crie antes um Secret do Kubernetes no
    namespace do monitoramento e referencie por `credentials_secret`.
    Ver o README do módulo para o formato de cada engine.

    Exemplo:
      database_targets = {
        pedidos-pg = {
          engine             = "postgres"
          host               = "pedidos.abc123.us-east-1.rds.amazonaws.com"
          port               = 5432
          credentials_secret = { name = "pg-pedidos", key = "datasource" }
        }
        cache = {
          engine             = "redis"
          host               = "cache.abc123.use1.cache.amazonaws.com"
          port               = 6379
          credentials_secret = { name = "redis-cache", key = "password" }
        }
      }
  EOT
  type = map(object({
    engine   = string
    host     = string
    port     = optional(number)
    username = optional(string)

    credentials_secret = optional(object({
      name = string
      key  = string
    }))

    # Escape hatch: valores Helm crus, mesclados POR CIMA dos gerados.
    # Cada chart de exporter tem o próprio esquema de valores e ele muda
    # entre versões. É aqui que se ajusta sem precisar alterar o módulo.
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

  validation {
    condition = alltrue([
      for db in values(var.database_targets) :
      contains(["postgres", "mysql", "redis", "mongodb", "elasticsearch"], db.engine)
    ])
    error_message = "engine aceita: postgres, mysql, redis, mongodb, elasticsearch."
  }

  validation {
    condition = alltrue([
      for db in values(var.database_targets) : length(db.host) > 0
    ])
    error_message = "Todo banco precisa de `host`."
  }
}

# --- Escape hatch global --------------------------------------------------

variable "extra_values" {
  description = <<-EOT
    Valores Helm crus mesclados por cima dos gerados para o
    kube-prometheus-stack.

    Existe para que nenhuma necessidade específica exija alterar o módulo.
    O Helm mescla arquivos de values em ordem, e este entra por último.
  EOT
  type        = any
  default     = {}
}
