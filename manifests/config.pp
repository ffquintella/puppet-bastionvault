# @summary Render config.hcl and place TLS material.
#
# TLS resolution (when $tls_disable = false):
#   1. If literal PEM (or base64 PEM) is supplied via
#      $tls_cert_content / $tls_cert_base64 (resolved upstream as
#      $tls_cert_pem_effective) — likewise for the key — write it out.
#   2. Else if $tls_cert_source / $tls_key_source is set, fetch from there.
#   3. Otherwise, if $tls_self_signed is true, generate a self-signed pair
#      via openssl on first run (idempotent — `creates` guards regeneration).
#   4. If TLS is enabled and none of the above provide a cert+key, fail.
#
# Cluster (Raft / hiqlite API) TLS material supplied as PEM content or
# base64-encoded PEM is written to $tls_dir as raft.crt/raft.key and
# cluster-api.crt/cluster-api.key; the in-container paths land in config.hcl
# automatically.
#
# @api private
class bastionvault::config {
  $user           = $bastionvault::user
  $group          = $bastionvault::group
  $config_dir     = $bastionvault::config_dir
  $tls_dir        = $bastionvault::tls_dir
  $cli_token_dir  = $bastionvault::cli_token_dir

  # Per-user token-helper directory. The CLI inside the container writes
  # ~/.vault-token equivalents here (path injected via $BVAULT_TOKEN_FILE
  # by the wrapper) and reads them back on subsequent invocations. Owner
  # is the host-side bastionvault user (= container UID via UserNS keep-
  # id), mode 0770 so any host user in the bastionvault group can have
  # the wrapper drop a token here on their behalf.
  file { $cli_token_dir:
    ensure => directory,
    owner  => $user,
    group  => $group,
    mode   => '0770',
  }

  file { "${config_dir}/config.hcl":
    ensure    => file,
    owner     => $user,
    group     => $group,
    mode      => '0640',
    content   => epp('bastionvault/config.hcl.epp', {
        'node_id'                              => $bastionvault::node_id,
        # Unwrap here rather than in the template: the rendered config.hcl
        # necessarily contains the plaintext secret anyway (show_diff => false
        # on this resource keeps it out of reports), and Sensitive.unwrap is
        # not portable across all EPP evaluators.
        'secret_raft'                          => $bastionvault::secret_raft_sensitive.unwrap,
        'secret_api'                           => $bastionvault::secret_api_sensitive.unwrap,
        'mode'                                 => $bastionvault::mode,
        'raft_listen_addr'                     => $bastionvault::raft_listen_addr,
        'internal_api_port'                    => $bastionvault::internal_api_port,
        'raft_port'                            => $bastionvault::raft_port,
        'nodes'                                => $bastionvault::nodes,
        'cluster_tls_raft_disable'             => $bastionvault::cluster_tls_raft_disable,
        'cluster_tls_raft_cert_path_effective' => $bastionvault::cluster_tls_raft_cert_path_effective,
        'cluster_tls_raft_key_path_effective'  => $bastionvault::cluster_tls_raft_key_path_effective,
        'cluster_tls_raft_no_verify'           => $bastionvault::cluster_tls_raft_no_verify,
        'cluster_tls_api_disable'              => $bastionvault::cluster_tls_api_disable,
        'cluster_tls_api_cert_path_effective'  => $bastionvault::cluster_tls_api_cert_path_effective,
        'cluster_tls_api_key_path_effective'   => $bastionvault::cluster_tls_api_key_path_effective,
        'cluster_tls_api_no_verify'            => $bastionvault::cluster_tls_api_no_verify,
        'listen_address'                       => $bastionvault::listen_address,
        'service_port'                         => $bastionvault::service_port,
        'tls_disable'                          => $bastionvault::tls_disable,
        'api_addr_effective'                   => $bastionvault::api_addr_effective,
        'log_level'                            => $bastionvault::log_level,
        'log_to_stderr'                        => $bastionvault::log_to_stderr,
        'log_rotate_size_mb'                   => $bastionvault::log_rotate_size_mb,
        'log_rotate_keep'                      => $bastionvault::log_rotate_keep,
        'pid_file'                             => $bastionvault::pid_file,
        'plugin_runtime_dir'                   => $bastionvault::plugin_runtime_dir,
        'hsm_backend'                          => $bastionvault::hsm_backend,
        'hsm_connector'                        => $bastionvault::hsm_connector,
        'hsm_password_env'                     => $bastionvault::hsm_password_env,
        'hsm_domains'                          => $bastionvault::hsm_domains,
        'hsm_node_id'                          => $bastionvault::hsm_node_id,
        'hsm_recovery'                         => $bastionvault::hsm_recovery,
        'hsm_pqc_key_cache_ttl'                => $bastionvault::hsm_pqc_key_cache_ttl,
        'hsm_mock_state_path'                  => $bastionvault::hsm_mock_state_path,
        'hsm_object_ids'                       => $bastionvault::hsm_object_ids,
    }),
    show_diff => false,
  }

  # ── HSM material ─────────────────────────────────────────────────────────
  # mock: pinned device material (cluster clone / reproducible dev). Written to
  # the host path that maps into the container's data volume so the mock reads
  # it on start and — being complete — never rewrites it. When no content is
  # supplied the mock self-provisions at this path on first boot (single node).
  if $bastionvault::hsm_backend == 'mock' and $bastionvault::hsm_mock_state_content_effective != undef {
    file { $bastionvault::hsm_mock_state_host_path:
      ensure    => file,
      owner     => $user,
      group     => $group,
      mode      => '0600',
      content   => $bastionvault::hsm_mock_state_content_effective,
      show_diff => false,
    }
  }

  # yubihsm2: password injected as an EnvironmentFile so it never lands in the
  # world-inspectable Quadlet unit or in config.hcl. config.hcl references it as
  # env:BASTIONVAULT_HSM_PASSWORD; the Quadlet loads this file at container start.
  if $bastionvault::hsm_backend == 'yubihsm2' and $bastionvault::hsm_password_sensitive != undef {
    file { $bastionvault::hsm_env_file:
      ensure    => file,
      owner     => $user,
      group     => $group,
      mode      => '0600',
      content   => Sensitive("${bastionvault::hsm_password_env}=${bastionvault::hsm_password_sensitive.unwrap}\n"),
      show_diff => false,
    }
  }

  if !$bastionvault::tls_disable {
    $_cert_path = "${tls_dir}/server.crt"
    $_key_path  = "${tls_dir}/server.key"

    $_cert_provided = $bastionvault::tls_cert_pem_effective != undef or $bastionvault::tls_cert_source != undef
    $_key_provided  = $bastionvault::tls_key_pem_effective  != undef or $bastionvault::tls_key_source  != undef

    if !($_cert_provided and $_key_provided) and !$bastionvault::tls_self_signed {
      fail('bastionvault: TLS is enabled but no cert/key was provided and tls_self_signed is false. Either set tls_disable=true, supply tls_cert_*/tls_key_*, or enable tls_self_signed.')
    }

    # 1. Operator-supplied cert.
    if $bastionvault::tls_cert_pem_effective != undef {
      file { $_cert_path:
        ensure  => file,
        owner   => $user,
        group   => $group,
        mode    => '0644',
        content => $bastionvault::tls_cert_pem_effective,
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
    if $bastionvault::tls_key_pem_effective != undef {
      file { $_key_path:
        ensure    => file,
        owner     => $user,
        group     => $group,
        mode      => '0600',
        content   => $bastionvault::tls_key_pem_effective,
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
      # Force the cert to be a true end-entity, not a self-signed CA. OpenSSL
      # 3.x adds `basicConstraints=CA:TRUE` to `req -x509` output by default,
      # which webpki/rustls rejects as `CaUsedAsEndEntity` when the bvault
      # CLI connects. Pinning CA:FALSE + serverAuth EKU + a SAN produces a
      # cert modern TLS stacks accept.
      exec { 'bastionvault-self-signed-cert':
        command => [
          '/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
          '-days', String($bastionvault::tls_self_signed_days),
          '-keyout', $_key_path,
          '-out', $_cert_path,
          '-subj', "/CN=${_cn}",
          '-addext', 'basicConstraints=critical,CA:FALSE',
          '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment',
          '-addext', 'extendedKeyUsage=serverAuth',
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

  # Publish a world-readable copy of the serving cert so the `bvault` CLI
  # (running on the host as any user) can pick it up as a TLS trust anchor
  # without --tls-skip-verify on every call. The CLI auto-discovers
  # /etc/bvault/ca.pem; we cannot land it inside the container's TLS dir
  # because that's bind-mounted read-only.
  if !$bastionvault::tls_disable and $bastionvault::cli_trust_path != undef {
    $_cli_trust_path = $bastionvault::cli_trust_path
    $_cli_trust_dir  = dirname($_cli_trust_path)

    ensure_resource('file', $_cli_trust_dir, {
        ensure => directory,
        owner  => 'root',
        group  => 'root',
        mode   => '0755',
    })

    # The source cert is owned by $user:$group and lives in a 0750 directory,
    # so a plain `file { source => "file://..." }` would race with Puppet's
    # readability checks when run as root (works) versus an unprivileged agent
    # (doesn't). Using `install(1)` sidesteps that — root can always read the
    # source, and the destination is created with explicit ownership/mode.
    exec { 'bastionvault-publish-cli-trust':
      command     => "/usr/bin/install -m 0644 -o root -g root ${_cert_path} ${_cli_trust_path}",
      unless      => "/usr/bin/cmp -s ${_cert_path} ${_cli_trust_path}",
      path        => ['/usr/bin', '/bin'],
      require     => [File[$_cli_trust_dir], File[$_cert_path]],
      subscribe   => File[$_cert_path],
      refreshonly => false,
    }
  }

  # Cluster (Raft + hiqlite API) TLS material written from PEM/base64 inputs.
  # These are independent of the listener TLS toggle — HA may run with the
  # listener disabled but cluster TLS enabled (or vice-versa).
  if $bastionvault::cluster_tls_raft_cert_pem_effective != undef {
    file { "${tls_dir}/raft.crt":
      ensure  => file,
      owner   => $user,
      group   => $group,
      mode    => '0644',
      content => $bastionvault::cluster_tls_raft_cert_pem_effective,
    }
  }
  if $bastionvault::cluster_tls_raft_key_pem_effective != undef {
    file { "${tls_dir}/raft.key":
      ensure    => file,
      owner     => $user,
      group     => $group,
      mode      => '0600',
      content   => $bastionvault::cluster_tls_raft_key_pem_effective,
      show_diff => false,
    }
  }
  if $bastionvault::cluster_tls_api_cert_pem_effective != undef {
    file { "${tls_dir}/cluster-api.crt":
      ensure  => file,
      owner   => $user,
      group   => $group,
      mode    => '0644',
      content => $bastionvault::cluster_tls_api_cert_pem_effective,
    }
  }
  if $bastionvault::cluster_tls_api_key_pem_effective != undef {
    file { "${tls_dir}/cluster-api.key":
      ensure    => file,
      owner     => $user,
      group     => $group,
      mode      => '0600',
      content   => $bastionvault::cluster_tls_api_key_pem_effective,
      show_diff => false,
    }
  }
}
