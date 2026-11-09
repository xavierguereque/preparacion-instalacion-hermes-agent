#!/usr/bin/env bash
# Verifica que el bloque común de UI/estado y el motor sean idénticos en
# prepare-macos.sh y prepare-linux.sh (se duplican a propósito para que cada
# script funcione solo con "curl | bash").
set -euo pipefail
cd "$(dirname "$0")/../scripts"

extract() { # extract <archivo> <marcador-inicio> <marcador-fin|EOF>
  if [ "$3" = "EOF" ]; then sed -n "/$2/,\$p" "$1"; else sed -n "/$2/,/$3/p" "$1"; fi
}

fail=0
if ! diff <(extract prepare-macos.sh 'BLOQUE COMÚN DE UI' 'FIN DEL BLOQUE COMÚN') \
          <(extract prepare-linux.sh 'BLOQUE COMÚN DE UI' 'FIN DEL BLOQUE COMÚN') >/dev/null; then
  echo "✖ El BLOQUE COMÚN difiere entre prepare-macos.sh y prepare-linux.sh"; fail=1
fi
if ! diff <(extract prepare-macos.sh 'MOTOR COMÚN' EOF) \
          <(extract prepare-linux.sh 'MOTOR COMÚN' EOF) >/dev/null; then
  echo "✖ El MOTOR COMÚN difiere entre prepare-macos.sh y prepare-linux.sh"; fail=1
fi
[ $fail -eq 0 ] && echo "✔ Bloques comunes sincronizados"
exit $fail
