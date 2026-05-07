# @summary Drop a systemd slice override with cgroups v2 limits for the user instance.
#
# Writes `/etc/systemd/system/user-<uid>.slice.d/50-bastionvault.conf` so
# limits apply to all units inside the rootless user manager.
#
# @api private
class bastionvault::cgroups {
  $user = $bastionvault::user

  # Resolve UID at apply time. Required for the slice unit name.
  $_uid_fact = $facts.dig('bastionvault_user_uid')
  $_uid = $bastionvault::uid ? {
    undef   => $_uid_fact,
    default => $bastionvault::uid,
  }

  if $_uid == undef {
    # First Puppet run: user just created, fact not yet populated.
    # Skip silently; the next run will write the drop-in.
    notice('bastionvault::cgroups: UID not yet known (custom fact missing). Slice drop-in will be applied on the next run.')
  } else {
    $dropin_dir = "/etc/systemd/system/user-${_uid}.slice.d"

    file { $dropin_dir:
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }

    file { "${dropin_dir}/50-bastionvault.conf":
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('bastionvault/slice.conf.epp', {
          'memory_max' => $bastionvault::memory_max,
          'cpu_quota'  => $bastionvault::cpu_quota,
          'tasks_max'  => $bastionvault::tasks_max,
          'io_weight'  => $bastionvault::io_weight,
      }),
      notify  => Exec['bastionvault-systemd-reload'],
      require => File[$dropin_dir],
    }

    exec { 'bastionvault-systemd-reload':
      command     => '/usr/bin/systemctl daemon-reload',
      refreshonly => true,
    }
  }
}
