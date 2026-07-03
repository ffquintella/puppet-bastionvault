# @summary Install and configure the standalone `bvault` CLI (client only).
#
# For hosts that talk to a remote BastionVault server but do not run one.
# Installs the upstream `bastionvault` RPM (ships /usr/bin/bvault plus
# manpage and shell completions), optionally places the server's CA
# certificate at a path the CLI trusts, and lays a thin wrapper at
# /usr/local/bin/bvault that injects the configured server address.
#
# The wrapper exists because the bvault binary does NOT read VAULT_ADDR /
# VAULT_TLS_SERVER_NAME from the environment (its help text mentions them,
# but no env binding exists) — the address must arrive as an --address
# flag. /usr/local/bin precedes /usr/bin on the default EL PATH, so the
# wrapper shadows the packaged binary transparently.
#
# Do NOT include this class on a node that also includes `bastionvault`
# (the server class): the server ships its own podman-exec wrapper at the
# same /usr/local/bin/bvault path and the catalog will fail with a
# duplicate File declaration.
#
# @param server_url URL of the BastionVault server the CLI should target
#   (e.g. `https://vault.example.com:4200`), or a bare cluster DNS name to
#   use SRV-based discovery (`_bvault._tcp.<name>`). When undef, no
#   --address is injected and the binary's default applies.
# @param manage_package Install the CLI package. Disable when the binary
#   arrives by other means (baked image, other packaging).
# @param package_name   Name of the CLI package.
# @param package_ensure Package ensure (`installed`, `latest`, or a version).
# @param package_source Optional path or URL of the RPM file. dnf installs
#   it directly and resolves dependencies; useful when no yum repo carries
#   the package.
# @param manage_repo   Manage a yumrepo pointing at a repository that
#   carries the CLI package. Requires $repo_baseurl.
# @param repo_baseurl  Base URL of the yum repository.
# @param repo_gpgkey   Optional GPG key URL for the repository.
# @param repo_gpgcheck Enable GPG verification on the repository.
# @param ca_cert_content Literal PEM content of the CA / serving cert the
#   CLI should trust when talking to the server. Precedence:
#   content > base64 > source.
# @param ca_cert_base64  Base64-encoded PEM (single Hiera-friendly line).
# @param ca_cert_source  Puppet file `source` URI for the cert.
# @param ca_cert_path Where the trust anchor is written. The default,
#   /etc/bvault/ca.pem, is also one of the CLI's native auto-discovery
#   paths, so the cert works even without the wrapper.
# @param tls_server_name Optional SNI/verification name to inject as
#   --tls-server-name, for when the connection address differs from the
#   name in the server cert's SAN.
# @param manage_wrapper Manage the /usr/local/bin wrapper. Without it the
#   operator must pass --address on every call (or export VAULT_CACERT
#   etc. themselves).
# @param wrapper_path Path of the wrapper script.
# @param binary_path  Path of the packaged bvault binary the wrapper execs.
#
# @example Point every workstation at the central vault
#   class { 'bastionvault::client':
#     server_url      => 'https://vault.example.com:4200',
#     ca_cert_base64  => lookup('vault_ca_b64'),
#   }
class bastionvault::client (
  Optional[String[1]]                          $server_url      = undef,

  Boolean                                      $manage_package  = true,
  String[1]                                    $package_name    = 'bastionvault',
  String[1]                                    $package_ensure  = 'installed',
  Optional[String[1]]                          $package_source  = undef,

  Boolean                                      $manage_repo     = false,
  Optional[Stdlib::HTTPUrl]                    $repo_baseurl    = undef,
  Optional[String[1]]                          $repo_gpgkey     = undef,
  Boolean                                      $repo_gpgcheck   = true,

  Optional[String]                             $ca_cert_content = undef,
  Optional[String]                             $ca_cert_base64  = undef,
  Optional[String]                             $ca_cert_source  = undef,
  Stdlib::Absolutepath                         $ca_cert_path    = '/etc/bvault/ca.pem',

  Optional[String[1]]                          $tls_server_name = undef,

  Boolean                                      $manage_wrapper  = true,
  Stdlib::Absolutepath                         $wrapper_path    = '/usr/local/bin/bvault',
  Stdlib::Absolutepath                         $binary_path     = '/usr/bin/bvault',
) {
  # OS gate — same support surface as the server class.
  if $facts['os']['family'] != 'RedHat' {
    fail("bastionvault::client supports RedHat-family OS only (got ${facts['os']['family']}).")
  }
  $_majver = $facts['os']['release']['major']
  unless $_majver in ['9', '10'] {
    fail("bastionvault::client supports EL9 and EL10 only (got major=${_majver}).")
  }

  if $wrapper_path == $binary_path {
    fail('bastionvault::client: $wrapper_path must differ from $binary_path (the wrapper would exec itself).')
  }

  if $manage_repo {
    if $repo_baseurl == undef {
      fail('bastionvault::client: $manage_repo is true but $repo_baseurl is unset.')
    }
    yumrepo { 'bastionvault':
      ensure   => present,
      descr    => 'BastionVault CLI',
      baseurl  => $repo_baseurl,
      enabled  => '1',
      gpgcheck => $repo_gpgcheck ? { true => '1', default => '0' },
      gpgkey   => $repo_gpgkey,
    }
  }

  if $manage_package {
    package { $package_name:
      ensure => $package_ensure,
      source => $package_source,
    }
    if $manage_repo {
      Yumrepo['bastionvault'] -> Package[$package_name]
    }
  }

  # Trust anchor resolution — content > base64 > source, mirroring the
  # server class's TLS input precedence.
  $ca_cert_pem_effective = $ca_cert_content ? {
    undef   => $ca_cert_base64 ? {
      undef   => undef,
      default => base64('decode', $ca_cert_base64),
    },
    default => $ca_cert_content,
  }

  if $ca_cert_pem_effective =~ NotUndef or $ca_cert_source =~ NotUndef {
    # Manage the conventional parent directory; a custom $ca_cert_path is
    # assumed to live somewhere that already exists.
    if dirname($ca_cert_path) == '/etc/bvault' {
      file { '/etc/bvault':
        ensure => directory,
        owner  => 'root',
        group  => 'root',
        mode   => '0755',
        before => File[$ca_cert_path],
      }
    }

    if $ca_cert_pem_effective =~ NotUndef {
      file { $ca_cert_path:
        ensure  => file,
        owner   => 'root',
        group   => 'root',
        mode    => '0644',
        content => $ca_cert_pem_effective,
      }
    } else {
      file { $ca_cert_path:
        ensure => file,
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => $ca_cert_source,
      }
    }
  }

  if $manage_wrapper {
    # Normalize optional params to plain strings before handing them to the
    # template: EPP renders manifest-computed values reliably under regent,
    # while undef (or template-local assignments) would stringify as the
    # literal word "undef" there. Empty string means "do not inject".
    $_addr_default = $server_url ? { undef => '', default => $server_url }
    $_sni_default  = $tls_server_name ? { undef => '', default => $tls_server_name }

    file { $wrapper_path:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      content => epp('bastionvault/bvault-client-wrapper.sh.epp', {
          'server_url'      => $_addr_default,
          'ca_cert_path'    => $ca_cert_path,
          'tls_server_name' => $_sni_default,
          'binary_path'     => $binary_path,
      }),
    }
    if $manage_package {
      Package[$package_name] -> File[$wrapper_path]
    }
  }
}
