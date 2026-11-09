#!/usr/bin/env bash
# =============================================================================
#  Preparación para Hermes Agent · lanzador universal (macOS / Linux)
#
#    curl -fsSL https://raw.githubusercontent.com/xavierguereque/preparacion-instalacion-hermes-agent/main/install.sh | bash
#    wget -qO-  https://raw.githubusercontent.com/xavierguereque/preparacion-instalacion-hermes-agent/main/install.sh | bash
#
#  Con opciones:  ... | bash -s -- --check-only
#
#  Detecta el sistema operativo y ejecuta el script que corresponde.
#  En Windows usa PowerShell (ver README).
# =============================================================================
RAW_BASE="${HERMES_PREP_RAW:-https://raw.githubusercontent.com/xavierguereque/preparacion-instalacion-hermes-agent/main}"

case "$(uname -s)" in
  Darwin) script="prepare-macos.sh" ;;
  Linux)  script="prepare-linux.sh" ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "En Windows ejecuta en PowerShell:"
    echo "  irm $RAW_BASE/scripts/prepare-windows.ps1 | iex"
    exit 1 ;;
  *) echo "Sistema operativo no soportado: $(uname -s)"; exit 1 ;;
esac

# Si se ejecuta desde una copia local del repo, usar el script local.
src="${BASH_SOURCE[0]:-}"
if [ -n "$src" ] && [ -f "$src" ]; then
  here="$(cd "$(dirname "$src")" && pwd)"
  if [ -f "$here/scripts/$script" ]; then exec bash "$here/scripts/$script" "$@"; fi
fi

tmp="$(mktemp)"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$RAW_BASE/scripts/$script" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp" "$RAW_BASE/scripts/$script"
else
  echo "Se necesita curl o wget para descargar $script."; rm -f "$tmp"; exit 1
fi || { echo "No se pudo descargar $RAW_BASE/scripts/$script"; rm -f "$tmp"; exit 1; }

bash "$tmp" "$@"
rc=$?
rm -f "$tmp"
exit $rc
