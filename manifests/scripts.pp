# @summary Publish operator helper wrappers under /srv/scripts/bastionvault.
#
# The bastionvault image ships its own helper scripts under
# /usr/local/bin/ (see deploy/container/Containerfile in the BastionVault
# repo). This class drops thin host-side wrappers at
# /srv/scripts/bastionvault/* that `podman exec` into the running
# container to invoke them, so operators don't need to remember the
# sudo + podman exec + env-injection incantation.
#
# Requires the image to be built with INCLUDE_SHELL=1 so /bin/sh exists
# inside the container.
#
# @api private
class bastionvault::scripts {
  $user         = $bastionvault::user
  $scripts_dir  = '/srv/scripts/bastionvault'
  $wrapper_path = "${scripts_dir}/rustion-master-bootstrap"

  # /srv/scripts is a baseapp root (ffquintella-baseapp owns it). Declaring it
  # here as well triggers a duplicate File[/srv/scripts] on any node that also
  # includes baseapp (e.g. via the ferrogate module). Use a mkdir -p exec to
  # guarantee the parent exists on standalone nodes — idempotent via `creates`,
  # and a no-op when baseapp has already created it — and let baseapp own it.
  exec { "bastionvault-mkdir-${scripts_dir}":
    command => "/usr/bin/mkdir -p ${scripts_dir}",
    creates => $scripts_dir,
    before  => File[$scripts_dir],
  }

  file { $scripts_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { $wrapper_path:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => epp('bastionvault/rustion-master-bootstrap-wrapper.sh.epp', {
        'user'                => $user,
        'in_container_script' => '/usr/local/bin/rustion-master-bootstrap.sh',
        'service_port'        => $bastionvault::service_port,
    }),
  }
}
