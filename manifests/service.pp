# @summary Install the Quadlet unit and start the rootless service.
#
# @api private
class bastionvault::service {
  $user  = $bastionvault::user
  $group = $bastionvault::group
  $home  = "/var/lib/${user}"
  $unit_path = "${home}/.config/containers/systemd/bastionvault.container"

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
    command     => "/usr/bin/sudo -iu ${user} /usr/bin/systemctl --user daemon-reload",
    refreshonly => true,
    notify      => Exec['bastionvault-user-restart'],
  }

  exec { 'bastionvault-user-restart':
    command     => "/usr/bin/sudo -iu ${user} /usr/bin/systemctl --user restart bastionvault.service",
    refreshonly => true,
  }

  exec { 'bastionvault-user-enable':
    command => "/usr/bin/sudo -iu ${user} /usr/bin/systemctl --user enable --now bastionvault.service",
    unless  => "/usr/bin/sudo -iu ${user} /usr/bin/systemctl --user is-active bastionvault.service",
    require => File[$unit_path],
  }

  if $bastionvault::manage_firewall {
    notice("bastionvault::service: \$manage_firewall is true; ensure firewalld permits tcp/${bastionvault::listen_port}.")
  }
}
