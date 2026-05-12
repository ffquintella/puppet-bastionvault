# bastionvault

Puppet module to install and run the **BastionVault** server (Vault-API
compatible secrets manager) on EL9 / EL10, using **rootless Podman** with
**SELinux enforcing** and **systemd cgroups v2** limits.

Full design lives in [docs/specs.md](docs/specs.md).

## What this module does

- Installs Podman and rootless networking helpers.
- Creates a non-root system user (`bastionvault`) with systemd lingering.
- Renders `config.hcl` (single-node or HA / hiqlite Raft) from parameters.
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

Defaults: `docker.io/bastionvault:0.3.2`, listening on host port `4200`.

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
  mode    => 'ha',
  node_id => 1,
  nodes   => [
    { id => 1, raft_host => '10.0.0.11', raft_port => 8210, api_host => '10.0.0.11', api_port => 8220 },
    { id => 2, raft_host => '10.0.0.12', raft_port => 8210, api_host => '10.0.0.12', api_port => 8220 },
    { id => 3, raft_host => '10.0.0.13', raft_port => 8210, api_host => '10.0.0.13', api_port => 8220 },
  ],
  secret_raft => Sensitive(lookup('bastionvault::secret_raft')),
  secret_api  => Sensitive(lookup('bastionvault::secret_api')),
}
```

`secret_raft` and `secret_api` MUST be identical on every node. Source
them from Hiera eyaml or an external secret store.

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

## Development

```sh
bundle install
bundle exec rake test     # validate + lint + spec
```

Author: Felipe Quintella
License: Apache-2.0
