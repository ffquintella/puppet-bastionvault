# @summary Manage the non-root system user, linger, and runtime dirs.
#
# Creates the bastionvault system user/group, enables systemd lingering so
# the user instance starts at boot without interactive login, and pre-
# creates the host directories that get bind-mounted into the container.
#
# system users are NOT auto-allocated subordinate IDs by useradd, so this
# class explicitly provisions /etc/subuid and /etc/subgid ranges for the
# user via puppet/podman's podman::subuid / podman::subgid defined types
# (rootless podman requires them to build the user namespace).
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
  $log_dir    = $bastionvault::log_dir

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

  # Make sure the full directory paths exist before the File resources below
  # take over ownership/mode management. `mkdir -p` is a no-op when the dirs
  # already exist (idempotent via `creates`) and tolerates arbitrarily deep
  # parent paths if an operator overrides $data_dir / $config_dir / $log_dir.
  [$data_dir, $config_dir, $tls_dir, $log_dir].each |$_dir| {
    exec { "bastionvault-mkdir-${_dir}":
      command => "/usr/bin/mkdir -p ${_dir}",
      creates => $_dir,
      before  => File[$_dir],
    }
  }

  # Manage the immediate parents so they get a sane mode (root:root 0755)
  # rather than mkdir's default umask. Idempotent + tolerates parents that
  # overlap with each other or with $home.
  #
  # The standard /srv/application-* roots are owned by the baseapp module
  # (ffquintella-baseapp), which bastionvault::init contains and orders ahead of
  # this class — they exist as root:root 0755 (world-traversable) before we run.
  # Declaring them here as well would trigger a duplicate File[...] declaration
  # on any node that also includes baseapp (e.g. via the ferrogate module), so
  # skip the baseapp roots and let baseapp own them. The `mkdir -p` exec above
  # still guarantees they exist as a fallback.
  $_baseapp_roots = [
    '/srv',
    '/srv/scripts',
    '/srv/application-config',
    '/srv/application-data',
    '/srv/application-logs',
  ]
  [dirname($data_dir), dirname($config_dir), dirname($log_dir)].unique.each |$_parent| {
    unless $_parent in $_baseapp_roots {
      ensure_resource('file', $_parent, {
          'ensure' => 'directory',
          'owner'  => 'root',
          'group'  => 'root',
          'mode'   => '0755',
      })
    }
  }

  # Host-side bind mount targets. The mkdir exec above guarantees they exist;
  # these resources own mode + ownership of the directory inode.
  file { [$config_dir, $tls_dir, $log_dir]:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0750',
    require => User[$user],
  }

  file { $data_dir:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0750',
    require => User[$user],
  }

  # Repair ownership of any pre-existing contents (e.g. data migrated in from
  # the old /var/lib/bastionvault/data path, or files seeded by an operator
  # before Puppet ran). The `find` guard makes this a no-op once everything is
  # already owned by ${user}:${group}, so it does not chown on every run.
  [$data_dir, $config_dir, $tls_dir, $log_dir].each |$_dir| {
    exec { "bastionvault-chown-${_dir}":
      command => "/usr/bin/chown -R ${user}:${group} ${_dir}",
      onlyif  => "/usr/bin/find ${_dir} \\( ! -user ${user} -o ! -group ${group} \\) -print -quit | /usr/bin/grep -q .",
      require => [
        User[$user],
        File[$_dir],
      ],
    }
  }

  # systemd linger so the user instance survives logout/reboot.
  exec { "bastionvault-enable-linger-${user}":
    command => "/usr/bin/loginctl enable-linger ${user}",
    unless  => "/usr/bin/loginctl show-user ${user} 2>/dev/null | grep -q '^Linger=yes$'",
    require => User[$user],
  }

  # Subordinate UID/GID ranges. System users are NOT auto-allocated subids by
  # useradd, but rootless podman requires them to set up the user namespace.
  # We use the puppet/podman defined types so the entries become fragments of
  # the concat-managed /etc/subuid and /etc/subgid (rather than fighting the
  # concat with a raw append). This requires `include podman` to be active in
  # the catalog so the Concat targets exist.
  podman::subuid { $user:
    subuid  => $bastionvault::subid_start,
    count   => $bastionvault::subid_count,
    require => User[$user],
  }

  podman::subgid { $user:
    subgid  => $bastionvault::subid_start,
    count   => $bastionvault::subid_count,
    require => User[$user],
  }
}
