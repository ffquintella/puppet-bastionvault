# frozen_string_literal: true

# Dual-mode spec:
#   * Under MRI Ruby with rspec-puppet + rspec-puppet-facts loaded
#     (i.e. `bundle exec rake spec`), runs the full catalog test matrix.
#   * Under runners that lack those gems (e.g. `regent test`, whose
#     Artichoke Ruby ships only a built-in minimal DSL), falls through
#     to a smoke spec that only uses matchers regent supports
#     (`compile`, `contain_class`, `contain_file`).
catalog_harness = begin
  require 'spec_helper'
  defined?(on_supported_os) ? :rspec_puppet : :regent
rescue StandardError, ScriptError
  :regent
end

if catalog_harness == :regent
  describe 'bastionvault' do
    it { is_expected.to compile }
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

        it 'publishes the host port 4200 mapped to container 8200' do
          is_expected.to contain_file(
            '/var/lib/bastionvault/.config/containers/systemd/bastionvault.container',
          ).with_content(%r{PublishPort=4200:8200})
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
            mode:    'ha',
            node_id: 2,
            nodes:   [
              { 'id' => 1, 'raft_host' => '10.0.0.11', 'raft_port' => 8210, 'api_host' => '10.0.0.11', 'api_port' => 8220 },
              { 'id' => 2, 'raft_host' => '10.0.0.12', 'raft_port' => 8210, 'api_host' => '10.0.0.12', 'api_port' => 8220 },
              { 'id' => 3, 'raft_host' => '10.0.0.13', 'raft_port' => 8210, 'api_host' => '10.0.0.13', 'api_port' => 8220 },
            ],
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'renders the hiqlite ha block with nodes and listen_addr_*' do
          is_expected.to contain_file('/srv/application-config/bastionvault/config.hcl')
            .with_content(%r{listen_addr_raft\s*=\s*"0\.0\.0\.0:8210"})
            .with_content(%r{listen_addr_api\s*=\s*"0\.0\.0\.0:8220"})
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

      context 'with custom listen_port' do
        let(:params) { { listen_port: 9200 } }

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
