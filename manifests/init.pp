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
# @param data_dir        Host path for persistent data.
# @param config_dir      Host path for the rendered config.hcl.
# @param tls_dir         Host path for TLS material.
# @param log_dir         Host path bind-mounted into the container at /var/log/bvault.
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
# @param log_level       BastionVault log level.
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

  Stdlib::Absolutepath                         $data_dir        = '/srv/application-data/bastionvault',
  Stdlib::Absolutepath                         $config_dir      = '/srv/application-config/bastionvault',
  Stdlib::Absolutepath                         $tls_dir         = '/srv/application-config/bastionvault/tls',
  Stdlib::Absolutepath                         $log_dir         = '/srv/application-logs/bastionvault',

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

  Enum['trace','debug','info','warn','error']  $log_level       = 'info',
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

  # Effective api_addr if operator did not pin one.
  $api_addr_effective = $api_addr ? {
    undef   => "https://${facts['networking']['fqdn']}:${listen_port}",
    default => $api_addr,
  }

  # Sub-port warning (rootless cannot bind <1024 by default).
  if $listen_port < 1024 {
    warning("bastionvault: \$listen_port=${listen_port} is privileged. Rootless Podman needs net.ipv4.ip_unprivileged_port_start lowered or use a reverse proxy.")
  }

  contain bastionvault::install
  contain bastionvault::user
  contain bastionvault::selinux
  contain bastionvault::config
  contain bastionvault::ca_trust
  contain bastionvault::cgroups
  contain bastionvault::service
  contain bastionvault::cli

  Class['bastionvault::install']
  -> Class['bastionvault::user']
  -> Class['bastionvault::selinux']
  -> Class['bastionvault::config']
  -> Class['bastionvault::ca_trust']
  -> Class['bastionvault::cgroups']
  -> Class['bastionvault::service']
  -> Class['bastionvault::cli']
}
