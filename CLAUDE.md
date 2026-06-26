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

`spec/classes/init_spec.rb` is dual-mode: a `catalog_harness` check picks a
regent branch (regent's minimal DSL) or an rspec-puppet branch (MRI + the
puppet/rspec-puppet gems, i.e. CI). Both run content assertions.

regent DSL — what works and what doesn't (verified empirically):

- **Supported**: `compile`, `contain_class`, `contain_file`, `with_content`,
  `let(:facts)`, `let(:params)`, nested `context`.
- **No `on_supported_os` / rspec-puppet-facts** — supply facts via
  `let(:facts)` (the regent branch hardcodes EL9 facts so the RedHat-only OS
  gate in `init.pp` compiles).
- **`without_content` is a NO-OP under regent** (always passes). Never rely on
  it to prove absence here. Assert absence with a POSITIVE match instead —
  e.g. `Network=host\nVolume=` proves no `PublishPort` line sits between them.
- **EPP that reads `$bastionvault::*` from scope renders `undef`** under
  regent. Templates whose content you want to assert must be **parameterized**
  (typed `<%- | ... | -%>` block) and fed via `epp(tpl, {...})` from the
  manifest. `bastionvault.container.epp` and `config.hcl.epp` were converted
  for exactly this reason.
- **`Sensitive#unwrap` inside EPP renders `undef`** under regent — unwrap in
  the manifest and pass the plain string to `epp()` (see `config.pp`, which
  passes the already-unwrapped Raft/API secrets).
- **Complex param types don't fully validate**: `$nodes` is
  `Array[Struct[{... Stdlib::Host ...}]]`, which regent's checker rejects, so
  **HA (`mode => 'ha'`) catalogs won't compile under regent**. HA rendering is
  covered only in the rspec-puppet branch.

Net: `regent test` exercises compile + resource presence + single-node /
networking-mode content; the rspec-puppet branch additionally covers HA,
multi-OS, and `without_content`-based assertions in CI.

For ad-hoc syntax checks, `puppet parser validate <file>.pp` and
`puppet epp validate <file>.epp` are available via `/opt/puppetlabs/bin/puppet`.
