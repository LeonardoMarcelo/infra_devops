# Módulo `observability`

Prometheus, Grafana e Alertmanager num cluster Kubernetes, com três formas
de conectar alvos: **API instrumentada**, **qualquer URL HTTP** e
**banco de dados**.

Envelopa o chart [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
e os exporters da comunidade.

## O que sobe

| Componente | Função |
|---|---|
| Prometheus | Coleta e armazena as séries temporais |
| Grafana | Visualização, já com datasource configurado |
| Alertmanager | Roteia alertas para Slack, e-mail, PagerDuty |
| node-exporter | Métricas de CPU, memória e disco de cada nó |
| kube-state-metrics | Estado dos objetos do Kubernetes (deployment, pod, PVC) |
| blackbox-exporter | Só quando há `http_probes` |
| exporters de banco | Um por entrada em `database_targets` |

Sem nenhum alvo configurado, a stack já monitora o cluster inteiro: nós,
pods, plano de controle, kubelet.

---

## Escolhendo o tipo de alvo

Esta é a decisão central do módulo:

| Você tem | Use | O que mede | O que não mede |
|---|---|---|---|
| API sua, com `/metrics` | `api_targets` | Tudo de dentro: erro por rota, latência por percentil, fila, pool de conexão | — |
| API sua, sem `/metrics` | `http_probes` | Está no ar? Em quanto tempo responde? Certificado vence quando? | Qualquer coisa interna |
| API de terceiro | `http_probes` | O mesmo acima | Idem (você não controla o código) |
| Banco de dados | `database_targets` | Conexões, locks, replicação, cache hit, tamanho | — |

**É o `http_probes` que faz este módulo "encaixar em qualquer API REST"**: ele
não exige uma linha de código na aplicação. Mas a troca é real — sonda de
fora enxerga disponibilidade, não enxerga comportamento. Quando a API for
sua, instrumentar e usar `api_targets` vale muito mais.

O caminho usual é usar os dois: `http_probes` desde o primeiro dia, para ter
alarme de queda; `api_targets` conforme cada serviço for instrumentado.

---

## Uso mínimo

```hcl
module "observability" {
  source = "../../modules/observability"

  namespace     = "monitoring"
  storage_class = "gp3"
}
```

Abra o Grafana sem expor nada na internet:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# usuário: admin
terraform output -raw grafana_admin_password
```

---

## Cenário 1 — API instrumentada

A aplicação expõe `/metrics` no formato Prometheus (`prom-client` no Node,
Micrometer no Spring, `prometheus_client` no Python, `promhttp` no Go).

```hcl
api_targets = {
  pedidos = {
    namespace      = "producao"
    service_labels = { "app.kubernetes.io/name" = "pedidos-api" }
    port           = "http"        # NOME da porta no Service, não o número
    path           = "/metrics"
    interval       = "30s"
  }

  faturamento = {
    namespace      = "producao"
    service_labels = { app = "faturamento" }
    port           = "metrics"
    interval       = "15s"         # endpoint crítico, coleta mais frequente
  }
}
```

Gera um `ServiceMonitor` por entrada. O Prometheus descobre os pods pelo
Service e passa a coletar.

**Pegadinha mais comum:** `port` é o **nome** da porta declarada no Service,
não o número. Se o Service declara `- name: http, port: 8080`, aqui vai
`"http"`. Com o número, o ServiceMonitor não casa e o alvo nunca aparece —
sem erro nenhum, só silêncio.

Para conferir se o alvo foi descoberto:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# abra http://localhost:9090/targets
```

---

## Cenário 2 — Qualquer API REST, sem instrumentação

Sobe o blackbox exporter e sonda a URL de fora.

```hcl
http_probes = {
  # API interna sem instrumentação
  pedidos-health = {
    targets = ["https://api.exemplo.com/health"]
    module  = "http_2xx"
  }

  # Vários endpoints de uma vez
  rotas-criticas = {
    targets = [
      "https://api.exemplo.com/v1/pedidos",
      "https://api.exemplo.com/v1/clientes",
      "https://api.exemplo.com/v1/pagamentos",
    ]
    interval = "30s"
    labels   = { criticidade = "alta" }
  }

  # API de terceiro: dependência externa que derruba você quando cai
  gateway-pagamento = {
    targets  = ["https://api.parceiro.com/status"]
    interval = "60s"
    timeout  = "15s"
  }
}
```

Métricas que passam a existir:

| Métrica | Para quê |
|---|---|
| `probe_success` | 1 ou 0. É a base do alerta de indisponibilidade |
| `probe_duration_seconds` | Latência ponta a ponta |
| `probe_http_status_code` | Diferencia 500 de 404 de 200 |
| `probe_ssl_earliest_cert_expiry` | Alerta de certificado vencendo — evita a queda por TLS expirado |

Módulos do blackbox disponíveis por padrão: `http_2xx`, `http_post_2xx`,
`tcp_connect`, `icmp`, `dns`. Para autenticação, header customizado ou
verificação de corpo da resposta, é preciso configurar um módulo próprio no
blackbox — via `extra_values`.

**Onde a sonda roda importa.** O blackbox está dentro do cluster: ele mede o
caminho cluster → API. Não mede o que o usuário na internet sente. Para isso,
monitoramento sintético externo (CloudWatch Synthetics, Pingdom) é
complementar, não substituto.

---

## Cenário 3 — Banco de dados

Um exporter por banco, rodando no cluster e conectando no `host` informado.
Funciona igual para banco gerenciado (RDS, ElastiCache, DocumentDB) e para
banco no próprio cluster.

### Passo 1: crie o Secret com a credencial

A credencial **nunca** entra no `.tfvars`. Crie o Secret antes:

```bash
# PostgreSQL — o Secret guarda a DSN completa
kubectl -n monitoring create secret generic pg-pedidos \
  --from-literal=datasource='postgresql://monitor:SENHA@pedidos.abc.us-east-1.rds.amazonaws.com:5432/postgres?sslmode=require'

# MySQL — só a senha
kubectl -n monitoring create secret generic mysql-faturamento \
  --from-literal=password='SENHA'

# Redis
kubectl -n monitoring create secret generic redis-cache \
  --from-literal=password='SENHA'
```

Em produção, o caminho melhor é guardar no AWS Secrets Manager e sincronizar
com o [External Secrets Operator](https://external-secrets.io/), para que a
rotação não exija intervenção manual.

### Passo 2: declare o alvo

```hcl
database_targets = {
  pedidos-pg = {
    engine             = "postgres"
    host               = "pedidos.abc.us-east-1.rds.amazonaws.com"
    port               = 5432
    credentials_secret = { name = "pg-pedidos", key = "datasource" }
  }

  faturamento-mysql = {
    engine             = "mysql"
    host               = "faturamento.abc.us-east-1.rds.amazonaws.com"
    port               = 3306
    username           = "monitor"
    credentials_secret = { name = "mysql-faturamento", key = "password" }
  }

  cache = {
    engine             = "redis"
    host               = "cache.abc.use1.cache.amazonaws.com"
    port               = 6379
    credentials_secret = { name = "redis-cache", key = "password" }
  }
}
```

### Passo 3: dê ao usuário do monitoramento o mínimo necessário

Crie um usuário só de leitura de estatísticas — nunca aponte o exporter para
o usuário da aplicação:

```sql
-- PostgreSQL
CREATE USER monitor WITH PASSWORD 'senha';
GRANT pg_monitor TO monitor;

-- MySQL
CREATE USER 'monitor'@'%' IDENTIFIED BY 'senha';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'monitor'@'%';
```

### Engines suportadas

| `engine` | Chart |
|---|---|
| `postgres` | `prometheus-postgres-exporter` |
| `mysql` | `prometheus-mysql-exporter` |
| `redis` | `prometheus-redis-exporter` |
| `mongodb` | `prometheus-mongodb-exporter` |

> **Confira o esquema de valores do chart.** Cada exporter tem o próprio
> esquema e ele muda entre versões. O módulo gera os caminhos usuais, mas a
> fonte da verdade é `helm show values <chart> --version <v>`. Ajuste pelo
> `extra_values` do alvo, que é mesclado por cima do que o módulo gerou:
>
> ```hcl
> pedidos-pg = {
>   engine = "postgres"
>   host   = "..."
>   extra_values = {
>     config = { datasource = { sslmode = "require" } }
>   }
> }
> ```
>
> Essa mescla é feita pelo próprio Helm (dois arquivos de values, o último
> vence), então funciona em qualquer profundidade do objeto.

### Grupo de segurança

O exporter roda nos nós do cluster. O security group do banco precisa aceitar
conexão vindo do security group dos nós — `module.kubernetes.node_security_group_id`
no ambiente base. Sem essa regra, o exporter sobe e falha ao conectar.

---

## Alertas

O padrão do chart **não notifica ninguém**. Alerta que não chega a uma pessoa
não é monitoramento.

```hcl
alertmanager_config = {
  route = {
    group_by        = ["alertname", "namespace"]
    group_wait      = "30s"
    group_interval  = "5m"
    repeat_interval = "4h"
    receiver        = "slack"
    routes = [
      {
        matchers = ["severity = critical"]
        receiver = "pagerduty"
      }
    ]
  }
  receivers = [
    { name = "slack", slack_configs = [{ channel = "#alertas" }] },
    { name = "pagerduty" },
  ]
}
```

A URL do webhook do Slack e a chave do PagerDuty **não vão aqui**: use
`extra_values` para montar o Alertmanager a partir de um Secret
(`alertmanager.alertmanagerSpec.secrets`), ou um `alertmanagerConfig` próprio.

Alertas que valem a pena desde o primeiro dia:

| Alerta | Expressão |
|---|---|
| API fora do ar | `probe_success == 0` por 2 min |
| Certificado vencendo | `probe_ssl_earliest_cert_expiry - time() < 14*24*3600` |
| Latência alta | `probe_duration_seconds > 2` por 5 min |
| Banco sem conexão | `pg_up == 0` / `mysql_up == 0` |
| Disco do nó acabando | `node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.1` |

---

## Variáveis principais

| Nome | Tipo | Padrão | Descrição |
|---|---|---|---|
| `namespace` | `string` | `"monitoring"` | Onde instalar |
| `kube_prometheus_stack_version` | `string` | `null` | Versão do chart; **fixe em produção** |
| `prometheus_retention` | `string` | `"15d"` | Janela de retenção |
| `prometheus_storage_size` | `string` | `"50Gi"` | Volume do Prometheus |
| `storage_class` | `string` | `"gp3"` | Exige `aws-ebs-csi-driver` |
| `grafana_enabled` | `bool` | `true` | Instala o Grafana |
| `grafana_admin_password` | `string` | `null` | `null` gera aleatória |
| `grafana_ingress` | `object` | `{enabled=false}` | Exposição por Ingress |
| `alertmanager_config` | `any` | `null` | Rotas e receivers |
| `api_targets` | `map(object)` | `{}` | APIs com `/metrics` |
| `http_probes` | `map(object)` | `{}` | URLs sondadas de fora |
| `database_targets` | `map(object)` | `{}` | Bancos |
| `extra_values` | `any` | `{}` | Values crus, mesclados por cima |

---

## Em quais casos adaptaria

Esta é a parte que decide se o módulo serve ao seu caso ou se o certo é
outra coisa.

### Trocar a retenção por armazenamento remoto

**Quando:** você precisa de mais de 30 dias de histórico, ou de visão
unificada de vários clusters.

**Por quê:** o Prometheus guarda série temporal em disco local do pod.
Aumentar `prometheus_retention` aumenta disco *e* memória, e um Prometheus
de 200 GB fica lento e frágil.

**O que fazer:** manter a retenção local curta (15 dias) e habilitar remote
write para Thanos, Mimir ou Amazon Managed Prometheus:

```hcl
extra_values = {
  prometheus = {
    prometheusSpec = {
      remoteWrite = [{
        url = "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-xxx/api/v1/remote_write"
        sigv4 = { region = "us-east-1" }
      }]
    }
  }
}
```

### Trocar a stack inteira por serviço gerenciado

**Quando:** não há quem opere Prometheus, ou a conta de EBS e de nó dedicado
ao monitoramento passa a doer.

**Alternativas:** Amazon Managed Prometheus + Amazon Managed Grafana,
Datadog, New Relic, Grafana Cloud.

**A troca:** paga-se por ingestão de métrica em vez de por disco, e some a
operação. Com cardinalidade alta, o gerenciado costuma sair mais caro —
convém estimar antes.

**O que muda no código:** só este módulo. `api_targets`, `http_probes` e
`database_targets` descrevem *o que* monitorar, não *com o quê* — a mesma
interface pode ser implementada por cima de outro backend.

### Rodar fora do Kubernetes

**Quando:** a carga está em EC2, ECS ou Lambda, e não há cluster.

**O que fazer:** este módulo não serve — ele instala charts Helm. Os
substitutos:

| Carga | Caminho |
|---|---|
| EC2 | node_exporter na instância + Prometheus com service discovery de EC2 |
| ECS Fargate | CloudWatch Container Insights, ou ADOT sidecar |
| Lambda | CloudWatch Metrics (já vem) + Lambda Powertools |
| Qualquer URL | Blackbox exporter continua valendo, de qualquer lugar |

O conceito de `http_probes` sobrevive a todos esses casos — sonda HTTP não
depende de onde a aplicação roda.

### Separar o monitoramento em outro cluster

**Quando:** a exigência é que o monitoramento continue de pé quando o cluster
monitorado cair.

**Por quê:** Prometheus rodando dentro do cluster que ele monitora cai junto
com ele — e é exatamente nesse momento que você precisa dos gráficos.

**O que fazer:** um cluster (ou conta) de observabilidade, com Prometheus
coletando os demais por federação ou remote write. Custa mais e vale a pena
a partir do momento em que há SLA externo.

### Substituir os exporters de banco por métricas do provedor

**Quando:** o banco é gerenciado e você quer o mínimo de peça móvel.

**A troca:** o CloudWatch do RDS já traz CPU, conexões, IOPS e latência, sem
exporter nenhum e sem credencial de banco. O que ele **não** traz é o de
dentro do banco: query lenta, lock, bloat de tabela, lag de replicação
lógica. Se a dor é essa, o exporter é necessário.

**Meio-termo:** CloudWatch via `yet-another-cloudwatch-exporter` para o que a
AWS já expõe, e exporter nativo só nos bancos onde o detalhe importa.

### Monitorar API de terceiro de fora da AWS

**Quando:** você precisa saber o que o usuário final sente, não o que o
cluster sente.

**O que fazer:** o blackbox daqui mede o caminho cluster → API. Para o
caminho usuário → API, use monitoramento sintético de múltiplas regiões
(CloudWatch Synthetics, Grafana Synthetic Monitoring). Os dois juntos
diferenciam "a API caiu" de "a nossa rede até ela caiu".

---

## Pré-requisitos e pegadinhas

1. **`aws-ebs-csi-driver` instalado no cluster.** Prometheus, Grafana e
   Alertmanager usam PVC. Sem o driver, todos ficam em `Pending` e a
   instalação estoura no timeout, sem erro óbvio.
2. **Recursos no cluster.** A stack pede na ordem de 1 vCPU e 4 GB. Em nós
   `t3.small` (2 GB cada), não cabe: suba o tipo de instância ou o número de
   nós antes.
3. **Saída para a internet** nos nós, para baixar os charts e as imagens. O
   NAT Gateway do módulo `network` já garante isso.
4. **State próprio.** Esta camada precisa de um cluster que já existe.
   Misturá-la ao state da infraestrutura base cria dependência de provider
   em valor desconhecido no plan — o que quebra o primeiro apply e o destroy.
5. **`port` é nome, não número**, em `api_targets`.
6. **Fixe as versões dos charts** antes de produção. Com `null`, dois applies
   em dias diferentes instalam versões diferentes.

## Custo

| Item | Ordem de grandeza |
|---|---|
| Volumes EBS (50 Gi + 10 Gi, gp3) | ~US$ 5/mês |
| CPU e memória dos pods | Equivale a cerca de um nó pequeno |
| Exporters de banco | Desprezível (~64 Mi cada) |

O que escala o custo não é o número de alvos, é a **cardinalidade**: uma
métrica com label de alta variação (ID de usuário, ID de pedido) multiplica
as séries e estoura memória. Essa é a causa número um de Prometheus caindo
em produção.
