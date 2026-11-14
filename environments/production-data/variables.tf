# ---------------------------------------------------------------------------
# VARIÁVEIS DA CAMADA DE DADOS
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "Região da AWS."
  type        = string
  nullable    = false
}

variable "name_prefix" {
  description = "Prefixo dos identificadores. Deve bater com o do projeto."
  type        = string
  nullable    = false
}

variable "project_tags" {
  description = "Tags aplicadas a todos os recursos."
  type        = map(string)
  nullable    = false
}

# --- Leitura da camada base ----------------------------------------------

variable "state_bucket" {
  description = <<-EOT
    Bucket S3 onde ficam os states.

    Não entra no terraform.tfvars: vem por `TF_VAR_state_bucket`, que a
    pipeline preenche a partir do secret AWS_BUCKET_NAME. Localmente:

      export TF_VAR_state_bucket="$TF_BACKEND_BUCKET"
  EOT
  type        = string
  nullable    = false
}

variable "state_key_base" {
  description = "Key do state da camada base (environments/production)."
  type        = string
  default     = "producao/infra.tfstate"
  nullable    = false
}

# --- Bancos ---------------------------------------------------------------

variable "databases" {
  description = <<-EOT
    Bancos a criar. Ver modules/database/README.md para a referência completa.

    O acesso a partir dos nós do cluster é acrescentado automaticamente em
    main.tf — não é preciso informar o security group aqui.
  EOT

  type = map(object({
    engine         = string
    engine_version = optional(string)

    instance_class = optional(string)
    instance_count = optional(number, 1)
    storage_gb     = optional(number, 20)

    username      = optional(string, "admin")
    database_name = optional(string)
    port          = optional(number)

    allowed_security_group_ids = optional(list(string), [])
    allowed_cidr_blocks        = optional(list(string), [])

    multi_az                = optional(bool, false)
    backup_retention_days   = optional(number, 7)
    deletion_protection     = optional(bool, false)
    skip_final_snapshot     = optional(bool, true)
    performance_insights    = optional(bool, false)
    cloudwatch_logs_exports = optional(list(string))

    monitoring_enabled = optional(bool, true)

    extra_tags = optional(map(string), {})
  }))

  default  = {}
  nullable = false
}

variable "allow_from_cluster_nodes" {
  description = <<-EOT
    Libera automaticamente o acesso aos bancos a partir dos nós do cluster.

    `true` é o que faz uma aplicação rodando no EKS conseguir conectar sem
    configuração extra. Desligue só se os bancos forem consumidos de fora do
    cluster.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "secret_recovery_days" {
  description = "Janela de recuperação dos segredos. 0 apaga na hora (ambiente de estudo)."
  type        = number
  default     = 0
  nullable    = false
}
