# @summary Install the BastionVault client and GUI on Windows from a Chocolatey (NuGet) feed.
#
# Windows counterpart to `bastionvault::client`. It registers a Chocolatey
# source pointing at the NuGet repository that carries the BastionVault
# packages, then installs the `bvault` CLI and the desktop GUI from it.
#
# Scope is deliberately install-only: no wrapper script, no CA trust
# anchor, no server. Client configuration on Windows is left to the
# packages themselves and to the operator. For the EL server or the EL
# CLI-plus-wrapper, use `bastionvault` / `bastionvault::client`.
#
# Chocolatey itself is assumed to be present (managed by the site's
# baseline profile). Set $manage_chocolatey to have this class pull in
# puppetlabs/chocolatey's bootstrap instead — note that the stock
# bootstrap reaches out to the public community feed, which is usually
# the opposite of what a site with an internal NuGet mirror wants.
#
# @param repo_url Location of the NuGet/Chocolatey repository carrying the
#   BastionVault packages. An HTTP(S) feed URL (e.g.
#   `https://nexus.example.com/repository/choco-hosted/`) or a UNC / local
#   path to a package share.
# @param manage_repo Register $repo_url as a Chocolatey source. Disable
#   when the source is already configured by another module or by the
#   image baseline.
# @param repo_name Name the source is registered under. This is also the
#   value passed to `choco install --source` by default, so credentials
#   attached to the source apply to the install.
# @param repo_priority Source priority. Lower numbers win; 0 means
#   unprioritized, which lets the public community feed compete on equal
#   footing. Set 1 to make this feed authoritative.
# @param repo_user Username for an authenticated feed.
# @param repo_password Password for an authenticated feed, wrapped in
#   Sensitive. Chocolatey cannot read a configured password back, so the
#   source resource reports a change on every run once this is set.
# @param manage_chocolatey Include the `chocolatey` class to bootstrap
#   Chocolatey before the source and packages are managed.
# @param client_package_name Chocolatey package ID of the `bvault` CLI.
#   Defaults to the ID BastionVault's own packaging publishes,
#   `bastionvault-cli` (see `installers/cli/nupkg/`); override only for a
#   feed that renames it.
# @param gui_package_name    Chocolatey package ID of the desktop GUI,
#   `bastionvault-gui` upstream (`gui/src-tauri/installers/windows/nupkg/`).
# @param client_ensure Package ensure for the CLI (`installed`, `latest`,
#   or a pinned version such as `'0.12.3'`).
# @param gui_ensure    Package ensure for the GUI, same accepted values.
# @param package_source Value passed to `choco install --source`,
#   overriding the default. The default is $repo_name when this class
#   manages the source (so any configured credentials are picked up), and
#   $repo_url otherwise.
# @param install_options Extra flags handed to `choco install` for both
#   packages, e.g. `['--ignore-checksums']` or
#   `[{'--installargs' => 'quiet'}]`.
# @param manage_ykman Install Yubico's `ykman` (YubiKey Manager CLI),
#   required for BastionVault's hardware-token-backed unseal/auth flows on
#   Windows. Declared with `ensure_packages()` rather than a plain `package`
#   resource, so a site profile or another module that already manages the
#   same package title does not collide with this class in a "duplicate
#   resource" catalog error — whichever declares it first wins, and this
#   class simply orders the CLI install after it either way.
# @param ykman_package_name Chocolatey package ID of YubiKey Manager.
#   Defaults to the upstream community-feed ID, `yubikey-manager`; override
#   if an internal mirror renames it.
# @param ykman_ensure Package ensure for `ykman` (`installed`, `latest`, or
#   a pinned version).
# @param ykman_package_source Value passed to `choco install --source` for
#   `ykman` only. Defaults to `undef` (Chocolatey's configured sources)
#   rather than `$package_source`, since `ykman` is ordinarily pulled from
#   the public community feed rather than the internal feed that carries
#   the BastionVault packages themselves.
#
# @example Internal Nexus feed, both packages tracking the newest build
#   class { 'bastionvault::windows':
#     repo_url      => 'https://nexus.example.com/repository/choco-hosted/',
#     repo_priority => 1,
#     client_ensure => 'latest',
#     gui_ensure    => 'latest',
#   }
#
# @example Authenticated feed with pinned versions
#   class { 'bastionvault::windows':
#     repo_url      => 'https://packages.example.com/nuget/windows/',
#     repo_user     => 'svc_puppet',
#     repo_password => Sensitive(lookup('choco_feed_password')),
#     client_ensure => '0.12.3',
#     gui_ensure    => '0.12.3',
#   }
class bastionvault::windows (
  Variant[Stdlib::HTTPUrl, Stdlib::Windowspath] $repo_url,

  Boolean                                       $manage_repo         = true,
  String[1]                                     $repo_name           = 'bastionvault',
  Integer[0]                                    $repo_priority       = 0,
  Optional[String[1]]                           $repo_user           = undef,
  Optional[Sensitive[String[1]]]                $repo_password       = undef,

  Boolean                                       $manage_chocolatey   = false,

  String[1]                                     $client_package_name = 'bastionvault-cli',
  String[1]                                     $gui_package_name    = 'bastionvault-gui',
  String[1]                                     $client_ensure       = 'installed',
  String[1]                                     $gui_ensure          = 'installed',

  Optional[String[1]]                           $package_source      = undef,
  Array[Variant[String[1], Hash[String[1], String]]] $install_options = [],

  Boolean                                       $manage_ykman        = true,
  String[1]                                     $ykman_package_name  = 'yubikey-manager',
  String[1]                                     $ykman_ensure        = 'installed',
  Optional[String[1]]                           $ykman_package_source = undef,
) {
  # OS gate — mirrors the RedHat-only gate the EL classes carry, from the
  # other side. Chocolatey exists nowhere else.
  if $facts['os']['family'] != 'windows' {
    fail("bastionvault::windows supports Windows only (got ${facts['os']['family']}). Use bastionvault::client on EL hosts.")
  }

  if $repo_user =~ NotUndef and $repo_password == undef {
    fail('bastionvault::windows: $repo_user is set but $repo_password is unset.')
  }

  if $manage_chocolatey {
    include chocolatey
  }

  # Prefer the source *name* over the raw URL: when the feed is
  # authenticated, Chocolatey attaches the stored credentials to the
  # registered source, and passing the bare URL bypasses them.
  $_package_source = $package_source ? {
    undef   => $manage_repo ? {
      true    => $repo_name,
      default => $repo_url,
    },
    default => $package_source,
  }

  if $manage_repo {
    chocolateysource { $repo_name:
      ensure   => present,
      location => $repo_url,
      priority => $repo_priority,
      user     => $repo_user,
      password => $repo_password ? {
        undef   => undef,
        default => $repo_password.unwrap,
      },
    }

    if $manage_chocolatey {
      Class['chocolatey'] -> Chocolateysource[$repo_name]
    }
  }

  if $manage_ykman {
    # ensure_packages(), not a plain `package` resource: $ykman_package_name
    # is a generic third-party dependency other modules or the site profile
    # may already manage, so this must no-op rather than collide with an
    # existing declaration of the same title.
    ensure_packages([$ykman_package_name], {
        'ensure'   => $ykman_ensure,
        'provider' => 'chocolatey',
        'source'   => $ykman_package_source,
    })
  }

  package { $client_package_name:
    ensure          => $client_ensure,
    provider        => chocolatey,
    source          => $_package_source,
    install_options => $install_options,
  }

  if $manage_ykman {
    Package[$ykman_package_name] -> Package[$client_package_name]
  }

  # The GUI is a front end for the CLI, so order it behind the client to
  # keep a partially-applied catalog in a sane state.
  package { $gui_package_name:
    ensure          => $gui_ensure,
    provider        => chocolatey,
    source          => $_package_source,
    install_options => $install_options,
    require         => Package[$client_package_name],
  }

  if $manage_repo {
    Chocolateysource[$repo_name] -> Package[$client_package_name]
  }
  if $manage_chocolatey {
    Class['chocolatey'] -> Package[$client_package_name]
  }
}
