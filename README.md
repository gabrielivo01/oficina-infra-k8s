# oficina-infra-k8s

Infraestrutura compartilhada do projeto Oficina. Um dos repositórios do projeto
(irmão de `oficina`, `oficina-auth-lambda` e `oficina-infra-db`; na Fase 4 também
`oficina-execution-service` e `oficina-billing-service`).

Contém duas coisas:

1. **Plataforma local (Fase 4, custo zero)** — tudo o que os microsserviços precisam
   para rodar e ser observados, em dois sabores:
   - `local/`: **Docker Compose** para desenvolvimento (RabbitMQ, 2× PostgreSQL,
     MongoDB, Jaeger, OTel Collector, MailHog).
   - `kind/` + `k8s/plataforma/` + `scripts/plataforma_*.sh`: **cluster kind**
     (Kubernetes local e no CI) com ingress-nginx, RabbitMQ, Jaeger, OTel Collector
     e Prometheus/Grafana.
2. **Infra AWS da Fase 3** (EKS, API Gateway, observabilidade via Terraform/Helm) —
   mantida como está; ver [Infra AWS (Fase 3)](#infra-aws-fase-3).

Decisão: ADR `0008-ambiente-local-kind.md` no repo `oficina`
(`documentacao/adrs/`). Topologia de mensagens: seção 3.3 de
`oficina/documentacao/plano_fase4.md`.

## Pré-requisitos

| Ferramenta | Para quê | Versão validada |
|---|---|---|
| Docker (Engine 28+ com Compose v2) | Compose e nós do kind | Engine 29.8, Compose 5.5 |
| kind | cluster local | 0.33 (nó `kindest/node:v1.37.0`) |
| kubectl | aplicar manifests / Kustomize | 1.37 |
| helm | kube-prometheus-stack | 4.3 (Helm 3 também funciona) |
| curl (opcional) | teste das UIs no fim do `plataforma_up.sh` | — |

Memória: o Compose usa ~0,6 GB; o cluster kind completo, ~2,5–3 GB. Num Docker
com ~4 GB (WSL2 padrão) **não rode os dois ao mesmo tempo**. Para mais folga no
WSL2, aumente `memory=` no `%UserProfile%\.wslconfig`.

## Plataforma no Docker Compose (`local/`)

```bash
docker compose -f local/docker-compose.yml up -d --wait   # sobe e espera todos "healthy"
docker compose -f local/docker-compose.yml ps             # estado e portas
docker compose -f local/docker-compose.yml logs -f rabbitmq
docker compose -f local/docker-compose.yml down           # para (mantém os dados)
docker compose -f local/docker-compose.yml down -v        # para e apaga os volumes
```

Todos os serviços têm healthcheck; `--wait` só retorna quando todos estão
`healthy`. A rede se chama `oficina-plataforma` (pode ser usada como rede
`external` por um compose de serviço).

### Portas, credenciais e conexões (somente dev)

| Serviço | Porta no host | Variável para trocar | Credencial | Conexão a partir do host |
|---|---|---|---|---|
| RabbitMQ (AMQP) | 5672 | `RABBITMQ_PORT` | `oficina` / `oficina` | `amqp://oficina:oficina@localhost:5672` |
| RabbitMQ Management UI | 15672 | `RABBITMQ_MANAGEMENT_PORT` | `oficina` / `oficina` | http://localhost:15672 |
| PostgreSQL do OS Service | 5432 | `POSTGRES_OS_PORT` | `postgres` / `postgres` | `jdbc:postgresql://localhost:5432/oficina_db` |
| PostgreSQL do Execution Service | 5433 | `POSTGRES_EXECUTION_PORT` | `postgres` / `postgres` | `jdbc:postgresql://localhost:5433/execution_db` |
| MongoDB (replica set `rs0`) | 27017 | `MONGODB_PORT` | sem autenticação | `mongodb://localhost:27017/billing_db?directConnection=true` |
| Jaeger UI | 16686 | `JAEGER_UI_PORT` | — | http://localhost:16686 |
| OTel Collector OTLP gRPC | 4317 | `OTEL_GRPC_PORT` | — | `http://localhost:4317` |
| OTel Collector OTLP HTTP | 4318 | `OTEL_HTTP_PORT` | — | `http://localhost:4318` (ex.: `/v1/traces`) |
| MailHog SMTP | 1025 | `MAILHOG_SMTP_PORT` | — | `localhost:1025` |
| MailHog UI | 8025 | `MAILHOG_UI_PORT` | — | http://localhost:8025 |

Dentro da rede do Compose, use o nome do serviço como host (`rabbitmq`,
`postgres-os:5432`, `postgres-execution:5432`, `mongodb:27017`,
`otel-collector:4317`, `mailhog:1025`).

Exemplo trocando portas (o `docker-compose.yml` do repo `oficina` também usa
5432, 1025 e 8025):

```bash
POSTGRES_OS_PORT=15432 MAILHOG_SMTP_PORT=11025 MAILHOG_UI_PORT=18025 \
  docker compose -f local/docker-compose.yml up -d --wait
```

### RabbitMQ: topologia versionada

`local/rabbitmq/definitions.json` é importado a cada boot
(`local/rabbitmq/rabbitmq.conf`) — no Compose e no kind. Contém:

| Exchange | Tipo | Fila (binding) | DLQ |
|---|---|---|---|
| `oficina.comandos` | direct | `execution.comandos` (routing key `execution.comandos`) | `execution.comandos.dlq` |
| `oficina.comandos` | direct | `billing.comandos` (routing key `billing.comandos`) | `billing.comandos.dlq` |
| `oficina.eventos` | topic | `os.saga.eventos` (routing key `#`) | `os.saga.eventos.dlq` |
| `oficina.dlx` | direct | `<fila>.dlq` (routing key `<fila>.dlq`) | — |

- Exchanges e filas **duráveis**; filas do tipo **quorum** (recomendação do
  RabbitMQ 4 para dados que não podem se perder).
- Cada fila principal tem `x-dead-letter-exchange: oficina.dlx`,
  `x-dead-letter-routing-key: <fila>.dlq` e `x-delivery-limit: 3`.
- **Retry com backoff é responsabilidade do consumidor** (Spring AMQP: 3 tentativas
  com backoff exponencial e, ao esgotar, rejeitar sem requeue → a mensagem vai para
  a DLQ). O `x-delivery-limit` é a rede de segurança do broker para mensagens que
  derrubam o consumidor repetidamente.
- Mensagens persistentes e publisher confirms são configurados nos produtores.
- Os serviços **não devem redeclarar** essas filas com argumentos diferentes (o
  broker responde `PRECONDITION_FAILED`). Nos testes com Testcontainers, carregue o
  mesmo `definitions.json` no container do RabbitMQ.
- Usuário único `oficina` (tag `administrator`, senha `oficina`); não há `guest`.
  Para trocar a senha: `docker run --rm rabbitmq:4.3-management-alpine rabbitmqctl hash_password <senha>`
  e substitua `password_hash`.

### MongoDB como replica set de 1 nó

O MongoDB roda com `--replSet rs0` porque o Billing Service (Fase 4) pode usar
**transações multi-documento** (mudança de estado + outbox atômicos), e transações
exigem replica set. O próprio healthcheck do container inicializa o replica set na
primeira subida (`rs.initiate`, idempotente) e só fica `healthy` quando o nó é
`PRIMARY`. O membro é anunciado como `localhost:27017`; por isso use
`directConnection=true` na URI (vale tanto do host quanto de outro container,
trocando o host). Sem autenticação: replica set com auth exige keyfile —
aceitável só em dev. Testcontainers (`MongoDBContainer`) já sobe um replica set de
1 nó por conta própria.

### Jaeger e OTel Collector

Os serviços exportam traces OTLP para o **Collector** (4317/4318), que repassa ao
**Jaeger** (`local/otel-collector-config.yaml`). O Jaeger v2 guarda até 20 mil
traces **em memória** (`local/jaeger-config.yaml`); eles se perdem ao reiniciar.
Só o pipeline de **traces** está configurado (métricas seguem pelo Prometheus).

Teste rápido do pipeline:

```bash
curl -s -X POST http://localhost:4318/v1/traces -H 'content-type: application/json' -d '{
  "resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"teste"}}]},
  "scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174",
  "name":"teste","kind":1,"startTimeUnixNano":"1763240000000000000","endTimeUnixNano":"1763240001000000000"}]}]}]}'
curl -s http://localhost:16686/api/traces/5b8efff798038103d269b633813fc60c | jq '.data[0].spans[0].operationName'
```

## Plataforma no kind (Kubernetes local e CI)

```bash
scripts/plataforma_up.sh     # cria o cluster "oficina" e instala tudo (idempotente)
kubectl get pods -A          # tudo Running/Completed
scripts/plataforma_down.sh   # apaga o cluster (idempotente)
```

`plataforma_up.sh`:

1. Cria o cluster a partir de `kind/cluster.yaml` (1 control-plane + 1 worker; o
   control-plane tem a label `ingress-ready` e as portas 80/443 do ingress
   publicadas em **127.0.0.1:8081/8443** do host — portas altas para não conflitar
   com um servidor web local nem exigir privilégio). Se o cluster já existir,
   reaproveita. Fixa o contexto `kind-oficina`.
2. Instala o **ingress-nginx** (`k8s/plataforma/ingress-nginx`, manifest oficial para
   kind versionado no repo + patches: só no control-plane, 2 workers do nginx).
3. Aplica `k8s/plataforma` (namespace `plataforma`): **RabbitMQ** (StatefulSet + PVC
   de 1 Gi, mesmas definitions do Compose), **Jaeger**, **OTel Collector** e o
   Ingress das UIs. As configs vêm dos mesmos arquivos de `local/`.
4. Roda o **`scripts/install_observability_stack.sh`** existente com
   `OBSERVABILITY_PROFILE=kind` (kube-prometheus-stack 93.1.2 + ServiceMonitor,
   PrometheusRule e dashboard da oficina no namespace `oficina`). Se uma execução
   anterior foi interrompida no meio do Helm (release `pending-*`), remove o
   release antes de reinstalar.
5. Espera todos os pods ficarem `Running`/`Completed` e testa as UIs pelo ingress.

Variáveis opcionais: `CLUSTER_NAME` (padrão `oficina`), `KIND_NODE_IMAGE`,
`KUBE_PROMETHEUS_STACK_VERSION` (padrão `93.1.2`), `WAIT_TIMEOUT` (padrão `600s`),
`INGRESS_HTTP_PORT` (padrão `8081`, igual ao `hostPort` de `kind/cluster.yaml`).
`--help` mostra o uso. Tempo típico num WSL2 com 4 GB: ~10 min na primeira vez
(download de imagens; o Grafana 13 leva 3–5 min para migrar o banco na primeira
subida), ~1 min nas seguintes.

### Acesso

| UI | Ingress | Port-forward | Credencial |
|---|---|---|---|
| Grafana | http://grafana.localtest.me:8081 | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` | `admin` / `admin` |
| Jaeger | http://jaeger.localtest.me:8081 | `kubectl -n plataforma port-forward svc/jaeger 16686:16686` | — |
| RabbitMQ | http://rabbitmq.localtest.me:8081 | `kubectl -n plataforma port-forward svc/rabbitmq 15672:15672` | `oficina` / `oficina` |
| Prometheus | — | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` | — |

`*.localtest.me` é um domínio público que resolve para `127.0.0.1`. Sem DNS
externo, use o header: `curl -H 'Host: jaeger.localtest.me' http://127.0.0.1:8081/`.

Endpoints internos para os serviços (Fases 3–7):
`rabbitmq.plataforma.svc:5672`, `otel-collector.plataforma.svc:4317` (gRPC) /
`:4318` (HTTP). Os serviços e os bancos de cada serviço são instalados pelos
próprios repositórios, no namespace `oficina`.

### Perfil enxuto (`values-kube-prometheus-stack-kind.yaml`)

Aplicado por cima de `values-kube-prometheus-stack.yaml` só quando
`OBSERVABILITY_PROFILE=kind` (o uso atual no EKS não muda): sem Alertmanager, sem
node-exporter, sem ServiceMonitors de etcd/scheduler/controller-manager/kube-proxy
(inacessíveis no kind), Prometheus com retenção de 6 h / 512 MB, dashboards
padrão do chart desligados, requests/limits pequenos e Ingress do Grafana.

| Componente | Request de memória | Limite |
|---|---|---|
| RabbitMQ | 256Mi | 512Mi |
| Jaeger | 64Mi | 256Mi |
| OTel Collector | 64Mi | 160Mi |
| ingress-nginx (2 workers do nginx) | 90Mi | 256Mi |
| Prometheus | 256Mi | 768Mi |
| Grafana (+2 sidecars) | 192Mi (+2×64Mi) | 512Mi (+2×192Mi) |

Consumo medido após o `plataforma_up.sh` (WSL2, Docker com 3,9 GB): nós do kind
com ~1,1 GB cada (`docker stats`), ~2,2 GB no total.
| Prometheus Operator / kube-state-metrics | 32Mi cada | 128Mi cada |

### No GitHub Actions

O script não pede nada interativamente nem usa `sudo`. O runner `ubuntu-latest`
já tem Docker, kind, kubectl e helm. Exemplo (usado pelos pipelines dos serviços
na Fase 7):

```yaml
- uses: actions/checkout@v4
  with:
    repository: gabrielivo01/oficina-infra-k8s
    ref: master
    path: oficina-infra-k8s
- name: Plataforma no kind
  run: oficina-infra-k8s/scripts/plataforma_up.sh
```

### Validação dos arquivos

```bash
docker compose -f local/docker-compose.yml config --quiet
kubectl kustomize --load-restrictor=LoadRestrictionsNone k8s/plataforma >/dev/null
kubectl kustomize k8s/plataforma/ingress-nginx >/dev/null
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:stable scripts/*.sh
```

O `--load-restrictor=LoadRestrictionsNone` é necessário porque `k8s/plataforma`
gera os ConfigMaps a partir de `local/` (fonte única para Compose e kind).

## Troubleshooting

| Sintoma | Causa provável / solução |
|---|---|
| `Bind for 0.0.0.0:5432 failed: port is already allocated` | Outro Postgres (ex.: o compose do repo `oficina`) usa a porta. Pare-o ou troque a porta pela variável (tabela acima). |
| `mongodb` fica `starting`/`unhealthy` | Veja `docker compose -f local/docker-compose.yml logs mongodb`. Se o volume veio de um Mongo sem replica set, `down -v` e suba de novo. |
| Serviço não conecta no Mongo com `replicaSet=rs0` | O membro é `localhost:27017`; de dentro de outro container use `directConnection=true`. |
| RabbitMQ: `PRECONDITION_FAILED - inequivalent arg` | O serviço declarou uma fila com argumentos diferentes de `definitions.json`. Não redeclare ou use os mesmos argumentos. |
| Mudei `definitions.json` e nada mudou (Compose) | `docker compose -f local/docker-compose.yml restart rabbitmq` (o import é a cada boot; itens removidos do arquivo não são apagados do broker — use `down -v`). No kind, o hash do ConfigMap muda e o `plataforma_up.sh` reinicia o pod. |
| Pods `Pending` ou `OOMKilled` no kind | Falta de memória no Docker. `docker stats`, `kubectl describe pod`, pare o Compose e outros containers, ou aumente a memória do WSL2. |
| `kind create cluster` falha com porta 8081/8443 em uso | Algum processo do host usa a porta. Libere-a ou troque `hostPort` em `kind/cluster.yaml` (e passe `INGRESS_HTTP_PORT`). |
| Resposta do ingress vem de outro servidor (ex.: `Server: nginx/1.24.0 (Ubuntu)`) | Um nginx local escuta no host. Use a porta do kind (8081), não a 80. |
| `grafana.localtest.me` não resolve | DNS sem acesso externo: use `curl -H 'Host: grafana.localtest.me' http://127.0.0.1:8081/` ou o port-forward. |
| `helm` falha com "another operation (install/upgrade/rollback) is in progress" | Uma execução anterior foi interrompida no meio do Helm. Rodar o `plataforma_up.sh` de novo remove o release pendente; se persistir, `plataforma_down.sh` e `plataforma_up.sh`. |
| Grafana demora a ficar pronto ou reinicia por liveness | Primeira subida do Grafana 13 (migrações). O perfil kind dá até ~5 min de tolerância; numa máquina mais lenta, aumente `WAIT_TIMEOUT`. |
| `kube-scheduler`/`kube-controller-manager` com 1–2 restarts logo após criar o cluster | Perda de leader election durante o boot com a máquina carregada; inofensivo se estiverem `Running`. |

## Dívidas da plataforma local

- **ingress-nginx foi descontinuado** pelo projeto Kubernetes (última versão
  `controller-v1.15.1`, março de 2026; sem correções de segurança depois disso).
  Mantido porque o plano da Fase 4 o especifica e o uso é só local/CI; a evolução
  natural é trocar por uma implementação da Gateway API.
- O healthcheck do OTel Collector no Compose monta o `busybox` a partir da imagem
  (`volumes: type: image`), recurso do Docker Engine 28+/Compose 2.35+.
- MongoDB de dev sem autenticação (replica set com auth exige keyfile).

## Infra AWS (Fase 3)

> Fora do escopo da Fase 4: mantida como está, sem alterações. Dívidas conhecidas
> (Terraform sem backend remoto, EKS com endpoint público, possibilidade de
> bypass do API Gateway) seguem registradas aqui.

Implementa os requisitos de infraestrutura obrigatória "Cluster Kubernetes
com escalabilidade" e "API Gateway para controle e roteamento", junto com o
requisito de "Monitoramento e Observabilidade" — tudo que é **cluster-wide**,
não específico de uma aplicação. O deploy da aplicação em si (Deployment,
Service, HPA daquele Deployment) vive no repositório da aplicação.

### Tecnologias

- Terraform (`hashicorp/aws`) para EKS, VPC e API Gateway (HTTP API)
- Helm (`prometheus-community/kube-prometheus-stack`) para Prometheus +
  Grafana + Alertmanager + node-exporter + kube-state-metrics
- `external-secrets` (ClusterSecretStore) para AWS Secrets Manager

### O que provisiona

- `infra/terraform/modules/eks-cluster` — VPC, subnets, cluster EKS, node
  group.
- `infra/terraform/modules/api-gateway` — API Gateway HTTP API único do
  projeto: rota `POST /auth/cpf` (proxy para o Lambda do repo
  `oficina-auth-lambda`) e rotas `ANY /{proxy+}` / `ANY /` (proxy HTTP para o
  `Service` `oficina-app-lb` do repo da aplicação).
- `k8s/observability/` — `ServiceMonitor`, `PrometheusRule` (3 alertas:
  falha de notificação, taxa de erro 5xx alta, app fora do ar) e dashboard
  Grafana (`ConfigMap` com 7 painéis: OS abertas/dia, uptime, falhas de
  notificação, tempo médio por status, latência p95, CPU e memória do pod).
- `k8s/external-secrets/clustersecretstore-aws.yaml` — `ClusterSecretStore`
  usado pelos `ExternalSecret` do repo da aplicação (recurso cluster-wide,
  por isso vive aqui e não lá).
- `scripts/install_observability_stack.sh` — instala o
  `kube-prometheus-stack` via Helm e aplica os manifests de
  `k8s/observability/` (perfil padrão; `OBSERVABILITY_PROFILE=kind` é usado
  pelo `plataforma_up.sh`).

### Deploy

```bash
cd infra/terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars   # preencher os valores
terraform init
terraform apply -var-file=terraform.tfvars
```

`lambda_function_name`/`lambda_invoke_arn` vêm do repositório
`oficina-auth-lambda` (`terraform output -raw lambda_function_name` /
`lambda_invoke_arn` naquele repo). `app_public_url` só é conhecida depois do
deploy da aplicação (hostname do `Service` `oficina-app-lb`)
— use um placeholder no primeiro apply e reaplique com o valor real depois
(ver comentário na própria variável em
`infra/terraform/environments/dev/main.tf`).

Depois que o cluster existir:

```bash
aws eks update-kubeconfig --name <cluster_name> --region <aws_region>
scripts/install_observability_stack.sh
kubectl apply -f k8s/external-secrets/clustersecretstore-aws.yaml
```

Outputs relevantes (`vpc_id`, `subnet_ids`) são consumidos pelo repositório
`oficina-infra-db` para provisionar o RDS na mesma VPC.

CI/CD (GitHub Actions):
- `.github/workflows/plan-infra.yml` — `terraform fmt/validate/plan` +
  scanners de segurança (`tfsec`, `checkov`) em todo PR.
- `.github/workflows/deploy-infra.yml` — disparado manualmente; `apply`
  automático apenas com `terraform_auto_apply=true` (ambiente `production`);
  opcionalmente também instala/atualiza a stack de observabilidade.

Segredos esperados no GitHub: `AWS_REGION`, `AWS_ROLE_TO_ASSUME`,
`EKS_CLUSTER_NAME`, `AUTH_LAMBDA_FUNCTION_NAME`, `AUTH_LAMBDA_INVOKE_ARN`,
`APP_PUBLIC_URL`.

### Arquitetura

```mermaid
graph TB
    cliente[Cliente] --> gw["API Gateway (HTTP API)\neste repositório"]
    gw -->|"POST /auth/cpf"| lambda["Lambda\nrepo oficina-auth-lambda"]
    gw -->|"ANY /{proxy+}, ANY /"| appLB["Service oficina-app-lb\nrepo da aplicação"]

    subgraph eks["Cluster EKS — este repositório"]
        appLB
        subgraph monitoring["namespace monitoring"]
            prometheus[Prometheus] --> grafana[Grafana]
            prometheus --> alertmanager[Alertmanager]
        end
        css["ClusterSecretStore\n(external-secrets)"]
    end

    prometheus -->|scrape /actuator/prometheus| appLB
    css -.->|segredos| secretsmgr[(AWS Secrets Manager)]
```

### Branch protection

`main` protegida contra push direto; merge somente via Pull Request
(gatilho de `plan-infra.yml`); deploy disparado manualmente após merge, com
`apply` exigindo confirmação explícita e aprovação do ambiente `production`.

### Observação de escopo

Terraform deste repositório **não foi validado** contra `terraform` real
(ferramenta indisponível no ambiente onde este repositório foi extraído do
monorepo `oficina`) — revisar antes do primeiro `apply`.
