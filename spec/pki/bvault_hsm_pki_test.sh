#!/usr/bin/env bash
# Tests for tools/bvault-hsm-pki. Run: bash spec/pki/bvault_hsm_pki_test.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
H="$here/../../tools/bvault-hsm-pki"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
D="$work/p"
fail=0
ok()   { echo "ok   - $1"; }
nok()  { echo "FAIL - $1"; fail=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else nok "$d"; fi; }
refuse() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then nok "$d (should have failed)"; else ok "$d"; fi; }
text() { openssl x509 -in "$1" -noout -text; }

check "init-ca"                  "$H" -d "$D" init-ca
check "gateway (DNS+IP SAN)"     "$H" -d "$D" gateway hsm-a segbo1fpr0004.fgv.br 10.0.0.5
check "second gateway"           "$H" -d "$D" gateway hsm-b segdc1fpr0005.fgv.br
check "node 1"                   "$H" -d "$D" node segbo1fpr0004.fgv.br
check "node 2"                   "$H" -d "$D" node segdc1fpr0005.fgv.br
check "verify passes"            "$H" -d "$D" verify

# validity floors: CA >= 20y, certs >= 5y
check "CA valid for >= 20y"      openssl x509 -in "$D/ca.pem" -noout -checkend $((7299 * 86400))
check "certs valid for >= 5y"    openssl x509 -in "$D/hsm-a.pem" -noout -checkend $((1825 * 86400))
check "node cert valid for >= 5y" openssl x509 -in "$D/segdc1fpr0005.fgv.br.pem" -noout -checkend $((1825 * 86400))
refuse "cert days < 5y refused"  env BVAULT_PKI_CERT_DAYS=365 "$H" -d "$D" node short
refuse "CA days < 20y refused"   env BVAULT_PKI_CA_DAYS=3650 "$H" -d "$work/q" init-ca

# extensions
text "$D/hsm-a.pem" | grep -q "TLS Web Server Authentication" && ok "gateway EKU serverAuth" || nok "gateway EKU"
text "$D/hsm-a.pem" | grep -q "IP Address:10.0.0.5"           && ok "gateway IP SAN"         || nok "gateway IP SAN"
text "$D/segbo1fpr0004.fgv.br.pem" | grep -q "TLS Web Client Authentication" && ok "node EKU clientAuth" || nok "node EKU"
text "$D/segbo1fpr0004.fgv.br.pem" | grep -q "DNS:segbo1fpr0004.fgv.br"     && ok "node DNS SAN = node name" || nok "node SAN"
text "$D/ca.pem" | grep -q "CA:TRUE" && ok "CA basicConstraints" || nok "CA basicConstraints"

# safety
refuse "init-ca will not overwrite" "$H" -d "$D" init-ca
refuse "issue will not overwrite"   "$H" -d "$D" node segbo1fpr0004.fgv.br
refuse "hiera refuses ca.key"       "$H" -d "$D" hiera x ca.key
[ "$(stat -f %Lp "$D/ca.key" 2>/dev/null || stat -c %a "$D/ca.key")" = 600 ] && ok "ca.key is 0600" || nok "ca.key mode"
[ "$(stat -f %Lp "$D/hsm-a.key" 2>/dev/null || stat -c %a "$D/hsm-a.key")" = 600 ] && ok "leaf key is 0600" || nok "leaf key mode"

# hiera snippet carries the right keys and no CA key
out="$("$H" -d "$D" hiera x ca.pem hsm-a.pem hsm-a.key)"
echo "$out" | grep -q "bastionvault::hsm_link_files:" && echo "$out" | grep -q "'hsm-a.key':" && ok "hiera snippet" || nok "hiera snippet"
echo "$out" | grep -q "$(head -n2 "$D/ca.key" | tail -n1)" && nok "hiera leaked ca.key" || ok "hiera has no ca.key material"

# verify catches a mismatched key and a cert from a foreign CA
cp "$D/hsm-b.key" "$D/hsm-a.key.bak"; cp "$D/hsm-a.key" "$D/hsm-a.key.orig"; cp "$D/hsm-b.key" "$D/hsm-a.key"
refuse "verify catches key/cert mismatch" "$H" -d "$D" verify
cp "$D/hsm-a.key.orig" "$D/hsm-a.key"; rm -f "$D"/hsm-a.key.bak "$D"/hsm-a.key.orig
check "verify passes again after restore" "$H" -d "$D" verify

"$H" -d "$work/other" init-ca >/dev/null 2>&1 && "$H" -d "$work/other" node intruder >/dev/null 2>&1
cp "$work/other/intruder.pem" "$D/intruder.pem"; cp "$work/other/intruder.key" "$D/intruder.key"
refuse "verify rejects cert from another CA" "$H" -d "$D" verify

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
