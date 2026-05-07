# frozen_string_literal: true

require 'rspec-puppet'
require 'rspec-puppet-facts'

include RspecPuppetFacts

fixture_path = File.expand_path(File.join(__dir__, 'fixtures'))

RSpec.configure do |c|
  c.module_path    = File.join(fixture_path, 'modules')
  c.hiera_config   = File.join(__dir__, '..', 'hiera.yaml')
  c.default_facts  = {
    networking: { fqdn: 'bv1.example.test' },
  }
  c.mock_framework = :rspec
  c.mock_with :rspec do |m|
    m.syntax = :expect
  end
  c.color     = true
  c.formatter = :documentation
end
