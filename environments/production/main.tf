# ---------------------------------------------------------------------------
# AMBIENTE: PRODUÇÃO
# ---------------------------------------------------------------------------
# Este arquivo é só COMPOSIÇÃO: ele liga módulos e passa valores. Nenhum
# recurso (`resource`) é declarado aqui.
#
# Essa separação é o que torna o projeto reaproveitável: para criar um novo
# ambiente, copie este diretório, ajuste o terraform.tfvars e aponte para
# outra key de state. Os módulos não mudam.
# ---------------------------------------------------------------------------

# ===========================================================================
# ETAPA 1 — Rede
# ===========================================================================
# Precisa existir antes do cluster: o EKS recebe os IDs de VPC e subnet.
# O Terraform deduz essa ordem sozinho pela referência a module.network.
module "network" {
  source = "../../modules/network"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  # Saída para a internet das subnets privadas.
  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  # Sem túnel VPN neste projeto: não há por que pagar por um gateway ocioso.
  enable_vpn_gateway = false

  # Auditoria de rede.
  enable_flow_logs         = var.enable_flow_logs
  flow_logs_retention_days = var.flow_logs_retention_days

  # Informar o cluster faz as subnets receberem as tags de descoberta que o
  # Kubernetes usa para saber onde criar Load Balancer.
  kubernetes_cluster_name = var.cluster_name

  tags = var.project_tags
}

# ===========================================================================
# ETAPA 2 — Cluster Kubernetes
# ===========================================================================
module "kubernetes" {
  source = "../../modules/kubernetes"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Nós sempre em subnet privada. O acesso externo às aplicações entra por
  # Load Balancer nas subnets públicas, não pelo nó.
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  # Exposição da API do cluster.
  endpoint_private_access      = true
  endpoint_public_access       = var.cluster_endpoint_public_access
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  node_groups = var.node_groups

  # Logs do plano de controle, incluindo auditoria.
  log_retention_days = var.cluster_log_retention_days

  addons              = var.cluster_addons
  deletion_protection = var.cluster_deletion_protection

  tags = var.project_tags
}
