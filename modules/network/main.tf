# ---------------------------------------------------------------------------
# MÓDULO: NETWORK
# ---------------------------------------------------------------------------
# Envelopa o módulo oficial terraform-aws-modules/vpc e expõe uma interface
# menor e opinativa.
#
# Por que envelopar em vez de chamar o módulo oficial direto do ambiente:
#   1. Padrões seguros por omissão (flow logs ligados, VPN gateway desligado)
#      valem para todo projeto que usar este módulo, sem precisar lembrar.
#   2. A interface fica estável: trocar a implementação por baixo (outra
#      versão, ou recursos `aws_vpc` escritos à mão) não quebra os ambientes.
#   3. As tags de Kubernetes ficam opcionais, o que permite reusar este mesmo
#      módulo em projeto sem EKS.
# ---------------------------------------------------------------------------

# ===========================================================================
# ETAPA 1 — Tags de descoberta do Kubernetes (condicionais)
# ===========================================================================
# O Kubernetes descobre em quais subnets criar Load Balancer lendo tags.
# Sem a tag `kubernetes.io/role/elb`, um Service do tipo LoadBalancer fica
# pendente para sempre. Com `kubernetes_cluster_name = null` nada disso é
# aplicado, e o módulo serve a qualquer projeto que não use Kubernetes.
locals {
  cluster_discovery_tag = var.kubernetes_cluster_name == null ? {} : {
    "kubernetes.io/cluster/${var.kubernetes_cluster_name}" = "shared"
  }

  # Subnet pública: onde entra o Load Balancer voltado para a internet.
  computed_public_subnet_tags = merge(
    local.cluster_discovery_tag,
    var.kubernetes_cluster_name == null ? {} : { "kubernetes.io/role/elb" = "1" },
    var.public_subnet_tags,
  )

  # Subnet privada: onde entra o Load Balancer interno.
  computed_private_subnet_tags = merge(
    local.cluster_discovery_tag,
    var.kubernetes_cluster_name == null ? {} : { "kubernetes.io/role/internal-elb" = "1" },
    var.private_subnet_tags,
  )
}

# ===========================================================================
# ETAPA 2 — VPC, subnets, rotas e saída para a internet
# ===========================================================================
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  # Faixa dentro do major 5: pega correção de bug sem receber quebra de
  # interface. A versão exata resolvida fica registrada no .terraform.lock.hcl.
  version = "~> 5.8"

  name = var.name
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # --- Saída para a internet ---
  # Subnets privadas não têm rota direta para a internet; o NAT Gateway dá a
  # elas saída (para baixar imagem de container, chamar API da AWS) sem
  # permitir conexão de entrada.
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  # Um NAT por AZ: o tráfego da AZ não cruza fronteira de zona e a queda de
  # uma AZ não derruba a saída das outras. Mutuamente exclusivo com
  # single_nat_gateway, daí a expressão.
  one_nat_gateway_per_az = var.enable_nat_gateway && !var.single_nat_gateway

  enable_vpn_gateway = var.enable_vpn_gateway

  # --- DNS ---
  # Exigido pelo EKS: os nós precisam resolver nome dentro da VPC para se
  # registrarem no cluster.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # --- Auditoria de rede ---
  # Flow logs registram conexões aceitas e rejeitadas. É a única forma de
  # reconstruir o que aconteceu na rede depois de um incidente.
  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_logs_retention_days

  # --- Tags ---
  tags                = var.tags
  public_subnet_tags  = local.computed_public_subnet_tags
  private_subnet_tags = local.computed_private_subnet_tags
}
