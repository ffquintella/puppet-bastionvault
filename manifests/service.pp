# @summary Install the Quadlet unit and start the rootless service.
#
# @api private
class bastionvault::service {
  $user  = $bastionvault::user
  $group = $bastionvault::group
  $uid   = $bastionvault::uid
  $home  = "/var/lib/${user}"
  $unit_path = "${home}/.config/containers/systemd/bastionvault.container"

  # systemctl --user must be run as the user with XDG_RUNTIME_DIR pointing at
  # the lingering runtime dir. We deliberately do NOT use `sudo -i` because the
  # account's shell is /sbin/nologin, which would refuse the login.
  $runas = "/usr/bin/sudo -u ${user} /usr/bin/env XDG_RUNTIME_DIR=/run/user/${uid}"

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

  if $bastionvault::manage_firewall {
    notice("bastionvault::service: \$manage_firewall is true; ensure firewalld permits tcp/${bastionvault::listen_port}.")
  }
}
