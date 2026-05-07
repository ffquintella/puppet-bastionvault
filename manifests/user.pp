# @summary Manage the non-root system user, linger, and runtime dirs.
#
# Creates the bastionvault system user/group, enables systemd lingering so
# the user instance starts at boot without interactive login, and pre-
# creates the host directories that get bind-mounted into the container.
#
# subuid/subgid entries are left to useradd defaults on EL9/EL10.
#
# @api private
class bastionvault::user {
  $user      = $bastionvault::user
  $group     = $bastionvault::group
  $uid       = $bastionvault::uid
  $gid       = $bastionvault::gid
  $home      = "/var/lib/${user}"
  $data_dir   = $bastionvault::data_dir
  $config_dir = $bastionvault::config_dir
  $tls_dir    = $bastionvault::tls_dir

  group { $group:
    ensure => present,
    system => true,
    gid    => $gid,
  }

  user { $user:
    ensure     => present,
    system     => true,
    gid        => $group,
    uid        => $uid,
    home       => $home,
    managehome => true,
    shell      => '/sbin/nologin',
    comment    => 'BastionVault rootless container user',
    require    => Group[$group],
  }

  # Quadlet config root.
  file { ["${home}/.config", "${home}/.config/containers", "${home}/.config/containers/systemd"]:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0750',
    require => User[$user],
  }

  # Host-side bind mount targets.
  file { [$config_dir, $tls_dir]:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0750',
    require => User[$user],
  }

  # Data dir parent + data dir. ensure_resource is idempotent and avoids
  # duplicate-declaration errors when the parent overlaps with $home.
  $_data_parent = dirname($data_dir)
  ensure_resource('file', $_data_parent, {
      'ensure' => 'directory',
      'owner'  => $user,
      'group'  => $group,
      'mode'   => '0750',
  })

  file { $data_dir:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0750',
    require => [User[$user], File[$_data_parent]],
  }

  # systemd linger so the user instance survives logout/reboot.
  exec { "bastionvault-enable-linger-${user}":
    command => "/usr/bin/loginctl enable-linger ${user}",
    unless  => "/usr/bin/loginctl show-user ${user} 2>/dev/null | grep -q '^Linger=yes$'",
    require => User[$user],
  }

  # Subordinate UID/GID ranges. System users are NOT auto-allocated subids by
  # useradd, but rootless podman requires them to set up the user namespace.
  # We append a single line to /etc/subuid and /etc/subgid; podman picks the
  # change up on the next `podman system migrate` (handled in service.pp).
  $_subid_line = "${user}:${bastionvault::subid_start}:${bastionvault::subid_count}"

  exec { "bastionvault-subuid-${user}":
    command => "/bin/sh -c \"printf '%s\\n' '${_subid_line}' >> /etc/subuid\"",
    unless  => "/bin/grep -q '^${user}:' /etc/subuid",
    require => User[$user],
  }

  exec { "bastionvault-subgid-${user}":
    command => "/bin/sh -c \"printf '%s\\n' '${_subid_line}' >> /etc/subgid\"",
    unless  => "/bin/grep -q '^${user}:' /etc/subgid",
    require => User[$user],
  }
}
