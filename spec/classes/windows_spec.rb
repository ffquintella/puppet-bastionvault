# frozen_string_literal: true

# Dual-mode spec for bastionvault::windows — same harness split as
# init_spec.rb / client_spec.rb. See init_spec.rb for the regent DSL
# capability notes (notably: without_content is a no-op under regent).
catalog_harness = begin
  require 'spec_helper'
  defined?(on_supported_os) ? :rspec_puppet : :regent
rescue StandardError, ScriptError
  :regent
end

FEED = 'https://nexus.example.test/repository/choco-hosted/'

if catalog_harness == :regent
  describe 'bastionvault::windows' do
    let(:facts) do
      {
        os: {
          family:  'windows',
          name:    'windows',
          release: { major: '2022', full: '10.0.20348' },
        },
        networking: {
          fqdn:     'ws1.example.test',
          hostname: 'ws1',
        },
      }
    end

    context 'with defaults' do
      let(:params) { { repo_url: FEED } }

      it { is_expected.to compile }
      it { is_expected.to contain_package('bastionvault-cli') }
      it { is_expected.to contain_package('bastionvault-gui') }
      it { is_expected.to contain_package('yubikey-manager') }
    end

    context 'with manage_ykman disabled' do
      let(:params) { { repo_url: FEED, manage_ykman: false } }

      it { is_expected.to compile }
      it { is_expected.not_to contain_package('yubikey-manager') }
    end

    context 'with pinned versions' do
      let(:params) do
        {
          repo_url:      FEED,
          client_ensure: '0.12.3',
          gui_ensure:    '0.12.3',
        }
      end

      it { is_expected.to compile }
    end
  end
else
  describe 'bastionvault::windows' do
    on_supported_os.select { |os, _facts| os.start_with?('windows') }.each do |os, os_facts|
      context "on #{os}" do
        let(:facts) { os_facts }

        context 'with defaults' do
          let(:params) { { repo_url: FEED } }

          it { is_expected.to compile.with_all_deps }

          it {
            is_expected.to contain_chocolateysource('bastionvault')
              .with_ensure('present')
              .with_location(FEED)
              .with_priority(0)
          }

          it 'installs the CLI from the managed source, by source name' do
            is_expected.to contain_package('bastionvault-cli')
              .with_ensure('installed')
              .with_provider('chocolatey')
              .with_source('bastionvault')
              .that_requires('Chocolateysource[bastionvault]')
          end

          it 'installs the GUI behind the CLI' do
            is_expected.to contain_package('bastionvault-gui')
              .with_ensure('installed')
              .with_provider('chocolatey')
              .with_source('bastionvault')
              .that_requires('Package[bastionvault-cli]')
          end

          it 'does not bootstrap Chocolatey by default' do
            is_expected.not_to contain_class('chocolatey')
          end

          it 'installs ykman ahead of the CLI, from Chocolatey default sources' do
            is_expected.to contain_package('yubikey-manager')
              .with_ensure('installed')
              .with_provider('chocolatey')
              .with_source(nil)

            is_expected.to contain_package('bastionvault-cli')
              .that_requires('Package[yubikey-manager]')
          end
        end

        context 'with manage_ykman disabled' do
          let(:params) { { repo_url: FEED, manage_ykman: false } }

          it { is_expected.not_to contain_package('yubikey-manager') }
        end

        context 'with a custom ykman package name, ensure, and source' do
          let(:params) do
            {
              repo_url:             FEED,
              ykman_package_name:   'ykman-cli',
              ykman_ensure:         '5.2.1',
              ykman_package_source: 'https://other.example.test/nuget/',
            }
          end

          it {
            is_expected.to contain_package('ykman-cli')
              .with_ensure('5.2.1')
              .with_provider('chocolatey')
              .with_source('https://other.example.test/nuget/')
          }
          it { is_expected.not_to contain_package('yubikey-manager') }
        end

        context 'when another module already declares the ykman package' do
          let(:pre_condition) { "package { 'yubikey-manager': ensure => latest, provider => chocolatey }" }
          let(:params) { { repo_url: FEED } }

          it { is_expected.to compile.with_all_deps }

          it 'does not redeclare it, leaving the pre-existing resource in charge' do
            is_expected.to contain_package('yubikey-manager').with_ensure('latest')
          end
        end

        context 'with pinned versions and custom package IDs' do
          let(:params) do
            {
              repo_url:            FEED,
              client_package_name: 'bvault-cli',
              gui_package_name:    'bvault-desktop',
              client_ensure:       '0.12.3',
              gui_ensure:          '0.12.2',
            }
          end

          it { is_expected.to contain_package('bvault-cli').with_ensure('0.12.3') }
          it { is_expected.to contain_package('bvault-desktop').with_ensure('0.12.2') }
          it { is_expected.not_to contain_package('bastionvault-cli') }
        end

        context 'with an authenticated feed' do
          let(:params) do
            {
              repo_url:      FEED,
              repo_user:     'svc_puppet',
              repo_password: sensitive('s3cr3t'),
              repo_priority: 1,
            }
          end

          it {
            is_expected.to contain_chocolateysource('bastionvault')
              .with_user('svc_puppet')
              .with_password('s3cr3t')
              .with_priority(1)
          }
        end

        context 'with repo_user but no repo_password' do
          let(:params) { { repo_url: FEED, repo_user: 'svc_puppet' } }

          it { is_expected.to compile.and_raise_error(%r{repo_password}) }
        end

        context 'with manage_repo disabled' do
          let(:params) { { repo_url: FEED, manage_repo: false } }

          it { is_expected.not_to contain_chocolateysource('bastionvault') }

          it 'falls back to the raw feed URL as the package source' do
            is_expected.to contain_package('bastionvault-cli').with_source(FEED)
          end
        end

        context 'with an explicit package_source override' do
          let(:params) { { repo_url: FEED, package_source: 'https://other.example.test/nuget/' } }

          it {
            is_expected.to contain_package('bastionvault-cli')
              .with_source('https://other.example.test/nuget/')
          }
        end

        context 'with manage_chocolatey' do
          let(:params) { { repo_url: FEED, manage_chocolatey: true } }

          it { is_expected.to contain_class('chocolatey') }

          it {
            is_expected.to contain_chocolateysource('bastionvault')
              .that_requires('Class[chocolatey]')
          }
        end

        context 'with install_options' do
          let(:params) { { repo_url: FEED, install_options: ['--ignore-checksums'] } }

          it {
            is_expected.to contain_package('bastionvault-cli')
              .with_install_options(['--ignore-checksums'])
          }

          it {
            is_expected.to contain_package('bastionvault-gui')
              .with_install_options(['--ignore-checksums'])
          }
        end

        context 'with a UNC package share as the feed' do
          let(:params) { { repo_url: '\\\\fileserver\\choco' } }

          it { is_expected.to compile.with_all_deps }
          it { is_expected.to contain_chocolateysource('bastionvault').with_location('\\\\fileserver\\choco') }
        end
      end
    end

    context 'on a non-Windows OS' do
      let(:facts) do
        {
          os: {
            family:  'RedHat',
            name:    'Rocky',
            release: { major: '9', full: '9.4' },
          },
        }
      end

      let(:params) { { repo_url: FEED } }

      it { is_expected.to compile.and_raise_error(%r{supports Windows only}) }
    end
  end
end
