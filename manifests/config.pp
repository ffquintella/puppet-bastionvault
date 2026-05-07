# @summary Render config.hcl and place TLS material.
#
# @api private
class bastionvault::config {
  $user       = $bastionvault::user
  $group      = $bastionvault::group
  $config_dir = $bastionvault::config_dir
  $tls_dir    = $bastionvault::tls_dir

  file { "${config_dir}/config.hcl":
    ensure    => file,
    owner     => $user,
    group     => $group,
    mode      => '0640',
    content   => epp('bastionvault/config.hcl.epp'),
    show_diff => false,
  }

  if $bastionvault::tls_cert_source {
    file { "${tls_dir}/server.crt":
      ensure => file,
      owner  => $user,
      group  => $group,
      mode   => '0644',
      source => $bastionvault::tls_cert_source,
    }
  }

  if $bastionvault::tls_key_content {
    file { "${tls_dir}/server.key":
      ensure    => file,
      owner     => $user,
      group     => $group,
      mode      => '0600',
      content   => $bastionvault::tls_key_content,
      show_diff => false,
    }
  }
}
