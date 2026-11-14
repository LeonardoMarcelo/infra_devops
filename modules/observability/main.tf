# ---------------------------------------------------------------------------
# MÓDULO: OBSERVABILITY (Prometheus + Grafana)
# ---------------------------------------------------------------------------
# Instala a stack kube-prometheus-stack e conecta três tipos de alvo:
#
#   1. APIs instrumentadas  -> ServiceMonitor  (var.api_targets)
#   2. Qualquer URL HTTP    -> blackbox probe  (var.http_probes)
#   3. Bancos de dados      -> exporter por engine (var.database_targets)
#
# O caso (2) é o que faz isto "encaixar em qualquer API REST": não exige
# instrumentação nenhuma na aplicação.
#
# ESTE MÓDULO PRESSUPÕE UM CLUSTER QUE JÁ EXISTE. Os providers helm e
# kubernetes são configurados na raiz, a partir de data sources. Configurar
# provider com valor produzido no mesmo apply é o anti-padrão que quebra o
# primeiro apply e, pior, o destroy.
# ---------------------------------------------------------------------------

# ===========================================================================
# ETAPA 1 — Credencial do Grafana
# ===========================================================================
resource "random_password" "grafana_admin" {
  count = var.grafana_enabled && var.grafana_admin_password == null ? 1 : 0

  length           = 24
  special          = true
  override_special = "!#%&*-_=+?"
}

locals {
  grafana_admin_password = (
    var.grafana_admin_password != null
    ? var.grafana_admin_password
    : try(random_password.grafana_admin[0].result, null)
  )

  # Nome de serviço determinístico do blackbox exporter. Sem o
  # fullnameOverride lá embaixo, o Helm prefixaria com o nome do release e
  # este endereço deixaria de bater.
  blackbox_service = "blackbox-exporter.${var.namespace}.svc.cluster.local:9115"

  has_probes = length(var.http_probes) > 0
}

# ===========================================================================
# ETAPA 2 — ServiceMonitors das APIs instrumentadas
# ===========================================================================
# Um ServiceMonitor diz ao Prometheus: "colete deste conjunto de Services,
# nesta porta, neste caminho". É a forma declarativa de registrar alvo, em
# vez de editar a configuração do Prometheus.
locals {
  api_service_monitors = [
    for target_name, target in var.api_targets : {
      name = target_name

      # Quais Services entram: casamento por label.
      selector = {
        matchLabels = target.service_labels
      }

      namespaceSelector = {
        matchNames = [target.namespace]
      }

      endpoints = [
        {
          port          = target.port
          path          = target.path
          interval      = target.interval
          scrapeTimeout = target.scrape_timeout
          scheme        = target.scheme
          honorLabels   = target.honor_labels
        }
      ]
    }
  ]
}

# ===========================================================================
# ETAPA 3 — Sondagem HTTP de qualquer URL (blackbox)
# ===========================================================================
# Padrão canônico do blackbox exporter: o Prometheus não coleta a URL
# diretamente. Ele coleta o blackbox, passando a URL como parâmetro — e o
# blackbox é quem faz a requisição de verdade e devolve o resultado como
# métrica (probe_success, probe_duration_seconds, código HTTP, validade do
# certificado TLS).
#
# Os relabel abaixo fazem exatamente essa troca:
#   1. o alvo configurado vira o parâmetro `target`
#   2. o parâmetro vira o label `instance` (para o alvo aparecer no gráfico)
#   3. o endereço real de coleta passa a ser o serviço do blackbox
locals {
  blackbox_scrape_configs = [
    for probe_name, probe in var.http_probes : {
      job_name        = "blackbox-${probe_name}"
      metrics_path    = "/probe"
      scrape_interval = probe.interval
      scrape_timeout  = probe.timeout

      params = {
        module = [probe.module]
      }

      static_configs = [
        {
          targets = probe.targets
          labels  = merge({ probe = probe_name }, probe.labels)
        }
      ]

      relabel_configs = [
        {
          source_labels = ["__address__"]
          target_label  = "__param_target"
        },
        {
          source_labels = ["__param_target"]
          target_label  = "instance"
        },
        {
          target_label = "__address__"
          replacement  = local.blackbox_service
        },
      ]
    }
  ]
}

# ===========================================================================
# ETAPA 4 — Valores do kube-prometheus-stack
# ===========================================================================
locals {
  grafana_values = var.grafana_enabled ? {
    grafana = merge(
      {
        enabled       = true
        adminPassword = local.grafana_admin_password

        persistence = {
          enabled          = true
          size             = var.grafana_storage_size
          storageClassName = var.storage_class
        }

        ingress = var.grafana_ingress.enabled ? merge(
          {
            enabled          = true
            ingressClassName = var.grafana_ingress.ingress_class
            hosts            = var.grafana_ingress.hosts
            annotations      = var.grafana_ingress.annotations
          },
          var.grafana_ingress.tls_secret_name == null ? {} : {
            tls = [{
              secretName = var.grafana_ingress.tls_secret_name
              hosts      = var.grafana_ingress.hosts
            }]
          }
        ) : { enabled = false }
      },

      # Dashboards públicos do grafana.com para os exporters de banco.
      # Confirme IDs e revisões em grafana.com/dashboards: eles mudam.
      var.install_community_dashboards ? {
        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [{
              name            = "default"
              orgId           = 1
              folder          = "Bancos de dados"
              type            = "file"
              disableDeletion = false
              editable        = true
              options         = { path = "/var/lib/grafana/dashboards/default" }
            }]
          }
        }
        dashboards = {
          default = {
            postgres = { gnetId = 9628, revision = 7, datasource = "Prometheus" }
            mysql    = { gnetId = 7362, revision = 5, datasource = "Prometheus" }
            redis    = { gnetId = 11835, revision = 1, datasource = "Prometheus" }
            blackbox = { gnetId = 7587, revision = 3, datasource = "Prometheus" }
          }
        }
      } : {}
    )
  } : { grafana = { enabled = false } }

  stack_values = merge(
    {
      prometheus = {
        # ServiceMonitors declarados por este módulo.
        additionalServiceMonitors = local.api_service_monitors

        prometheusSpec = {
          retention = var.prometheus_retention
          resources = var.prometheus_resources

          # Por padrão o chart faz o Prometheus enxergar apenas os
          # ServiceMonitors com a label `release` dele. Isso esconderia os
          # ServiceMonitors criados pelos exporters e pelas suas aplicações.
          # Com `false`, o Prometheus descobre tudo que existir no cluster.
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          probeSelectorNilUsesHelmValues          = false
          ruleSelectorNilUsesHelmValues           = false

          # Sondagens HTTP, quando houver.
          additionalScrapeConfigs = local.blackbox_scrape_configs

          # Disco das séries temporais.
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = var.storage_class
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = { storage = var.prometheus_storage_size }
                }
              }
            }
          }
        }
      }

      alertmanager = merge(
        { enabled = var.alertmanager_enabled },
        var.alertmanager_config == null ? {} : { config = var.alertmanager_config }
      )
    },
    local.grafana_values,
  )
}

# ===========================================================================
# ETAPA 5 — Instalação da stack
# ===========================================================================
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version

  namespace        = var.namespace
  create_namespace = var.create_namespace

  # Helm mescla arquivos de values em ordem; o último vence. É assim que
  # `extra_values` sobrescreve qualquer coisa gerada aqui, sem que o módulo
  # precise prever cada necessidade.
  values = [
    yamlencode(local.stack_values),
    yamlencode(var.extra_values),
  ]

  # `atomic` desfaz a instalação se ela falhar, em vez de deixar o release
  # pela metade. A stack instala CRDs e demora: 15 minutos é folga realista.
  atomic  = true
  timeout = 900
}

# ===========================================================================
# ETAPA 6 — Blackbox exporter (só se houver sondagem configurada)
# ===========================================================================
resource "helm_release" "blackbox_exporter" {
  count = local.has_probes ? 1 : 0

  name       = "blackbox-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-blackbox-exporter"
  version    = var.blackbox_exporter_version

  namespace = var.namespace

  values = [
    yamlencode({
      # Nome fixo para o endereço em local.blackbox_service continuar válido.
      fullnameOverride = "blackbox-exporter"

      serviceMonitor = {
        enabled = true
      }

      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { memory = "128Mi" }
      }
    })
  ]

  # Depende da stack: os CRDs (ServiceMonitor) precisam existir antes.
  depends_on = [helm_release.kube_prometheus_stack]
}

# ===========================================================================
# ETAPA 7 — Exporters de banco de dados
# ===========================================================================
# Um exporter por banco. Ele roda no cluster, conecta no banco (gerenciado ou
# não) e traduz o estado interno para métricas Prometheus.
locals {
  # engine -> chart e porta padrão
  exporter_charts = {
    postgres      = "prometheus-postgres-exporter"
    mysql         = "prometheus-mysql-exporter"
    redis         = "prometheus-redis-exporter"
    mongodb       = "prometheus-mongodb-exporter"
    elasticsearch = "prometheus-elasticsearch-exporter"
  }

  default_ports = {
    postgres      = 5432
    mysql         = 3306
    redis         = 6379
    mongodb       = 27017
    elasticsearch = 9200
  }

  # Valores base por engine.
  #
  # ATENÇÃO: cada chart de exporter tem o próprio esquema de valores, e ele
  # muda entre versões. Estes são os caminhos usuais; confirme contra a
  # versão que você fixar (`helm show values <chart> --version <v>`) e
  # ajuste pelo `extra_values` do alvo, que é mesclado por cima.
  database_values = {
    for db_name, db in var.database_targets : db_name => merge(
      { serviceMonitor = { enabled = true } },
      { resources = db.resources },

      db.engine == "postgres" ? {
        config = db.credentials_secret == null ? {} : {
          # O Secret guarda a DSN completa, ex.:
          # postgresql://user:senha@host:5432/postgres?sslmode=require
          datasourceSecret = {
            name = db.credentials_secret.name
            key  = db.credentials_secret.key
          }
        }
      } : {},

      db.engine == "mysql" ? {
        mysql = merge(
          {
            host = db.host
            port = coalesce(db.port, local.default_ports.mysql)
          },
          db.username == null ? {} : { user = db.username },
          db.credentials_secret == null ? {} : {
            existingPasswordSecret = {
              name = db.credentials_secret.name
              key  = db.credentials_secret.key
            }
          }
        )
      } : {},

      db.engine == "redis" ? merge(
        {
          redisAddress = "redis://${db.host}:${coalesce(db.port, local.default_ports.redis)}"
        },
        db.credentials_secret == null ? {} : {
          auth = {
            enabled = true
            secret = {
              name = db.credentials_secret.name
              key  = db.credentials_secret.key
            }
          }
        }
      ) : {},

      db.engine == "mongodb" ? {
        mongodb = db.credentials_secret == null ? {} : {
          existingSecret = {
            name = db.credentials_secret.name
            key  = db.credentials_secret.key
          }
        }
      } : {},

      # Atende Elasticsearch e Amazon OpenSearch — mesmo protocolo.
      # Porta 443 quando o domínio é do OpenSearch Service (HTTPS
      # obrigatório), 9200 num Elasticsearch próprio.
      db.engine == "elasticsearch" ? {
        es = {
          uri = format(
            "%s://%s:%s",
            coalesce(db.port, local.default_ports.elasticsearch) == 443 ? "https" : "http",
            db.host,
            coalesce(db.port, local.default_ports.elasticsearch)
          )
          all              = true
          indices          = true
          cluster_settings = true
        }
        # A autenticação varia bastante entre versões deste chart. Passe
        # usuário e senha pelo `extra_values` do alvo — ver o README.
      } : {},
    )
  }
}

resource "helm_release" "database_exporter" {
  for_each = var.database_targets

  name       = "exporter-${each.key}"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = local.exporter_charts[each.value.engine]
  version    = lookup(var.database_exporter_versions, each.value.engine, null)

  namespace = var.namespace

  values = [
    yamlencode(local.database_values[each.key]),
    yamlencode(each.value.extra_values),
  ]

  depends_on = [helm_release.kube_prometheus_stack]
}
