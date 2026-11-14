# ---------------------------------------------------------------------------
# INTERFACE DO MÓDULO DE BANCO DE DADOS
# ---------------------------------------------------------------------------
# Uma única variável `databases` declara qualquer quantidade de bancos, de
# qualquer engine suportada. O módulo escolhe o serviço AWS correspondente:
#
#   mysql, postgres, mariadb, oracle  ->  RDS
#   mongodb                           ->  DocumentDB (compatível com MongoDB)
#   elasticsearch, opensearch         ->  OpenSearch Service
#
# Acrescentar um banco ao projeto é acrescentar uma entrada no mapa.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefixo dos identificadores. Ex.: \"live\" gera \"live-pedidos\"."
  type        = string
  nullable    = false
}

variable "vpc_id" {
  description = "VPC onde os bancos ficam."
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = <<-EOT
    Subnets dos bancos. Use SEMPRE as privadas.

    Banco em subnet pública com `publicly_accessible` ligado é a forma mais
    comum de vazamento de dados em nuvem.
  EOT
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS, DocumentDB e OpenSearch exigem subnets em ao menos 2 AZs."
  }
}

variable "tags" {
  description = "Tags aplicadas a todos os recursos."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "databases" {
  description = <<-EOT
    Bancos a criar, indexados por nome.

    Exemplo:
      databases = {
        pedidos = {
          engine                     = "mysql"
          storage_gb                 = 20
          allowed_security_group_ids = [module.kubernetes.node_security_group_id]
        }
        catalogo = {
          engine         = "mongodb"
          instance_count = 1
        }
        busca = {
          engine     = "elasticsearch"
          storage_gb = 10
        }
        legado = {
          engine         = "oracle"
          instance_class = "db.t3.small"
        }
      }

    O que é deixado em branco usa o padrão da engine (ver locals em main.tf).
  EOT

  type = map(object({
    engine         = string
    engine_version = optional(string)

    # --- Dimensionamento ---
    instance_class = optional(string)
    # Nós do cluster. Vale para DocumentDB e OpenSearch; RDS ignora.
    instance_count = optional(number, 1)
    storage_gb     = optional(number, 20)

    # --- Acesso ---
    username      = optional(string, "admin")
    database_name = optional(string)
    port          = optional(number)

    # Quem pode conectar. Em geral, o security group dos nós do cluster.
    allowed_security_group_ids = optional(list(string), [])
    allowed_cidr_blocks        = optional(list(string), [])

    # --- Operação ---
    multi_az                = optional(bool, false)
    backup_retention_days   = optional(number, 7)
    deletion_protection     = optional(bool, false)
    skip_final_snapshot     = optional(bool, true)
    performance_insights    = optional(bool, false)
    cloudwatch_logs_exports = optional(list(string))

    # --- Monitoramento ---
    # Quando true, o banco entra na saída `monitoring_targets` e é coletado
    # automaticamente pela camada de observabilidade.
    monitoring_enabled = optional(bool, true)

    extra_tags = optional(map(string), {})
  }))

  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for db in values(var.databases) : contains(
        ["mysql", "postgres", "mariadb", "oracle", "mongodb", "elasticsearch", "opensearch"],
        db.engine
      )
    ])
    error_message = "engine aceita: mysql, postgres, mariadb, oracle, mongodb, elasticsearch, opensearch."
  }

  validation {
    condition = alltrue([
      for db in values(var.databases) : db.instance_count >= 1
    ])
    error_message = "instance_count deve ser no mínimo 1."
  }

  validation {
    condition = alltrue([
      for db in values(var.databases) : db.storage_gb >= 10
    ])
    error_message = "storage_gb deve ser no mínimo 10 (exigência da AWS)."
  }

  validation {
    condition = alltrue([
      for name, db in var.databases :
      length(name) <= 24 && can(regex("^[a-z][a-z0-9-]*$", name))
    ])
    error_message = "O nome do banco deve ser minúsculo, começar com letra, aceitar só letras, números e hífen, e ter no máximo 24 caracteres."
  }
}

variable "secret_recovery_days" {
  description = <<-EOT
    Dias de janela de recuperação dos segredos no Secrets Manager.

    `0` apaga na hora — necessário em ambiente de estudo, onde criar e
    destruir o mesmo nome várias vezes esbarraria em "segredo agendado para
    exclusão". Em produção, use 7 ou mais.
  EOT
  type        = number
  default     = 0
  nullable    = false
}
