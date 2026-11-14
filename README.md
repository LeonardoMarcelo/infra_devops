# Infraestrutura como Código — Terraform + EKS + GitHub Actions

Provisionamento automatizado de um cluster Kubernetes gerenciado na AWS, com
observabilidade (Prometheus + Grafana) e pipeline de entrega em gitflow.

O repositório é estruturado como **template reaproveitável**: os blocos de
infraestrutura ficam em `modules/`, desacoplados de qualquer projeto
específico, e cada ambiente é apenas uma composição desses blocos com um
arquivo de configuração. Trocar de projeto, de ambiente ou de nuvem é mexer
em uma camada só — ver [Como adaptar](#como-adaptar-para-outros-cenários).

---

## Índice

- [Objetivo](#objetivo)
- [Premissas do projeto](#premissas-do-projeto)
- [Estrutura do repositório](#estrutura-do-repositório)
- [Tecnologias](#tecnologias)
- [Como usar](#como-usar)
- [Monitoramento](#monitoramento)
- [Quando usar este projeto (e quando não)](#quando-usar-este-projeto-e-quando-não)
- [A pipeline](#a-pipeline)
- [Como adaptar para outros cenários](#como-adaptar-para-outros-cenários)
- [Boas práticas a seguir](#boas-práticas-a-seguir)
- [Melhorias implementadas](#melhorias-implementadas)
- [Pendências conhecidas](#pendências-conhecidas)

---

## Objetivo

Automatizar a criação e a manutenção do ambiente de execução dos projetos de
software da Mr. Fusion Solutions, com uma base escalável que suporte o
crescimento de vários microsserviços.

## Premissas do projeto

- Terraform como ferramenta de infraestrutura como código.
- Cluster Kubernetes criado com o Amazon EKS.
- O projeto deve ser o mais simples e reaproveitável possível.
- Alteração no código Terraform da branch principal dispara a pipeline.
- Um único cluster Kubernetes: desenvolvimento, homologação e produção são
  separados por *namespace*, não por cluster.

## Estrutura do repositório

```mermaid
flowchart LR
    subgraph MODULES["modules/ — blocos reutilizáveis (versões em faixa)"]
        MN["network<br/>VPC · subnets · NAT · flow logs"]
        MK["kubernetes<br/>EKS · node groups · access entries"]
        MO["observability<br/>Prometheus · Grafana · exporters"]
    end

    subgraph ENVS["environments/ — composição (versões fixas, 1 state cada)"]
        EP["production<br/>key: producao/infra.tfstate"]
        EO["production-observability<br/>key: producao/observability.tfstate"]
    end

    subgraph AWS["AWS"]
        VPC["VPC — 3 AZ<br/>subnets privadas e públicas · NAT"]
        EKS["EKS<br/>node group 2..4 nós"]
        STACK["Stack de monitoramento<br/>namespace monitoring"]
        S3["S3<br/>state + lock nativo"]
    end

    MN --> EP
    MK --> EP
    MO --> EO

    EP --> VPC
    EP --> EKS
    EO --> STACK
    STACK -.->|roda dentro| EKS
    EO -.->|"lê o cluster<br/>(data source)"| EKS

    EP --> S3
    EO --> S3
```

As setas da esquerda para a direita são a única direção de dependência que
existe: módulo não conhece ambiente, ambiente não conhece pipeline. A seta
pontilhada de `production-observability` para o EKS é leitura por data
source — não é criação, e é o que permite as duas camadas terem states
separados.

```
.
├── modules/                          # CAMADA 1 — blocos reutilizáveis
│   ├── network/                      #   VPC, subnets, NAT, flow logs
│   │   ├── main.tf
│   │   ├── variables.tf              #   interface do módulo, com validações
│   │   ├── outputs.tf
│   │   ├── versions.tf               #   versões em FAIXA (>=, ~>)
│   │   └── README.md
│   ├── kubernetes/                   #   cluster EKS, node groups, access entries
│   └── observability/                #   Prometheus, Grafana, exporters
│
├── environments/                     # CAMADA 2 — composição, um state cada
│   ├── production/                   #   rede + cluster
│   │   ├── main.tf                   #     só liga módulos; nenhum `resource`
│   │   ├── variables.tf
│   │   ├── terraform.tfvars          #     o que muda entre ambientes
│   │   ├── backend.tf                #     onde o state mora
│   │   ├── providers.tf
│   │   ├── versions.tf               #     versões FIXAS (a raiz é quem fixa)
│   │   ├── outputs.tf
│   │   ├── moved.tf                  #     refatoração sem destruir recursos
│   │   └── .terraform.lock.hcl       #     versionado, cobre Linux e macOS
│   └── production-observability/     #   o que roda DENTRO do cluster
│
├── .github/workflows/                # CAMADA 3 — automação
│   ├── terraform.yml                 #   motor reutilizável (plan/apply)
│   ├── gitflow.yml                   #   quando rodar o quê
│   ├── validate.yml                  #   checagem rápida, sem credencial
│   └── destroy.yaml                  #   destruição manual, com barreiras
│
├── diagrama/
├── requisitos.md
└── README.md
```

### Por que três camadas

**`modules/` não sabe que ambiente existe.** Um módulo recebe parâmetros e
devolve saídas. Não tem backend, não tem provider configurado, não tem
`terraform.tfvars`. É isso que permite usá-lo em outro repositório sem
arrastar nada deste.

**`environments/` não declara recurso.** Só compõe. Criar um ambiente novo é
copiar um diretório e editar um arquivo de valores — o código não é
duplicado, apenas reusado com outra configuração e outro state.

**As versões seguem regras opostas nas duas camadas.** Módulo declara faixa
(`>= 6.0`); raiz fixa exato (`6.73.0`). Se um módulo fixasse versão, dois
módulos no mesmo projeto poderiam exigir versões diferentes do mesmo provider
e o projeto não daria `init`.

### Por que a observabilidade tem state separado

`environments/production-observability` é uma raiz própria, não um módulo a
mais dentro de `production`. Três razões:

1. **Raio de dano.** Um erro na stack de monitoramento não alcança a VPC nem
   o cluster.
2. **Ciclo de vida.** Dashboard e alerta mudam toda semana; VPC quase nunca.
   Misturados, todo ajuste de alerta replanejaria a rede inteira.
3. **Dependência de provider.** Os providers Helm e Kubernetes precisam de um
   cluster que **já existe**. Configurar provider a partir de recurso criado
   no mesmo apply é o anti-padrão clássico do Terraform: quebra o primeiro
   apply e, pior, quebra o `destroy`.

## Tecnologias

| Tecnologia | Papel | Por quê |
|---|---|---|
| [Terraform](https://www.terraform.io/) 1.17.2 | IaC | Requisito do projeto. Versão fixada em CI e na raiz |
| [AWS EKS](https://aws.amazon.com/eks) | Kubernetes gerenciado | Requisito do projeto |
| [AWS S3](https://aws.amazon.com/s3) | Backend de state | Serviço da própria AWS, com versionamento de objeto e lock nativo |
| [módulo VPC](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws) `~> 5.8` | Rede | Módulo oficial, mantido pela comunidade |
| [módulo EKS](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws) `~> 21.0` | Cluster | Módulo oficial, mantido pela comunidade |
| [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) | Monitoramento | Padrão de fato para Prometheus + Grafana em Kubernetes |
| [GitHub Actions](https://github.com/features/actions) | CI/CD | Requisito do projeto |

---

## Como usar

### Pré-requisitos

- Terraform 1.17.x (`terraform version`)
- AWS CLI configurado (`aws sts get-caller-identity`)
- Um bucket S3 para o state, **com versionamento habilitado**
- Permissões de IAM para criar VPC, EKS, IAM roles e grupos de log

### Configuração no GitHub

**Secrets** (*Settings → Secrets and variables → Actions*):

| Secret | Para quê |
|---|---|
| `AWS_ACCESS_KEY_ID` | Credencial da AWS |
| `AWS_SECRET_ACCESS_KEY` | Credencial da AWS |
| `AWS_BUCKET_NAME` | Bucket S3 do state |
| `AWS_BUCKET_FILE` | Caminho do arquivo de state dentro do bucket |

**Environment** (*Settings → Environments*): crie um chamado `production` e
marque **Required reviewers**. É esse ajuste que transforma o gate de
aprovação da pipeline em aprovação de verdade — sem ele, o `apply` roda
direto.

**Branch protection** em `main` e `develop`: exija o check `Plan` aprovado
antes de permitir merge.

### Ordem de aplicação

```
1. environments/production                 VPC + cluster
2. addon aws-ebs-csi-driver no cluster     sem ele os volumes não sobem
3. environments/production-observability   Prometheus + Grafana
```

### Execução local

```bash
cd environments/production

# Aponta para o state remoto (os valores são os mesmos dos secrets)
terraform init \
  -backend-config="bucket=<seu-bucket>" \
  -backend-config="key=producao/infra.tfstate" \
  -backend-config="region=us-east-1"

terraform plan
```

Para só conferir sintaxe, sem tocar no state nem precisar de credencial:

```bash
terraform init -backend=false
terraform validate
terraform fmt -check -recursive ../..
```

### Acessar o cluster depois do apply

```bash
aws eks update-kubeconfig --region us-east-1 --name live-eks
kubectl get nodes
```

O comando pronto também sai como output: `terraform output kubeconfig_command`.

### Fluxo do dia a dia

```bash
git switch develop && git pull
git switch -c feature/minha-mudanca

# edite environments/production/terraform.tfvars ou os módulos
terraform fmt -recursive .
git commit -am "ajusta tamanho do node group" && git push -u origin HEAD
# -> Validate roda em segundos, sem credencial

gh pr create --base develop
# -> Plan roda e o resultado aparece como comentário no PR
```

Para ir a produção: abra um PR de `release/x.y` para `main`, revise o plan
comentado, faça o merge e aprove o gate.

---

## Monitoramento

Prometheus, Grafana e Alertmanager, com três formas de conectar alvos. A
documentação completa, com todos os cenários, está em
[`modules/observability/README.md`](modules/observability/README.md).

```mermaid
flowchart LR
    subgraph ALVOS["Alvos — declarados no terraform.tfvars"]
        A1["API COM /metrics<br/>instrumentada"]
        A2["QUALQUER URL HTTP<br/>API sua, legada ou de terceiro"]
        A3["BANCO DE DADOS<br/>RDS · ElastiCache · no cluster"]
    end

    subgraph COLETA["Coleta — namespace monitoring"]
        SM["ServiceMonitor"]
        BB["blackbox-exporter<br/>sonda de fora"]
        EX["exporter por engine<br/>postgres · mysql · redis · mongodb"]
        PROM["Prometheus<br/>retenção 15d"]
    end

    subgraph SAIDA["Consumo"]
        GRAF["Grafana<br/>dashboards"]
        ALERT["Alertmanager"]
        NOTIF["Slack · e-mail · PagerDuty"]
    end

    A1 -->|api_targets| SM
    A2 -->|http_probes| BB
    A3 -->|database_targets| EX

    SM --> PROM
    BB --> PROM
    EX --> PROM

    PROM --> GRAF
    PROM --> ALERT
    ALERT --> NOTIF

    SEC["Secret do Kubernetes<br/>credencial nunca vai no tfvars"] -.-> EX
```

### Subindo a stack

```bash
cd environments/production-observability

terraform init \
  -backend-config="bucket=<seu-bucket>" \
  -backend-config="key=producao/observability.tfstate" \
  -backend-config="region=us-east-1"

terraform apply
```

Abra o Grafana sem expor nada na internet:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# usuário: admin
terraform output -raw grafana_admin_password
```

Sem nenhum alvo configurado, a stack já monitora o cluster inteiro: nós,
pods, plano de controle, kubelet.

### Escolhendo o tipo de alvo

Esta é a decisão central do monitoramento:

| Você tem | Use | O que mede | O que não mede |
|---|---|---|---|
| API sua, com `/metrics` | `api_targets` | Tudo de dentro: erro por rota, latência por percentil, fila, pool de conexão | — |
| API sua, sem `/metrics` | `http_probes` | Está no ar? Em quanto tempo responde? Certificado vence quando? | Qualquer coisa interna |
| API de terceiro | `http_probes` | O mesmo acima | Idem (você não controla o código) |
| Banco de dados | `database_targets` | Conexões, locks, replicação, cache hit, tamanho | — |

**É o `http_probes` que faz o módulo encaixar em qualquer API REST**: ele não
exige uma linha de código na aplicação. Mas a troca é real — sonda de fora
enxerga disponibilidade, não enxerga comportamento. Quando a API for sua,
instrumentar e usar `api_targets` vale muito mais.

O caminho usual é usar os dois: `http_probes` desde o primeiro dia, para ter
alarme de queda; `api_targets` conforme cada serviço for instrumentado.

### Registrando alvos

Tudo acontece em `environments/production-observability/terraform.tfvars`.
Nenhum módulo precisa ser alterado para monitorar algo novo.

```hcl
# 1. API instrumentada — gera um ServiceMonitor
api_targets = {
  pedidos = {
    namespace      = "producao"
    service_labels = { "app.kubernetes.io/name" = "pedidos-api" }
    port           = "http"      # NOME da porta no Service, não o número
    path           = "/metrics"
  }
}

# 2. Qualquer URL HTTP — sobe o blackbox exporter e sonda de fora
http_probes = {
  pedidos-health = {
    targets = ["https://api.exemplo.com/health"]
    module  = "http_2xx"
  }
  parceiro-pagamentos = {
    targets  = ["https://api.parceiro.com/status"]
    interval = "60s"
  }
}

# 3. Bancos — um exporter por entrada, funciona com RDS/ElastiCache
database_targets = {
  pedidos-pg = {
    engine             = "postgres"
    host               = "pedidos.abc.us-east-1.rds.amazonaws.com"
    port               = 5432
    credentials_secret = { name = "pg-pedidos", key = "datasource" }
  }
  cache = {
    engine             = "redis"
    host               = "cache.abc.use1.cache.amazonaws.com"
    credentials_secret = { name = "redis-cache", key = "password" }
  }
}
```

Engines suportadas: `postgres`, `mysql`, `redis`, `mongodb`.

**Credencial nunca entra no `.tfvars`.** Crie o Secret antes:

```bash
kubectl -n monitoring create secret generic pg-pedidos \
  --from-literal=datasource='postgresql://monitor:SENHA@host:5432/postgres?sslmode=require'
```

E dê ao usuário do monitoramento só leitura de estatísticas
(`GRANT pg_monitor TO monitor;` no PostgreSQL), nunca o usuário da aplicação.

### Alertas

O padrão do chart **não notifica ninguém** — alerta que não chega a uma
pessoa não é monitoramento. Configure `alertmanager_config` com rota e
receiver. Os alertas que valem desde o primeiro dia:

| Alerta | Expressão |
|---|---|
| API fora do ar | `probe_success == 0` por 2 min |
| Certificado vencendo | `probe_ssl_earliest_cert_expiry - time() < 14*24*3600` |
| Latência alta | `probe_duration_seconds > 2` por 5 min |
| Banco sem conexão | `pg_up == 0` / `mysql_up == 0` |
| Disco do nó acabando | `node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.1` |

### Pegadinhas que custam tempo

1. **Sem `aws-ebs-csi-driver`**, os PVCs do Prometheus e do Grafana ficam em
   `Pending` e a instalação estoura no timeout, sem erro óbvio.
2. **`t3.small` não comporta a stack.** Ela pede na ordem de 1 vCPU e 4 GB; o
   nó tem 2 GB. Suba o tipo ou o número de nós antes.
3. **`port` em `api_targets` é o nome da porta**, não o número. Com o número,
   o ServiceMonitor não casa e o alvo nunca aparece — sem erro, só silêncio.
4. **O security group do banco** precisa aceitar conexão vinda do security
   group dos nós (`module.kubernetes.node_security_group_id`).
5. **O que estoura o Prometheus é cardinalidade**, não número de alvos. Label
   com valor de alta variação (ID de usuário, ID de pedido) multiplica séries
   e consome memória até derrubar o pod.

---

## Quando usar este projeto (e quando não)

### Use como está quando

- A carga roda em contêiner, de forma contínua, e precisa de orquestração.
- Existem vários serviços que compartilham rede, escala e observabilidade.
- A separação por namespace atende (não há exigência de isolamento de conta).
- Alguém vai operar o cluster: Kubernetes gerenciado não é Kubernetes grátis.

### Use só a camada `modules/` quando

Você quer a VPC, mas não o cluster. O módulo `network` é independente e serve
a Lambda, RDS, EC2 ou qualquer outra coisa — basta omitir
`kubernetes_cluster_name`.

### Prefira outra coisa quando

| Situação | Alternativa |
|---|---|
| Carga orientada a evento, sem processo de longa duração | Lambda + API Gateway (bem mais barato e sem cluster para operar) |
| Um contêiner só, sem necessidade de orquestração | ECS Fargate ou App Runner |
| Exigência de isolamento forte entre ambientes | Uma conta AWS por ambiente, não namespaces |
| Site estático | S3 + CloudFront |

O EKS cobra pelo plano de controle mesmo sem nenhum pod rodando, e os NAT
Gateways cobram por hora. É infraestrutura com custo de base.

---

## A pipeline

Separando **quando** rodar (`gitflow.yml`) de **como** rodar
(`terraform.yml`):

```mermaid
flowchart TD
    DEV["Dev"] -->|push| FEAT["feature/* · bugfix/*"]

    FEAT -->|push| VAL["validate.yml<br/>fmt + validate<br/>SEM credencial AWS"]
    FEAT -->|Pull Request| DEVELOP["develop"]

    DEVELOP -->|"PR e merge"| PLAN1["gitflow.yml → terraform.yml<br/>PLAN<br/>comentado no PR"]
    PLAN1 -.->|nunca aplica| NOOP["develop não altera infraestrutura"]

    DEVELOP --> REL["release/* · hotfix/*"]
    REL -->|push| VAL
    REL -->|Pull Request| MAIN["main"]

    MAIN -->|no PR| PLAN2["PLAN<br/>é esta a revisão do que vai a produção"]
    MAIN -->|após o merge| PLAN3["PLAN<br/>plano salvo como artefato"]

    PLAN3 --> GATE{"Environment production<br/>aprovação manual"}
    GATE -->|aprovado| APPLY["APPLY do plano salvo<br/>não é replan"]
    GATE -->|sem mudança| SKIP["Não abre o gate"]

    APPLY --> CLOUD["AWS"]

    MANUAL["workflow_dispatch"] --> DESTROY["destroy.yaml<br/>1. digitar o nome do cluster<br/>2. aprovação do Environment"]
    DESTROY --> CLOUD
```

O ponto de partida era o fluxo direto do desafio
([`diagrama/image.png`](diagrama/image.png)): push na main dispara
`terraform apply --auto-approve`, sem revisão e sem gate.

Em forma de tabela:

| Evento | O que roda | Precisa de credencial AWS? |
|---|---|---|
| push em `feature/*`, `bugfix/*` | `fmt` + `validate` de cada módulo e de cada ambiente | **Não** |
| PR → `develop` | `plan`, comentado no PR | Sim |
| merge em `develop` | `plan` (confirma a integração, não aplica) | Sim |
| push em `release/*`, `hotfix/*` | `fmt` + `validate` | **Não** |
| PR → `main` | `plan` — é a revisão do que vai a produção | Sim |
| merge em `main` | `plan` → **aprovação manual** → `apply` do plano salvo | Sim |
| manual | `destroy`, com confirmação por digitação + aprovação | Sim |

Decisões embutidas na pipeline:

- **`develop` nunca aplica.** Como existe um cluster só, não há ambiente de
  desenvolvimento para aplicar. `develop` valida contra o state real sem
  mudá-lo.
- **O `apply` usa o plano salvo**, não um replan. O que foi revisado é
  exatamente o que executa.
- **O gate fica entre o plan e o apply**, e só abre se houver mudança
  (`-detailed-exitcode == 2`). Merge que não muda infraestrutura não acorda
  ninguém.
- **Branch não revisada nunca vê secret.** O `validate.yml` roda com
  `-backend=false` e zero credenciais.
- **`concurrency` compartilhado** entre `apply` e `destroy`: dois merges
  próximos não disputam o mesmo state.

---

## Como adaptar para outros cenários

Esta é a seção que torna o repositório um template. Em todos os casos, a
pergunta a fazer é: **qual camada muda?**

### 1. Adicionar um ambiente (staging, homologação)

Muda só `environments/`.

```bash
cp -r environments/production environments/staging
rm environments/staging/moved.tf          # moved só vale sobre state existente
# edite environments/staging/terraform.tfvars
```

Ajustes típicos no `terraform.tfvars` do novo ambiente:

```hcl
vpc_name     = "staging-vpc"
vpc_cidr     = "10.1.0.0/16"              # NÃO pode sobrepor outro ambiente
cluster_name = "staging-eks"

single_nat_gateway = true                 # 1 NAT em vez de 3: ~US$ 64/mês a menos

node_groups = {
  default = {
    instance_types = ["t3.small"]
    capacity_type  = "SPOT"               # staging tolera interrupção
    min_size       = 1
    max_size       = 3
    desired_size   = 1
  }
}
```

Depois, aponte a pipeline para o novo diretório — o motor já é parametrizado:

```yaml
jobs:
  plan-staging:
    uses: ./.github/workflows/terraform.yml
    with:
      working-directory: ./environments/staging
      action: plan
    secrets: inherit
```

**Cada ambiente precisa da própria `key` de state.** Dois ambientes no mesmo
arquivo de state é como o Terraform acaba destruindo o ambiente errado.

### 2. Outra região ou várias regiões

`aws_region` no `terraform.tfvars`, e `availability_zones` coerentes com a
nova região (`sa-east-1a`, `sa-east-1b`...). Para multi-região de verdade,
um diretório por região (`environments/producao-us`, `environments/producao-br`),
cada um com seu state — e não `alias` de provider no mesmo state, que
acopla a disponibilidade das duas regiões num plano só.

### 3. Trocar EKS por Lambda (serverless)

Muda `environments/*/main.tf` e entra um módulo novo. **A rede continua a
mesma.**

```hcl
# ETAPA 1 — Rede (sem nenhuma tag de Kubernetes)
module "network" {
  source = "../../modules/network"

  name            = "api-vpc"
  cidr            = "10.10.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24"]
  public_subnets  = []                  # Lambda não precisa de subnet pública

  single_nat_gateway      = true
  kubernetes_cluster_name = null        # <- é isto que desliga o acoplamento

  tags = var.project_tags
}

# ETAPA 2 — Funções
module "api" {
  source = "../../modules/serverless"   # novo módulo, mesmo padrão

  subnet_ids = module.network.private_subnet_ids
  tags       = var.project_tags
}
```

O módulo `modules/serverless` seguiria a mesma forma dos existentes
(`main.tf` + `variables.tf` + `outputs.tf` + `versions.tf` + `README.md`),
envelopando [terraform-aws-modules/lambda](https://registry.terraform.io/modules/terraform-aws-modules/lambda/aws).

**Lambda só precisa de VPC se for falar com recurso privado** (RDS,
ElastiCache). Função que só chama API pública fica mais rápida e mais simples
fora da VPC — e aí nem o módulo `network` é necessário.

Para o monitoramento, `modules/observability` **não serve**: ele instala
charts Helm num cluster. Em Lambda, as métricas já chegam ao CloudWatch sem
configuração; o que se acrescenta é Lambda Powertools para métrica de
negócio. O conceito de `http_probes`, porém, sobrevive — sonda HTTP não
depende de onde a aplicação roda.

A pipeline **não muda**: ela não sabe o que o Terraform cria.

### 4. Trocar AWS por Azure (ou GCP)

Mudam três coisas; a quarta é a que importa que **não** mude.

**a) O backend** — só `environments/*/backend.tf`:

```hcl
terraform {
  backend "azurerm" {
    # resource_group_name, storage_account_name e container_name
    # entram por -backend-config, como hoje
    key = "producao.tfstate"
  }
}
```

**b) O provider** — `environments/*/providers.tf` e os `versions.tf`:

```hcl
provider "azurerm" {
  features {}
}
```

**c) Os módulos** — `modules/network` passa a envelopar
`Azure/network/azurerm`, e `modules/kubernetes` passa a envelopar
`Azure/aks/azurerm`.

**d) A interface dos módulos, essa fica.** Este é o ponto da arquitetura:
`modules/kubernetes` continua recebendo `name`, `kubernetes_version`,
`subnet_ids`, `node_groups` e devolvendo `cluster_name`, `cluster_endpoint`,
`oidc_provider_arn`. O `environments/*/main.tf` quase não muda, porque ele
nunca falou com a AWS — falou com a sua interface.

**`modules/observability` é o que menos muda de todos.** Prometheus, Grafana
e os exporters são Kubernetes puro: o mesmo módulo roda em AKS ou GKE
trocando só o `storage_class` (`managed-csi` no Azure, `standard-rwo` no
GCP) e a autenticação do provider Helm.

Na pipeline, trocam-se os passos de autenticação (`azure/login@v2` no lugar
de `aws-actions/configure-aws-credentials@v4`). O resto — gitflow, gate,
plano salvo, concorrência — é agnóstico de nuvem.

**Multi-cloud não sai de graça.** Um módulo `network` que serve AWS e Azure
ao mesmo tempo vira o menor denominador comum entre as duas e perde o que
cada uma tem de bom. O padrão que funciona é um repositório (ou um diretório
de módulos) por nuvem, com a mesma convenção de interface.

### 5. Trocar o backend de state, continuando na AWS

Só `backend.tf`. Para Terraform Cloud / HCP:

```hcl
terraform {
  cloud {
    organization = "minha-org"
    workspaces { name = "producao" }
  }
}
```

### 6. Trocar Prometheus por serviço gerenciado

**Quando:** não há quem opere Prometheus, ou a conta de EBS e de nó dedicado
ao monitoramento passa a doer.

**Alternativas:** Amazon Managed Prometheus + Amazon Managed Grafana,
Datadog, New Relic, Grafana Cloud.

**A troca:** paga-se por ingestão de métrica em vez de por disco, e some a
operação. Com cardinalidade alta, o gerenciado costuma sair mais caro.

**Meio-termo**, sem trocar nada: manter a retenção local curta e mandar o
histórico longo para fora via remote write.

```hcl
extra_values = {
  prometheus = {
    prometheusSpec = {
      remoteWrite = [{
        url   = "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-xxx/api/v1/remote_write"
        sigv4 = { region = "us-east-1" }
      }]
    }
  }
}
```

Mais cenários de adaptação do monitoramento — monitoramento fora do
Kubernetes, cluster de observabilidade separado, CloudWatch no lugar dos
exporters — em [`modules/observability/README.md`](modules/observability/README.md#em-quais-casos-adaptaria).

### 7. Usar os módulos em outro repositório

`source` aceita Git. Versione os módulos com tag e consuma assim:

```hcl
module "network" {
  source = "git::https://github.com/LeonardoMarcelo/infra_devops.git//modules/network?ref=v1.2.0"
  # ...
}
```

Sempre com `?ref=` numa tag. Sem isso, o `init` pega o `main` do momento e o
seu ambiente muda sozinho quando alguém faz commit em outro repositório.

---

## Boas práticas a seguir

### Estrutura

- **Raiz fixa versão, módulo declara faixa.** Fixar em módulo torna o projeto
  insolúvel quando dois módulos discordam.
- **Versione o `.terraform.lock.hcl`**, e registre todas as plataformas que
  usam o projeto:
  ```bash
  terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
  ```
  Sem a plataforma do runner no lock, o `init` falha em CI por falta de hash.
- **Um state por ambiente e por ciclo de vida.** É a fronteira de raio de
  dano: um `destroy` errado só alcança o que está naquele state.
- **`environments/` não declara `resource`.** Ambiente compõe; módulo cria.
- **Módulo não configura provider.** Quem configura é a raiz. Módulo com
  provider próprio não pode ser reusado com outra autenticação e quebra o
  `destroy`.
- **Nunca `terraform apply` sem plano salvo em automação.** Entre o plan que
  você leu e o apply que roda, alguém pode ter feito merge.

### Código

- **Toda variável com `description` e tipo explícito.** `type = any` só
  quando a estrutura for mesmo livre.
- **`validation` nas regras de negócio.** O erro aparece no plan, legível, em
  vez de estourar no apply como erro cru da API.
- **Marque saídas sensíveis com `sensitive = true`** para não vazarem em log
  de pipeline.
- **Use `moved` para refatorar**, nunca `state mv` manual em automação.
- **`default_tags` no provider.** Garante que nenhum recurso escape sem tag,
  mesmo os criados indiretamente pelos módulos.
- **Dê um escape hatch aos wrappers.** `extra_values` é o que evita que toda
  necessidade nova exija alterar o módulo.

### Segurança

- **Troque chave estática por OIDC.** É a melhoria de segurança de maior
  impacto pendente aqui. Em vez de `AWS_ACCESS_KEY_ID` e
  `AWS_SECRET_ACCESS_KEY` guardados para sempre, o GitHub emite um token de
  curta duração e assume uma role:
  ```yaml
  permissions:
    id-token: write
    contents: read
  steps:
    - uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: arn:aws:iam::<conta>:role/github-actions-terraform
        aws-region: us-east-1
  ```
  Exige criar o provedor OIDC e a role na AWS, com `sub` restrito ao
  repositório e à branch. Credencial que não existe não vaza.
- **Nós sempre em subnet privada.** O acesso externo entra por Load Balancer.
- **Restrinja `cluster_endpoint_public_access_cidrs`** à faixa de IP da
  empresa sempre que houver uma.
- **Log de auditoria ligado** no plano de controle e flow logs na VPC. Ambos
  já vêm habilitados aqui.
- **IRSA em vez de permissão no nó.** Dê IAM ao *service account* do pod
  (usando `oidc_provider_arn`), não à role do nó — onde qualquer pod naquele
  nó herdaria o acesso.
- **Nada de segredo em `.tfvars`.** Secrets do GitHub Actions, AWS Secrets
  Manager, ou Secret do Kubernetes referenciado por nome.
- **Usuário de monitoramento só de leitura.** O exporter nunca usa a
  credencial da aplicação.
- **Não exponha Grafana na internet sem autenticação na frente.** Dashboard
  de observabilidade é mapa da topologia interna.
- **`deletion_protection = true`** em produção de verdade.

### Pipeline

- **Branch não revisada não vê secret.** Validação de sintaxe não precisa de
  credencial; separe os dois jobs.
- **Fixe a versão do Terraform** no workflow. Sem isso, a versão muda quando
  a imagem do runner é atualizada e o plano muda junto.
- **Fixe a versão dos charts Helm.** Com `null`, dois applies em dias
  diferentes instalam versões diferentes e o `plan` deixa de prever o que vai
  acontecer.
- **`concurrency` por state**, com `cancel-in-progress: false`. Cancelar
  `apply` pela metade é pior do que esperar na fila.
- **Nunca interpole `${{ github.event.* }}` dentro de `run:`.** Título de PR
  e mensagem de commit são texto controlado por quem abre o PR; passe por
  `env:` e leia como `"$VAR"`.
- **Fixe as actions de terceiros** em tag de major (`@v4`), nunca `@master`.

### Análise estática (recomendado, não habilitado aqui)

Não foi incluído na pipeline porque não consegui executar e verificar estas
ferramentas neste ambiente — e workflow não verificado é workflow que quebra
no primeiro uso. O snippet abaixo é o ponto de partida, para você adicionar
em `validate.yml` e conferir na primeira execução:

```yaml
  scan:
    name: Análise estática
    runs-on: ubuntu-latest
    continue-on-error: true    # remova quando o backlog de achados estiver limpo
    steps:
      - uses: actions/checkout@v4
      - uses: terraform-linters/setup-tflint@v4
      - run: tflint --init && tflint --recursive
```

Vale avaliar também `tfsec`/`trivy config` (varredura de segurança),
`checkov` (compliance) e `infracost` (estimativa de custo no PR, que torna a
conta visível antes do merge).

---

## Melhorias implementadas

Tudo abaixo partiu do estado inicial do repositório.

### Correções

| O que estava | O que foi feito |
|---|---|
| `main.tf` e `provider.tf` declaravam `required_providers` e `provider "aws"` duas vezes — o Terraform abortava antes de qualquer plan | Declaração única, na raiz |
| Bump do módulo EKS para `~> 21.0` sem ajustar os argumentos renomeados na v21 | `cluster_name` → `name`, `cluster_version` → `kubernetes_version`, `cluster_endpoint_public_access` → `endpoint_public_access` |
| Sem `.gitignore`: um `git add src/` levaria **743 MB** de `.terraform/` para o repositório | `.gitignore` completo. O commit passou a ser de ~200 KB |
| `terraform.tfvars` desformatado | `terraform fmt` aplicado; `fmt -check` agora é gate da pipeline |
| Tag residual `Teste = "ok"` | Removida; tags padronizadas em `Project`, `Environment`, `ManagedBy`, `Repository` |
| `azs` e as subnets eram `set(string)`, tipo que o Terraform reordena — a associação subnet↔AZ ficava imprevisível | `list(string)`, onde a posição é preservada |
| Todas as variáveis com a descrição `"Colocar sempre a descrição"` | Descrição real em cada uma, com o porquê do padrão escolhido |

### Segurança

- **Secret nunca mais vai para branch não revisada**: a validação de sintaxe
  roda com `-backend=false` e sem credencial.
- **Gate de aprovação humana** entre o plan e o apply, via GitHub Environment.
- **Destroy com três barreiras**: só manual, exige digitar o nome do cluster,
  e exige aprovação.
- **Zero interpolação de dado de evento em shell** — o `inputs.confirm` do
  destroy era exatamente o vetor clássico de injeção de comando.
- **Lock de state nativo do S3** (`use_lockfile = true`): impede dois applies
  simultâneos corrompendo o state. Resolve o item "usar DynamoDB" das
  evoluções sugeridas originalmente, com a solução atual, que dispensa a
  tabela.
- **`encrypt = true`** no backend.
- **VPC Flow Logs** e **logs de auditoria do plano de controle** habilitados.
- **Saída sensível marcada** (`cluster_certificate_authority_data`, senha do
  Grafana).
- **Credencial de banco só por referência a Secret**, nunca em `.tfvars`.
- **VPN Gateway desligado**: estava `true` sem nenhum túnel conectado —
  recurso cobrado sem função.

### Escalabilidade

- **Node group com `max_size` 4 contra `min_size` 2.** Estava `min = max = 2`:
  o cluster não escalava, apenas repunha nó morto.
- **Interface de `node_groups` tipada**, com suporte a vários grupos, SPOT,
  labels e taints — base para separar carga de sistema de carga de lote.
- **NAT Gateway por AZ** em produção, com `single_nat_gateway` disponível
  como alavanca de custo para os demais ambientes.

### Observabilidade

- **Módulo `observability`** com Prometheus, Grafana, Alertmanager,
  node-exporter e kube-state-metrics.
- **Três formas de conectar alvo**: ServiceMonitor para API instrumentada,
  blackbox para qualquer URL HTTP, exporter para banco de dados.
- **Quatro engines de banco** suportadas: PostgreSQL, MySQL, Redis, MongoDB —
  funcionando com banco gerenciado (RDS, ElastiCache) ou no cluster.
- **Camada com state próprio**, para que o monitoramento não compartilhe raio
  de dano nem ciclo de vida com a infraestrutura base.
- **Autenticação por `exec`** no provider Helm: o token do EKS expira em ~15
  minutos e a instalação da stack passa disso.
- **Escape hatch (`extra_values`)** em todos os níveis, mesclado pelo próprio
  Helm — nenhuma necessidade específica obriga a alterar o módulo.

### Velocidade

- **Validação sem credencial em segundos**, antes de qualquer PR.
- **Versão do Terraform fixada**: o runner não baixa versão diferente a cada
  atualização de imagem.
- **Lock multiplataforma**: sem renegociação de provider no `init` do CI.
- **Matriz de validação**: os três módulos e os dois ambientes validam em
  paralelo.
- **Gate não abre sem mudança**: merge que não altera infraestrutura não
  gasta tempo de ninguém.

### Estrutura e documentação

- Separação em `modules/` e `environments/`, com as regras de versionamento
  opostas em cada camada.
- `moved.tf` para a refatoração não destruir o que já existe.
- README por módulo, com cenários de uso e critérios de adaptação.
- Comentários por etapa em todos os `.tf` e `.yml`.
- Pipeline dividida em motor reutilizável + workflows finos de gitflow.

---

## Pendências conhecidas

Itens reais, em ordem de prioridade. Nenhum foi resolvido silenciosamente.

1. **Chave estática da AWS nos secrets.** Trocar por OIDC é a melhoria de
   segurança de maior impacto pendente. Exige criar o provedor OIDC e a role
   na AWS — por isso não foi feito aqui sem a sua decisão.
2. **`kubernetes_version = "1.29"`.** Confirme se ainda está no suporte padrão
   da AWS antes do próximo apply; versão fora de suporte entra em *extended
   support*, cobrado à parte. Subir a versão é upgrade de plano de controle,
   com janela e plano próprios.
3. **Endpoint público do cluster aberto para `0.0.0.0/0`.** Restrinja os
   CIDRs se houver faixa fixa. Fechar por completo exige runner self-hosted
   dentro da VPC.
4. **Addons gerenciados vazios.** Sem `aws-ebs-csi-driver`, nenhum PVC
   funciona — e a stack de monitoramento não sobe. Adicionar cria recursos:
   faça num apply próprio, com plan revisado.
5. **Nós `t3.small` não comportam a stack de monitoramento.** 2 GB por nó
   contra ~4 GB pedidos. Suba o tipo de instância antes de aplicar a camada
   de observabilidade.
6. **Versões dos charts Helm em `null`** (última publicada). Fixe antes de
   produção; o comando para descobrir as disponíveis está no
   `terraform.tfvars` da camada.
7. **Esquema de valores dos exporters de banco.** Cada chart tem o seu e ele
   muda entre versões. O módulo gera os caminhos usuais; confirme com
   `helm show values <chart> --version <v>` e ajuste pelo `extra_values`.
8. **A camada de observabilidade não está na pipeline.** Hoje roda por
   `terraform apply` local. Ligá-la ao `gitflow.yml` é acrescentar um job
   apontando `working-directory` para ela.
9. **Módulo VPC em `~> 5.8` enquanto o EKS está em `~> 21.0`.** Subir a VPC
   para a v6 é major upgrade com mudanças de interface — merece commit
   próprio, não misturado a uma refatoração.
10. **Sem análise estática na pipeline.** Ver o snippet na seção de boas
    práticas.
11. **O artefato do plano** fica disponível a quem tem leitura no repositório
    durante 1 dia. Planos contêm valores resolvidos. Retenção já é a mínima;
    avalie se o repositório deve ser privado.

---

## Licença

Ver [LICENSE](LICENSE).
