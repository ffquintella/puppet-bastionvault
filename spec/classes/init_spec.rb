# frozen_string_literal: true

# Dual-mode spec:
#   * Under MRI Ruby with rspec-puppet + rspec-puppet-facts loaded
#     (i.e. `bundle exec rake spec`), runs the full catalog test matrix.
#   * Under runners that lack those gems (e.g. `regent test`, whose
#     Artichoke Ruby ships only a built-in minimal DSL), runs an
#     equivalent suite using only matchers regent supports.
#
# regent DSL capabilities (verified empirically):
#   * Supported: compile, contain_class, contain_file, with_content,
#     let(:facts), let(:params), nested context.
#   * NOT usable: on_supported_os / rspec-puppet-facts (so facts are
#     supplied explicitly), and `without_content` — it is a no-op under
#     regent (always passes), so absence is asserted with POSITIVE
#     matches instead (e.g. `Network=host` immediately followed by the
#     first `Volume=` line proves no PublishPort was emitted between them).
#   * The .container and config.hcl templates are parameterized EPP fed
#     via epp(tpl, {...}); regent renders those real values. (Templates
#     that read $bastionvault::* from scope render `undef` under regent,
#     and Sensitive#unwrap inside EPP renders `undef` too — which is why
#     config.pp unwraps the Raft/API secrets before passing them in.)
catalog_harness = begin
  require 'spec_helper'
  defined?(on_supported_os) ? :rspec_puppet : :regent
rescue StandardError, ScriptError
  :regent
end

if catalog_harness == :regent
  describe 'bastionvault' do
    # regent's minimal DSL has no rspec-puppet-facts; supply EL9 facts
    # explicitly so the RedHat-only OS gate in init.pp lets the catalog
    # compile. Mirrors the fact shape used by the rspec-puppet branch.
    let(:facts) do
      {
        os: {
          family:  'RedHat',
          name:    'Rocky',
          release: { major: '9', full: '9.4' },
          selinux: { enabled: true },
        },
        networking: {
          fqdn:     'bv1.example.test',
          hostname: 'bv1',
          ip:       '10.0.0.10',
        },
        bastionvault_user_uid: 1234,
      }
    end

    it { is_expected.to compile }
    it { is_expected.to contain_class('baseapp') }
    it { is_expected.to contain_class('bastionvault::install') }
    it { is_expected.to contain_class('bastionvault::user') }
    it { is_expected.to contain_class('bastionvault::selinux') }
    it { is_expected.to contain_class('bastionvault::config') }
    it { is_expected.to contain_class('bastionvault::cgroups') }
    it { is_expected.to contain_class('bastionvault::service') }
    it { is_expected.to contain_class('bastionvault::cli') }
    it { is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl') }
    it { is_expected.to contain_file('/var/lib/bastionvault/.config/containers/systemd/bastionvault.container') }
    it { is_expected.to contain_file('/etc/systemd/system/bastionvault.service') }
    it { is_expected.to contain_file('/usr/local/bin/bvault') }
    it { is_expected.to contain_file('/etc/sudoers.d/bastionvault') }

    quadlet = '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container'
    config  = '/srv/application-config/bastionvault/config.hcl'
    wrapper = '/usr/local/bin/bvault'

    context 'with defaults (host networking)' do
      it 'composes the image ref' do
        is_expected.to contain_file(quadlet).with_content(%r{Image=docker\.io/bastionvault:0\.3\.2})
      end

      it 'uses Network=host' do
        is_expected.to contain_file(quadlet).with_content(%r{^Network=host$})
      end

      # `without_content` is a no-op under regent, so prove the PublishPort
      # line is absent positionally: Network=host is immediately followed by
      # the first Volume= line, with no PublishPort between them.
      it 'emits no PublishPort line under host networking' do
        is_expected.to contain_file(quadlet).with_content(%r{Network=host\nVolume=})
      end

      it 'binds the in-container listener directly on host port 4200' do
        is_expected.to contain_file(config).with_content(%r{address\s*=\s*"0\.0\.0\.0:4200"})
      end

      it 'points the CLI wrapper at the host-facing port 4200' do
        is_expected.to contain_file(wrapper).with_content(%r{--address=https://127\.0\.0\.1:4200})
      end

      it 'bind-mounts the backup directory at /backups' do
        is_expected.to contain_file(quadlet)
          .with_content(%r{Volume=/srv/application-data/bastionvault/backups:/backups:Z})
      end

      it 'renders the single-node hiqlite storage block' do
        is_expected.to contain_file(config).with_content(%r{storage "hiqlite"})
      end

      it 'points plugin_runtime_dir at an exec-allowed staging dir' do
        is_expected.to contain_file(config)
          .with_content(%r{plugin_runtime_dir\s*=\s*"/var/lib/bvault/plugin-run"})
      end
    end
    # NOTE: the `plugin_runtime_dir => undef` (key-omitted) path is covered only
    # in the rspec-puppet branch — regent's param injection cannot express a
    # Puppet undef (`:undef` is passed through as a literal), so the default
    # value still renders here.

    context 'with network_mode=pasta (legacy user-mode networking)' do
      let(:params) { { network_mode: 'pasta' } }

      it 'emits the user-mode network backend' do
        is_expected.to contain_file(quadlet).with_content(%r{^Network=pasta$})
      end

      it 'maps host port 4200 to the in-container listener 8200' do
        is_expected.to contain_file(quadlet).with_content(%r{PublishPort=4200:8200})
      end

      it 'keeps the in-container listener on the container port 8200' do
        is_expected.to contain_file(config).with_content(%r{address\s*=\s*"0\.0\.0\.0:8200"})
      end

      it 'points the CLI wrapper at the container port 8200' do
        is_expected.to contain_file(wrapper).with_content(%r{--address=https://127\.0\.0\.1:8200})
      end
    end

    context 'with custom listen_port (host networking)' do
      let(:params) { { listen_port: 9200 } }

      it 'binds the listener directly on the override port' do
        is_expected.to contain_file(config).with_content(%r{address\s*=\s*"0\.0\.0\.0:9200"})
      end
    end

    # NOTE: mode=ha is NOT exercised here. The $nodes parameter is typed
    # Array[Struct[{ id, raft_host => Stdlib::Host, ... }]]; regent's type
    # checker cannot validate that nested Struct/Stdlib::Host alias and
    # rejects any array-of-hashes for it, so an HA catalog will not compile
    # under regent. HA rendering (peer list, PublishPort of Raft/API ports,
    # and host-mode HA binding directly with no PublishPort) is fully
    # covered in the rspec-puppet branch below, which runs under real Puppet.
  end
  return
end

describe 'bastionvault' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts.merge(bastionvault_user_uid: 1234) }

      context 'with defaults (single-node)' do
        it { is_expected.to compile.with_all_deps }

        it 'composes the image ref with no account segment' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{Image=docker\.io/bastionvault:0\.3\.2})
        end

        it 'uses host networking with no PublishPort mapping by default' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{^Network=host$})
            .without_content(%r{PublishPort})
        end

        it 'binds the in-container listener directly on the host port 4200' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{address\s*=\s*"0\.0\.0\.0:4200"})
        end

        it 'points the CLI wrapper at the host-facing port 4200' do
          is_expected.to contain_file('/usr/local/bin/bvault')
            .with_content(%r{--address=https://127\.0\.0\.1:4200})
        end

        it 'creates the host backup directory owned by the service user' do
          is_expected.to contain_file('/srv/application-data/bastionvault/backups').with(
            'ensure' => 'directory',
            'owner'  => 'bastionvault',
            'group'  => 'bastionvault',
            'mode'   => '0750',
          )
        end

        it 'bind-mounts the backup directory at /backups inside the container' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{Volume=/srv/application-data/bastionvault/backups:/backups:Z})
        end

        it 'renders config.hcl with single-node hiqlite block' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl').with_content(
            %r{storage "hiqlite"},
          )
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl').without_content(
            %r{listen_addr_raft},
          )
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl').without_content(
            %r{nodes\s*=},
          )
        end

        it 'renders plugin_runtime_dir pointing at an exec-allowed staging dir' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{plugin_runtime_dir\s*=\s*"/var/lib/bvault/plugin-run"})
        end
      end

      context 'with plugin_runtime_dir => undef' do
        let(:params) { { plugin_runtime_dir: :undef } }

        it 'omits the plugin_runtime_dir key so the server uses its OS-temp default' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .without_content(%r{plugin_runtime_dir})
        end

        it 'creates the non-root user with linger guard' do
          is_expected.to contain_user('bastionvault').with(
            system: true,
            shell:  '/sbin/nologin',
          )
          is_expected.to contain_exec('bastionvault-enable-linger-bastionvault')
        end

        it 'manages SELinux fcontext for the data dir' do
          is_expected.to contain_selinux__fcontext('bastionvault-data').with(
            pathspec: '/srv/application-data/bastionvault(/.*)?',
            seltype:  'container_file_t',
          )
        end

        it 'writes the cgroups slice drop-in' do
          is_expected.to contain_file('/etc/systemd/system/user-1234.slice.d/50-bastionvault.conf')
            .with_content(%r{MemoryMax=2G})
            .with_content(%r{CPUQuota=200%})
        end
      end

      context 'with image_account set' do
        let(:params) { { image_account: 'ffquintella' } }

        it 'includes the account in the image ref' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{Image=docker\.io/ffquintella/bastionvault:0\.3\.2})
        end
      end

      context 'with image_account containing a leading slash' do
        let(:params) { { image_account: '/bad' } }

        it { is_expected.to compile.and_raise_error(%r{must not start or end with}) }
      end

      context 'with custom registry, name, and tag' do
        let(:params) do
          {
            registry:    'registry.example.com',
            image_name:  'bastionvault',
            image_tag:   '1.0.0',
          }
        end

        it 'composes the full image ref' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{Image=registry\.example\.com/bastionvault:1\.0\.0})
        end
      end

      context 'with mode=ha and a valid 3-node peer list' do
        let(:params) do
          {
            mode:         'ha',
            node_id:      2,
            network_mode: 'pasta',
            nodes:        [
              { 'id' => 1, 'raft_host' => '10.0.0.11', 'raft_port' => 8210, 'api_host' => '10.0.0.11', 'api_port' => 8220 },
              { 'id' => 2, 'raft_host' => '10.0.0.12', 'raft_port' => 8210, 'api_host' => '10.0.0.12', 'api_port' => 8220 },
              { 'id' => 3, 'raft_host' => '10.0.0.13', 'raft_port' => 8210, 'api_host' => '10.0.0.13', 'api_port' => 8220 },
            ],
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'renders the hiqlite ha block with nodes and listen_addr_*' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{listen_addr_raft\s*=\s*"0\.0\.0\.0"})
            .with_content(%r{listen_addr_api\s*=\s*"0\.0\.0\.0"})
            .with_content(%r{port_raft\s*=\s*8210})
            .with_content(%r{port_api\s*=\s*8220})
            .with_content(%r{"1:10\.0\.0\.11:8210:10\.0\.0\.11:8220"})
            .with_content(%r{"2:10\.0\.0\.12:8210:10\.0\.0\.12:8220"})
            .with_content(%r{"3:10\.0\.0\.13:8210:10\.0\.0\.13:8220"})
        end

        it 'publishes raft and internal-api ports in the Quadlet unit' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{PublishPort=8210:8210})
            .with_content(%r{PublishPort=8220:8220})
        end
      end

      context 'with mode=ha under host networking (default)' do
        let(:params) do
          {
            mode:    'ha',
            node_id: 1,
            nodes:   [
              { 'id' => 1, 'raft_host' => '10.0.0.11', 'raft_port' => 8210, 'api_host' => '10.0.0.11', 'api_port' => 8220 },
            ],
          }
        end

        # Host netns shares the host network, so the Raft/API listeners bind
        # their ports directly — no PublishPort is emitted even in HA.
        it 'emits Network=host and no PublishPort even in HA' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{^Network=host$})
            .without_content(%r{PublishPort})
        end

        it 'still renders the HA peer list in config.hcl' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{"1:10\.0\.0\.11:8210:10\.0\.0\.11:8220"})
        end
      end

      context 'with mode=ha but missing nodes' do
        let(:params) { { mode: 'ha' } }

        it { is_expected.to compile.and_raise_error(%r{\$nodes is empty}) }
      end

      context 'with mode=ha and node_id not in peers' do
        let(:params) do
          {
            mode:    'ha',
            node_id: 99,
            nodes:   [
              { 'id' => 1, 'raft_host' => '10.0.0.11', 'raft_port' => 8210, 'api_host' => '10.0.0.11', 'api_port' => 8220 },
            ],
          }
        end

        it { is_expected.to compile.and_raise_error(%r{not present in \$nodes ids}) }
      end

      context 'with cluster TLS disabled on Raft and API' do
        let(:params) do
          {
            mode:                     'ha',
            node_id:                  1,
            nodes:                    [
              { 'id' => 1, 'raft_host' => '10.0.0.11', 'raft_port' => 8210, 'api_host' => '10.0.0.11', 'api_port' => 8220 },
            ],
            cluster_tls_raft_disable: true,
            cluster_tls_api_disable:  true,
          }
        end

        it 'emits both disable flags' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{tls_raft_disable\s*=\s*true})
            .with_content(%r{tls_api_disable\s*=\s*true})
        end
      end

      context 'with cluster TLS no_verify on Raft and API' do
        let(:params) do
          {
            mode:                       'ha',
            node_id:                    1,
            nodes:                      [
              { 'id' => 1, 'raft_host' => '10.0.0.11', 'raft_port' => 8210, 'api_host' => '10.0.0.11', 'api_port' => 8220 },
            ],
            cluster_tls_raft_no_verify: true,
            cluster_tls_api_no_verify:  true,
          }
        end

        it 'emits both no_verify flags' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{tls_raft_no_verify\s*=\s*true})
            .with_content(%r{tls_api_no_verify\s*=\s*true})
        end
      end

      context 'with custom listen_port (host networking)' do
        let(:params) { { listen_port: 9200 } }

        it 'binds the in-container listener directly on the override port' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{address\s*=\s*"0\.0\.0\.0:9200"})
        end
      end

      context 'with network_mode=pasta (legacy user-mode networking)' do
        let(:params) { { network_mode: 'pasta' } }

        it 'emits the user-mode network backend' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{^Network=pasta$})
        end

        it 'maps the host port 4200 to the in-container listener 8200' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{PublishPort=4200:8200})
        end

        it 'keeps the in-container listener on the container port 8200' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{address\s*=\s*"0\.0\.0\.0:8200"})
        end

        it 'points the CLI wrapper at the container port 8200' do
          is_expected.to contain_file('/usr/local/bin/bvault')
            .with_content(%r{--address=https://127\.0\.0\.1:8200})
        end
      end

      context 'with custom listen_port under pasta networking' do
        let(:params) { { listen_port: 9200, network_mode: 'pasta' } }

        it 'uses the override in the Quadlet PublishPort' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{PublishPort=9200:8200})
        end
      end
    end
  end

  context 'on an unsupported OS' do
    let(:facts) do
      {
        os: {
          family:  'Debian',
          name:    'Ubuntu',
          release: { major: '22', full: '22.04' },
        },
        networking: { fqdn: 'bv1.example.test' },
      }
    end

    it { is_expected.to compile.and_raise_error(%r{RedHat-family OS only}) }
  end

  context 'on EL8 (unsupported major)' do
    let(:facts) do
      {
        os: {
          family:  'RedHat',
          name:    'Rocky',
          release: { major: '8', full: '8.9' },
          selinux: { enabled: true },
        },
        networking: { fqdn: 'bv1.example.test' },
        bastionvault_user_uid: 1234,
      }
    end

    it { is_expected.to compile.and_raise_error(%r{EL9 and EL10 only}) }
  end
end
