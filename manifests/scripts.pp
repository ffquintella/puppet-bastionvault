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

  ensure_resource('file', '/srv/scripts', {
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
  })

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
    }),
  }
}
