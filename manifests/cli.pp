# @summary Install the system-wide `bvault` CLI wrapper and group access.
#
# Provides /usr/local/bin/bvault for any user in the bastionvault group.
# The wrapper sudo's to the rootless service user, then runs `podman exec
# bastionvault bvault ...`. The bastionvault group itself is created in
# bastionvault::user.
#
# @api private
class bastionvault::cli {
  $user         = $bastionvault::user
  $group        = $bastionvault::group
  $service_port = $bastionvault::service_port

  # Env var names the wrapper forwards into the container by name (never by
  # value). Joined here because EPP lambdas/join render poorly under regent.
  $passthrough_env = join($bastionvault::cli_passthrough_env, ' ')

  file { '/usr/local/bin/bvault':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => epp('bastionvault/bvault-wrapper.sh.epp', {
        'user'            => $user,
        'service_port'    => $service_port,
        'passthrough_env' => $passthrough_env,
        'hsm_out_dir'     => $bastionvault::hsm_out_dir,
    }),
  }

  # Operator helper: `bvault-ctl status` reports the systemd wrapper unit
  # state plus the rootless container state. Read-only; safe for any user
  # in the bastionvault group.
  file { '/usr/local/bin/bvault-ctl':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => epp('bastionvault/bvault-ctl.sh.epp', { 'user' => $user }),
  }

  file { '/etc/sudoers.d/bastionvault':
    ensure       => file,
    owner        => 'root',
    group        => 'root',
    mode         => '0440',
    content      => epp('bastionvault/sudoers.epp', { 'user' => $user, 'group' => $group }),
    validate_cmd => '/usr/sbin/visudo -cf %',
  }
}
