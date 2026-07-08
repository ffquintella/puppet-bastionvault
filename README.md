# bastionvault

Puppet module to install and run the **BastionVault** server (Vault-API
compatible secrets manager) on EL9 / EL10, using **rootless Podman** with
**SELinux enforcing** and **systemd cgroups v2** limits.

Full design lives in [docs/specs.md](docs/specs.md).

## What this module does

- Installs Podman and rootless networking helpers.
- Runs the container on **host networking** by default (`network_mode => 'host'`),
  so it avoids the pasta/passt flow-table socket leak under long-lived HA peer
  connections and reaches host-local services (e.g. ferrogate) over loopback.
  Set `network_mode => 'pasta'` (or `'slirp4netns'`) for the legacy user-mode
  stack with published ports.
- Creates a non-root system user (`bastionvault`) with systemd lingering.
- Renders `config.hcl` (single-node or HA / hiqlite Raft) from parameters.
- Optionally configures HSM auto-unseal (mock or YubiHSM 2) — see
  [HSM auto-unseal](#hsm-auto-unseal).
- Installs a Quadlet `.container` unit under the user's systemd manager.
- Sets SELinux `container_file_t` on the data, config, TLS, and log dirs.
- Drops a cgroups v2 slice override with `MemoryMax`, `CPUQuota`,
  `TasksMax`, and `IOWeight`.
- Brings the service to **running, but uninitialized**.

## What this module deliberately does NOT do

- **Never** runs `bvault operator init`.
- **Never** handles unseal keys or the root token.
- **Never** generates or rotates TLS material (it places operator-supplied
  files with the right ownership/labels).
- Does not touch firewall rules unless `manage_firewall => true`.

After the service is up, an operator must run `bvault operator init` and
`bvault operator unseal` interactively. See [docs/specs.md §12](docs/specs.md).

## Quick start (single-node)

```puppet
include bastionvault
```

Defaults: `docker.io/bastionvault:0.3.2`, listening on host port `4200`
(bound directly on the host under the default `host` networking mode).

## Custom registry / account / tag

```puppet
class { 'bastionvault':
  registry      => 'registry.example.com',
  image_account => 'platform',         # optional; empty by default
  image_name    => 'bastionvault',
  image_tag     => '0.3.2',
  listen_port   => 4200,
}
```

## HA cluster (hiqlite Raft)

```puppet
class { 'bastionvault':
  mode             => 'ha',
  node_id          => 1,
  raft_listen_addr => 'bvault-01.example.com',  # this node's FQDN; must NOT be 0.0.0.0
  nodes            => [
    { id => 1, raft_host => 'bvault-01.example.com', raft_port => 8210, api_host => 'bvault-01.example.com', api_port => 8220 },
    { id => 2, raft_host => 'bvault-02.example.com', raft_port => 8210, api_host => 'bvault-02.example.com', api_port => 8220 },
    { id => 3, raft_host => 'bvault-03.example.com', raft_port => 8210, api_host => 'bvault-03.example.com', api_port => 8220 },
  ],
  secret_raft => Sensitive(lookup('bastionvault::secret_raft')),
  secret_api  => Sensitive(lookup('bastionvault::secret_api')),
}
```

`secret_raft` and `secret_api` MUST be identical on every node. Source
them from Hiera eyaml or an external secret store.

> **Bootstrap immutability.** hiqlite persists each node's `addr_raft`/`addr_api`
> (as `<host>:<port>`) into the Raft membership at bootstrap. Changing
> `raft_port`, `internal_api_port`, `raft_listen_addr`, or any per-node
> `raft_host`/`api_host`/`raft_port`/`api_port` after the cluster has been
> bootstrapped produces a malformed bind address on restart (e.g.
> `0.0.0.0:8210:8220`) and the listeners silently fail to come up. If you
> need to change any of these values, wipe `data_dir` on every node and
> rebootstrap. The module enforces uniform ports across `$nodes` and
> refuses `0.0.0.0` as a routable host to make this class of drift loud
> at compile time.

## HSM auto-unseal

Wraps the barrier KEK under an HSM so the server auto-unseals on start with no
operator shares (BastionVault v0.24.0+). Leave `hsm_backend` unset to stay on
Shamir unseal (the default). The **official image ships both HSM backends baked
in** — one image serves production and homologation, and the active backend is
chosen entirely by `hsm_backend`. No special image build is required.

### Mock backend (dev / homolog)

Software-only, **no hardware protection**; the server refuses to start with the
mock when `BVAULT_ENV=production` (or `environment = "production"`), so a
production node must use `yubihsm2` (or Shamir).

```puppet
class { 'bastionvault':
  hsm_backend => 'mock',
  # hsm_node_id defaults to the hostname; single node needs nothing else.
}
```

On first boot the mock self-provisions its key store at
`/var/lib/bvault/data/mock-hsm.json` (inside the data volume, so it survives
restarts). Then run `bvault operator init` once — it returns **no** unseal
shares, and every restart auto-unseals.

### YubiHSM 2 backend (production)

```puppet
class { 'bastionvault':
  hsm_backend   => 'yubihsm2',
  hsm_connector => 'http://127.0.0.1:12345',   # yubihsm-connector on the host
  hsm_password  => Sensitive('...'),            # via Hiera/eyaml in practice
  hsm_auth_key_id => 1,                          # optional; default 1
  hsm_domains     => [1],                        # optional; default [1]
}
```

Under the default `host` networking a connector on the host's loopback is
reachable from the container. The password is written to a 0600 `hsm.env`
EnvironmentFile and referenced from `config.hcl` as
`env:BASTIONVAULT_HSM_PASSWORD` — never rendered into `config.hcl` in the clear.

### HA cluster with the mock

Each node runs its own mock "device", and the wrapped KEK is bound to the
wrapping device's identity **and** the `node_id`. So to unseal a cluster off the
mock, every node must present **byte-identical device material** under a
**shared `node_id`** (this mirrors a real YubiHSM shared-wrap-key domain; true
per-node enrollment is not yet wired in the server). The module enforces both:

1. Provision once — start one node with `hsm_backend => 'mock'`, let it write
   `mock-hsm.json`, then `bvault operator init`.
2. Base64 that file into Hiera/eyaml and pin it on **every** node, with the
   **same** `hsm_node_id`:

```puppet
class { 'bastionvault':
  mode                   => 'ha',
  # ... nodes / node_id as usual ...
  hsm_backend            => 'mock',
  hsm_node_id            => 'hml',                       # SAME on all nodes
  hsm_mock_state_base64  => Sensitive($mock_hsm_b64),    # SAME on all nodes
}
```

The seal record replicates over Raft; peers unwrap the shared KEK with their
identical device and auto-unseal. Puppet fails compilation if `hsm_node_id` or
the pinned material is missing in HA + mock.

### Checking status

`bvault-ctl hsm-status` (added to the host helper) proxies to
`bvault operator hsm status` — reporting seal type, backend, device serial,
cluster epoch and enrolled-node count. It needs a login token, so run
`bvault login ...` first.

## TLS material

The module accepts cert/key material for **three** independent TLS endpoints:

| Endpoint              | Purpose                                  | In-container path                |
| --------------------- | ---------------------------------------- | -------------------------------- |
| Listener (API)        | The public HTTPS API on `$listen_port`   | `/etc/bvault/tls/server.{crt,key}` |
| Cluster Raft          | hiqlite Raft channel (HA only)           | `/etc/bvault/tls/raft.{crt,key}` |
| Cluster hiqlite API   | hiqlite internal API channel (HA only)   | `/etc/bvault/tls/cluster-api.{crt,key}` |

For each endpoint you can supply the cert and key in any of these forms
(highest precedence first):

1. **`*_content`** — literal PEM string.
2. **`*_base64`** — base64-encoded PEM (decoded on the agent). Convenient
   for Hiera/eyaml where multi-line PEM blocks are awkward.
3. **`*_source`** — Puppet file `source` URI (**listener only**).
4. **`*_self_signed`** *(listener only)* — generate a self-signed pair on
   first run via `openssl`. Enabled by default.

Keys accept `Sensitive[String]` so they are not echoed in catalogs or
diffs.

### Listener parameters

| Parameter            | Type                                      | Notes |
| -------------------- | ----------------------------------------- | ----- |
| `tls_cert_content`   | `Optional[String]`                        | Literal PEM. |
| `tls_cert_base64`    | `Optional[String]`                        | Base64-encoded PEM. |
| `tls_cert_source`    | `Optional[String]`                        | Puppet `source` URI (e.g. `puppet:///modules/profile/bvault/server.crt`). |
| `tls_key_content`    | `Optional[Sensitive[String]]`             | Literal PEM. |
| `tls_key_base64`     | `Optional[Variant[Sensitive[String], String]]` | Base64-encoded PEM. |
| `tls_key_source`     | `Optional[String]`                        | Puppet `source` URI. |
| `tls_self_signed`    | `Boolean` (default `true`)                | Generate via openssl when no cert/key is supplied. |

### Cluster Raft parameters (HA only)

| Parameter                         | Type                                      |
| --------------------------------- | ----------------------------------------- |
| `cluster_tls_raft_disable`        | `Boolean` (default `false`)               |
| `cluster_tls_raft_no_verify`      | `Boolean` (default `false`) — skip peer cert verification (`tls_raft_no_verify`) |
| `cluster_tls_raft_cert_content`   | `Optional[String]`                        |
| `cluster_tls_raft_cert_base64`    | `Optional[String]`                        |
| `cluster_tls_raft_key_content`    | `Optional[Sensitive[String]]`             |
| `cluster_tls_raft_key_base64`     | `Optional[Variant[Sensitive[String], String]]` |
| `cluster_tls_raft_cert`           | `Optional[Stdlib::Absolutepath]` — in-container path override |
| `cluster_tls_raft_key`            | `Optional[Stdlib::Absolutepath]` — in-container path override |

When you supply content or base64, the module writes the file under
`$tls_dir` and config.hcl is rendered to point at the corresponding
in-container path. The path overrides are only needed if you mount the
material in yourself.

### Cluster hiqlite API parameters (HA only)

Same shape as Raft: `cluster_tls_api_disable`,
`cluster_tls_api_no_verify`,
`cluster_tls_api_cert_content`, `cluster_tls_api_cert_base64`,
`cluster_tls_api_key_content`, `cluster_tls_api_key_base64`,
`cluster_tls_api_cert`, `cluster_tls_api_key`.

### Host CA bundle auto-mount

When `mount_host_ca_bundle` is `true` (default) the module bind-mounts the
host CA trust bundle read-only into the container so the in-container TLS
stack trusts the same roots as the host (corporate CAs added via
`update-ca-trust`, etc.).

| Parameter              | Type                              | Default |
| ---------------------- | --------------------------------- | ------- |
| `mount_host_ca_bundle` | `Boolean`                         | `true`  |
| `host_ca_bundle_path`  | `Optional[Stdlib::Absolutepath]`  | auto → `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` |

The bundle is mounted at both `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`
and `/etc/ssl/certs/ca-certificates.crt` so software looking for either
location finds it. The mount uses the lowercase `:z` SELinux flag
(shared label) so it does not steal the label from other host consumers.

### Adding extra CAs to the trust store

When bvault TLS material (listener cert, Raft cert, hiqlite API cert) is
signed by a private CA that the host does not trust yet, peer TLS
verification fails. The `extra_ca_certs` parameter installs additional
CA certificates into the host trust store and rebuilds the bundle via
`update-ca-trust extract`. Because the bundle is bind-mounted into the
container, the new CA is trusted on both sides. The service is restarted
when the bundle changes.

```puppet
class { 'bastionvault':
  extra_ca_certs => {
    'internal-root' => { source => 'puppet:///modules/profile/ca/internal-root.crt' },
    'raft-issuer'   => { base64 => lookup('bastionvault::raft_issuer_ca_b64') },
    'inline-ca'     => { content => "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n" },
  },
}
```

Each entry accepts exactly one of `content` (literal PEM), `base64`
(base64-encoded PEM), or `source` (Puppet `source` URI). The anchor file
lands at `/etc/pki/ca-trust/source/anchors/bvault-<name>.crt`.

### Example: base64 PEM via Hiera + eyaml

`eyaml encrypt -s "$(base64 -w0 server.key)"` produces an
`ENC[PKCS7,...]` envelope you can paste into Hiera. hiera-eyaml decrypts
it on the puppetserver at compile time:

```yaml
# data/nodes/bvault-01.example.com.yaml
bastionvault::tls_cert_base64: >
  LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUR...
bastionvault::tls_key_base64: >
  ENC[PKCS7,MIIBiQYJKoZIhvcNAQcDoIIBejCCAXYC...]

bastionvault::cluster_tls_raft_cert_base64: >
  LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUR...
bastionvault::cluster_tls_raft_key_base64: >
  ENC[PKCS7,MIIBiQYJKoZIhvcNAQcDoIIBejCCAXYC...]

bastionvault::cluster_tls_api_cert_base64: >
  LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUR...
bastionvault::cluster_tls_api_key_base64: >
  ENC[PKCS7,MIIBiQYJKoZIhvcNAQcDoIIBejCCAXYC...]
```

The module decodes the base64, writes the PEM files under
`$tls_dir` with the right ownership and `0600` / `0644` modes, and points
`config.hcl` at the in-container paths automatically.

## Client-only install (`bastionvault::client`)

For hosts that only need the `bvault` CLI to talk to a remote BastionVault
server — no container, no service, none of the server plumbing. The class
does three things:

1. **Installs the CLI** — the upstream `bastionvault` RPM, which ships
   `/usr/bin/bvault` plus a manpage and bash/zsh/fish completions.
2. **Places the trust anchor** — the server's CA (or self-signed serving
   cert) at `/etc/bvault/ca.pem`, a path the CLI natively auto-discovers.
3. **Configures the default server** — a wrapper at `/usr/local/bin/bvault`
   that injects `--address` / `--ca-cert` / `--tls-server-name`, so
   `bvault status` "just works" for every user on the host.

The wrapper is what makes configuration stick: the bvault binary does
**not** read `VAULT_ADDR` / `VAULT_TLS_SERVER_NAME` from the environment
(its help text mentions them, but no env binding exists), so the address
must arrive as an `--address` flag on every call. `/usr/local/bin`
precedes `/usr/bin` on the default EL PATH, so the wrapper shadows the
packaged binary transparently; `bvault --version`, `bvault --help`, and
group-only invocations (`bvault operator`) pass through untouched.

Do **not** include `bastionvault::client` on a node that also includes
the server class: the server already ships its own podman-exec wrapper at
`/usr/local/bin/bvault`, and the catalog will fail with a duplicate File
declaration. Server nodes get their CLI through `bastionvault::cli`
automatically.

### Quick start

```puppet
class { 'bastionvault::client':
  server_url     => 'https://vault.example.com:4200',
  ca_cert_base64 => lookup('vault_ca_b64'),   # or ca_cert_content / ca_cert_source
}
```

Or, Hiera-driven (the usual roles/profiles shape):

```puppet
# profile::bvault_client
include bastionvault::client
```

```yaml
# data/common.yaml (the CA cert is public material — plain base64 is fine)
bastionvault::client::server_url: 'https://vault.example.com:4200'
bastionvault::client::ca_cert_base64: >
  LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUR...
```

To produce the base64 blob from the server host (the module publishes the
serving cert world-readable under `$tls_dir`):

```sh
base64 -w0 /srv/application-config/bastionvault/tls/server.crt
```

`server_url` may also be a bare cluster DNS name — the CLI then runs
SRV-based discovery (`_bvault._tcp.<name>` plus `/sys/health` scoring) to
pick a healthy HA node:

```yaml
bastionvault::client::server_url: 'vault.example.com'
```

### Package delivery options

By default the class installs the `bastionvault` package from whatever
repos the host already has. Two alternatives:

```puppet
# From a module-managed yum repository:
class { 'bastionvault::client':
  server_url   => 'https://vault.example.com:4200',
  manage_repo  => true,
  repo_baseurl => 'https://repo.example.com/bastionvault/el9',
  repo_gpgkey  => 'https://repo.example.com/bastionvault/RPM-GPG-KEY',
}

# From a direct RPM URL (dnf installs it and resolves dependencies):
class { 'bastionvault::client':
  server_url     => 'https://vault.example.com:4200',
  package_source => 'https://github.com/ffquintella/BastionVault/releases/download/v0.9.0/bastionvault-0.9.0-1.x86_64.rpm',
}
```

Set `manage_package => false` when the binary arrives by other means
(baked image, other packaging) and you only want the CA + wrapper.

### How settings are resolved at run time

The wrapper never overrides anything the operator set explicitly. Per
setting, first match wins:

| Setting             | 1. flag                                        | 2. environment                               | 3. Puppet                | 4. fallback                              |
|---------------------|------------------------------------------------|----------------------------------------------|--------------------------|------------------------------------------|
| server address      | `--address`                                    | `BVAULT_ADDR`, `VAULT_ADDR`                  | `$server_url`            | binary default (`https://127.0.0.1:8200`) |
| trust anchor        | `--ca-cert` / `--ca-path` / `--tls-skip-verify`| `VAULT_CACERT` / `VAULT_CAPATH` / `VAULT_SKIP_VERIFY` | `$ca_cert_path` (if the file exists) | CLI auto-discovery (`~/.bvault/ca.pem`, `/etc/bvault/ca.pem`) |
| SNI / verify name   | `--tls-server-name`                            | `VAULT_TLS_SERVER_NAME`                      | `$tls_server_name`       | hostname from the address                |

Login tokens need no plumbing: `bvault login` persists the token to
`~/.vault-token` (or `$BVAULT_TOKEN_FILE`) per invoking user, and later
invocations read it back automatically.

### First use on a client host

```sh
bvault status            # reachability + seal status of the remote server
bvault login ...         # token is persisted to ~/.vault-token
bvault secrets list      # any CLI command now targets the configured server
```

### Parameters

| Parameter          | Default                  | Purpose                                                            |
|--------------------|--------------------------|--------------------------------------------------------------------|
| `server_url`       | `undef`                  | Server URL, or bare cluster name for SRV discovery. `undef` = no `--address` injection. |
| `manage_package`   | `true`                   | Install the CLI package.                                           |
| `package_name`     | `'bastionvault'`         | Package name.                                                      |
| `package_ensure`   | `'installed'`            | `installed`, `latest`, or a pinned version.                        |
| `package_source`   | `undef`                  | Path/URL of an RPM file to install directly.                       |
| `manage_repo`      | `false`                  | Manage a yumrepo for the package (requires `repo_baseurl`).        |
| `repo_baseurl`     | `undef`                  | Base URL of the yum repository.                                    |
| `repo_gpgkey`      | `undef`                  | GPG key URL for the repository.                                    |
| `repo_gpgcheck`    | `true`                   | Enable GPG verification.                                           |
| `ca_cert_content`  | `undef`                  | Literal PEM trust anchor (precedence: content > base64 > source).  |
| `ca_cert_base64`   | `undef`                  | Base64-encoded PEM (single Hiera-friendly line).                   |
| `ca_cert_source`   | `undef`                  | Puppet file `source` URI for the cert.                             |
| `ca_cert_path`     | `'/etc/bvault/ca.pem'`   | Where the trust anchor is written.                                 |
| `tls_server_name`  | `undef`                  | SNI/verification name when the address differs from the cert SAN.  |
| `manage_wrapper`   | `true`                   | Manage the `/usr/local/bin` wrapper.                               |
| `wrapper_path`     | `'/usr/local/bin/bvault'`| Wrapper location.                                                  |
| `binary_path`      | `'/usr/bin/bvault'`      | Packaged binary the wrapper execs.                                 |

## Development

```sh
bundle install
bundle exec rake test     # validate + lint + spec
```

Author: Felipe Quintella
License: Apache-2.0
