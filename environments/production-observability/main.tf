# ---------------------------------------------------------------------------
# AMBIENTE: OBSERVABILIDADE DE PRODUÇÃO
# ---------------------------------------------------------------------------
# Camada que roda DENTRO do cluster, com state próprio.
#
# Ordem de aplicação:
#   1. environments/production               VPC + cluster
#   2. addon aws-ebs-csi-driver no cluster   sem ele os PVCs não sobem
#   3. environments/production-data          bancos (opcional)
#   4. environments/production-observability (esta camada)
# ---------------------------------------------------------------------------

# ===========================================================================
# ETAPA 1 — Namespace
# ===========================================================================
# Criado aqui, e não pelo Helm, porque os Secrets das credenciais de banco
# precisam existir ANTES dos exporters. O Terraform só sabe ordenar isso se
# o namespace for um recurso dele.
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name   = var.namespace
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

# ===========================================================================
# ETAPA 2 — Descoberta automática dos bancos
# ===========================================================================
locals {
  # Alvos publicados pela camada de dados. Vazio se ela ainda não existir.
  bancos_descobertos = try(
    data.terraform_remote_state.data[0].outputs.monitoring_targets,
    {}
  )

  # Chave que cada exporter espera dentro do Secret do Kubernetes.
  # Varia por chart: uns querem a DSN inteira, outros só a senha.
  chave_do_segredo = {
    postgres      = "datasource"
    mysql         = "password"
    mongodb       = "uri"
    elasticsearch = "password"
    redis         = "password"
  }
}

# Lê a credencial que a camada de dados guardou no Secrets Manager.
data "aws_secretsmanager_secret_version" "banco" {
  for_each = local.bancos_descobertos

  secret_id = each.value.secret_arn
}

locals {
  credenciais = {
    for nome, alvo in local.bancos_descobertos :
    nome => jsondecode(data.aws_secretsmanager_secret_version.banco[nome].secret_string)
  }

  # Valor do segredo, montado no formato de cada exporter.
  valor_do_segredo = {
    for nome, alvo in local.bancos_descobertos : nome => (
      alvo.engine == "postgres" ?
      "postgresql://${alvo.username}:${urlencode(local.credenciais[nome].password)}@${alvo.host}:${alvo.port}/${alvo.database}?sslmode=require" :

      alvo.engine == "mongodb" ?
      "mongodb://${alvo.username}:${urlencode(local.credenciais[nome].password)}@${alvo.host}:${alvo.port}/?tls=true&retryWrites=false" :

      # mysql, elasticsearch e redis recebem só a senha.
      local.credenciais[nome].password
    )
  }
}

# ===========================================================================
# ETAPA 3 — Credenciais como Secret do Kubernetes
# ===========================================================================
# A senha nunca aparece em values de Helm nem em tfvars: o exporter a lê
# deste Secret, por referência.
resource "kubernetes_secret" "banco" {
  for_each = local.bancos_descobertos

  metadata {
    name      = "db-${each.key}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "database"                     = each.key
    }
  }

  data = {
    (local.chave_do_segredo[each.value.engine]) = local.valor_do_segredo[each.key]
  }

  type = "Opaque"
}

# ===========================================================================
# ETAPA 4 — Alvos: descobertos + declarados à mão
# ===========================================================================
locals {
  # Bancos vindos da camada de dados, já com o Secret do Kubernetes criado.
  alvos_automaticos = {
    for nome, alvo in local.bancos_descobertos : nome => {
      engine   = alvo.engine
      host     = alvo.host
      port     = alvo.port
      username = alvo.username
      credentials_secret = {
        name = kubernetes_secret.banco[nome].metadata[0].name
        key  = local.chave_do_segredo[alvo.engine]
      }
      extra_values = {}
      resources    = {}
    }
  }

  # Declarados manualmente em terraform.tfvars vencem, caso haja conflito de
  # nome: ajuste manual deve poder sobrepor a descoberta automática.
  todos_os_bancos = merge(local.alvos_automaticos, var.database_targets)
}

# ===========================================================================
# ETAPA 5 — Stack de monitoramento
# ===========================================================================
module "observability" {
  source = "../../modules/observability"

  namespace = kubernetes_namespace.monitoring.metadata[0].name
  # Já criado na etapa 1.
  create_namespace = false

  # --- Versões dos charts ---
  kube_prometheus_stack_version = var.kube_prometheus_stack_version
  blackbox_exporter_version     = var.blackbox_exporter_version
  database_exporter_versions    = var.database_exporter_versions

  # --- Prometheus ---
  prometheus_retention    = var.prometheus_retention
  prometheus_storage_size = var.prometheus_storage_size
  storage_class           = var.storage_class

  # --- Grafana ---
  grafana_enabled              = var.grafana_enabled
  grafana_admin_password       = var.grafana_admin_password
  install_community_dashboards = var.install_community_dashboards

  # --- Alertas ---
  alertmanager_enabled = true
  alertmanager_config  = var.alertmanager_config

  # --- Alvos ---
  # APIs instrumentadas (expõem /metrics).
  api_targets = var.api_targets

  # Qualquer URL HTTP, sem exigir instrumentação.
  http_probes = var.http_probes

  # Bancos: descobertos na camada de dados + declarados à mão.
  database_targets = local.todos_os_bancos

  common_labels = var.project_tags

  depends_on = [kubernetes_secret.banco]
}
