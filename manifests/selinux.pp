# @summary Apply SELinux fcontext labels for module-owned host paths.
#
# Sets `container_file_t` on the data, config, and TLS directories so the
# container can read/write through `:Z` mounts under enforcing policy.
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
    'bastionvault-data'   => $bastionvault::data_dir,
    'bastionvault-config' => $bastionvault::config_dir,
    'bastionvault-tls'    => $bastionvault::tls_dir,
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
