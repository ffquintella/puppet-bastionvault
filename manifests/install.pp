# @summary Install Podman and rootless networking helpers.
#
# @api private
class bastionvault::install {
  $packages = [
    'podman',
    'slirp4netns',
    'fuse-overlayfs',
    'shadow-utils',
    'policycoreutils-python-utils',
  ]

  ensure_packages($packages, { 'ensure' => 'installed' })
}
