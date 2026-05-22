# @summary Publish operator helper scripts under /srv/scripts/bastionvault.
#
# The bastionvault runtime image is distroless and ships no shell, so
# auxiliary bash scripts (like the Rustion master bootstrap) can't be run
# via `podman exec`. Instead we drop them on the host alongside a thin
# wrapper that sets PATH / env aliases and execs the script — the script
# itself drives the in-container CLI through /usr/local/bin/bvault.
#
# @api private
class bastionvault::scripts {
  $scripts_dir   = '/srv/scripts/bastionvault'
  $script_path   = "${scripts_dir}/rustion-master-bootstrap.sh"
  $wrapper_path  = "${scripts_dir}/rustion-master-bootstrap"
  $cli_token_dir = $bastionvault::cli_token_dir

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

  file { $script_path:
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
    source => 'puppet:///modules/bastionvault/rustion-master-bootstrap.sh',
  }

  file { $wrapper_path:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => epp('bastionvault/rustion-master-bootstrap-wrapper.sh.epp', {
        'script_path'   => $script_path,
        'cli_token_dir' => $cli_token_dir,
    }),
  }
}
