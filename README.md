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

## Development

```sh
bundle install
bundle exec rake test     # validate + lint + spec
```

Author: Felipe Quintella
License: Apache-2.0
