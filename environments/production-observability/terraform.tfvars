# ---------------------------------------------------------------------------
# CONFIGURAÇÃO DA OBSERVABILIDADE DE PRODUÇÃO
# ---------------------------------------------------------------------------
# Este é o arquivo que você edita no dia a dia para registrar um alvo novo.
# Adicionar uma API ou um banco ao monitoramento é acrescentar uma entrada
# aqui — nenhum módulo precisa ser alterado.
# ---------------------------------------------------------------------------

aws_region   = "us-east-1"
cluster_name = "live-eks"

project_tags = {
  Project     = "live"
  Environment = "producao"
  ManagedBy   = "terraform"
  Repository  = "infra_devops"
  Layer       = "observability"
}

# --- Stack ----------------------------------------------------------------

namespace = "monitoring"

# `null` instala a última versão publicada do chart. FIXE antes de produção:
#   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#   helm search repo prometheus-community/kube-prometheus-stack --versions | head
kube_prometheus_stack_version = null
blackbox_exporter_version     = null
database_exporter_versions    = {}

# Exige o addon aws-ebs-csi-driver instalado no cluster. Sem ele os volumes
# ficam em Pending e nada sobe.
storage_class = "gp3"

prometheus_retention    = "15d"
prometheus_storage_size = "50Gi"

# --- Grafana --------------------------------------------------------------

grafana_enabled = true

# `null` gera senha aleatória, legível com:
#   terraform output -raw grafana_admin_password
# Em produção de verdade, configure SSO e trate esta senha como quebra-galho.
grafana_admin_password = null

# Dashboards públicos do grafana.com para os exporters de banco.
# Exige saída para a internet no pod do Grafana.
install_community_dashboards = false

# ---------------------------------------------------------------------------
# ALVOS
# ---------------------------------------------------------------------------
# Começa vazio de propósito: a stack sobe e já monitora o cluster (nós, pods,
# controle, kubelet) sem nenhum alvo declarado. Os blocos abaixo são exemplos
# prontos para descomentar.
# ---------------------------------------------------------------------------

# --- 1. APIs que JÁ expõem /metrics --------------------------------------
# Use quando a aplicação foi instrumentada (prom-client, micrometer,
# prometheus_client). Dá métrica de dentro: taxa de erro por rota, latência
# por percentil, tamanho de fila, pool de conexão.
api_targets = {}

# api_targets = {
#   pedidos = {
#     namespace      = "producao"
#     service_labels = { "app.kubernetes.io/name" = "pedidos-api" }
#     port           = "http"       # nome da porta no Service, não o número
#     path           = "/metrics"
#     interval       = "30s"
#   }
# }

# --- 2. Qualquer API REST, sem instrumentação -----------------------------
# Sobe o blackbox exporter e sonda a URL de fora. Serve para API legada, API
# de terceiro, qualquer coisa que responda HTTP. Mede disponibilidade,
# latência, código de status e validade do certificado TLS.
http_probes = {}

# http_probes = {
#   pedidos-health = {
#     targets = ["https://api.exemplo.com/health"]
#     module  = "http_2xx"
#   }
#   parceiro-pagamentos = {
#     targets  = ["https://api.parceiro.com/status"]
#     interval = "60s"
#     labels   = { criticidade = "alta" }
#   }
# }

# --- 3. Bancos de dados ---------------------------------------------------
# Um exporter por banco. Funciona com RDS, ElastiCache, DocumentDB e com
# banco rodando no próprio cluster.
#
# A credencial NUNCA vem aqui. Crie antes o Secret no namespace:
#
#   kubectl -n monitoring create secret generic pg-pedidos \
#     --from-literal=datasource='postgresql://monitor:SENHA@host:5432/postgres?sslmode=require'
#
database_targets = {}

# database_targets = {
#   pedidos-pg = {
#     engine             = "postgres"
#     host               = "pedidos.abc123.us-east-1.rds.amazonaws.com"
#     port               = 5432
#     credentials_secret = { name = "pg-pedidos", key = "datasource" }
#   }
#   cache = {
#     engine             = "redis"
#     host               = "cache.abc123.use1.cache.amazonaws.com"
#     port               = 6379
#     credentials_secret = { name = "redis-cache", key = "password" }
#   }
# }

# --- Alertas --------------------------------------------------------------
# `null` mantém o padrão do chart, que NÃO notifica ninguém. Alerta que não
# chega a uma pessoa não é monitoramento.
alertmanager_config = null

# alertmanager_config = {
#   route = {
#     group_by        = ["alertname", "namespace"]
#     group_wait      = "30s"
#     repeat_interval = "4h"
#     receiver        = "slack"
#   }
#   receivers = [
#     {
#       name = "slack"
#       slack_configs = [
#         {
#           # A URL do webhook deve vir de um Secret montado no Alertmanager,
#           # não escrita aqui. Ver o README do módulo.
#           channel = "#alertas-producao"
#         }
#       ]
#     }
#   ]
# }
