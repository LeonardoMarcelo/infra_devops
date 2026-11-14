# ---------------------------------------------------------------------------
# INTERFACE DO MÓDULO DE REDE
# ---------------------------------------------------------------------------
# Toda variável tem descrição, tipo explícito e — quando há regra de negócio —
# um bloco `validation`. Validar aqui faz o erro aparecer no `plan`, com
# mensagem clara, em vez de estourar no meio do `apply` como erro da API da AWS.
# ---------------------------------------------------------------------------

# --- Identificação --------------------------------------------------------

variable "name" {
  description = "Nome da VPC. Serve de prefixo para todos os recursos filhos."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.name) > 0 && length(var.name) <= 64
    error_message = "O nome da VPC deve ter entre 1 e 64 caracteres."
  }
}

variable "tags" {
  description = "Tags aplicadas a todos os recursos de rede."
  type        = map(string)
  default     = {}
  nullable    = false
}

# --- Endereçamento --------------------------------------------------------

variable "cidr" {
  description = "Bloco CIDR da VPC. Ex.: 10.0.0.0/16."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "O valor de `cidr` precisa ser um bloco CIDR IPv4 válido."
  }
}

variable "azs" {
  description = <<-EOT
    Zonas de disponibilidade, em ordem.

    É `list` e não `set` de propósito: a posição importa. O módulo de VPC
    associa `private_subnets[i]` a `azs[i]`, então um `set` (que o Terraform
    reordena) embaralharia a distribuição das subnets entre as AZs.
  EOT
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Use no mínimo 2 zonas de disponibilidade para haver tolerância a falha."
  }
}

variable "private_subnets" {
  description = "CIDRs das subnets privadas, uma por AZ e na mesma ordem de `azs`."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "public_subnets" {
  description = "CIDRs das subnets públicas, uma por AZ e na mesma ordem de `azs`."
  type        = list(string)
  default     = []
  nullable    = false
}

# --- Saída para a internet ------------------------------------------------

variable "enable_nat_gateway" {
  description = "Cria NAT Gateway para dar saída à internet às subnets privadas."
  type        = bool
  default     = true
  nullable    = false
}

variable "single_nat_gateway" {
  description = <<-EOT
    Usa um único NAT Gateway para todas as AZs, em vez de um por AZ.

    Esta é a principal alavanca de custo do módulo. Um NAT Gateway custa na
    ordem de US$ 32/mês mais tráfego; com 3 AZs são 3 cobranças.
    `true`  -> barato, mas a queda de uma AZ derruba a saída de todas.
    `false` -> um por AZ: resiliente, indicado para produção.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_vpn_gateway" {
  description = <<-EOT
    Cria um Virtual Private Gateway para VPN site-to-site.

    Padrão `false`: só habilite se existir um túnel VPN de verdade para
    conectar. Um VGW ocioso é recurso cobrado sem nenhuma função.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

# --- Observabilidade e auditoria ------------------------------------------

variable "enable_flow_logs" {
  description = <<-EOT
    Habilita VPC Flow Logs no CloudWatch.

    Padrão `true`: sem flow logs não há como responder "quem falou com quem"
    depois de um incidente. É o registro de auditoria da rede.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "flow_logs_retention_days" {
  description = "Dias de retenção dos flow logs no CloudWatch."
  type        = number
  default     = 30
  nullable    = false
}

# --- Integração com Kubernetes (opcional) ---------------------------------

variable "kubernetes_cluster_name" {
  description = <<-EOT
    Nome do cluster EKS que vai usar esta VPC.

    Quando informado, as subnets recebem as tags que o Kubernetes exige para
    descobrir onde criar Load Balancers. Quando `null`, nenhuma tag de
    Kubernetes é aplicada — é isso que permite reusar este mesmo módulo em
    projetos sem EKS (Lambda, RDS, EC2).
  EOT
  type        = string
  default     = null
}

variable "public_subnet_tags" {
  description = "Tags extras só nas subnets públicas."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "private_subnet_tags" {
  description = "Tags extras só nas subnets privadas."
  type        = map(string)
  default     = {}
  nullable    = false
}
