# Módulo `network`

VPC com subnets públicas e privadas distribuídas por zona de disponibilidade,
saída para a internet via NAT Gateway e flow logs no CloudWatch.

Envelopa o [módulo oficial de VPC](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws)
e expõe uma interface menor, com padrões seguros.

## Quando usar

Em qualquer projeto AWS que precise de rede própria. Não é específico de
Kubernetes: a integração com EKS é opcional e controlada por uma variável.

## Uso mínimo

```hcl
module "network" {
  source = "../../modules/network"

  name = "meu-projeto-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  tags = { Project = "meu-projeto" }
}
```

## Com EKS

Informe `kubernetes_cluster_name`. As subnets passam a receber as tags que o
Kubernetes usa para descobrir onde criar Load Balancer:

```hcl
module "network" {
  source = "../../modules/network"
  # ...
  kubernetes_cluster_name = "meu-cluster"
}
```

Sem essas tags, um `Service` do tipo `LoadBalancer` fica em `Pending` para
sempre — e a causa não aparece em lugar óbvio.

## Sem EKS (Lambda, RDS, EC2)

Omita `kubernetes_cluster_name`. Nenhuma tag de Kubernetes é aplicada.

Para Lambda em VPC, bastam as subnets privadas com NAT:

```hcl
module "network" {
  source = "../../modules/network"

  name            = "lambda-vpc"
  cidr            = "10.20.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.20.1.0/24", "10.20.2.0/24"]
  public_subnets  = []          # Lambda não precisa de subnet pública

  single_nat_gateway = true     # economia em ambiente sem exigência de HA
  tags               = { Project = "lambda-api" }
}
```

## Variáveis

| Nome | Tipo | Padrão | Descrição |
|---|---|---|---|
| `name` | `string` | — | Nome da VPC, prefixo dos recursos filhos |
| `cidr` | `string` | — | CIDR da VPC |
| `azs` | `list(string)` | — | AZs em ordem; mínimo 2 |
| `private_subnets` | `list(string)` | `[]` | CIDRs privados, na ordem de `azs` |
| `public_subnets` | `list(string)` | `[]` | CIDRs públicos, na ordem de `azs` |
| `enable_nat_gateway` | `bool` | `true` | Saída para a internet das subnets privadas |
| `single_nat_gateway` | `bool` | `false` | Um NAT para todas as AZs (barato, menos resiliente) |
| `enable_vpn_gateway` | `bool` | `false` | Virtual Private Gateway para VPN site-to-site |
| `enable_flow_logs` | `bool` | `true` | Flow logs no CloudWatch |
| `flow_logs_retention_days` | `number` | `30` | Retenção dos flow logs |
| `kubernetes_cluster_name` | `string` | `null` | Liga as tags de descoberta do EKS |
| `public_subnet_tags` | `map(string)` | `{}` | Tags extras nas subnets públicas |
| `private_subnet_tags` | `map(string)` | `{}` | Tags extras nas subnets privadas |
| `tags` | `map(string)` | `{}` | Tags em todos os recursos |

## Saídas

`vpc_id`, `vpc_cidr_block`, `private_subnet_ids`, `public_subnet_ids`, `azs`,
`nat_public_ips`.

## Decisões embutidas

**`azs` é `list`, não `set`.** A posição importa: o módulo associa
`private_subnets[i]` à `azs[i]`. Um `set` é reordenado pelo Terraform e
embaralharia a distribuição.

**`enable_vpn_gateway` começa `false`.** Um Virtual Private Gateway sem túnel
conectado é recurso cobrado sem função nenhuma.

**`enable_flow_logs` começa `true`.** Sem flow logs não existe como
reconstruir "quem falou com quem" depois de um incidente de segurança.

**`one_nat_gateway_per_az` é derivado**, não é variável. O módulo oficial
rejeita a combinação `single_nat_gateway = true` com
`one_nat_gateway_per_az = true`; a expressão interna torna o conflito
impossível de expressar.

## Custo

O NAT Gateway é o item dominante: cerca de US$ 32/mês cada, mais tráfego.
Com `single_nat_gateway = false` e 3 AZs, são três. É a primeira coisa a
revisar em ambiente que não é produção.
