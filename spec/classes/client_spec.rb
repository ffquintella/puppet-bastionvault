# frozen_string_literal: true

# Dual-mode spec for bastionvault::client — same harness split as
# init_spec.rb: full matrix under rspec-puppet (CI), a regent-compatible
# subset otherwise. See init_spec.rb for the regent DSL capability notes.
catalog_harness = begin
  require 'spec_helper'
  defined?(on_supported_os) ? :rspec_puppet : :regent
rescue StandardError, ScriptError
  :regent
end

# A tiny self-signed-style PEM stand-in; content only needs to round-trip.
TEST_CA_PEM = "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n"

if catalog_harness == :regent
  describe 'bastionvault::client' do
    let(:facts) do
      {
        os: {
          family:  'RedHat',
          name:    'Rocky',
          release: { major: '9', full: '9.4' },
          selinux: { enabled: true },
        },
        networking: {
          fqdn:     'ws1.example.test',
          hostname: 'ws1',
          ip:       '10.0.0.50',
        },
      }
    end

    wrapper = '/usr/local/bin/bvault'

    context 'with defaults' do
      it { is_expected.to compile }
      it { is_expected.to contain_file(wrapper) }

      it 'execs the packaged binary' do
        is_expected.to contain_file(wrapper).with_content(%r{exec /usr/bin/bvault "\$@" \$extra})
      end

      it 'renders an empty address default (no server_url)' do
        is_expected.to contain_file(wrapper).with_content(%r{VAULT_ADDR:-""})
      end

      it 'points --ca-cert at the conventional trust anchor path' do
        is_expected.to contain_file(wrapper).with_content(%r{ca_file='/etc/bvault/ca\.pem'})
      end
    end

    context 'with a server_url' do
      let(:params) { { server_url: 'https://vault.example.test:4200' } }

      it { is_expected.to compile }

      it 'injects the configured address behind the env fallbacks' do
        is_expected.to contain_file(wrapper)
          .with_content(%r{VAULT_ADDR:-"https://vault\.example\.test:4200"})
      end
    end

    context 'with a tls_server_name' do
      let(:params) do
        {
          server_url:      'https://10.0.0.5:4200',
          tls_server_name: 'vault.example.test',
        }
      end

      it 'injects the SNI name behind the env fallback' do
        is_expected.to contain_file(wrapper)
          .with_content(%r{VAULT_TLS_SERVER_NAME:-"vault\.example\.test"})
      end
    end

    context 'with ca_cert_content' do
      let(:params) { { ca_cert_content: TEST_CA_PEM } }

      it { is_expected.to compile }
      it { is_expected.to contain_file('/etc/bvault') }

      it 'writes the trust anchor verbatim' do
        is_expected.to contain_file('/etc/bvault/ca.pem').with_content(%r{BEGIN CERTIFICATE})
      end
    end

    context 'with manage_wrapper disabled' do
      let(:params) { { manage_wrapper: false } }

      it { is_expected.to compile }
    end
  end
else
  describe 'bastionvault::client' do
    on_supported_os.each do |os, os_facts|
      context "on #{os}" do
        let(:facts) { os_facts }

        wrapper = '/usr/local/bin/bvault'

        context 'with defaults' do
          it { is_expected.to compile.with_all_deps }

          it { is_expected.to contain_package('bastionvault').with_ensure('installed') }

          it {
            is_expected.to contain_file(wrapper)
              .with_owner('root').with_group('root').with_mode('0755')
          }

          it 'execs the packaged binary' do
            is_expected.to contain_file(wrapper).with_content(%r{exec /usr/bin/bvault "\$@" \$extra})
          end

          it 'manages no trust anchor without CA input' do
            is_expected.not_to contain_file('/etc/bvault/ca.pem')
          end
        end

        context 'with a server_url' do
          let(:params) { { server_url: 'https://vault.example.test:4200' } }

          it 'injects the configured address behind the env fallbacks' do
            is_expected.to contain_file(wrapper)
              .with_content(%r{VAULT_ADDR:-"https://vault\.example\.test:4200"})
          end
        end

        context 'with ca_cert_content' do
          let(:params) { { ca_cert_content: TEST_CA_PEM } }

          it { is_expected.to contain_file('/etc/bvault').with_ensure('directory') }

          it {
            is_expected.to contain_file('/etc/bvault/ca.pem')
              .with_mode('0644').with_content(%r{BEGIN CERTIFICATE})
          }
        end

        context 'with ca_cert_base64' do
          let(:params) { { ca_cert_base64: Base64.strict_encode64(TEST_CA_PEM) } }

          it 'decodes and writes the trust anchor' do
            is_expected.to contain_file('/etc/bvault/ca.pem').with_content(%r{BEGIN CERTIFICATE})
          end
        end

        context 'with a custom ca_cert_path outside /etc/bvault' do
          let(:params) do
            {
              ca_cert_content: TEST_CA_PEM,
              ca_cert_path:    '/etc/pki/tls/certs/bvault-ca.pem',
            }
          end

          it { is_expected.to contain_file('/etc/pki/tls/certs/bvault-ca.pem') }
          it { is_expected.not_to contain_file('/etc/bvault') }
        end

        context 'with manage_package disabled' do
          let(:params) { { manage_package: false } }

          it { is_expected.not_to contain_package('bastionvault') }
          it { is_expected.to contain_file(wrapper) }
        end

        context 'with manage_wrapper disabled' do
          let(:params) { { manage_wrapper: false } }

          it { is_expected.not_to contain_file(wrapper) }
        end

        context 'with a package_source' do
          let(:params) { { package_source: 'https://example.test/bastionvault-0.9.0-1.x86_64.rpm' } }

          it {
            is_expected.to contain_package('bastionvault')
              .with_source('https://example.test/bastionvault-0.9.0-1.x86_64.rpm')
          }
        end

        context 'with manage_repo' do
          let(:params) do
            {
              manage_repo:  true,
              repo_baseurl: 'https://repo.example.test/bastionvault/el9',
            }
          end

          it {
            is_expected.to contain_yumrepo('bastionvault')
              .with_baseurl('https://repo.example.test/bastionvault/el9')
              .that_comes_before('Package[bastionvault]')
          }
        end

        context 'with manage_repo but no baseurl' do
          let(:params) { { manage_repo: true } }

          it { is_expected.to compile.and_raise_error(%r{repo_baseurl}) }
        end

        context 'when wrapper_path equals binary_path' do
          let(:params) { { wrapper_path: '/usr/bin/bvault' } }

          it { is_expected.to compile.and_raise_error(%r{wrapper_path must differ}) }
        end
      end
    end

    context 'on an unsupported OS' do
      let(:facts) do
        {
          os: {
            family:  'Debian',
            name:    'Ubuntu',
            release: { major: '24', full: '24.04' },
          },
        }
      end

      it { is_expected.to compile.and_raise_error(%r{RedHat-family}) }
    end
  end
end
