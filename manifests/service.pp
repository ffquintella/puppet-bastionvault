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

    exec { 'bastionvault-user-enable':
      command => "${runas} /usr/bin/systemctl --user enable --now bastionvault.service",
      unless  => "${runas} /usr/bin/systemctl --user is-active bastionvault.service",
      require => File[$unit_path],
    }
  }

  if $bastionvault::manage_firewall {
    notice("bastionvault::service: \$manage_firewall is true; ensure firewalld permits tcp/${bastionvault::listen_port}.")
  }
}
