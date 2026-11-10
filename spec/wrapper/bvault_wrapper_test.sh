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

# shellcheck disable=SC2016  # the EPP markers are literal text for sed
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

# 4. passthrough env: --env NAME without value, --preserve-env, no secret in argv
PASSTHROUGH='HSM_ADMIN_PW_A HSM_ADMIN_PW_B'
render
out=$(HSM_ADMIN_PW_A='s3cret-value' env -u HSM_ADMIN_PW_B "$work/bvault" operator hsm bootstrap 2>&1)
c4() {
  printf '%s\n' "$out" | grep -qx -- '--env' &&
  printf '%s\n' "$out" | grep -qx 'HSM_ADMIN_PW_A' &&
  has '^--preserve-env=.*HSM_ADMIN_PW_A' && ! has 's3cret-value'
}
t 'passthrough: --env NAME + --preserve-env, value never in argv' c4
# 5. unset variable: no --env for it
c5() { ! has 'HSM_ADMIN_PW_B'; }
t 'passthrough: unset variable is not forwarded' c5

# 6. token is forwarded by name only
render
out=$(VAULT_TOKEN='tok-secret-123' "$work/bvault" operator hsm status 2>&1)
c6() { printf '%s\n' "$out" | grep -qx 'VAULT_TOKEN' && ! has 'tok-secret-123' && has '^--preserve-env=.*VAULT_TOKEN'; }
t 'VAULT_TOKEN forwarded by name, value not in argv' c6

# 7. empty passthrough list renders a valid script
PASSTHROUGH=''
run "$work/bvault" operator hsm status
t 'empty passthrough list: still works' flags3

# 8. stdin/terminal flags of `podman exec`. With stdin on the operator's tty
# but stdout piped, a bare `-i` leaves the exec reading the tty from a
# background group: SIGTTIN stops it, Ctrl+C cannot reach it, later execs queue.
PASSTHROUGH=''
render
# expected flags: stdin pipe/file -> -i; tty+tty -> -i -t; tty stdin, other stdout -> none
exec_flags() { printf '%s\n' "$out" | tr -d '\r' | grep -x -e '-i' -e '-t' | tr '\n' ' '; }

out=$(echo data | "$work/bvault" operator hsm status 2>&1)
c8a() { [ "$(exec_flags)" = '-i ' ]; }
t 'stdin pipe: -i, no -t' c8a
out=$("$work/bvault" operator hsm status </dev/null 2>&1)
t 'stdin /dev/null: -i, no -t' c8a

if command -v python3 >/dev/null 2>&1; then
  # pty.fork, not pty.spawn: spawn blocks when the caller's own stdin is not a tty (CI)
  pty() {
    python3 -c 'import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
buf = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    buf += d
_, st = os.waitpid(pid, 0)
sys.stdout.buffer.write(buf)
sys.exit(os.waitstatus_to_exitcode(st))' "$@"
  }

  out=$(pty "$work/bvault" operator hsm status 2>&1)
  c8b() { [ "$(exec_flags)" = '-i -t ' ]; }
  t 'stdin tty + stdout tty: -i -t' c8b

  out=$(pty sh -c "\"$work/bvault\" operator hsm status | cat" 2>&1)
  c8c() { [ "$(exec_flags)" = '' ]; }
  t 'stdin tty + stdout piped: neither -i nor -t (no tty read, cannot hang)' c8c

  out=$(pty sh -c "\"$work/bvault\" operator hsm status > $work/o.txt; cat $work/o.txt" 2>&1)
  t 'stdin tty + stdout redirected to a file: neither -i nor -t' c8c
else
  printf 'skip - tty cases need python3\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
