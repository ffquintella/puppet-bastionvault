# @summary Apply SELinux fcontext labels for module-owned host paths.
#
# Sets `container_file_t` on the data, config, TLS, log, backup and HSM exchange
# directories so the container can read/write through the bind mounts under
# enforcing policy. The HSM exchange dir lives under the service user's home
# (`var_lib_t`), where podman's `:z` does not relabel it, so it needs an
# explicit rule; only that one directory is labeled, its 0750 mode is unchanged.
#
# @api private
class bastionvault::selinux {
  if !$bastionvault::manage_selinux {
    return()
  }

  if $facts['os']['selinux']['enabled'] == false {
    notice('bastionvault::selinux: SELinux disabled on this host; skipping fcontext management.')
    return()
  }

  $paths = {
    'bastionvault-data'    => $bastionvault::data_dir,
    'bastionvault-config'  => $bastionvault::config_dir,
    'bastionvault-tls'     => $bastionvault::tls_dir,
    'bastionvault-logs'    => $bastionvault::log_dir,
    'bastionvault-backup'  => $bastionvault::backup_dir,
    'bastionvault-hsm-out' => $bastionvault::hsm_out_dir,
  }

  $paths.each |$title, $path| {
    selinux::fcontext { $title:
      pathspec => "${path}(/.*)?",
      seltype  => 'container_file_t',
    }

    selinux::exec_restorecon { $path:
      require => Selinux::Fcontext[$title],
    }
  }
}
