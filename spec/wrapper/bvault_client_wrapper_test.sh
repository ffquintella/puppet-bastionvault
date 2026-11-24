#!/bin/sh
# Behavioural tests for templates/bvault-client-wrapper.sh.epp.
# The EPP is rendered with sed; the "binary" is a stub that prints its argv.
# Run: sh spec/wrapper/bvault_client_wrapper_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
tpl="$here/../../templates/bvault-client-wrapper.sh.epp"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
TLS_NAME=''

cat > "$work/bin" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
exit "${STUB_RC:-0}"
STUB
chmod +x "$work/bin"

# shellcheck disable=SC2016
render() {
  sed -e '1,/^| -%>/d' \
      -e 's|<%= \$server_url %>|https://vault.test:4200|g' \
      -e "s|<%= \$ca_cert_path %>|$work/none.pem|g" \
      -e "s|<%= \$tls_server_name %>|$TLS_NAME|g" \
      -e "s|<%= \$binary_path %>|$work/bin|g" "$tpl" > "$work/bvault"
  chmod +x "$work/bvault"
}

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
t() { if "$2"; then ok "$1"; else bad "$1"; printf '%s\n' "$out" | sed 's/^/     | /'; fi; }
sni() { printf '%s\n' "$out" | grep '^--tls-server-name='; }
hint='verified the server cert against'

# run <env-assignments-for-VAULT_TLS_SERVER_NAME-or-empty> -- args
runw() { render; out=$(env -u VAULT_TLS_SERVER_NAME "$@" 2>"$work/err"); rc=$?; }

TLS_NAME='puppet.test'
runw "$work/bvault" status
c1() { [ "$(sni)" = '--tls-server-name=puppet.test' ]; }
t 'default: Puppet value is used when neither flag nor env is set' c1

runw VAULT_TLS_SERVER_NAME=env.test "$work/bvault" status
c2() { [ "$(sni)" = '--tls-server-name=env.test' ]; }
t 'env override beats the Puppet default' c2

runw VAULT_TLS_SERVER_NAME=env.test "$work/bvault" status --tls-server-name=flag.test
c3() { [ "$(sni)" = '--tls-server-name=flag.test' ]; }
t 'explicit flag beats env (nothing injected twice)' c3

TLS_NAME=''
runw "$work/bvault" status
c4() { [ -z "$(sni)" ]; }
t 'no Puppet value and no env: no --tls-server-name' c4

TLS_NAME='puppet.test'
runw "$work/bvault" status
c5() { [ "$rc" -eq 0 ] && ! grep -q "$hint" "$work/err"; }
t 'hint absent on success' c5

runw STUB_RC=4 "$work/bvault" status
c6() { [ "$rc" -eq 4 ] && grep -q "$hint 'puppet.test'" "$work/err" \
  && grep -q 'VAULT_TLS_SERVER_NAME=<a name on the cert> bvault' "$work/err" \
  && ! printf '%s\n' "$out" | grep -q "$hint"; }
t 'hint on failure: names the injected name, stderr only, exit code kept' c6

runw STUB_RC=4 "$work/bvault" status --tls-server-name=x
c7() { [ "$rc" -eq 4 ] && ! grep -q "$hint" "$work/err"; }
t 'hint absent when the operator passed the flag' c7
runw STUB_RC=4 "$work/bvault" --version
t 'hint absent when nothing was injected (--version)' c7

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
