# @summary Install the system-wide `bvault` CLI wrapper and group access.
#
# Provides /usr/local/bin/bvault for any user in the bastionvault group.
# The wrapper sudo's to the rootless service user, then runs `podman exec
# bastionvault bvault ...`. The bastionvault group itself is created in
# bastionvault::user.
#
# @api private
class bastionvault::cli {
  $user  = $bastionvault::user
  $group = $bastionvault::group

  file { '/usr/local/bin/bvault':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => epp('bastionvault/bvault-wrapper.sh.epp', { 'user' => $user }),
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
