# ---------------------------------------------------------------------------
# VARIÁVEIS DO AMBIENTE DE PRODUÇÃO
# ---------------------------------------------------------------------------
# Os valores vivem em terraform.tfvars, carregado automaticamente.
# Nada sensível aqui: segredo vai para os secrets do GitHub Actions ou para
# o AWS Secrets Manager, nunca para arquivo versionado.
# ---------------------------------------------------------------------------

# --- Conta e região -------------------------------------------------------

variable "aws_region" {
  description = "Região da AWS onde a infraestrutura é criada."
  type        = string
  nullable    = false
}

variable "project_tags" {
  description = <<-EOT
    Tags de identificação do projeto, aplicadas a todos os recursos.

    Mantenha ao menos Project, Environment e ManagedBy: são elas que
    permitem separar custo por projeto no Cost Explorer e saber, olhando um
    recurso solto no console, de onde ele veio.
  EOT
  type        = map(string)
  nullable    = false
}

# --- Rede -----------------------------------------------------------------

variable "vpc_name" {
  description = "Nome da VPC."
  type        = string
  nullable    = false
}

variable "vpc_cidr" {
  description = "Bloco CIDR da VPC."
  type        = string
  nullable    = false
}

variable "availability_zones" {
  description = "Zonas de disponibilidade, em ordem."
  type        = list(string)
  nullable    = false
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas, na mesma ordem de availability_zones."
  type        = list(string)
  nullable    = false
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets públicas, na mesma ordem de availability_zones."
  type        = list(string)
  nullable    = false
}

variable "single_nat_gateway" {
  description = <<-EOT
    `true` usa um NAT Gateway só (mais barato, menos resiliente).

    Principal alavanca de custo do projeto. Em produção, `false`.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_flow_logs" {
  description = "Habilita VPC Flow Logs."
  type        = bool
  default     = true
  nullable    = false
}

variable "flow_logs_retention_days" {
  description = "Dias de retenção dos flow logs."
  type        = number
  default     = 30
  nullable    = false
}

# --- Cluster --------------------------------------------------------------

variable "cluster_name" {
  description = "Nome do cluster EKS."
  type        = string
  nullable    = false
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes no plano de controle."
  type        = string
  nullable    = false
}

variable "cluster_endpoint_public_access" {
  description = <<-EOT
    Expõe o endpoint da API do cluster na internet.

    Precisa ser `true` enquanto o apply roda em runner hospedado pelo
    GitHub, que está fora da VPC. Ver a nota no README sobre como fechar isso.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs autorizados a alcançar o endpoint público da API."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  nullable    = false
}

variable "node_groups" {
  description = "Grupos de nós do cluster. Ver modules/kubernetes/README.md."
  type = map(object({
    instance_types = optional(list(string), ["t3.medium"])
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string)
    disk_size      = optional(number)
    labels         = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})
  }))
  nullable = false
}

variable "cluster_log_retention_days" {
  description = "Dias de retenção dos logs do plano de controle."
  type        = number
  default     = 30
  nullable    = false
}

variable "cluster_deletion_protection" {
  description = <<-EOT
    Impede a exclusão do cluster.

    Mantido `false` porque o desafio prevê um workflow de destroy. Em
    produção de verdade, `true`.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "cluster_addons" {
  description = "Addons gerenciados do EKS. Ver modules/kubernetes/README.md."
  type        = any
  default     = {}
}
