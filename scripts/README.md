# Scripts operacionais

Quatro scripts, uma biblioteca compartilhada. Todos funcionam de qualquer
diretório e todos respondem a `--help`.

```
scripts/
├── lib/comum.sh            biblioteca: cores, confirmação, camadas, terraform
├── preflight.sh            [leitura]  confere tudo ANTES do apply
├── custo.sh                [leitura]  quanto está custando AGORA
├── destroy.sh              [ESCRITA]  desliga na ordem correta
└── verificar-limpeza.sh    [leitura]  sobrou algo cobrando?
```

Só `destroy.sh` altera alguma coisa. Os outros três são somente leitura e
podem ser rodados à vontade.

## Fluxo de uso

```
 antes do apply          durante                depois
 ─────────────────       ─────────────          ──────────────────────
 ./preflight.sh    ──►   ./custo.sh       ──►   ./destroy.sh
                         (acompanhar)           └─► chama verificar-limpeza
```

---

## `preflight.sh` — antes do apply

```bash
./scripts/preflight.sh [--regiao us-east-1]
```

Confere em segundos o que costuma fazer o apply falhar no meio ou gastar
mais do que você esperava:

| Verifica | Por quê |
|---|---|
| terraform, aws, kubectl, helm | falta de ferramenta quebra no meio |
| Versão do Terraform | a raiz exige `~> 1.17`; versão diferente gera outro plano |
| Credenciais da AWS | erro aqui só aparece depois de 10 minutos de init |
| Bucket do state: existe, versionado, não público | sem versionamento, state corrompido é perda total |
| **Existe budget configurado** | proteção financeira é proteção |
| `single_nat_gateway` e número de AZ | é a maior alavanca de custo do projeto |
| Tipo de nó × stack de monitoramento | `t3.small` não comporta a stack |
| `cluster_addons` vazio | sem `aws-ebs-csi-driver`, todo PVC fica em `Pending` |
| Endpoint aberto para `0.0.0.0/0` | exposição desnecessária |
| Formatação do Terraform | é gate da pipeline |

Ao final, imprime o **custo previsto por hora, por dia e por mês**, e quantos
dias os US$ 100 duram nessa configuração.

Sai com `1` se houver impedimento, `0` se só houver alertas.

---

## `custo.sh` — taxa de consumo atual

```bash
./scripts/custo.sh [--regiao us-east-1] [--credito 100]
```

Consulta os recursos **realmente existentes** na conta e calcula a taxa por
hora. Não é o seu faturamento: o Cost Explorer mostra o passado com até 24 h
de atraso; isto mostra o presente.

```
Recursos ativos
  Cluster EKS                1 x  US$ 0.100/h   = US$ 0.100/h
  NAT Gateway                3 x  US$ 0.045/h   = US$ 0.135/h
  IPv4 público               3 x  US$ 0.005/h   = US$ 0.015/h
  EC2 t3.small               2 x  US$ 0.021/h   = US$ 0.042/h
  Volumes EBS                 40 GB             = US$ 0.004/h
──────────────────────────────────────────────────────────
  Por hora                  US$ 0.296
  Por dia (24h)             US$ 7.10
  US$ 100 duram             338 horas  (14.1 dias)
```

Avisa em amarelo abaixo de 10 dias de crédito e em vermelho abaixo de 3.

Preços on-demand de `us-east-1`, embutidos no script. Não inclui
transferência de dados, processamento do NAT nem CloudWatch — por isso é
estimativa, e sempre **por baixo**.

---

## `destroy.sh` — desligar na ordem correta

```bash
./scripts/destroy.sh [--camada tudo|producao|observability]
                     [--regiao us-east-1] [--dry-run] [--sim] [--pular-k8s]
```

### Por que não basta `terraform destroy`

O Terraform remove o que o Terraform criou. O que o **Kubernetes** criou na
AWS não está no state:

| Você criou no cluster | A AWS criou | Sobrevive ao destroy |
|---|---|---|
| `Service type: LoadBalancer` | ELB/NLB | **sim** |
| `Ingress` | ALB | **sim** |
| `PersistentVolumeClaim` | volume EBS | às vezes |

E é pior do que o custo residual: as interfaces de rede do Load Balancer
ficam presas nas subnets, o `destroy` tenta apagar a subnet por ~20 minutos
e **falha** — deixando cluster, NAT e nós de pé, cobrando.

### O que o script faz

```
Etapa 1  remove Services type=LoadBalancer e Ingresses
         e ESPERA os Load Balancers sumirem da AWS (até 5 min)
Etapa 2  destrói a camada de observabilidade   (state próprio)
Etapa 3  destrói a infraestrutura base
Etapa 4  roda verificar-limpeza.sh
```

A observabilidade sempre vem antes da base: ela depende do cluster existir.

### Segurança

- Exige **digitar o nome do cluster** para confirmar. `s/n` é fácil demais
  de responder no automático.
- `--dry-run` mostra o plano de destruição sem executar nada.
- Para na primeira falha em vez de seguir destruindo às cegas.

### Exemplos

```bash
# Ver o que seria destruído, sem destruir
./scripts/destroy.sh --dry-run

# Desligar tudo (pede confirmação)
TF_BACKEND_BUCKET=meu-bucket ./scripts/destroy.sh

# Só a camada de monitoramento, mantendo o cluster
./scripts/destroy.sh --camada observability

# Sem confirmação, para automação
./scripts/destroy.sh --sim
```

### Variáveis de ambiente

| Variável | Padrão | Para quê |
|---|---|---|
| `TF_BACKEND_BUCKET` | — | bucket do state; obrigatória se o diretório não estiver inicializado |
| `TF_BACKEND_KEY` | `producao/infra.tfstate` | key da camada base |
| `TF_BACKEND_KEY_OBS` | `producao/observability.tfstate` | key da observabilidade |

---

## `verificar-limpeza.sh` — sobrou algo?

```bash
./scripts/verificar-limpeza.sh [regiao]
```

Lista cluster, NAT, instâncias, Load Balancers, volumes EBS órfãos, IPs
elásticos soltos, VPC e grupos de log — com o custo de cada um ao lado. Sai
com `1` se achar qualquer coisa ativa.

Chamado automaticamente no fim do `destroy.sh`, mas vale rodar sozinho
**no dia seguinte**: alguns custos levam até 24 h para aparecer no Cost
Explorer.

---

## `lib/comum.sh`

Carregada com `source` pelos quatro scripts. Nada executa sozinha.

| Função | Faz |
|---|---|
| `info` `ok` `aviso` `erro` `passo` `titulo` | saída padronizada, cor desligada fora de terminal |
| `morrer` | mensagem e `exit 1` |
| `coluna` | alinhamento que conta caracteres, não bytes (acento quebra `%-Ns`) |
| `exigir` | aborta se faltar um comando |
| `aws_autenticado` `conta_aws` `identidade_aws` | contexto da AWS |
| `confirmar_digitando` `confirmar_sn` | confirmação |
| `camada_dir` `camada_key_padrao` | nome amigável → diretório e key do state |
| `tf_inicializado` `tf_init` `tf_tem_recursos` | Terraform |
| `ler_tfvar` | lê um valor do `terraform.tfvars` sem precisar de state |
| `cluster_existe` `kubectl_conectado` | Kubernetes |

Para acrescentar um script, comece por:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"
```

`RAIZ`, `SCRIPTS_DIR` e `LIB_DIR` já vêm resolvidos, então o script funciona
chamado de qualquer diretório.

## Compatibilidade

Escritos para **bash 3.2**, o padrão do macOS. Sem array associativo, sem
`${var,,}`, sem `mapfile`. Aritmética de ponto flutuante via `awk`, que
existe em qualquer Unix.
