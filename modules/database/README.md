# Módulo `database`

Bancos de dados gerenciados na AWS, declarados num único mapa, com
monitoramento integrado automaticamente.

| `engine` | Serviço AWS | Porta padrão | Classe padrão |
|---|---|---|---|
| `mysql` | RDS MySQL | 3306 | `db.t3.micro` |
| `postgres` | RDS PostgreSQL | 5432 | `db.t3.micro` |
| `mariadb` | RDS MariaDB | 3306 | `db.t3.micro` |
| `oracle` | RDS Oracle SE2 | 1521 | `db.t3.small` |
| `mongodb` | Amazon DocumentDB | 27017 | `db.t3.medium` |
| `elasticsearch` / `opensearch` | Amazon OpenSearch | 443 | `t3.small.search` |

## Como usar

```hcl
module "databases" {
  source = "../../modules/database"

  name_prefix = "live"
  vpc_id      = module.network.vpc_id
  subnet_ids  = module.network.private_subnet_ids

  databases = {
    pedidos = {
      engine     = "mysql"
      storage_gb = 20
    }
    busca = {
      engine     = "elasticsearch"
      storage_gb = 10
    }
    catalogo = {
      engine = "mongodb"
    }
  }

  tags = { Project = "live" }
}
```

Acrescentar um banco é acrescentar uma entrada no mapa. Nada mais muda.

## A integração automática com o monitoramento

É o ponto central do módulo. A saída `monitoring_targets` sai **no formato
exato** que `modules/observability` consome em `database_targets`:

```
environments/production-data              environments/production-observability
──────────────────────────────            ────────────────────────────────────
databases = { pedidos = {...} }
          ↓
cria RDS + senha no Secrets Manager
          ↓
output monitoring_targets        ──────►  terraform_remote_state lê a saída
                                                   ↓
                                          lê a senha no Secrets Manager
                                                   ↓
                                          cria o Secret do Kubernetes
                                                   ↓
                                          sobe o exporter e registra no Prometheus
                                                   ↓
                                          dashboard no Grafana
```

Na prática: declare o banco no `terraform.tfvars` da camada de dados, aplique
as duas camadas, e o banco aparece monitorado. Sem copiar endpoint, sem criar
Secret à mão, sem editar módulo.

### Oracle é a exceção

Não existe exporter Prometheus mantido pela comunidade `prometheus-community`
para Oracle. Bancos Oracle aparecem na saída `monitoring_unsupported` — de
forma visível, não descartados em silêncio.

O caminho para Oracle é o CloudWatch: o RDS já publica CPU, conexões, IOPS e
latência sem exporter nem credencial de banco. Para trazer isso ao Prometheus,
use o `yet-another-cloudwatch-exporter`.

## Segurança

**A senha nunca passa por variável.** O módulo gera com `random_password` e
guarda no AWS Secrets Manager, como JSON:

```json
{
  "engine": "mysql", "host": "...", "port": 3306,
  "username": "admin", "password": "...", "dbname": "pedidos"
}
```

Para ler:

```bash
aws secretsmanager get-secret-value --secret-id live/database/pedidos \
  --query SecretString --output text | jq
```

Outros padrões embutidos:

- **`publicly_accessible = false`**, sem exceção. Banco acessível da internet
  é a causa mais comum de vazamento de dados em nuvem.
- **Criptografia em repouso** ligada em RDS, DocumentDB e OpenSearch.
- **Um security group por banco**, que começa sem permitir nada. O acesso é
  concedido explicitamente, de preferência referenciando outro security group
  em vez de faixa de IP — assim acompanha a troca de nós do cluster sozinho.
- **OpenSearch** com HTTPS obrigatório, criptografia entre nós e
  *fine-grained access control* com usuário mestre.

```hcl
pedidos = {
  engine = "mysql"
  # Regra por security group: um nó novo já nasce autorizado.
  allowed_security_group_ids = [module.kubernetes.node_security_group_id]
  # Faixa de IP só quando não há SG de origem (VPN, peering).
  allowed_cidr_blocks = ["10.50.0.0/16"]
}
```

## Variáveis por banco

| Atributo | Padrão | Observação |
|---|---|---|
| `engine` | — | obrigatório |
| `engine_version` | — | vazio = padrão da AWS |
| `instance_class` | por engine | ver tabela no topo |
| `instance_count` | `1` | DocumentDB e OpenSearch; RDS ignora |
| `storage_gb` | `20` | mínimo 10 |
| `username` | `"admin"` | |
| `database_name` | nome da chave | |
| `port` | por engine | |
| `allowed_security_group_ids` | `[]` | origem recomendada |
| `allowed_cidr_blocks` | `[]` | |
| `multi_az` | `false` | dobra o custo; produção de verdade usa `true` |
| `backup_retention_days` | `7` | |
| `deletion_protection` | `false` | `true` em produção |
| `skip_final_snapshot` | `true` | `false` em produção |
| `performance_insights` | `false` | |
| `cloudwatch_logs_exports` | por engine | |
| `monitoring_enabled` | `true` | |

## Saídas

| Saída | Para quê |
|---|---|
| `monitoring_targets` | consumida pela camada de observabilidade |
| `monitoring_unsupported` | bancos sem exporter (Oracle) |
| `endpoints`, `ports` | endereço e porta de cada banco |
| `security_group_ids` | liberar acesso depois, sem recriar |
| `secret_arns`, `secret_names` | credenciais no Secrets Manager |
| `connection_commands` | comando pronto de conexão, para conferência |

## Custo

us-east-1, on-demand, estimativa:

| Banco | Classe | US$/hora | US$/mês |
|---|---|---|---|
| MySQL / PostgreSQL | `db.t3.micro` | ~0,017 | ~12 |
| Oracle SE2 | `db.t3.small` | ~0,047 | ~34 |
| DocumentDB | `db.t3.medium` | ~0,078 | ~57 |
| OpenSearch | `t3.small.search` | ~0,036 | ~26 |

Mais armazenamento gp3 a ~US$ 0,08/GB-mês. `multi_az = true` dobra o valor da
instância.

Cada banco soma ao custo do EKS. Com crédito limitado, suba um por vez.

## Pegadinhas

1. **DocumentDB não é MongoDB.** Fala o mesmo protocolo, mas é motor próprio
   da AWS com compatibilidade parcial: agregações recentes, transações entre
   coleções e alguns operadores podem faltar. Se a aplicação depende disso, o
   caminho é MongoDB Atlas ou MongoDB no próprio cluster.
2. **Oracle não roda em `db.t3.micro`.** O mínimo é `db.t3.small`, e a licença
   entra no preço da instância (`license-included`).
3. **OpenSearch com mais de um nó** liga *zone awareness*, que exige número
   par de nós. O módulo arredonda para cima automaticamente.
4. **`skip_final_snapshot = false` exige nome de snapshot.** O módulo gera.
   Mas atenção: o nome não pode repetir, então destruir e recriar com o mesmo
   nome falha até o snapshot antigo ser removido.
5. **`secret_recovery_days = 0`** é o padrão aqui por causa do ambiente de
   estudo: com janela de recuperação, recriar um banco com o mesmo nome
   esbarra em "segredo agendado para exclusão". Em produção, use 7 ou mais.
6. **Trocar `engine_version` em major version** recria ou atualiza o banco.
   Leia o plan com atenção.
