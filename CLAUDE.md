# Project instructions — puppet-bastionvault

## Testing & validation: always use `regent`

This module is tested and validated with **regent** (the Rust/Artichoke Puppet
dev kit), not PDK or MRI Ruby. The local environment has no `puppet` gem, so
`bundle exec rake spec` / `rspec` cannot resolve dependencies, and `pdk`
reports the module as "not PDK compatible".

When running tests or validation, use regent:

- Run the test suite: `regent test`
- Detailed test output: `regent test --detail`
- Validate syntax/structure: `regent validate`
- Install required gems/runtime: `regent bootstrap`
- Download fixture modules from `.fixtures.yml`: `regent fixtures`

Do **not** use `pdk`, `bundle exec rake spec`, `bundle exec rspec`, or raw
`ruby`/`rspec` to run the suite — they are unsupported here and will fail.

### Spec notes

`spec/classes/init_spec.rb` is dual-mode: under regent's minimal DSL it runs a
smoke branch (matchers `compile`, `contain_class`, `contain_file` only) and
supplies EL9 facts via `let(:facts)` so the RedHat-only OS gate compiles. The
richer rspec-puppet assertions only run under MRI Ruby with rspec-puppet
loaded, which is not available locally — so the catalog-detail matchers are
exercised in CI, while `regent test` covers compile + resource presence here.

For ad-hoc syntax checks, `puppet parser validate <file>.pp` and
`puppet epp validate <file>.epp` are available via `/opt/puppetlabs/bin/puppet`.
