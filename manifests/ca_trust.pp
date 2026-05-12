# @summary Install extra CA certificates into the host trust store.
#
# Each entry of `bastionvault::extra_ca_certs` is written to
# `/etc/pki/ca-trust/source/anchors/bvault-<name>.crt` and `update-ca-trust
# extract` is run to rebuild `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`.
# That bundle is bind-mounted into the container by `bastionvault.container`,
# so the new CA becomes trusted both on the host and inside the container.
#
# When the bundle is rebuilt, the bvault service is restarted so any in-memory
# trust cache picks up the new anchors.
#
# @api private
class bastionvault::ca_trust {
  if empty($bastionvault::extra_ca_certs) {
    return()
  }

  ensure_packages(['ca-certificates'])

  exec { 'bastionvault-update-ca-trust':
    command     => '/usr/bin/update-ca-trust extract',
    refreshonly => true,
    require     => Package['ca-certificates'],
    # Bounce the container so any in-memory trust cache reloads from the
    # freshly-extracted bundle. The wrapper service in bastionvault::service
    # proxies through to the rootless user unit.
    notify      => Service['bastionvault'],
  }

  $bastionvault::extra_ca_certs.each |$_name, $_spec| {
    # Sanitize the anchor filename; only alnum/_/- allowed.
    $_safe = regsubst($_name, '[^A-Za-z0-9_-]', '_', 'G')
    $_path = "/etc/pki/ca-trust/source/anchors/bvault-${_safe}.crt"

    $_content = $_spec['content'] ? {
      undef   => $_spec['base64'] ? {
        undef   => undef,
        default => base64('decode', $_spec['base64']),
      },
      default => $_spec['content'],
    }

    # Exactly one of (content|base64) and source must be provided.
    if $_content != undef and $_spec['source'] != undef {
      fail("bastionvault::extra_ca_certs[${_name}]: set either content/base64 OR source, not both.")
    }
    if $_content == undef and $_spec['source'] == undef {
      fail("bastionvault::extra_ca_certs[${_name}]: one of content, base64, or source is required.")
    }

    if $_content != undef {
      file { $_path:
        ensure  => file,
        owner   => 'root',
        group   => 'root',
        mode    => '0644',
        content => $_content,
        notify  => Exec['bastionvault-update-ca-trust'],
      }
    } else {
      file { $_path:
        ensure => file,
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => $_spec['source'],
        notify => Exec['bastionvault-update-ca-trust'],
      }
    }
  }
}
