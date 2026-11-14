# ---------------------------------------------------------------------------
# MÓDULO: KUBERNETES (Amazon EKS)
# ---------------------------------------------------------------------------
# Envelopa o módulo oficial terraform-aws-modules/eks.
#
# O que este wrapper acrescenta sobre chamar o módulo oficial direto:
#   1. Interface pequena e tipada: `node_groups` aceita só o que faz sentido
#      ajustar, com validação de min/max/desired antes do apply.
#   2. Padrões seguros: endpoint público desligado, log de auditoria ligado.
#   3. Ponto único para trocar a implementação — inclusive por outro serviço
#      de Kubernetes gerenciado — sem mexer em nenhum ambiente.
# ---------------------------------------------------------------------------

# ===========================================================================
# ETAPA 1 — Normalização dos grupos de nós
# ===========================================================================
# Converte a interface enxuta deste módulo no formato que o módulo oficial
# espera. Atributos nulos são omitidos pelo próprio módulo oficial, que então
# aplica o padrão dele — é assim que este wrapper evita forçar mudança de
# infraestrutura por simples opinião de valor.
locals {
  managed_node_groups = {
    for group_name, group in var.node_groups : group_name => {
      instance_types = group.instance_types
      capacity_type  = group.capacity_type

      # Limites de escala. max_size > min_size é o que permite ao
      # Cluster Autoscaler / Karpenter crescer o cluster sob carga.
      min_size     = group.min_size
      max_size     = group.max_size
      desired_size = group.desired_size

      ami_type  = group.ami_type
      disk_size = group.disk_size

      # Labels e taints controlam o agendamento: é por aqui que se separa
      # carga de produção de carga de desenvolvimento no mesmo cluster.
      labels = group.labels
      taints = group.taints

      tags = var.tags
    }
  }
}

# ===========================================================================
# ETAPA 2 — Plano de controle, nós e permissões
# ===========================================================================
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # Faixa dentro do major 21. A v21 removeu o prefixo "cluster_" de vários
  # argumentos, por isso a faixa não pode atravessar major.
  version = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  # --- Rede ---
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # --- Exposição da API ---
  endpoint_private_access      = var.endpoint_private_access
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # --- Nós gerenciados ---
  # "Gerenciados" = a AWS cuida do ciclo de vida (patch de AMI, drain
  # ordenado na troca). Menos código e menos risco que node group próprio.
  eks_managed_node_groups = local.managed_node_groups

  # --- Permissões de acesso ao cluster ---
  # Access Entries é a forma atual, via API da AWS. A forma antiga era editar
  # o ConfigMap aws-auth dentro do cluster, onde um erro de digitação
  # trancava todo mundo para fora sem recuperação simples.
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  access_entries                           = var.access_entries

  # --- Logs do plano de controle ---
  enabled_log_types                      = var.enabled_log_types
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # --- Complementos gerenciados ---
  addons = var.addons

  # --- Proteção contra exclusão acidental ---
  deletion_protection = var.deletion_protection

  tags = var.tags
}
