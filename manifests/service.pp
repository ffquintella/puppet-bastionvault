# @summary Install the Quadlet unit and start the rootless service.
#
# @api private
class bastionvault::service {
  $user  = $bastionvault::user
  $group = $bastionvault::group
  $home  = "/var/lib/${user}"
  $unit_path = "${home}/.config/containers/systemd/bastionvault.container"

  # Resolve UID at apply time. Prefer the explicit param; otherwise fall back
  # to the custom fact populated after the user is created.
  $_uid_fact = $facts.dig('bastionvault_user_uid')
  $_uid = $bastionvault::uid ? {
    undef   => $_uid_fact,
    default => $bastionvault::uid,
  }

  if $_uid == undef {
    # First Puppet run: user just created, fact not yet populated.
    # Skip the user-systemd interactions; the next run will manage them.
    notice('bastionvault::service: UID not yet known (custom fact missing). Quadlet unit + service will be applied on the next run.')
  } else {
    # systemctl --user must be run as the user with XDG_RUNTIME_DIR pointing at
    # the lingering runtime dir. We deliberately do NOT use `sudo -i` because the
    # account's shell is /sbin/nologin, which would refuse the login.
    $runas = "/usr/bin/sudo -u ${user} /usr/bin/env XDG_RUNTIME_DIR=/run/user/${_uid}"

    # Apply subid changes to podman's storage. Required after writing
    # /etc/subuid and /etc/subgid for the first time, otherwise the rootless
    # user namespace is built with the old (empty) mapping and image pulls
    # fail with "potentially insufficient UIDs or GIDs available". Idempotent
    # via a flag file under the user's home.
    $_migrate_flag = "${home}/.podman-subid-migrated"
    exec { 'bastionvault-podman-migrate':
      command => "${runas} /bin/sh -c '/usr/bin/podman system migrate && /usr/bin/touch ${_migrate_flag}'",
      creates => $_migrate_flag,
      cwd     => $home,
      require => [
        Podman::Subuid[$user],
        Podman::Subgid[$user],
      ],
    }

    file { $unit_path:
      ensure  => file,
      owner   => $user,
      group   => $group,
      mode    => '0640',
      content => epp('bastionvault/bastionvault.container.epp'),
      notify  => Exec['bastionvault-user-daemon-reload'],
    }

    # Reload the user systemd manager so it picks up the Quadlet generator.
    exec { 'bastionvault-user-daemon-reload':
      command     => "${runas} /usr/bin/systemctl --user daemon-reload",
      refreshonly => true,
      notify      => Exec['bastionvault-user-restart'],
    }

    exec { 'bastionvault-user-restart':
      command     => "${runas} /usr/bin/systemctl --user restart bastionvault.service",
      refreshonly => true,
    }

    # Quadlet-generated units cannot be `systemctl enable`d (they live under
    # /run/.../generator/). Auto-start at boot is configured via [Install] in
    # the .container file; here we only need to start it on first apply.
    exec { 'bastionvault-user-start':
      command => "${runas} /usr/bin/systemctl --user start bastionvault.service",
      unless  => "${runas} /usr/bin/systemctl --user is-active bastionvault.service",
      require => [
        File[$unit_path],
        Exec['bastionvault-user-daemon-reload'],
        Exec['bastionvault-podman-migrate'],
      ],
    }

    # System-level wrapper unit so operators can run `systemctl status
    # bastionvault` (and start/stop/reload) without remembering the
    # `--user --machine=<user>@.host` incantation. The wrapper is a
    # oneshot/RemainAfterExit unit that proxies to the rootless user
    # service via systemd's user@.host machine target.
    file { '/etc/systemd/system/bastionvault.service':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('bastionvault/bastionvault.service.epp', { 'uid' => $_uid, 'user' => $user }),
      notify  => Exec['bastionvault-system-daemon-reload'],
    }

    exec { 'bastionvault-system-daemon-reload':
      command     => '/usr/bin/systemctl daemon-reload',
      refreshonly => true,
    }

    service { 'bastionvault':
      ensure  => running,
      enable  => true,
      require => [
        File['/etc/systemd/system/bastionvault.service'],
        Exec['bastionvault-system-daemon-reload'],
        Exec['bastionvault-user-start'],
      ],
    }
  }

  if $bastionvault::manage_firewall {
    notice("bastionvault::service: \$manage_firewall is true; ensure firewalld permits tcp/${bastionvault::listen_port}.")
  }
}
