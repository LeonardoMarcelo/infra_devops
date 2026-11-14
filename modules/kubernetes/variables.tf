# ---------------------------------------------------------------------------
# INTERFACE DO MÓDULO DE KUBERNETES
# ---------------------------------------------------------------------------

# --- Identificação --------------------------------------------------------

variable "name" {
  description = "Nome do cluster EKS."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-_]{0,99}$", var.name))
    error_message = "O nome do cluster aceita letras, números, hífen e underscore, começando por letra ou número."
  }
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes no plano de controle. Ex.: \"1.33\"."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^1\\.(2[0-9]|3[0-9])$", var.kubernetes_version))
    error_message = "Informe a versão no formato MAIOR.MENOR, ex.: \"1.33\" (sem patch)."
  }
}

variable "tags" {
  description = "Tags aplicadas ao cluster e aos node groups."
  type        = map(string)
  default     = {}
  nullable    = false
}

# --- Rede -----------------------------------------------------------------

variable "vpc_id" {
  description = "ID da VPC onde o cluster será criado."
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = <<-EOT
    Subnets dos nós do cluster.

    Use SEMPRE as subnets privadas. Nó em subnet pública recebe IP público e
    fica exposto à internet sem necessidade: o acesso externo às aplicações
    deve entrar por Load Balancer, não pelo nó.
  EOT
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "O EKS exige subnets em no mínimo 2 zonas de disponibilidade."
  }
}

# --- Acesso ao endpoint da API -------------------------------------------

variable "endpoint_private_access" {
  description = "Permite acesso ao endpoint da API de dentro da VPC."
  type        = bool
  default     = true
  nullable    = false
}

variable "endpoint_public_access" {
  description = <<-EOT
    Expõe o endpoint da API do cluster na internet.

    Padrão `false` (seguro por omissão). Mas atenção ao ligar/desligar: o
    runner do GitHub Actions é máquina fora da VPC, e o Terraform precisa
    falar com a API do cluster para gerenciar access entries. Com `false`,
    o apply pela pipeline só funciona com runner self-hosted dentro da VPC
    ou com VPN. Quando `true`, restrinja com `endpoint_public_access_cidrs`.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDRs autorizados a alcançar o endpoint público.

    `["0.0.0.0/0"]` significa "qualquer IP do planeta pode tentar autenticar".
    Vale restringir à faixa de IP da empresa/VPN sempre que possível.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
  nullable    = false
}

# --- Nós ------------------------------------------------------------------

variable "node_groups" {
  description = <<-EOT
    Grupos de nós gerenciados, indexados pelo nome.

    Atributos sem valor padrão aqui são repassados como `null`, e o módulo
    oficial aplica o padrão dele. Isso é deliberado: evita que este wrapper
    force uma mudança de infraestrutura (trocar `disk_size`, por exemplo,
    substitui os nós) só por ter opinião sobre o valor.

    Exemplo:
      node_groups = {
        default = {
          instance_types = ["t3.medium"]
          min_size       = 2
          max_size       = 6
          desired_size   = 2
        }
        spot = {
          instance_types = ["t3.medium", "t3a.medium"]
          capacity_type  = "SPOT"
          min_size       = 0
          max_size       = 10
          desired_size   = 0
          labels         = { workload = "batch" }
          taints = {
            spot = { key = "spot", value = "true", effect = "NO_SCHEDULE" }
          }
        }
      }
  EOT
  type = map(object({
    instance_types = optional(list(string), ["t3.medium"])
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    # ON_DEMAND ou SPOT. SPOT custa bem menos e serve a carga tolerante a
    # interrupção; não use para carga que não pode ser evacuada.
    capacity_type = optional(string, "ON_DEMAND")
    ami_type      = optional(string)
    disk_size     = optional(number)
    labels        = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})
  }))
  nullable = false

  validation {
    condition     = length(var.node_groups) > 0
    error_message = "Defina ao menos um grupo de nós."
  }

  validation {
    condition = alltrue([
      for ng in values(var.node_groups) : ng.max_size >= ng.min_size
    ])
    error_message = "Em todo grupo de nós, max_size deve ser maior ou igual a min_size."
  }

  validation {
    condition = alltrue([
      for ng in values(var.node_groups) :
      ng.desired_size >= ng.min_size && ng.desired_size <= ng.max_size
    ])
    error_message = "Em todo grupo de nós, desired_size deve ficar entre min_size e max_size."
  }

  validation {
    condition = alltrue([
      for ng in values(var.node_groups) :
      contains(["ON_DEMAND", "SPOT"], ng.capacity_type)
    ])
    error_message = "capacity_type aceita apenas ON_DEMAND ou SPOT."
  }
}

# --- Permissões -----------------------------------------------------------

variable "enable_cluster_creator_admin_permissions" {
  description = <<-EOT
    Dá permissão de admin no cluster à identidade que executou o apply.

    Com `true`, quem manda é a credencial da pipeline. Em time maior, o
    correto é `false` e declarar explicitamente quem tem acesso em
    `access_entries`, para que o acesso não dependa de quem rodou o apply.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "access_entries" {
  description = <<-EOT
    Mapeamento explícito de IAM para permissão no cluster (EKS Access Entries).

    Substitui a edição manual do ConfigMap aws-auth, que era a forma antiga
    e uma das principais causas de perda de acesso a cluster EKS.
  EOT
  type        = any
  default     = {}
}

# --- Observabilidade ------------------------------------------------------

variable "enabled_log_types" {
  description = <<-EOT
    Logs do plano de controle enviados ao CloudWatch.

    O padrão inclui `audit`: é o registro de quem fez o que na API do
    cluster. Sem ele não há investigação de incidente possível.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
  nullable    = false
}

variable "log_retention_days" {
  description = "Dias de retenção dos logs do plano de controle."
  type        = number
  default     = 30
  nullable    = false
}

# --- Complementos ---------------------------------------------------------

variable "addons" {
  description = <<-EOT
    Addons gerenciados do EKS (coredns, kube-proxy, vpc-cni, ebs-csi-driver).

    Padrão `{}` para não alterar um cluster existente sem intenção. Ver o
    README deste módulo para o conjunto recomendado.
  EOT
  type        = any
  default     = {}
}

variable "deletion_protection" {
  description = <<-EOT
    Impede a exclusão do cluster enquanto estiver `true`.

    Recomendado em produção. Atenção: com `true`, o workflow de destroy
    falha de propósito até alguém desligar esta proteção conscientemente.
  EOT
  type        = bool
  default     = false
  nullable    = false
}
