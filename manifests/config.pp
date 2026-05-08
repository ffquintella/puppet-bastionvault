# @summary Render config.hcl and place TLS material.
#
# TLS resolution (when $tls_disable = false):
#   1. If $tls_cert_content / $tls_cert_source is set, use that for the cert.
#   2. If $tls_key_content / $tls_key_source is set, use that for the key.
#   3. Otherwise, if $tls_self_signed is true, generate a self-signed pair
#      via openssl on first run (idempotent — `creates` guards regeneration).
#   4. If TLS is enabled and none of the above provide a cert+key, fail.
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

  if !$bastionvault::tls_disable {
    $_cert_path = "${tls_dir}/server.crt"
    $_key_path  = "${tls_dir}/server.key"

    $_cert_provided = $bastionvault::tls_cert_content != undef or $bastionvault::tls_cert_source != undef
    $_key_provided  = $bastionvault::tls_key_content  != undef or $bastionvault::tls_key_source  != undef

    if !($_cert_provided and $_key_provided) and !$bastionvault::tls_self_signed {
      fail('bastionvault: TLS is enabled but no cert/key was provided and tls_self_signed is false. Either set tls_disable=true, supply tls_cert_*/tls_key_*, or enable tls_self_signed.')
    }

    # 1. Operator-supplied cert.
    if $bastionvault::tls_cert_content != undef {
      file { $_cert_path:
        ensure  => file,
        owner   => $user,
        group   => $group,
        mode    => '0644',
        content => $bastionvault::tls_cert_content,
      }
    } elsif $bastionvault::tls_cert_source != undef {
      file { $_cert_path:
        ensure => file,
        owner  => $user,
        group  => $group,
        mode   => '0644',
        source => $bastionvault::tls_cert_source,
      }
    }

    # 2. Operator-supplied key.
    if $bastionvault::tls_key_content != undef {
      file { $_key_path:
        ensure    => file,
        owner     => $user,
        group     => $group,
        mode      => '0600',
        content   => $bastionvault::tls_key_content,
        show_diff => false,
      }
    } elsif $bastionvault::tls_key_source != undef {
      file { $_key_path:
        ensure    => file,
        owner     => $user,
        group     => $group,
        mode      => '0600',
        source    => $bastionvault::tls_key_source,
        show_diff => false,
      }
    }

    # 3. Self-signed fallback. Only generates files that the operator did NOT
    #    supply, so a partial override (e.g. only a custom cert) still works.
    if $bastionvault::tls_self_signed and !($_cert_provided and $_key_provided) {
      $_cn = $bastionvault::tls_self_signed_cn ? {
        undef   => $facts['networking']['fqdn'],
        default => $bastionvault::tls_self_signed_cn,
      }

      $_default_san = [
        "DNS:${facts['networking']['fqdn']}",
        "DNS:${facts['networking']['hostname']}",
      ] + ($facts['networking']['ip'] ? {
          undef   => [],
          default => ["IP:${facts['networking']['ip']}"],
      })

      $_san_list = $bastionvault::tls_self_signed_san ? {
        undef   => $_default_san,
        default => $bastionvault::tls_self_signed_san,
      }
      $_san_str = $_san_list.unique.join(',')

      # Generate both files atomically. `creates` on the cert path makes this
      # idempotent — once the cert exists, the exec is skipped on subsequent
      # runs. If the operator later supplies a real cert via parameters, the
      # File resources above will replace the generated one.
      exec { 'bastionvault-self-signed-cert':
        command => [
          '/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
          '-days', String($bastionvault::tls_self_signed_days),
          '-keyout', $_key_path,
          '-out', $_cert_path,
          '-subj', "/CN=${_cn}",
          '-addext', "subjectAltName=${_san_str}",
        ],
        creates => $_cert_path,
        require => [
          Package['openssl'],
          File[$tls_dir],
        ],
      }

      # Own/perm the generated files. Conditional on the operator NOT having
      # supplied that half — otherwise the File resource above already manages
      # it and a duplicate declaration would fail compilation.
      if !$_cert_provided {
        file { $_cert_path:
          ensure  => file,
          owner   => $user,
          group   => $group,
          mode    => '0644',
          require => Exec['bastionvault-self-signed-cert'],
        }
      }
      if !$_key_provided {
        file { $_key_path:
          ensure    => file,
          owner     => $user,
          group     => $group,
          mode      => '0600',
          show_diff => false,
          require   => Exec['bastionvault-self-signed-cert'],
        }
      }
    }
  }
}
