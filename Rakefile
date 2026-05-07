# frozen_string_literal: true

require 'puppetlabs_spec_helper/rake_tasks'

begin
  require 'puppet-lint/tasks/puppet-lint'
rescue LoadError
  # puppet-lint optional
end

begin
  require 'metadata-json-lint/rake_task'
rescue LoadError
  # metadata-json-lint optional
end

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new(:rubocop) do |task|
    task.patterns = ['lib/**/*.rb', 'spec/**/*.rb']
  end
rescue LoadError
  # rubocop optional
end

task default: %i[validate lint spec]
task test: %i[validate lint spec]
