#!/bin/sh
# Behavioural tests for templates/bvault-wrapper.sh.epp (no bats needed).
# The EPP is rendered with sed, sudo is replaced by a stub that prints every
# argument it receives (one per line), so podman is never executed.
# Run: sh spec/wrapper/bvault_wrapper_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
tpl="$here/../../templates/bvault-wrapper.sh.epp"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

PASSTHROUGH=${PASSTHROUGH:-}

render() {
  # drop the typed-parameter header, substitute the EPP values, point the
  # absolute sudo path at the stub
  sed -e '1,/^| -%>/d' \
      -e 's|<%= \$service_port %>|4200|g' \
      -e 's|<%= \$user %>|bastionvault|g' \
      -e "s|<%= \$passthrough_env %>|$PASSTHROUGH|g" \
      -e 's|<%= \$hsm_out_dir %>|/var/lib/bastionvault/hsm-out|g' \
      -e "s|/usr/bin/sudo|$work/sudo|g" "$tpl" > "$work/bvault"
  chmod +x "$work/bvault"
}

cat > "$work/sudo" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
STUB
chmod +x "$work/sudo"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

# run <args...>: wrapper output in $out (env cleared of address/ca/token vars)
run() {
  render
  out=$(env -u BVAULT_ADDR -u VAULT_ADDR -u VAULT_CACERT -u VAULT_CAPATH \
            -u VAULT_SKIP_VERIFY -u VAULT_TLS_SERVER_NAME "$@" 2>&1)
}
has()  { printf '%s\n' "$out" | grep -q -- "$1"; }
flags3() { has '^--address=' && has '^--ca-cert=' && has '^--tls-server-name='; }
noflags() { ! has '^--address' && ! has '^--ca-cert' && ! has '^--tls-server-name'; }

t() { # t <name> <cmd-that-returns-0-on-pass>
  if "$2"; then ok "$1"; else bad "$1"; printf '%s\n' "$out" | sed 's/^/     | /'; fi
}

# 1. local command: no injection
run "$work/bvault" operator hsm provision --connector http://127.0.0.1:12345 --out /hsm-out/a.json
c1() { noflags && has '^--connector$' && has '^/hsm-out/a.json$'; }
t 'operator hsm provision: no --address/--ca-cert/--tls-server-name' c1
for cmd in "server" "hsm-gateway --x" "operator cloud-target add" "operator hsm provision"; do
  # shellcheck disable=SC2086
  run "$work/bvault" $cmd
  c1b() { noflags; }
  t "local command '$cmd': no injection" c1b
done

# 2. HTTP commands keep all three flags
for cmd in "operator hsm status" "operator init" "operator hsm bootstrap" "operator hsm node add" \
           "operator hsm repair" "operator hsm recover" "operator hsm members" "login"; do
  # shellcheck disable=SC2086
  run "$work/bvault" $cmd
  t "'$cmd': keeps the three flags" flags3
done

# 3. bare / group invocations: no flags
for cmd in "--version" "operator" "operator hsm" "rustion master"; do
  # shellcheck disable=SC2086
  run "$work/bvault" $cmd
  t "'$cmd': no flags" noflags
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
