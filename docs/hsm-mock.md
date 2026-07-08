# Ativando o HSM (mock)

Guia prático para ligar o **auto-unseal por HSM mock** no BastionVault. O
backend `mock` é software puro, **sem proteção de hardware** — serve apenas para
dev/testes. O servidor **recusa** subir com o mock quando o ambiente é
`production` (`BVAULT_ENV=production`), então este caminho não vaza para produção
por acidente.

> Requer BastionVault v0.24.0+. A imagem oficial já traz os dois backends
> (`mock` e `yubihsm2`) embutidos — o backend ativo é escolhido só pelo
> parâmetro `hsm_backend`, sem build de imagem especial.

---

## Como funciona (resumo)

- Com `hsm_backend => 'mock'`, o servidor envelopa (wrap) a **barrier KEK** sob
  um "device" mock e **auto-unseal** a cada start, **sem shares de operador**.
- O device mock persiste seu key store em
  `/var/lib/bvault/data/mock-hsm.json` (dentro do volume de dados, sobrevive a
  restarts).
- Em **HA**, o KEK envelopado fica atrelado à identidade do device **e** ao
  `node_id`. Para o cluster inteiro conseguir dar unseal, **todo nó precisa
  apresentar material de device byte-a-byte idêntico sob o mesmo `hsm_node_id`**.
  O módulo falha a compilação se isso não for satisfeito.

---

## Pré-requisitos

- Ambiente do nó **não** é `production` (senão o servidor recusa o mock).
- Acesso para rodar Puppet no(s) nó(s) e para executar `bvault-ctl` / `bvault`
  no host.
- Se for HA: eyaml/Hiera disponível para guardar o material do device mock.

---

## Caso A — **Nó único**

O mais simples. Basta o backend:

```puppet
class { 'bastionvault':
  hsm_backend => 'mock',
  # hsm_node_id assume o hostname; nó único não precisa de mais nada.
}
```

Ou via Hiera (o eyaml/dados do ambiente):

```yaml
bastionvault::hsm_backend: 'mock'
```

Fluxo:

1. Aplique o Puppet no nó.
2. No primeiro boot o mock se **auto-provisiona** e escreve
   `/var/lib/bvault/data/mock-hsm.json`.
3. Rode `bvault operator init` **uma vez** — ele retorna **nenhum** share de
   unseal.
4. Todo restart daqui pra frente dá **auto-unseal** sozinho.

---

## Caso B — Cluster em **HA**

Em HA cada nó tem seu próprio "device" mock, mas o KEK envelopado é replicado
via Raft. Para os peers desenveloparem o KEK compartilhado, **todos precisam do
mesmo material de device e do mesmo `hsm_node_id`**. Isso espelha um domínio de
shared-wrap-key de um YubiHSM real (enrollment por-nó ainda não está no
servidor).

### Passo 1 — Provisionar o device mock **uma vez**

Em **um** nó, suba temporariamente com o mock (pode ser em modo single ou o
próprio nó HA) e deixe ele criar o key store:

```puppet
class { 'bastionvault':
  hsm_backend => 'mock',
  hsm_node_id => 'cluster1',   # o node_id que o cluster inteiro vai usar
}
```

Aplique o Puppet, depois:

```bash
bvault operator init      # inicializa; NÃO devolve shares (auto-unseal via HSM)
```

Isso grava `/var/lib/bvault/data/mock-hsm.json` já provisionado.

### Passo 2 — Empacotar o material do device

No host onde o volume de dados está montado (o data dir configurado do módulo),
gere o base64 do arquivo:

```bash
base64 -w0 <data_dir>/mock-hsm.json > /tmp/mock-hsm.b64
# <data_dir> = o $data_dir do módulo (o host path que mapeia para
# /var/lib/bvault/data dentro do container).
```

Guarde esse conteúdo **criptografado** no eyaml (não commite em claro).

### Passo 3 — Pinar o **mesmo** material em **todos** os nós

Em Hiera (eyaml), para o cluster:

```yaml
bastionvault::mode:            'ha'
# ... node_id / nodes por nó, como de costume ...
bastionvault::hsm_backend:     'mock'
bastionvault::hsm_node_id:     'cluster1'            # IGUAL em todos os nós
bastionvault::hsm_mock_state_base64: >
  ENC[PKCS7,eyaml...base64 de mock-hsm.json...]      # IGUAL em todos os nós
```

Equivalente em Puppet DSL:

```puppet
class { 'bastionvault':
  mode                  => 'ha',
  # ... nodes / node_id de sempre ...
  hsm_backend           => 'mock',
  hsm_node_id           => 'cluster1',               # IGUAL em todos os nós
  hsm_mock_state_base64 => Sensitive($mock_hsm_b64), # IGUAL em todos os nós
}
```

Notas do módulo:

- Use `hsm_mock_state_base64` (conveniente via Hiera/eyaml) **ou**
  `hsm_mock_state_content` (JSON literal). Se ambos forem passados,
  `hsm_mock_state_content` vence.
- O `hsm_mock_state_path` precisa ficar sob `/var/lib/bvault/data/` (default
  `/var/lib/bvault/data/mock-hsm.json`) para o arquivo cair no volume montado.
- O módulo **falha a compilação** em HA + mock se faltar `hsm_node_id` ou o
  material pinado. (Obs.: catálogos HA não compilam sob `regent`; a cobertura HA
  vive só no branch rspec-puppet do CI.)

### Passo 4 — Aplicar e subir o cluster

Rode o Puppet em todos os nós. A seal record replica via Raft e cada peer
desenvelopa o KEK compartilhado com seu device idêntico, dando **auto-unseal**.

---

## Verificação

`bvault-ctl hsm-status` (helper do host) faz proxy para
`bvault operator hsm status` e reporta: tipo de seal, backend, serial do device,
epoch do cluster e contagem de nós enrolados. Precisa de token de login:

```bash
bvault login ...          # obtém o token
bvault-ctl hsm-status
```

Cheque também:

```bash
bvault status             # alcançabilidade + status de seal do servidor
```

Espere ver seal type = HSM/auto e backend = `mock`. Em HA, confirme que a
contagem de nós enrolados bate com o tamanho do cluster.

---

## Config gerado (referência)

Com o mock ligado, o `config.hcl` renderiza um bloco assim:

```hcl
hsm "mock" {
  state_path = "/var/lib/bvault/data/mock-hsm.json"
  node_id    = "cluster1"     # presente quando hsm_node_id é definido
  # recovery = "..."          # só se hsm_recovery != 'none'
}
```

(No `yubihsm2` o bloco traz `connector`, `password = "env:BASTIONVAULT_HSM_PASSWORD"`
e `domains` — não se aplica ao mock.)

---

## Reverter para Shamir

Para voltar ao unseal por shares (default), deixe `hsm_backend` sem valor:

```yaml
bastionvault::hsm_backend: ~
```

> Trocar de backend em um cluster já inicializado envolve re-seal/migração da
> KEK — não é só editar o parâmetro. Em ambientes descartáveis, o caminho limpo
> costuma ser reinicializar o estado. Valide o procedimento de migração no
> servidor antes de mexer num cluster com dados que você quer preservar.

---

## Armadilhas comuns

| Sintoma | Causa provável |
| --- | --- |
| Servidor recusa subir com o mock | Ambiente é `production` (`BVAULT_ENV=production`) — o mock só roda fora de produção. |
| Puppet falha ao compilar (HA) | Faltou `hsm_node_id` ou `hsm_mock_state_base64`/`_content` em HA + mock. |
| Peers não dão unseal em HA | `hsm_node_id` diferente entre nós, ou material de device não idêntico. Reempacote e pine o **mesmo** base64 em todos. |
| `hsm_mock_state_path` rejeitado | Path fora de `/var/lib/bvault/data/` ao fornecer o conteúdo do device. |
| `hsm-status` retorna erro de auth | Rode `bvault login ...` primeiro. |

## Referências

- [README — HSM auto-unseal](../README.md#hsm-auto-unseal)
- [docs/specs.md](specs.md) (§ HSM / seal)
- Parâmetros HSM: `manifests/init.pp` (bloco "HSM auto-unseal")
- Defaults/exemplos: `data/common.yaml`
