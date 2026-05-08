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
# @param tls_key_source Optional Puppet `source` URI for the TLS key file.
# @param tls_key_content Optional Sensitive PEM content for the TLS key file.
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
# @param cluster_tls_raft_cert    Optional custom cert path inside the container.
# @param cluster_tls_raft_key     Optional custom key path inside the container.
# @param cluster_tls_api_cert     Optional custom cert path inside the container.
# @param cluster_tls_api_key      Optional custom key path inside the container.
# @param api_addr        Public api_addr URL. Auto-derived if undef.
# @param pid_file        Path used by the binary for its pidfile.
# @param manage_selinux  Manage SELinux fcontext entries for module-owned paths.
# @param manage_firewall Open $listen_port in firewalld (off by default).
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

  Optional[String]                             $tls_cert_source = undef,
  Optional[String]                             $tls_cert_content = undef,
  Optional[String]                             $tls_key_source  = undef,
  Optional[Sensitive[String]]                  $tls_key_content = undef,

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

  Enum['single','ha']                          $mode            = 'single',
  Integer[1, 255]                              $node_id         = 1,
  Sensitive[String[1]]                         $secret_raft     = Sensitive('CHANGE_ME_RAFT'),
  Sensitive[String[1]]                         $secret_api      = Sensitive('CHANGE_ME_API_'),

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

  Boolean                                      $cluster_tls_raft_disable = false,
  Boolean                                      $cluster_tls_api_disable  = false,
  Optional[Stdlib::Absolutepath]               $cluster_tls_raft_cert    = undef,
  Optional[Stdlib::Absolutepath]               $cluster_tls_raft_key     = undef,
  Optional[Stdlib::Absolutepath]               $cluster_tls_api_cert     = undef,
  Optional[Stdlib::Absolutepath]               $cluster_tls_api_key      = undef,

  Optional[Stdlib::HTTPSUrl]                   $api_addr        = undef,
  Stdlib::Absolutepath                         $pid_file        = '/var/run/bvault.pid',

  Boolean                                      $manage_selinux  = true,
  Boolean                                      $manage_firewall = false,
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
  if $mode == 'ha' {
    if $nodes == undef or empty($nodes) {
      fail('bastionvault: $mode is "ha" but $nodes is empty.')
    }
    $_node_ids = $nodes.map |$n| { $n['id'] }
    unless $node_id in $_node_ids {
      fail("bastionvault: \$node_id=${node_id} not present in \$nodes ids ${_node_ids}.")
    }
  }

  # Placeholder secret warning (compile-time, no Sensitive leak).
  if $secret_raft.unwrap == 'CHANGE_ME_RAFT' or $secret_api.unwrap == 'CHANGE_ME_API_' {
    warning('bastionvault: Raft/API secrets are still set to placeholder values. Set them via Hiera eyaml before production use.')
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
  contain bastionvault::cgroups
  contain bastionvault::service
  contain bastionvault::cli

  Class['bastionvault::install']
  -> Class['bastionvault::user']
  -> Class['bastionvault::selinux']
  -> Class['bastionvault::config']
  -> Class['bastionvault::cgroups']
  -> Class['bastionvault::service']
  -> Class['bastionvault::cli']
}
