# @summary Install and run BastionVault server rootlessly via Podman Quadlet.
#
# Orchestrates the install -> user -> selinux -> config -> cgroups -> service
# chain. See docs/specs.md for the full design. Initialization and unseal
# are intentionally NOT performed by this module; the operator runs
# `bvault operator init` / `unseal` interactively after first start.
#
# @param registry        OCI registry hostname (no path component).
# @param image_account   Optional account/org path segment. Empty means none.
# @param image_name      Image name. Defaults to `bastionvault`.
# @param image_tag       Image tag (pinned).
# @param listen_port     Host-side TCP port published for the API listener.
# @param container_port  In-container API listener port.
# @param listen_address  Bind address inside the container.
# @param tls_disable     Disable TLS on the API listener (NOT recommended).
# @param network_mode    Container network backend. `host` (default) shares the
#   host network namespace: there is no pasta/slirp4netns user-mode translation
#   layer, so the passt flow-table socket leak that exhausts the ephemeral port
#   range under long-lived peer connections (HA Raft/hiqlite) cannot occur, and
#   the server reaches host-local services such as ferrogate directly over
#   loopback. With `host` the listener binds `listen_port` on the host directly
#   and no `PublishPort` mapping is emitted. `pasta` / `slirp4netns` select the
#   legacy rootless user-mode network stack with `PublishPort` mappings — only
#   appropriate for short-lived connection patterns or when host-namespace
#   sharing is unacceptable.
# @param data_dir        Host path for persistent data.
# @param config_dir      Host path for the rendered config.hcl.
# @param tls_dir         Host path for TLS material.
# @param log_dir         Host path bind-mounted into the container at /var/log/bvault.
# @param backup_dir      Host path bind-mounted into the container at /backups.
# @param tls_cert_source Optional Puppet `source` URI for the TLS cert file.
# @param tls_cert_content Optional literal PEM content for the TLS cert file.
# @param tls_cert_base64 Optional base64-encoded PEM cert. Decoded on the
#   agent. Convenient when shipping the cert through Hiera/eyaml as a
#   single line. Ignored if `tls_cert_content` or `tls_cert_source` is set.
# @param tls_key_source Optional Puppet `source` URI for the TLS key file.
# @param tls_key_content Optional Sensitive PEM content for the TLS key file.
# @param tls_key_base64 Optional Sensitive base64-encoded PEM key. Decoded on
#   the agent. Ignored if `tls_key_content` or `tls_key_source` is set.
# @param tls_self_signed When true and no cert/key is supplied (and TLS is not
#   disabled), generate a self-signed cert+key on the host the first time the
#   module runs. NOT for production — use a real CA-issued cert in prod.
# @param tls_self_signed_cn CN for the self-signed cert. Defaults to the FQDN.
# @param tls_self_signed_san Array of SAN entries (`DNS:` or `IP:` prefixed)
#   for the self-signed cert. Defaults to DNS:<fqdn>, DNS:<hostname>, plus the
#   primary IPv4 if known.
# @param tls_self_signed_days Validity period in days for the self-signed cert.
# @param user            Non-root system user the container runs under.
# @param group           Group for $user.
# @param uid             Optional fixed UID; otherwise allocated by useradd.
# @param gid             Optional fixed GID.
# @param subid_start     First subordinate UID/GID for the rootless namespace.
# @param subid_count     Size of the subordinate UID/GID range (>=65536).
# @param container_uid   UID the bvault process runs as inside the image.
# @param container_gid   GID the bvault process runs as inside the image.
# @param memory_max      systemd MemoryMax for the user slice drop-in.
# @param cpu_quota       systemd CPUQuota for the user slice drop-in.
# @param tasks_max       systemd TasksMax for the user slice drop-in.
# @param io_weight       systemd IOWeight for the user slice drop-in.
# @param log_level       BastionVault log level. A plain level (e.g. 'info') or a
#                        RUST_LOG-style directive list with per-target filters
#                        (e.g. 'info,hiqlite=warn').
# @param log_to_stderr   Mirror operations/security logs to stderr in addition to the on-disk files.
# @param log_rotate_size_mb Per-file rotation threshold in MiB. 0 = use server default (100).
# @param log_rotate_keep    Number of rotated copies kept per stream. 0 = use server default (5).
# @param mode            'single' or 'ha'.
# @param node_id         hiqlite Raft node id (must be in $nodes when ha).
# @param secret_raft     Sensitive shared Raft secret (HA: same on all nodes).
# @param secret_api      Sensitive shared internal-API secret.
# @param raft_listen_addr        HA: bind address for Raft.
# @param raft_port               HA: Raft port.
# @param internal_api_port       HA: hiqlite internal API port.
# @param nodes                   HA: full peer list.
# @param cluster_tls_raft_disable Disable TLS on the Raft channel.
# @param cluster_tls_api_disable  Disable TLS on the hiqlite internal API.
# @param cluster_tls_raft_no_verify Skip peer certificate verification on the
#   Raft channel (`tls_raft_no_verify` in config.hcl). Useful when peers use
#   self-signed certs whose CA isn't yet distributed.
# @param cluster_tls_api_no_verify  Skip peer certificate verification on the
#   hiqlite internal API (`tls_api_no_verify` in config.hcl).
# @param cluster_tls_raft_cert    Optional custom cert path inside the container.
#   Set this only when you bring your own mount; if you supply cert *content*
#   via the parameters below the module writes the file for you and points
#   the config at the in-container default path automatically.
# @param cluster_tls_raft_key     Optional custom key path inside the container.
# @param cluster_tls_api_cert     Optional custom cert path inside the container.
# @param cluster_tls_api_key      Optional custom key path inside the container.
# @param cluster_tls_raft_cert_content Optional literal PEM for the Raft cert.
# @param cluster_tls_raft_cert_base64  Optional base64-encoded PEM Raft cert.
# @param cluster_tls_raft_key_content  Optional Sensitive PEM for the Raft key.
# @param cluster_tls_raft_key_base64   Optional Sensitive base64-encoded Raft key.
# @param cluster_tls_api_cert_content  Optional literal PEM for the hiqlite API cert.
# @param cluster_tls_api_cert_base64   Optional base64-encoded PEM hiqlite API cert.
# @param cluster_tls_api_key_content   Optional Sensitive PEM for the hiqlite API key.
# @param cluster_tls_api_key_base64    Optional Sensitive base64-encoded hiqlite API key.
# @param api_addr        Public api_addr URL. Auto-derived if undef.
# @param pid_file        Path used by the binary for its pidfile.
# @param plugin_runtime_dir In-container directory the process-plugin runtime
#   stages plugin executables in before spawning them. The module writes it to
#   both config.hcl (`plugin_runtime_dir`) and the Quadlet unit as the
#   `BV_PLUGIN_RUNTIME_DIR` environment variable; the env var takes precedence
#   and is honoured even before config.hcl is parsed.
#   The OS temp dir (`/tmp`) is frequently mounted `noexec` in hardened
#   containers, which makes `execve` of a process-runtime plugin (e.g.
#   `xca-import`) fail with `EACCES`, surfacing as a generic invoke error;
#   WASM-runtime plugins (e.g. totp) never exec and are unaffected. The default
#   sits under the persistent data bind mount (`/var/lib/bvault/data`), which is
#   writable by the container's non-root uid and exec-allowed; the server
#   creates the subdir on first use. (The image's own `/var/lib/bvault` is a
#   root-owned layer the non-root uid cannot write to, so the runtime dir must
#   live on the data volume.) Set to undef to omit the key and fall back to the
#   server's OS-temp-dir default. On deployments whose data volume is mounted
#   `noexec`, override this with a path backed by a writable, exec-allowed mount.
# @param hsm_backend HSM auto-unseal backend. `undef` (default) leaves the
#   server on Shamir unseal (operator enters shares). `mock` uses the software
#   mock HSM (dev/homolog only — no hardware protection; the server refuses it
#   when BVAULT_ENV=production). `yubihsm2` uses a real YubiHSM 2 over a
#   yubihsm-connector. The official container image ships both HSM backends
#   baked in, so no special image is needed; the mock still refuses to run when
#   the environment is production.
# @param hsm_node_id Stable per-node HSM identity written into the seal record
#   and every wrap context. Defaults to the container hostname. In an HA cluster
#   backed by the *mock* it MUST be set to the SAME value on every node (see
#   $hsm_mock_state_content); with real per-node YubiHSMs each node uses its own.
# @param hsm_recovery Recovery posture recorded at init: `none` (losing every
#   cluster HSM makes the vault unrecoverable — the intended auto-unseal
#   posture) or `shamir-ceremony` (an offline recovery-share set is produced).
# @param hsm_pqc_key_cache_ttl Optional cache TTL for PQC custody keys, e.g.
#   `'60s'` / `'500ms'` / `'0'` to disable. Omitted ⇒ server default (60s).
# @param hsm_domains Optional YubiHSM domain list the objects live in. Omitted
#   ⇒ `[1]`. Mock ignores it.
# @param hsm_auth_key_id Optional override for the auth key object id (default 1).
# @param hsm_wrap_barrier_key_id Optional override for the barrier-KEK wrap key
#   object id (default 2).
# @param hsm_wrap_pqc_key_id Optional override for the PQC wrap key id (default 3).
# @param hsm_identity_key_id Optional override for the identity key id (default 4).
# @param hsm_authz_key_id Optional override for the authz key id (default 5).
# @param hsm_mock_state_path In-container path where the mock persists its
#   object store. Must live under the data volume (`/var/lib/bvault/data`) so it
#   survives restarts; when $hsm_mock_state_content is supplied the module writes
#   the file to the host path that maps here.
# @param hsm_mock_state_content Literal JSON of a provisioned mock device
#   (serial + wrap/identity/authz keys). Supply this to PIN device material —
#   required to run the mock on an HA cluster, where every node must load
#   byte-identical material (and share $hsm_node_id) so peers can unwrap the
#   replicated KEK. Provision once (`bvault server` + `bvault operator init` on
#   one node), copy the resulting mock-hsm.json here, distribute to all nodes.
#   Sensitive — never rendered in diffs. Omit for a single node to let the mock
#   self-provision on first boot.
# @param hsm_mock_state_base64 Base64-encoded form of $hsm_mock_state_content
#   (convenient via Hiera/eyaml). Ignored if $hsm_mock_state_content is set.
# @param hsm_connector YubiHSM connector URL (e.g. `http://127.0.0.1:12345`).
#   REQUIRED for `yubihsm2`. Under host networking a connector on the host's
#   loopback is reachable from the container as-is.
# @param hsm_password YubiHSM authentication password for $hsm_auth_key_id.
#   REQUIRED for `yubihsm2`. Sensitive — injected into the container via an
#   EnvironmentFile and referenced from config.hcl as `env:BASTIONVAULT_HSM_PASSWORD`,
#   never written into config.hcl in the clear.
# @param manage_selinux  Manage SELinux fcontext entries for module-owned paths.
# @param manage_firewall Open $listen_port in firewalld (off by default).
# @param mount_host_ca_bundle When true, bind-mount the host's system CA trust
#   bundle read-only into the container so bvault trusts the same CAs as the
#   host (corporate root CAs added via `update-ca-trust`, etc.).
# @param host_ca_bundle_path Override for the host CA bundle path. When undef
#   (default), the module auto-detects the canonical EL location
#   (`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`).
# @param extra_ca_certs Hash of additional CA certificates to install into the
#   host trust store (`/etc/pki/ca-trust/source/anchors/bvault-<name>.crt`).
#   `update-ca-trust extract` is run to rebuild the bundle, and the service is
#   restarted so the container picks up the new anchors. Each entry accepts
#   one of `content` (literal PEM), `base64` (base64-encoded PEM), or
#   `source` (Puppet file source URI). Useful when bvault TLS material is
#   signed by an internal CA that isn't in the system trust store yet —
#   without this, peer Raft / hiqlite API verification fails.
#
# @example
#   include bastionvault
class bastionvault (
  String[1]                                    $registry        = 'docker.io',
  String                                       $image_account   = '',
  String[1]                                    $image_name      = 'bastionvault',
  String[1]                                    $image_tag       = '0.3.2',

  Stdlib::Port                                 $listen_port     = 4200,
  Stdlib::Port                                 $container_port  = 8200,
  Stdlib::IP::Address                          $listen_address  = '0.0.0.0',
  Boolean                                      $tls_disable     = false,
  Enum['host', 'pasta', 'slirp4netns']         $network_mode    = 'host',

  Stdlib::Absolutepath                         $data_dir        = '/srv/application-data/bastionvault',
  Stdlib::Absolutepath                         $config_dir      = '/srv/application-config/bastionvault',
  Stdlib::Absolutepath                         $tls_dir         = '/srv/application-config/bastionvault/tls',
  Stdlib::Absolutepath                         $log_dir         = '/srv/application-logs/bastionvault',
  Stdlib::Absolutepath                         $backup_dir      = '/srv/application-data/bastionvault/backups',

  Optional[String]                             $tls_cert_source  = undef,
  Optional[String]                             $tls_cert_content = undef,
  Optional[String]                             $tls_cert_base64  = undef,
  Optional[String]                             $tls_key_source   = undef,
  Optional[Sensitive[String]]                  $tls_key_content  = undef,
  Optional[Variant[Sensitive[String], String]] $tls_key_base64   = undef,

  Boolean                                      $tls_self_signed      = true,
  Optional[String[1]]                          $tls_self_signed_cn   = undef,
  Optional[Array[String[1]]]                   $tls_self_signed_san  = undef,
  Integer[1]                                   $tls_self_signed_days = 825,

  # Host-side path where puppet publishes a world-readable copy of the
  # serving cert. Useful only for bare-metal `bvault` CLI installs that
  # read directly from the host filesystem. The default rootless-podman
  # deployment runs the CLI inside the container via `podman exec` (see
  # bastionvault::cli), so the host copy is invisible there and the
  # wrapper instead loads /etc/bvault/tls/server.crt — the bind-mounted
  # serving cert. Defaults to undef (no publication); set to a path to
  # opt in.
  Optional[Stdlib::Absolutepath]               $cli_trust_path       = undef,

  # Host-side directory for the bvault CLI's on-disk token helper. The
  # wrapper bind-mounts this into the container at /etc/bvault/cli-tokens
  # and sets $BVAULT_TOKEN_FILE per invoking host user, so the token
  # issued by `bvault login` survives across container restarts and
  # across podman exec invocations. The directory is created owned by
  # the container UID/GID so the in-container CLI can write to it.
  Stdlib::Absolutepath                         $cli_token_dir       = '/srv/application-config/bastionvault/cli-tokens',

  String[1]                                    $user            = 'bastionvault',
  String[1]                                    $group           = 'bastionvault',
  Optional[Integer]                            $uid             = undef,
  Optional[Integer]                            $gid             = undef,

  Integer[1000]                                $subid_start     = 1000000,
  Integer[65536]                               $subid_count     = 65536,

  Integer[0]                                   $container_uid   = 65532,
  Integer[0]                                   $container_gid   = 65532,

  String[1]                                    $memory_max      = '2G',
  String[1]                                    $cpu_quota       = '200%',
  Integer                                      $tasks_max       = 4096,
  Integer                                      $io_weight       = 100,

  Pattern[/\A([A-Za-z0-9_:.*-]+=)?(trace|debug|info|warn|error|off)(,([A-Za-z0-9_:.*-]+=)?(trace|debug|info|warn|error|off))*\z/] $log_level = 'info',
  Boolean                                      $log_to_stderr      = true,
  Integer[0]                                   $log_rotate_size_mb = 0,
  Integer[0]                                   $log_rotate_keep    = 0,

  Enum['single','ha']                          $mode            = 'single',
  Integer[1, 255]                              $node_id         = 1,
  Variant[Sensitive[String[1]], String[1]]     $secret_raft     = Sensitive('CHANGE_ME_RAFT'),
  Variant[Sensitive[String[1]], String[1]]     $secret_api      = Sensitive('CHANGE_ME_API_'),

  Stdlib::Host                                 $raft_listen_addr  = '0.0.0.0',
  Stdlib::Port                                 $raft_port         = 8210,
  Stdlib::Port                                 $internal_api_port = 8220,
  Optional[Array[Struct[{
        id        => Integer[1, 255],
        raft_host => Stdlib::Host,
        raft_port => Stdlib::Port,
        api_host  => Stdlib::Host,
        api_port  => Stdlib::Port,
  }]]]                                          $nodes           = undef,

  Boolean                                      $cluster_tls_raft_disable   = false,
  Boolean                                      $cluster_tls_api_disable    = false,
  Boolean                                      $cluster_tls_raft_no_verify = false,
  Boolean                                      $cluster_tls_api_no_verify  = false,
  Optional[Stdlib::Absolutepath]               $cluster_tls_raft_cert    = undef,
  Optional[Stdlib::Absolutepath]               $cluster_tls_raft_key     = undef,
  Optional[Stdlib::Absolutepath]               $cluster_tls_api_cert     = undef,
  Optional[Stdlib::Absolutepath]               $cluster_tls_api_key      = undef,

  Optional[String]                             $cluster_tls_raft_cert_content = undef,
  Optional[String]                             $cluster_tls_raft_cert_base64  = undef,
  Optional[Sensitive[String]]                  $cluster_tls_raft_key_content  = undef,
  Optional[Variant[Sensitive[String], String]] $cluster_tls_raft_key_base64   = undef,

  Optional[String]                             $cluster_tls_api_cert_content  = undef,
  Optional[String]                             $cluster_tls_api_cert_base64   = undef,
  Optional[Sensitive[String]]                  $cluster_tls_api_key_content   = undef,
  Optional[Variant[Sensitive[String], String]] $cluster_tls_api_key_base64    = undef,

  Optional[Stdlib::HTTPSUrl]                   $api_addr        = undef,
  Stdlib::Absolutepath                         $pid_file        = '/var/run/bvault.pid',

  Optional[Stdlib::Absolutepath]               $plugin_runtime_dir = '/var/lib/bvault/data/plugin-run',

  # ── HSM auto-unseal (BastionVault v0.24.0+; both backends baked into the stock image) ──
  Optional[Enum['mock', 'yubihsm2']]           $hsm_backend             = undef,
  Optional[String[1]]                          $hsm_node_id             = undef,
  Enum['none', 'shamir-ceremony']              $hsm_recovery            = 'none',
  Optional[String[1]]                          $hsm_pqc_key_cache_ttl   = undef,
  Optional[Array[Integer[0, 65535]]]           $hsm_domains             = undef,
  Optional[Integer[0, 65535]]                  $hsm_auth_key_id         = undef,
  Optional[Integer[0, 65535]]                  $hsm_wrap_barrier_key_id = undef,
  Optional[Integer[0, 65535]]                  $hsm_wrap_pqc_key_id     = undef,
  Optional[Integer[0, 65535]]                  $hsm_identity_key_id     = undef,
  Optional[Integer[0, 65535]]                  $hsm_authz_key_id        = undef,

  # mock backend
  Stdlib::Absolutepath                         $hsm_mock_state_path     = '/var/lib/bvault/data/mock-hsm.json',
  Optional[Variant[Sensitive[String], String]] $hsm_mock_state_content  = undef,
  Optional[Variant[Sensitive[String], String]] $hsm_mock_state_base64   = undef,

  # yubihsm2 backend
  Optional[String[1]]                          $hsm_connector           = undef,
  Optional[Variant[Sensitive[String[1]], String[1]]] $hsm_password      = undef,

  Boolean                                      $manage_selinux  = true,
  Boolean                                      $manage_firewall = false,

  Boolean                                      $mount_host_ca_bundle = true,
  Optional[Stdlib::Absolutepath]               $host_ca_bundle_path  = undef,

  Hash[String[1], Struct[{
        Optional['content'] => String,
        Optional['base64']  => String,
        Optional['source']  => String,
  }]]                                          $extra_ca_certs       = {},
) {
  # OS gate.
  if $facts['os']['family'] != 'RedHat' {
    fail("bastionvault supports RedHat-family OS only (got ${facts['os']['family']}).")
  }
  $_majver = $facts['os']['release']['major']
  unless $_majver in ['9', '10'] {
    fail("bastionvault supports EL9 and EL10 only (got major=${_majver}).")
  }

  # image_account hygiene: no leading/trailing slashes.
  if $image_account != '' and $image_account =~ /\A\/|\/\z/ {
    fail("image_account must not start or end with '/': '${image_account}'")
  }

  # Composed image reference.
  $image_ref = $image_account ? {
    ''      => "${registry}/${image_name}:${image_tag}",
    default => "${registry}/${image_account}/${image_name}:${image_tag}",
  }

  # HA validation.
  #
  # The checks below guard against the hiqlite malformed-bind bug where
  # "<listen_addr>:<port>" gets re-concatenated with the configured port on
  # restart (e.g. "host:8210:8220"). Drift between cluster-wide
  # port_api/port_raft and per-node entries is silently catastrophic.
  #
  # raft_listen_addr is the local *bind* address and is independent of the
  # membership host published in $nodes[*].raft_host/api_host. 0.0.0.0 is
  # permitted (and often required under rootless/pasta networking where the
  # FQDN does not resolve to a bindable interface inside the container);
  # only the per-node membership hosts must be routable.
  if $mode == 'ha' {
    if $nodes == undef or empty($nodes) {
      fail('bastionvault: $mode is "ha" but $nodes is empty.')
    }
    $_node_ids = $nodes.map |$n| { $n['id'] }
    unless $node_id in $_node_ids {
      fail("bastionvault: \$node_id=${node_id} not present in \$nodes ids ${_node_ids}.")
    }

    # Every node entry must agree with the cluster-wide port assignment.
    # hiqlite assumes a uniform port plan; mismatched values produce the
    # "0.0.0.0:8220:8210" malformed-bind bug on restart.
    $nodes.each |$n| {
      if $n['raft_port'] != $raft_port {
        fail("bastionvault: nodes[id=${n['id']}].raft_port=${n['raft_port']} does not match cluster \$raft_port=${raft_port}. All nodes must use the same Raft port.")
      }
      if $n['api_port'] != $internal_api_port {
        fail("bastionvault: nodes[id=${n['id']}].api_port=${n['api_port']} does not match cluster \$internal_api_port=${internal_api_port}. All nodes must use the same hiqlite API port.")
      }
      if $n['raft_host'] in ['0.0.0.0', '::', '', undef] {
        fail("bastionvault: nodes[id=${n['id']}].raft_host is not a routable host. Use the peer's FQDN.")
      }
      if $n['api_host'] in ['0.0.0.0', '::', '', undef] {
        fail("bastionvault: nodes[id=${n['id']}].api_host is not a routable host. Use the peer's FQDN.")
      }
    }
  }

  # ── HSM validation ─────────────────────────────────────────────────────
  # Fixed env var name the container reads the YubiHSM password from; config.hcl
  # references it as `env:...` and bastionvault::config writes it to hsm.env.
  $hsm_password_env = 'BASTIONVAULT_HSM_PASSWORD'

  if $hsm_backend == 'yubihsm2' {
    if $hsm_connector == undef {
      fail('bastionvault: $hsm_backend is "yubihsm2" but $hsm_connector is unset (e.g. "http://127.0.0.1:12345").')
    }
    if $hsm_password == undef {
      fail('bastionvault: $hsm_backend is "yubihsm2" but $hsm_password is unset.')
    }
  }

  if $hsm_backend == 'mock' {
    # The mock gives NO hardware protection and every node in a cluster must
    # present byte-identical device material (same wrap-barrier + bv-authz
    # keys) under a shared node_id, because the wrapped KEK blob is bound to
    # both the wrapping device's authz-key fingerprint and the node_id. Enforce
    # that operators pin the material and the id when running mock in HA.
    if $mode == 'ha' {
      if $hsm_node_id == undef {
        fail('bastionvault: mock HSM in HA requires $hsm_node_id — set the SAME value on every node (the seal record is keyed by it and it is bound into every wrap context).')
      }
      if $hsm_mock_state_content == undef and $hsm_mock_state_base64 == undef {
        fail('bastionvault: mock HSM in HA requires $hsm_mock_state_content/$hsm_mock_state_base64 — every node must load byte-identical mock device material so peers can unwrap the replicated KEK. Provision once (`bvault server` + `bvault operator init` on one node), then distribute that mock-hsm.json to all nodes.')
      }
    }
    # When pinning material, we place the file on the host path that maps into
    # the container's data volume; require the in-container path to live there.
    if ($hsm_mock_state_content != undef or $hsm_mock_state_base64 != undef)
    and $hsm_mock_state_path !~ /\A\/var\/lib\/bvault\/data\// {
      fail("bastionvault: \$hsm_mock_state_path must be under /var/lib/bvault/data/ when supplying \$hsm_mock_state_content (so the file lands in the mounted data volume); got '${hsm_mock_state_path}'.")
    }
  }

  # Normalize secrets to Sensitive. Operators may pass either a Sensitive
  # value (preferred — eyaml decrypts to Sensitive automatically) or a plain
  # String. Downstream code and templates always read the *_sensitive vars.
  $secret_raft_sensitive = $secret_raft ? {
    Sensitive => $secret_raft,
    default   => Sensitive($secret_raft),
  }
  $secret_api_sensitive = $secret_api ? {
    Sensitive => $secret_api,
    default   => Sensitive($secret_api),
  }

  # Placeholder secret warning (compile-time, no Sensitive leak).
  if $secret_raft_sensitive.unwrap == 'CHANGE_ME_RAFT' or $secret_api_sensitive.unwrap == 'CHANGE_ME_API_' {
    warning('bastionvault: Raft/API secrets are still set to placeholder values. Set them via Hiera eyaml before production use.')
  }

  # ---------------------------------------------------------------------------
  # TLS material resolution.
  #
  # For each (cert, key) pair the operator can supply input in any of these
  # forms (highest precedence first):
  #   1. *_content  — literal PEM string
  #   2. *_base64   — base64-encoded PEM (decoded on the agent)
  #   3. *_source   — Puppet file `source` URI            (listener only)
  # The resolved `*_pem_effective` variables below are consumed by
  # `bastionvault::config` to materialise the files; `*_path_effective` is the
  # in-container path written into config.hcl.
  # ---------------------------------------------------------------------------

  # Listener cert/key.
  $tls_cert_pem_effective = $tls_cert_content ? {
    undef   => $tls_cert_base64 ? {
      undef   => undef,
      default => base64('decode', $tls_cert_base64),
    },
    default => $tls_cert_content,
  }
  $_tls_key_b64_unwrapped = $tls_key_base64 ? {
    undef     => undef,
    Sensitive => $tls_key_base64.unwrap,
    default   => $tls_key_base64,
  }
  $tls_key_pem_effective = $tls_key_content ? {
    undef   => $_tls_key_b64_unwrapped ? {
      undef   => undef,
      default => Sensitive(base64('decode', $_tls_key_b64_unwrapped)),
    },
    default => $tls_key_content,
  }

  # Cluster Raft cert/key.
  $cluster_tls_raft_cert_pem_effective = $cluster_tls_raft_cert_content ? {
    undef   => $cluster_tls_raft_cert_base64 ? {
      undef   => undef,
      default => base64('decode', $cluster_tls_raft_cert_base64),
    },
    default => $cluster_tls_raft_cert_content,
  }
  $_raft_key_b64_unwrapped = $cluster_tls_raft_key_base64 ? {
    undef     => undef,
    Sensitive => $cluster_tls_raft_key_base64.unwrap,
    default   => $cluster_tls_raft_key_base64,
  }
  $cluster_tls_raft_key_pem_effective = $cluster_tls_raft_key_content ? {
    undef   => $_raft_key_b64_unwrapped ? {
      undef   => undef,
      default => Sensitive(base64('decode', $_raft_key_b64_unwrapped)),
    },
    default => $cluster_tls_raft_key_content,
  }

  # Cluster hiqlite API cert/key.
  $cluster_tls_api_cert_pem_effective = $cluster_tls_api_cert_content ? {
    undef   => $cluster_tls_api_cert_base64 ? {
      undef   => undef,
      default => base64('decode', $cluster_tls_api_cert_base64),
    },
    default => $cluster_tls_api_cert_content,
  }
  $_api_key_b64_unwrapped = $cluster_tls_api_key_base64 ? {
    undef     => undef,
    Sensitive => $cluster_tls_api_key_base64.unwrap,
    default   => $cluster_tls_api_key_base64,
  }
  $cluster_tls_api_key_pem_effective = $cluster_tls_api_key_content ? {
    undef   => $_api_key_b64_unwrapped ? {
      undef   => undef,
      default => Sensitive(base64('decode', $_api_key_b64_unwrapped)),
    },
    default => $cluster_tls_api_key_content,
  }

  # In-container paths to write into config.hcl. Operator-supplied container
  # path wins; otherwise, if we have content, point at the file we will write
  # into $tls_dir (mounted at /etc/bvault/tls inside the container).
  $cluster_tls_raft_cert_path_effective = $cluster_tls_raft_cert ? {
    undef   => $cluster_tls_raft_cert_pem_effective ? {
      undef   => undef,
      default => '/etc/bvault/tls/raft.crt',
    },
    default => $cluster_tls_raft_cert,
  }
  $cluster_tls_raft_key_path_effective = $cluster_tls_raft_key ? {
    undef   => $cluster_tls_raft_key_pem_effective ? {
      undef   => undef,
      default => '/etc/bvault/tls/raft.key',
    },
    default => $cluster_tls_raft_key,
  }
  $cluster_tls_api_cert_path_effective = $cluster_tls_api_cert ? {
    undef   => $cluster_tls_api_cert_pem_effective ? {
      undef   => undef,
      default => '/etc/bvault/tls/cluster-api.crt',
    },
    default => $cluster_tls_api_cert,
  }
  $cluster_tls_api_key_path_effective = $cluster_tls_api_key ? {
    undef   => $cluster_tls_api_key_pem_effective ? {
      undef   => undef,
      default => '/etc/bvault/tls/cluster-api.key',
    },
    default => $cluster_tls_api_key,
  }

  # Effective host CA bundle path. RHEL-family canonical location is the
  # `update-ca-trust`-managed extracted bundle, which always exists when the
  # `ca-certificates` package is installed (it is in the EL base).
  $host_ca_bundle_effective = $host_ca_bundle_path ? {
    undef   => '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
    default => $host_ca_bundle_path,
  }

  # Port the in-container listener actually binds. Under host networking there
  # is no port translation, so the listener binds the canonical host-facing
  # $listen_port directly; under the user-mode stacks (pasta/slirp4netns) the
  # listener stays on $container_port and Quadlet maps $listen_port:$container_port.
  # config.hcl and the CLI wrapper both consume $service_port, so the external
  # contract ($listen_port and $api_addr) is identical across modes.
  $service_port = $network_mode ? {
    'host'  => $listen_port,
    default => $container_port,
  }

  # Effective api_addr if operator did not pin one.
  $api_addr_effective = $api_addr ? {
    undef   => "https://${facts['networking']['fqdn']}:${listen_port}",
    default => $api_addr,
  }

  # ── HSM effective values ───────────────────────────────────────────────
  # YubiHSM password → Sensitive (for the hsm.env EnvironmentFile).
  $hsm_password_sensitive = $hsm_password ? {
    undef     => undef,
    Sensitive => $hsm_password,
    default   => Sensitive($hsm_password),
  }

  # Mock device material: literal content wins, else decode base64. Kept
  # Sensitive because it holds the raw wrap/authz/identity key bytes.
  $_hsm_state_b64_unwrapped = $hsm_mock_state_base64 ? {
    undef     => undef,
    Sensitive => $hsm_mock_state_base64.unwrap,
    default   => $hsm_mock_state_base64,
  }
  $_hsm_state_content_raw = $hsm_mock_state_content ? {
    undef     => undef,
    Sensitive => $hsm_mock_state_content.unwrap,
    default   => $hsm_mock_state_content,
  }
  $hsm_mock_state_content_effective = $_hsm_state_content_raw ? {
    undef   => $_hsm_state_b64_unwrapped ? {
      undef   => undef,
      default => Sensitive(base64('decode', $_hsm_state_b64_unwrapped)),
    },
    default => Sensitive($_hsm_state_content_raw),
  }

  # Host path that maps to $hsm_mock_state_path inside the container. Only used
  # when pinning material; validated above to live under the data volume.
  $hsm_mock_state_host_path = regsubst($hsm_mock_state_path, '\A/var/lib/bvault/data', $data_dir)

  # Host path of the YubiHSM password EnvironmentFile.
  $hsm_env_file = "${config_dir}/hsm.env"

  # Effective object ids (undef ⇒ server default; a 0 value is treated as
  # "use default" server-side, so undef here simply omits the key).
  $hsm_object_ids = {
    'auth_key_id'         => $hsm_auth_key_id,
    'wrap_barrier_key_id' => $hsm_wrap_barrier_key_id,
    'wrap_pqc_key_id'     => $hsm_wrap_pqc_key_id,
    'identity_key_id'     => $hsm_identity_key_id,
    'authz_key_id'        => $hsm_authz_key_id,
  }

  # Sub-port warning (rootless cannot bind <1024 by default).
  if $listen_port < 1024 {
    warning("bastionvault: \$listen_port=${listen_port} is privileged. Rootless Podman needs net.ipv4.ip_unprivileged_port_start lowered or use a reverse proxy.")
  }

  # baseapp owns the shared /srv/application-* roots as root:root 0755, so any
  # app user can traverse into its own (app-owned) subdirectory. Including it
  # here (rather than re-declaring the roots ourselves) keeps a single owner of
  # those roots and works whether or not another app module (e.g. ferrogate)
  # also pulls baseapp in. It must run before bastionvault::user, which creates
  # the bastionvault subdirs beneath the roots.
  contain baseapp

  contain bastionvault::install
  contain bastionvault::user
  contain bastionvault::selinux
  contain bastionvault::config
  contain bastionvault::ca_trust
  contain bastionvault::cgroups
  contain bastionvault::service
  contain bastionvault::cli
  contain bastionvault::scripts

  Class['baseapp']
  -> Class['bastionvault::install']
  -> Class['bastionvault::user']
  -> Class['bastionvault::selinux']
  -> Class['bastionvault::config']
  -> Class['bastionvault::ca_trust']
  -> Class['bastionvault::cgroups']
  -> Class['bastionvault::service']
  -> Class['bastionvault::cli']
  -> Class['bastionvault::scripts']
}
