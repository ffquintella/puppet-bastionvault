# puppet-bastionvault — Design & Test Specification

Status: draft v1
Scope: server-side install of BastionVault on EL9 / EL10 via Puppet, using
rootless Podman (Quadlet), SELinux enforcing, and systemd cgroups v2 limits.
Out of scope: initialization and unseal — performed interactively by an
operator after the service is up.

---

## 1. Goals & non-goals

**Goals**
- Idempotent Puppet-managed install of the BastionVault server container on
  EL9 and EL10.
- Run rootless under a dedicated non-root system user with systemd lingering.
- SELinux remains `Enforcing`; data volumes get correct labels.
- cgroups v2 resource limits applied via the user slice.
- Single-node and HA (hiqlite/Raft) topologies supported by parameter, with
  the same class surface.
- Configuration is driven entirely by Puppet/Hiera; no in-place edits.

**Non-goals**
- The module never initializes the vault and never handles unseal keys or
  root tokens. `bvault operator init` / unseal happens out-of-band, by a
  human, after first start. The module surfaces a clear "ready to init"
  state via service health, nothing more.
- The module does not generate or rotate TLS material. It places operator-
  supplied certs/keys with correct ownership and SELinux context.
- The module does not provision the firewall by default (opt-in flag).

---

## 2. Inputs derived from `../BastionVault`

From `deploy/container/Containerfile`:

- Container runs as UID/GID `65532:65532` (distroless `nonroot`). Host-side
  bind mounts must be readable/writable by that subordinate UID inside the
  user namespace — i.e. host owner is the rootless user, but the kernel
  sees the mapped subuid. Volumes use `:Z` for private SELinux relabel.
- Config path inside container: `/etc/bvault/config.hcl`.
- TLS material expected under `/etc/bvault/tls/`.
- Data volume: `/var/lib/bvault/data` (declared `VOLUME`).
- Backup volume: `/backups` (host `$backup_dir`, default under the data root).
- Working directory: `/var/lib/bvault`.
- Default container `EXPOSE` is `8200`; the product default for the API
  listener is `8200`. **This module defaults the host-facing API port to
  `4200`** (operator preference) and maps it to the in-container listener
  port via the Quadlet `PublishPort`.
- Image entrypoint: `bvault server --config /etc/bvault/config.hcl`. The
  image refuses to start with the bundled sample config unmodified, so the
  module MUST always write a real config before starting the service.

From `config/single-node.hcl` and `config/ha-cluster.hcl` (HCL schema):

- `storage "hiqlite" { … }` block with: `data_dir`, `node_id`, `secret_raft`,
  `secret_api`. HA additionally sets `listen_addr_api`, `listen_addr_raft`
  (host-only — hiqlite appends the port from `nodes`), `port_api`, `port_raft`,
  and `nodes = [ "id:raft_host:raft_port:api_host:api_port", … ]`. TLS on
  Raft/API channels is on by default with auto-generated certs (post-quantum
  X25519MLKEM768); custom certs go under `tls_raft_*` / `tls_api_*`; can be
  disabled with `tls_raft_disable` / `tls_api_disable` (not recommended).
- `listener "tcp" { address, tls_disable, tls_cert_file, tls_key_file }` —
  API listener for clients. In HA, address typically `0.0.0.0:8300`; in
  single-node, `0.0.0.0:8200`. The module exposes `address` as a parameter
  but defaults the *host* publish port to `4200`.
- Top-level: `api_addr`, `log_level`, `pid_file`.

The module's HCL template will reproduce exactly these blocks from
parameters; nothing extra, nothing renamed.

---

## 3. Image identity & registry

Defaults (all overridable):

| Parameter        | Default                | Notes                                     |
|------------------|------------------------|-------------------------------------------|
| `registry`       | `docker.io`            | Hostname only, no path.                   |
| `image_account`  | `''` (empty)           | Optional path prefix / org / account.     |
| `image_name`     | `bastionvault`         | Fixed by convention; overridable.         |
| `image_tag`      | `0.3.2`                | Pinned start tag; bump per release.       |

Composition rule (in `init.pp`):
```
$image_ref = $image_account ? {
  ''      => "${registry}/${image_name}:${image_tag}",
  default => "${registry}/${image_account}/${image_name}:${image_tag}",
}
```
This must be exercised by rspec for both branches.

---

## 4. Supported OS

- `RedHat`-family **9** and **10** (Rocky, Alma, RHEL).
- `metadata.json` `operatingsystem_support` populated accordingly.
- Compile-time `fail()` for anything else; explicit, no silent fallbacks.
- cgroups v2 is the default unified hierarchy on both — no v1 fallback path.

---

## 5. Module layout

```
manifests/
  init.pp        # entrypoint, params, orchestration, $image_ref
  install.pp     # podman + helpers (slirp4netns/pasta, policycoreutils-python-utils)
  user.pp        # non-root user/group, linger, subuid/subgid, XDG dirs
  selinux.pp    # fcontext for $data_dir + $config_dir, restorecon
  config.pp      # config.hcl from template + TLS material placement
  cgroups.pp     # user slice drop-in (MemoryMax/CPUQuota/TasksMax/IOWeight)
  service.pp    # Quadlet .container unit, daemon-reload, start
templates/
  config.hcl.epp        # renders single-node or HA from $cluster
  bastionvault.container.epp
  slice.conf.epp
files/
  health.sh            # optional health probe script
data/
  common.yaml          # Hiera defaults
docs/
  specs.md             # this document
spec/
  classes/             # rspec-puppet unit tests
  acceptance/          # litmus tests
```

Class containment / order:
```
Class[bastionvault::install]
  -> Class[bastionvault::user]
  -> Class[bastionvault::selinux]
  -> Class[bastionvault::config]
  -> Class[bastionvault::cgroups]
  -> Class[bastionvault::service]
```

---

## 6. Parameter surface (`class bastionvault`)

```puppet
class bastionvault (
  # --- image ---
  String[1]                   $registry        = 'docker.io',
  String                      $image_account   = '',          # may be empty
  String[1]                   $image_name      = 'bastionvault',
  String[1]                   $image_tag       = '0.3.2',

  # --- listener ---
  Stdlib::Port                $listen_port     = 4200,         # host publish
  Stdlib::Port                $container_port  = 8200,         # in-container API
  Stdlib::IP::Address         $listen_address  = '0.0.0.0',
  Boolean                     $tls_disable     = false,

  # --- paths (host) ---
  Stdlib::Absolutepath        $data_dir        = '/srv/application-data/bastionvault',
  Stdlib::Absolutepath        $config_dir      = '/srv/application-config/bastionvault',
  Stdlib::Absolutepath        $tls_dir         = '/srv/application-config/bastionvault/tls',
  Stdlib::Absolutepath        $log_dir         = '/srv/application-logs/bastionvault',
  Stdlib::Absolutepath        $backup_dir      = '/srv/application-data/bastionvault/backups',

  # --- TLS material (operator-supplied) ---
  # Listener cert/key. Precedence: *_content > *_base64 > *_source > self-signed.
  Optional[String]            $tls_cert_source  = undef,        # puppet:/// or file path
  Optional[String]            $tls_cert_content = undef,        # literal PEM
  Optional[String]            $tls_cert_base64  = undef,        # base64-encoded PEM
  Optional[String]            $tls_key_source   = undef,
  Optional[Sensitive[String]] $tls_key_content  = undef,
  Optional[Variant[Sensitive[String], String]] $tls_key_base64 = undef,
  Boolean                     $tls_self_signed  = true,         # generate via openssl as fallback

  # --- user / runtime ---
  String[1]                   $user            = 'bastionvault',
  String[1]                   $group           = 'bastionvault',
  Optional[Integer]           $uid             = undef,        # let useradd allocate by default
  Optional[Integer]           $gid             = undef,

  # --- cgroups limits ---
  String[1]                   $memory_max      = '2G',
  String[1]                   $cpu_quota       = '200%',
  Integer                     $tasks_max       = 4096,
  Integer                     $io_weight       = 100,

  # --- logging ---
  Enum['trace','debug','info','warn','error'] $log_level = 'info',

  # --- cluster ---
  Enum['single','ha']         $mode            = 'single',
  Integer[1,255]              $node_id         = 1,
  Sensitive[String[1]]        $secret_raft     = Sensitive('CHANGE_ME_RAFT'),
  Sensitive[String[1]]        $secret_api      = Sensitive('CHANGE_ME_API_'),

  # HA-only (validated when $mode == 'ha')
  Optional[Stdlib::Host]      $raft_listen_addr = undef,       # e.g. '0.0.0.0'
  Optional[Stdlib::Port]      $raft_port        = 8210,
  Optional[Stdlib::Port]      $internal_api_port= 8220,        # hiqlite API
  Optional[Array[Struct[{
    id        => Integer[1,255],
    raft_host => Stdlib::Host,
    raft_port => Stdlib::Port,
    api_host  => Stdlib::Host,
    api_port  => Stdlib::Port,
  }]]]                        $nodes           = undef,

  # HA TLS toggles (mirrors hiqlite block)
  Boolean                     $cluster_tls_raft_disable = false,
  Boolean                     $cluster_tls_api_disable  = false,
  # In-container path overrides (rarely needed — only when you bring your own mount).
  Optional[Stdlib::Absolutepath] $cluster_tls_raft_cert = undef,
  Optional[Stdlib::Absolutepath] $cluster_tls_raft_key  = undef,
  Optional[Stdlib::Absolutepath] $cluster_tls_api_cert  = undef,
  Optional[Stdlib::Absolutepath] $cluster_tls_api_key   = undef,
  # PEM / base64 cert+key — module writes them under $tls_dir and points
  # config.hcl at /etc/bvault/tls/{raft,cluster-api}.{crt,key} automatically.
  Optional[String]            $cluster_tls_raft_cert_content = undef,
  Optional[String]            $cluster_tls_raft_cert_base64  = undef,
  Optional[Sensitive[String]] $cluster_tls_raft_key_content  = undef,
  Optional[Variant[Sensitive[String], String]] $cluster_tls_raft_key_base64 = undef,
  Optional[String]            $cluster_tls_api_cert_content  = undef,
  Optional[String]            $cluster_tls_api_cert_base64   = undef,
  Optional[Sensitive[String]] $cluster_tls_api_key_content   = undef,
  Optional[Variant[Sensitive[String], String]] $cluster_tls_api_key_base64  = undef,

  # --- host CA trust ---
  Boolean                     $mount_host_ca_bundle = true,    # bind-mount host CA bundle into container
  Optional[Stdlib::Absolutepath] $host_ca_bundle_path = undef, # auto-detect when undef
  # Extra CAs installed into /etc/pki/ca-trust/source/anchors/ and picked up
  # by `update-ca-trust extract`. Service is restarted on bundle change.
  Hash[String[1], Struct[{
    Optional['content'] => String,
    Optional['base64']  => String,
    Optional['source']  => String,
  }]]                         $extra_ca_certs = {},

  # --- top-level config ---
  Optional[Stdlib::HTTPSUrl]  $api_addr        = undef,        # rendered as https://<host>:<listen_port>
  Stdlib::Absolutepath        $pid_file        = '/var/run/bvault.pid',

  # --- toggles ---
  Boolean                     $manage_selinux  = true,
  Boolean                     $manage_firewall = false,
) { … }
```

Validation rules:
- `$mode == 'ha'` requires `$nodes` non-empty AND `$node_id` present in
  `$nodes[*].id`. Otherwise `fail()` at compile.
- `$image_account` may be empty; if set, must not contain leading/trailing
  slashes (regex check).
- `$listen_port < 1024` triggers a warning; document the
  `net.ipv4.ip_unprivileged_port_start` workaround. Default `4200` avoids
  this entirely.

---

## 7. Configuration rendering (`templates/config.hcl.epp`)

The template emits one of two shapes, driven by `$mode`. It mirrors the
HCL in `../BastionVault/config/{single-node,ha-cluster}.hcl` exactly — same
keys, same order, same quoting.

**single**:
```hcl
storage "hiqlite" {
  data_dir    = "<%= $data_dir %>"
  node_id     = <%= $node_id %>
  secret_raft = "<%= $secret_raft.unwrap %>"
  secret_api  = "<%= $secret_api.unwrap %>"
}

listener "tcp" {
  address       = "<%= $listen_address %>:<%= $container_port %>"
  tls_disable   = <%= $tls_disable %>
  tls_cert_file = "<%= $tls_dir %>/server.crt"
  tls_key_file  = "<%= $tls_dir %>/server.key"
}

api_addr  = "<%= $api_addr_effective %>"
log_level = "<%= $log_level %>"
pid_file  = "<%= $pid_file %>"
```

**ha** adds `listen_addr_api`, `listen_addr_raft` (host-only), `port_api`,
`port_raft`, `nodes`, and the optional TLS toggles inside the
`storage "hiqlite"` block, exactly as in `ha-cluster.hcl`.

The file is written `0640`, owner `$user:$group`, and notifies
`Service[bastionvault]` (i.e. the Quadlet unit).

---

## 8. Quadlet unit (`templates/bastionvault.container.epp`)

Located at `/home/$user/.config/containers/systemd/bastionvault.container`
(or `/var/lib/$user/.config/containers/systemd/...` if `$user` home is
under `/var/lib`). Generated keys:

```
[Unit]
Description=BastionVault server
Wants=network-online.target
After=network-online.target

[Container]
Image=<%= $image_ref %>
ContainerName=bastionvault
PublishPort=<%= $listen_port %>:<%= $container_port %>
# HA cluster ports (only when $mode == 'ha'):
# PublishPort=<raft_port>:<raft_port>
# PublishPort=<internal_api_port>:<internal_api_port>
Volume=<%= $config_dir %>/config.hcl:/etc/bvault/config.hcl:ro,Z
Volume=<%= $tls_dir %>:/etc/bvault/tls:ro,Z
Volume=<%= $data_dir %>:/var/lib/bvault/data:Z
Volume=<%= $backup_dir %>:/backups:Z
Environment=RUST_LOG=<%= $log_level %>
HealthCmd=/usr/local/bin/bvault status || exit 1
HealthInterval=30s
HealthRetries=3

[Service]
Restart=on-failure
RestartSec=5
Slice=user-<%= $uid %>.slice

[Install]
WantedBy=default.target
```

`systemctl --user daemon-reload` is fired on template change; the service
itself is `ensure => running, enable => true` via the `puppet/systemd`
module's user-instance support, or an explicit guarded `exec`.

---

## 9. Non-root user & rootless plumbing

- `user { $user: managehome => true, shell => '/sbin/nologin', system => true }`
  with home that owns `~/.config/containers/systemd/`.
- `loginctl enable-linger $user` via `exec` with
  `unless => "loginctl show-user $user | grep -q 'Linger=yes'"`.
- subuid/subgid: rely on `useradd` defaults on EL9/10; assert presence with
  a unit test reading `/etc/subuid` (acceptance-time check).
- Pre-create `$data_dir`, `$config_dir`, `$tls_dir` with `0750`, owner
  `$user:$group`. The container's UID 65532 reaches them via the user
  namespace map — no host-side chown to 65532 needed for rootless.
- The shared `/srv/application-{config,data,logs}` roots are owned by the
  `baseapp` module as `root:root 0755` (world-traversable) so `$user` can
  traverse into its own `0750` subdir. `baseapp` is `contain`ed and ordered
  ahead of `bastionvault::user`. Do **not** let any app module re-own these
  roots as `<app>:<app> 0750` — that locks every *other* app user out of its
  own subdir (`statfs: permission denied` at container start).
- `XDG_RUNTIME_DIR=/run/user/<uid>` exported for any `podman` exec resources.

---

## 10. SELinux

- Stay `Enforcing`. No `setenforce 0`, ever.
- `selinux::fcontext`:
  - `${data_dir}(/.*)?`   → `container_file_t`
  - `${config_dir}(/.*)?` → `container_file_t`
  - `${tls_dir}(/.*)?`    → `container_file_t`
- `selinux::exec_restorecon` on each.
- Volume mount flags use `:Z` (private label per container).
- Document any boolean toggles that turn out to be needed (e.g. for mlock-
  style memory locking) — add them only if a real AVC denial proves the
  need.

---

## 11. cgroups v2 limits

Drop-in: `/etc/systemd/system/user-<uid>.slice.d/50-bastionvault.conf`:

```
[Slice]
MemoryMax=<%= $memory_max %>
CPUQuota=<%= $cpu_quota %>
TasksMax=<%= $tasks_max %>
IOWeight=<%= $io_weight %>
```

Triggers `systemctl daemon-reload` (system instance) on change.
Verified by reading `systemctl show user-<uid>.slice -p MemoryMax` in
acceptance tests.

---

## 12. Initialization & unseal — explicitly out of scope

The module brings the service to *running but uninitialized*. From there,
an operator runs (manually, on one node):

```
bvault operator init             # produces unseal keys + root token
bvault operator unseal …         # quorum of keys
```

Reasons: unseal material must never live in Puppet code, Hiera, or the
Puppet report stream. The module:

- Does not template, store, or transmit unseal keys or the root token.
- Does not auto-run `init`.
- Documents the manual procedure in `README.md` with a pointer here.

A future, separate module (`bastionvault::client` / `_init`) may automate
init via an external KMS-backed seal; that is a different design.

---

## 13. Cluster awareness

- `$mode = 'ha'` flips the template branch and adds the hiqlite Raft/API
  ports to the Quadlet `PublishPort` list.
- `$nodes` is an array of structs (see §6), rendered exactly into the
  hiqlite `nodes = [ "id:raft_host:raft_port:api_host:api_port", … ]` form.
- `$secret_raft` and `$secret_api` are `Sensitive` — never logged, never
  echoed in reports. They MUST be the same on every node; the operator is
  responsible for delivering them via Hiera eyaml or an external secret
  store. A compile-time `warning()` fires if they still equal the default
  `CHANGE_ME_*` placeholders.
- TLS on cluster channels: defaults to on (matches BastionVault default of
  auto-generated PQ certs). The operator may supply custom cert+key for
  Raft and the hiqlite internal API in any of three forms:
  - `cluster_tls_{raft,api}_cert_content` / `_key_content` — literal PEM,
  - `cluster_tls_{raft,api}_cert_base64`  / `_key_base64`  — base64 PEM
    (decoded on the agent; convenient for eyaml-encrypted blobs), or
  - `cluster_tls_{raft,api}_{cert,key}`  — explicit in-container path
    (only if you mount the material in yourself).
  When content/base64 is provided the module writes the file under
  `$tls_dir` and renders `config.hcl` to point at
  `/etc/bvault/tls/{raft,cluster-api}.{crt,key}` automatically.
- Host CA trust: when `mount_host_ca_bundle` is true (default) the host's
  `update-ca-trust`-managed bundle is bind-mounted read-only into the
  container at both the EL canonical path
  (`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`) and the
  Debian-style symlink path (`/etc/ssl/certs/ca-certificates.crt`), so
  corporate root CAs added on the host are trusted inside the container
  without any extra plumbing.

---

## 14. Hiera shape (example)

`data/common.yaml` (defaults only; secrets in eyaml):
```yaml
bastionvault::registry: 'docker.io'
bastionvault::image_account: ''
bastionvault::image_tag: '0.3.2'
bastionvault::listen_port: 4200
bastionvault::mode: 'single'
```

Per-node HA override (`data/nodes/bv1.example.com.yaml`):
```yaml
bastionvault::mode: 'ha'
bastionvault::node_id: 1
bastionvault::nodes:
  - { id: 1, raft_host: 10.0.0.11, raft_port: 8210, api_host: 10.0.0.11, api_port: 8220 }
  - { id: 2, raft_host: 10.0.0.12, raft_port: 8210, api_host: 10.0.0.12, api_port: 8220 }
  - { id: 3, raft_host: 10.0.0.13, raft_port: 8210, api_host: 10.0.0.13, api_port: 8220 }
```

---

## 15. Test plan

### 15.1 Static
- `puppet-lint` (no exclusions), `puppet parser validate`, `metadata-json-lint`.
- `rubocop` on `spec/`.

### 15.2 Unit — rspec-puppet (`spec/classes/`)
For each class, on EL9 and EL10 facts via `rspec-puppet-facts`:
- **image_ref composition**: empty `$image_account` →
  `docker.io/bastionvault:0.3.2`; non-empty → includes account segment.
- **port default**: Quadlet renders `PublishPort=4200:8200`.
- **mode=single**: config.hcl contains `storage "hiqlite"` with no `nodes`.
- **mode=ha**: config.hcl contains host-only `listen_addr_api` /
  `listen_addr_raft`, separate `port_api` / `port_raft`, and `nodes = [ … ]`
  lines matching the input array.
- **HA validation**: `$mode='ha'` without `$nodes` → compile failure;
  `$node_id` not in `$nodes[*].id` → compile failure.
- **secrets**: `Sensitive` values never appear in resource titles or
  parameters that get reported (assert on resource catalog).
- **placeholder warning**: default `CHANGE_ME_*` triggers a `warning()`.
- **selinux fcontext** present for all three host paths.
- **cgroups drop-in** has expected keys.
- **rejects non-EL9/10**: `operatingsystem => Ubuntu` → compile failure.

### 15.3 Acceptance — Litmus (`spec/acceptance/`)
Targets: `rockylinux-9`, `almalinux-9`, `rockylinux-10` (or whichever
EL10 image is current).

Common assertions after `apply_manifest` (run twice; second run = 0
changes):
- User `bastionvault` exists; `loginctl show-user bastionvault` reports
  `Linger=yes`.
- `sudo -iu bastionvault env XDG_RUNTIME_DIR=/run/user/$(id -u bastionvault) systemctl --user is-active bastionvault.service` → `active`.
- `ss -ltn | grep ':4200'` shows the listener on the host.
- `curl -sk https://127.0.0.1:4200/v1/sys/health` returns a JSON body
  whose `initialized` field is `false` (proves the module brought it up
  but did NOT initialize — required by §12).
- `ls -Z $data_dir` shows `container_file_t`.
- `getenforce` = `Enforcing`; `ausearch -m AVC -ts recent` empty.
- `systemctl show user-$(id -u bastionvault).slice -p MemoryMax` matches
  the parameter value.

Mode-specific:
- **Single-node**: above is sufficient.
- **HA**: 3-VM matrix; after all three are up, `bvault operator
  members` (run once, manually in the test) lists three nodes — or, if
  that requires init, assert instead that each node logs Raft peer
  discovery for the other two within 60 s of start. (Init/unseal stays
  out of automated flow per §12.)

### 15.4 Manual smoke
- Reboot host → service comes back without interactive login.
- Bump `image_tag`, re-run Puppet → exactly one container restart, no
  config churn.
- Flip `mode` single → ha → single → ha; ensure config diffs are clean.

---

## 16. CI

- GitHub Actions, two jobs:
  1. **lint+unit**: `bundle exec rake validate lint spec` on every push.
  2. **acceptance**: Litmus with `provision::docker` for EL9/EL10 on PRs
     to `main`. Cache bundler.
- `metadata.json` `operatingsystem_support` populated for EL9 and EL10
  before the first acceptance run.

---

## 17. Deliverables / order of work

1. `metadata.json`: deps (`puppetlabs/stdlib`, `puppet/selinux`,
   `puppet/systemd`, optionally `puppet/podman`), OS support EL9+EL10.
2. Class skeletons + parameter surface from §6 with rspec stubs that
   compile on both OSes.
3. `install` + `user` classes; acceptance test that linger + user
   converge idempotently.
4. `selinux` + `config` (single-node first); rspec for HCL rendering.
5. `cgroups` drop-in + verification test.
6. `service` (Quadlet); first end-to-end green acceptance run.
7. HA branch in `config.hcl.epp` + `nodes` rendering + 3-node Litmus
   matrix.
8. README with the manual init/unseal procedure cross-referenced to §12.
9. Tag `0.2.0` once §15.2 and §15.3 single-node pass; `0.3.0` after HA.

---

## 18. Open items

- Confirm exact EL10 image name in the Litmus provisioner (Rocky 10 vs
  Alma 10 availability in the CI runner pool).
- Decide whether `puppet/podman` is pulled in for image management or we
  stick to plain `exec`/Quadlet (current bias: Quadlet only, no extra dep).
- Decide whether a default `firewalld` rule for `$listen_port` is worth
  shipping behind `$manage_firewall = true`.
- Confirm BastionVault's exact health-check command inside the distroless
  image (`bvault status` is a placeholder until verified against the
  binary's CLI surface).
