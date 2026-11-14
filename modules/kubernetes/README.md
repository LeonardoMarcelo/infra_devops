# Módulo `kubernetes`

Cluster Amazon EKS com nós gerenciados, access entries, logs de auditoria do
plano de controle e padrões seguros de exposição da API.

Envelopa o [módulo oficial de EKS](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws)
(major 21) e expõe uma interface tipada e validada.

## Quando usar

Quando o projeto precisa de Kubernetes gerenciado na AWS. Para carga
orientada a evento, sem processo de longa duração, Lambda sai mais barato e
mais simples — ver a seção de adaptação no README raiz.

## Uso mínimo

```hcl
module "kubernetes" {
  source = "../../modules/kubernetes"

  name               = "meu-cluster"
  kubernetes_version = "1.33"

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 6
      desired_size   = 2
    }
  }

  tags = { Project = "meu-projeto" }
}
```

## Cenários

### Produção com nós spot para carga tolerante a interrupção

```hcl
node_groups = {
  # Carga que não pode ser evacuada: on-demand.
  sistema = {
    instance_types = ["t3.medium"]
    min_size       = 2
    max_size       = 6
    desired_size   = 2
  }

  # Processamento em lote: spot, bem mais barato, com taint para que só
  # pod que tolera interrupção seja agendado nele.
  batch = {
    instance_types = ["t3.medium", "t3a.medium", "t3.large"]
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
```

Vários tipos de instância em `instance_types` não é redundância: amplia o
pool de capacidade spot e reduz a chance de a AWS não ter máquina para
entregar.

### Endpoint privado (sem API na internet)

```hcl
endpoint_public_access  = false
endpoint_private_access = true
```

**Antes de fazer isso, leia:** o runner hospedado pelo GitHub está fora da
VPC. Com o endpoint fechado, o Terraform não alcança a API do cluster e o
apply da pipeline falha ao gerenciar access entries. O caminho completo exige
runner self-hosted dentro da VPC, ou VPN, ou AWS Systems Manager. Fechar o
endpoint sem resolver o acesso da pipeline primeiro quebra a automação.

### Acesso de time, sem depender de quem rodou o apply

```hcl
enable_cluster_creator_admin_permissions = false

access_entries = {
  plataforma = {
    principal_arn = "arn:aws:iam::123456789012:role/PlataformaAdmin"
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }
}
```

Com `enable_cluster_creator_admin_permissions = true`, quem tem admin é a
identidade que executou o apply — ou seja, a credencial da pipeline. Em time
maior, declare explicitamente quem acessa.

### Addons recomendados

O padrão é `{}` para não alterar cluster existente sem intenção. O conjunto
recomendado para cluster novo:

```hcl
addons = {
  coredns                = {}   # DNS interno
  kube-proxy             = {}   # rede de Service
  vpc-cni                = {}   # CNI da AWS
  aws-ebs-csi-driver     = {}   # necessário para PersistentVolumeClaim
  eks-pod-identity-agent = {}   # credencial de AWS por pod
}
```

Sem `aws-ebs-csi-driver`, qualquer PVC fica em `Pending` e nada com estado
sobe no cluster. Adicionar addons cria recursos novos: faça num apply
próprio, com o plan revisado.

## Variáveis

| Nome | Tipo | Padrão | Descrição |
|---|---|---|---|
| `name` | `string` | — | Nome do cluster |
| `kubernetes_version` | `string` | — | Versão MAIOR.MENOR, ex. `"1.33"` |
| `vpc_id` | `string` | — | VPC do cluster |
| `subnet_ids` | `list(string)` | — | Subnets dos nós; use as privadas |
| `endpoint_private_access` | `bool` | `true` | API acessível de dentro da VPC |
| `endpoint_public_access` | `bool` | `false` | API acessível pela internet |
| `endpoint_public_access_cidrs` | `list(string)` | `["0.0.0.0/0"]` | CIDRs autorizados no endpoint público |
| `node_groups` | `map(object)` | — | Grupos de nós; ver abaixo |
| `enable_cluster_creator_admin_permissions` | `bool` | `true` | Admin para quem rodou o apply |
| `access_entries` | `any` | `{}` | Mapeamento explícito IAM → cluster |
| `enabled_log_types` | `list(string)` | `["api","audit","authenticator"]` | Logs do plano de controle |
| `log_retention_days` | `number` | `30` | Retenção dos logs |
| `addons` | `any` | `{}` | Addons gerenciados |
| `deletion_protection` | `bool` | `false` | Impede exclusão do cluster |
| `tags` | `map(string)` | `{}` | Tags no cluster e nos nós |

### Estrutura de `node_groups`

| Atributo | Tipo | Padrão |
|---|---|---|
| `instance_types` | `list(string)` | `["t3.medium"]` |
| `min_size` | `number` | `2` |
| `max_size` | `number` | `4` |
| `desired_size` | `number` | `2` |
| `capacity_type` | `string` | `"ON_DEMAND"` |
| `ami_type` | `string` | — (padrão do módulo oficial) |
| `disk_size` | `number` | — (padrão do módulo oficial) |
| `labels` | `map(string)` | `{}` |
| `taints` | `map(object({key, value, effect}))` | `{}` |

`ami_type` e `disk_size` ficam sem padrão de propósito: definir um valor aqui
substituiria os nós de todo cluster que usa este módulo. Quem quiser muda no
ambiente, com o plan na mão.

## Saídas

`cluster_name`, `cluster_arn`, `cluster_endpoint`, `cluster_version`,
`cluster_certificate_authority_data` (sensível), `cluster_security_group_id`,
`node_security_group_id`, `oidc_provider_arn`, `cluster_oidc_issuer_url`.

## Validações que rodam no plan

- `max_size >= min_size`
- `min_size <= desired_size <= max_size`
- `capacity_type` ∈ {`ON_DEMAND`, `SPOT`}
- ao menos 1 grupo de nós
- ao menos 2 subnets (exigência do EKS)
- formato de `kubernetes_version` (`1.NN`, sem patch)

Validar aqui faz o erro aparecer no plan, com mensagem legível, em vez de
estourar no meio do apply como erro cru da API da AWS.

## Decisões embutidas

**`endpoint_public_access` começa `false`.** Seguro por omissão. O ambiente de
produção deste repositório liga explicitamente, com o motivo comentado.

**`min_size` 2 e `max_size` 4 como padrão.** Com `min = max`, o cluster não
escala: só repõe nó morto. A elasticidade exige folga entre os dois.

**Access entries, não `aws-auth`.** A forma antiga era editar um ConfigMap
dentro do cluster — um erro de digitação ali trancava o time inteiro para
fora, sem recuperação simples.

**Log de auditoria ligado.** `audit` registra quem fez o que na API do
cluster. Sem ele, investigação de incidente não acontece.
