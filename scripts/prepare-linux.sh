#!/usr/bin/env bash
# =============================================================================
#  Preparación para Hermes Agent · Linux (apt · dnf · pacman)
#  Diagnostica, instala solo lo que falta y reanuda donde se quedó.
#
#  Uso:
#    curl -fsSL https://raw.githubusercontent.com/xavierguereque/preparacion-instalacion-hermes-agent/main/install.sh | bash
#    ./scripts/prepare-linux.sh [--check-only] [--yes] [--no-hermes] [--reset] [--no-color]
#
#  Requiere bash 3.2 o superior.
# =============================================================================

PREP_VERSION="1.0.2"
PLATFORM_NAME="Linux"
HERMES_INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"

# ----------------------------------------------------------------------------
#  Opciones
# ----------------------------------------------------------------------------
CHECK_ONLY=0; ASSUME_YES=0; NO_HERMES=0; RESET=0; NO_COLOR_FLAG=0
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --no-hermes)  NO_HERMES=1 ;;
    --reset)      RESET=1 ;;
    --no-color)   NO_COLOR_FLAG=1 ;;
    -h|--help)
      echo "Uso: $0 [--check-only] [--yes] [--no-hermes] [--reset] [--no-color]"
      echo "  --check-only  Solo diagnostica, no instala nada."
      echo "  --yes         Responde que sí a todas las preguntas."
      echo "  --no-hermes   No ofrece lanzar el instalador oficial al final."
      echo "  --reset       Borra el estado guardado y empieza de cero."
      echo "  --no-color    Salida sin colores."
      exit 0 ;;
    *) echo "Opción desconocida: $arg (usa --help)"; exit 2 ;;
  esac
done
[ "${HERMES_PREP_YES:-0}" = "1" ] && ASSUME_YES=1
[ "${HERMES_PREP_CHECK_ONLY:-0}" = "1" ] && CHECK_ONLY=1
[ "${HERMES_PREP_NO_HERMES:-0}" = "1" ] && NO_HERMES=1

# ============================================================================
#  BLOQUE COMÚN DE UI + ESTADO  (idéntico en prepare-macos.sh y prepare-linux.sh)
# ============================================================================
STATE_DIR="$HOME/.hermes-prep"
STATE_FILE="$STATE_DIR/state"
mkdir -p "$STATE_DIR" 2>/dev/null

# Log de cada ejecución en Descargas/hermes-prep-logs (para compartirlo si algo falla)
downloads_dir() {
  local d=""
  if command -v xdg-user-dir >/dev/null 2>&1; then d="$(xdg-user-dir DOWNLOAD 2>/dev/null)"; [ "$d" = "$HOME" ] && d=""; fi
  [ -z "$d" ] && [ -d "$HOME/Descargas" ] && d="$HOME/Descargas"
  [ -z "$d" ] && d="$HOME/Downloads"
  echo "$d"
}
RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="$(downloads_dir)/hermes-prep-logs"
LOG_FILE="$LOG_DIR/hermes-prep-$RUN_STAMP.log"
if ! { mkdir -p "$LOG_DIR" && : >>"$LOG_FILE"; } 2>/dev/null; then
  LOG_DIR="$STATE_DIR"; LOG_FILE="$STATE_DIR/hermes-prep-$RUN_STAMP.log"; : >>"$LOG_FILE"
fi

IS_TTY=0; [ -t 1 ] && IS_TTY=1
HAS_DEVTTY=0; { : </dev/tty; } 2>/dev/null && HAS_DEVTTY=1

if [ "$IS_TTY" = "1" ] && [ "$NO_COLOR_FLAG" = "0" ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[0m'; C_B=$'\033[1m'; C_D=$'\033[2m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'; C_CYN=$'\033[36m'; C_MAG=$'\033[35m'
else
  C_R=""; C_B=""; C_D=""; C_GRN=""; C_YEL=""; C_RED=""; C_CYN=""; C_MAG=""
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*|*utf-8*) UTF=1 ;;
  *) UTF=0; [ "$(uname -s)" = "Darwin" ] && UTF=1 ;;
esac
if [ "$UTF" = "1" ]; then
  G_OK="✔"; G_WARN="⚠"; G_ERR="✖"; G_SKIP="↷"; G_TODO="•"; B_FULL="█"; B_EMPTY="░"
  SPIN_FRAMES="⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏"; H_LINE="═"; V_LINE="║"; C_TL="╔"; C_TR="╗"; C_BL="╚"; C_BR="╝"
else
  G_OK="OK"; G_WARN="!!"; G_ERR="XX"; G_SKIP="--"; G_TODO="*"; B_FULL="#"; B_EMPTY="."
  SPIN_FRAMES="| / - \\"; H_LINE="="; V_LINE="|"; C_TL="+"; C_TR="+"; C_BL="+"; C_BR="+"
fi
# shellcheck disable=SC2206
SPIN_ARR=($SPIN_FRAMES)
SPIN_PID=""

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG_FILE"; }

# Rellena con espacios contando caracteres (no bytes) para que las tildes alineen.
pad() {
  local s="$1" w="$2" n
  n=${#s}
  if [ "$n" -gt "$w" ]; then s="${s:0:$((w-1))}…"; n=$w; fi
  printf '%s' "$s"
  while [ "$n" -lt "$w" ]; do printf ' '; n=$((n+1)); done
}

repeat() { local i=0; while [ $i -lt "$2" ]; do printf '%s' "$1"; i=$((i+1)); done; }

bar() { # bar <hechos> <total> <ancho>
  local done="$1" total="$2" w="${3:-28}" fill
  [ "$total" -le 0 ] && total=1
  fill=$(( done * w / total ))
  printf '%s%s%s%s%s' "$C_GRN" "$(repeat "$B_FULL" "$fill")" "$C_D" "$(repeat "$B_EMPTY" $((w-fill)))" "$C_R"
}

pct() { [ "$2" -le 0 ] && { echo 100; return; }; echo $(( $1 * 100 / $2 )); }

ui_banner() {
  local title="$1" w=64
  echo
  printf ' %s%s%s%s%s\n' "$C_CYN" "$C_TL" "$(repeat "$H_LINE" $w)" "$C_TR" "$C_R"
  printf ' %s%s%s %s%s%s %s%s%s\n' "$C_CYN" "$V_LINE" "$C_R" "$C_B" "$(pad "$title" $((w-2)))" "$C_R" "$C_CYN" "$V_LINE" "$C_R"
  printf ' %s%s%s%s%s\n' "$C_CYN" "$C_BL" "$(repeat "$H_LINE" $w)" "$C_BR" "$C_R"
}

ui_section() { echo; printf ' %s%s%s %s%s%s\n' "$C_MAG" "$C_B" "$1" "$C_D" "${2:-}" "$C_R"; }

clear_line() { [ "$IS_TTY" = "1" ] && printf '\r\033[K'; }

# Línea de progreso animada: [3/5] ⠹ Etiqueta — acción  ████░░░ 40%  12s
draw_progress() {
  [ "$IS_TTY" = "1" ] || return 0
  local pos="$1" total="$2" frame="$3" label="$4" action="$5" secs="${6:-}"
  local done=$((pos-1)); [ $done -lt 0 ] && done=0
  printf '\r\033[K %s[%d/%d]%s %s%s%s %s %s%s%s  %s %s%3d%%%s %s' \
    "$C_B" "$pos" "$total" "$C_R" "$C_CYN" "$frame" "$C_R" \
    "$(pad "$label" 18)" "$C_D" "$(pad "$action" 26)" "$C_R" \
    "$(bar $done "$total" 20)" "$C_B" "$(pct $done "$total")" "$C_R" \
    "${secs:+${secs}s}"
}

# Fila de resultado
#   ui_row <ok|update|missing|fail|warn|skip|done> <etiqueta> <versión> <mensaje>
ui_row() {
  local st="$1" label="$2" ver="${3:-—}" msg="${4:-}" g c t
  case "$st" in
    ok)      g="$G_OK";   c="$C_GRN"; t="LISTO " ;;
    done)    g="$G_OK";   c="$C_GRN"; t="LISTO " ;;
    skip)    g="$G_SKIP"; c="$C_GRN"; t="OMITIDO" ;;
    update)  g="$G_WARN"; c="$C_YEL"; t="ACTUALIZAR" ;;
    missing) g="$G_TODO"; c="$C_YEL"; t="FALTA " ;;
    warn)    g="$G_WARN"; c="$C_YEL"; t="AVISO " ;;
    *)       g="$G_ERR";  c="$C_RED"; t="ERROR " ;;
  esac
  [ -z "$ver" ] && ver="—"
  log "[$t] $label | $ver | $msg"
  clear_line
  printf '   %s%s %s%s %s %s%s%s %s\n' "$c" "$g" "$(pad "$t" 10)" "$C_R" "$(pad "$label" 20)" "$C_D" "$(pad "$ver" 14)" "$C_R" "$msg"
}

# Pregunta sí/no leyendo de /dev/tty (funciona con curl | bash). Default: S.
ask_yes() {
  local q="$1" ans
  if [ "$ASSUME_YES" = "1" ]; then printf ' %s?%s %s %s[S/n]%s s (--yes)\n' "$C_CYN" "$C_R" "$q" "$C_D" "$C_R"; return 0; fi
  if [ "$HAS_DEVTTY" = "0" ]; then printf ' %s (sin terminal interactiva: se asume que no; usa --yes)\n' "$q"; return 1; fi
  printf ' %s?%s %s %s[S/n]%s ' "$C_CYN" "$C_R" "$q" "$C_D" "$C_R"
  read -r ans </dev/tty || ans="n"
  case "$ans" in ""|s|S|si|SI|sí|Sí|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# Ejecuta un comando en segundo plano con spinner; la salida va al log.
CUR_POS=1; CUR_TOTAL=1; CUR_LABEL=""
spin() { # spin "<acción visible>" cmd args...
  local action="$1"; shift
  local start=$SECONDS rc i=0 n=${#SPIN_ARR[@]}
  log "RUN: $*"
  if [ "$IS_TTY" = "0" ]; then
    printf '   ... %s: %s\n' "$CUR_LABEL" "$action"
    "$@" >>"$LOG_FILE" 2>&1 </dev/null; rc=$?
    log "RC=$rc"; return $rc
  fi
  printf '\033[?25l'
  "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  SPIN_PID=$!
  while kill -0 "$SPIN_PID" 2>/dev/null; do
    draw_progress "$CUR_POS" "$CUR_TOTAL" "${SPIN_ARR[$((i % n))]}" "$CUR_LABEL" "$action" $((SECONDS-start))
    i=$((i+1)); sleep 0.1
  done
  wait "$SPIN_PID"; rc=$?
  SPIN_PID=""
  printf '\033[?25h'
  log "RC=$rc"
  return $rc
}

ver_ge() { # ver_ge 3.12.1 3.11  -> 0 si a >= b
  awk -v a="$1" -v b="$2" 'BEGIN{n=split(a,x,".");m=split(b,y,".");k=(n>m?n:m);
    for(i=1;i<=k;i++){p=x[i]+0;q=y[i]+0;if(p>q)exit 0;if(p<q)exit 1}exit 0}'
}
first_version() { grep -oE '[0-9]+(\.[0-9]+)+' | head -1; }
# Recorta stdin a N bytes sin dejar un carácter UTF-8 partido (cut -c en macOS cuenta bytes).
short_text() {
  if have iconv; then cut -c1-"$1" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null; else cut -c1-"$1"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }

# --- Estado persistente (key=value) ---
state_get() { [ -f "$STATE_FILE" ] || return 0; sed -n "s/^$1=//p" "$STATE_FILE" | tail -1; }
state_set() {
  local tmp="$STATE_FILE.tmp"
  { grep -v "^$1=" "$STATE_FILE" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } >"$tmp" && mv "$tmp" "$STATE_FILE"
}

on_interrupt() {
  [ -n "$SPIN_PID" ] && kill "$SPIN_PID" 2>/dev/null
  [ "$IS_TTY" = "1" ] && printf '\033[?25h'; clear_line; echo
  [ "$(state_get run_status)" = "running" ] && state_set run_status interrupted
  if [ -n "$CUR_LABEL" ]; then
    printf ' %s%s Interrumpido%s en [%s/%s] %s.\n' "$C_YEL" "$G_WARN" "$C_R" "$CUR_POS" "$CUR_TOTAL" "$CUR_LABEL"
    printf '   Vuelve a ejecutar el mismo comando para continuar desde ahí.\n'
    log "RESULTADO: interrumpido en $CUR_LABEL"
  else
    printf ' %s%s Cancelado.%s Lo que ya se instaló queda instalado.\n' "$C_YEL" "$G_WARN" "$C_R"
    log "RESULTADO: cancelado por el usuario (fuera de un paso)"
  fi
  show_log_path
  exit 130
}
trap on_interrupt INT TERM
trap '[ "$IS_TTY" = "1" ] && printf "\033[?25h"' EXIT

show_log_path() {
  printf '\n   %sLog de esta ejecución:%s %s\n' "$C_B" "$C_R" "$(tilde "$LOG_FILE")"
  printf '   %s(si algo falló, comparte este archivo para diagnosticarlo)%s\n\n' "$C_D" "$C_R"
}

log_system_info() {
  {
    echo "--- Sistema ---"
    echo "uname: $(uname -a)"
    [ -r /etc/os-release ] && grep -E '^(PRETTY_NAME|ID|VERSION_ID)=' /etc/os-release
    command -v sw_vers >/dev/null 2>&1 && sw_vers
    echo "usuario: $(id -un) (uid $(id -u)) · shell: ${SHELL:-?} · bash: $BASH_VERSION"
    echo "locale: ${LC_ALL:-${LANG:-?}} · tty: $IS_TTY · opciones: check=$CHECK_ONLY yes=$ASSUME_YES no-hermes=$NO_HERMES"
    echo "PATH: $PATH"
    echo "--- Estado previo ($STATE_FILE) ---"
    cat "$STATE_FILE" 2>/dev/null || echo "(sin estado previo)"
    echo "---------------"
  } >>"$LOG_FILE" 2>&1
}

add_line_once() { # add_line_once <archivo> <línea>
  touch "$1" 2>/dev/null
  grep -qF "$2" "$1" 2>/dev/null || printf '\n# Añadido por hermes-prep\n%s\n' "$2" >>"$1"
}

user_rc_file() {
  case "$(basename "${SHELL:-bash}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) if [ "$(uname -s)" = "Darwin" ]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi ;;
    *)    echo "$HOME/.profile" ;;
  esac
}
# --- Rutas legibles: /Users/x/a -> ~/a (funciona igual en bash 3.2 y 5) ---
tilde() { case "$1" in "$HOME"/*|"$HOME") printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# --- En macOS sin Xcode CLT, /usr/bin/git y /usr/bin/python3 son "stubs" que
#     abren la ventana de instalación de Apple: nunca hay que ejecutarlos. ---
is_apple_stub() {
  [ "$(uname -s)" = "Darwin" ] || return 1
  case "$(command -v "$1" 2>/dev/null)" in
    /usr/bin/*) xcode-select -p >/dev/null 2>&1 && return 1; return 0 ;;
  esac
  return 1
}

# ============================================================================
#  REVISIONES COMPARTIDAS (macOS y Linux)
#  Cada check_* deja: CHK_STATUS (ok|update|missing|fail|warn), CHK_VER, CHK_MSG
# ============================================================================
chk() { CHK_STATUS="$1"; CHK_VER="$2"; CHK_MSG="$3"; }

check_disk() {
  local kb gb
  kb="$(df -Pk "$HOME" | awk 'NR==2{print $4}')"; gb=$(( ${kb:-0} / 1048576 ))
  if [ "$gb" -lt "$DISK_FAIL_GB" ]; then chk fail "${gb} GB libres" "se necesitan al menos ${DISK_MIN_GB} GB"
  elif [ "$gb" -lt "$DISK_MIN_GB" ]; then chk warn "${gb} GB libres" "poco espacio; se recomiendan ${DISK_MIN_GB} GB"
  else chk ok "${gb} GB libres" "suficiente"; fi
}

net_probe() {
  if have curl; then curl -sk -o /dev/null --connect-timeout 8 --max-time 12 -I "https://$1" 2>/dev/null
  elif have wget; then wget -q --no-check-certificate --spider -T 10 "https://$1" 2>/dev/null
  else timeout 10 bash -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null; fi
}
NET_HOSTS="github.com raw.githubusercontent.com hermes-agent.nousresearch.com"
check_net() {
  # Las tres pruebas van en paralelo (antes podían sumar ~36 s con red lenta)
  local okc=0 bad="" h i=0 pids="" d p
  d="$(mktemp -d 2>/dev/null || echo "$STATE_DIR/net.$$")"; mkdir -p "$d"
  for h in $NET_HOSTS; do
    ( net_probe "$h" && : >"$d/ok.$i" ) &
    pids="$pids $!"; i=$((i+1))
  done
  for p in $pids; do wait "$p" 2>/dev/null; done
  i=0
  for h in $NET_HOSTS; do
    if [ -e "$d/ok.$i" ]; then okc=$((okc+1)); else bad="$bad $h"; fi
    i=$((i+1))
  done
  rm -rf "$d"
  case "$bad" in
    "") chk ok "3/3 sitios" "github y hermes accesibles" ;;
    *github*) chk fail "$okc/3 sitios" "sin acceso a:$bad → revisa internet/proxy" ;;
    *) chk warn "$okc/3 sitios" "sin acceso a:$bad" ;;
  esac
}

check_curl() {
  if have curl; then chk ok "$(curl --version 2>/dev/null | head -1 | first_version)" "ya instalado"; else chk missing "" "se instalará"; fi
}

check_git() {
  local v
  if have git && is_apple_stub git; then chk missing "" "solo existe el stub de Apple (faltan Xcode CLT)"; return; fi
  if ! have git; then chk missing "" "se instalará"; return; fi
  local out rc; out="$(git --version 2>&1)"; rc=$?
  # git existe pero no responde (en macOS: licencia de Xcode sin aceptar): muestra su propio error.
  if [ $rc -ne 0 ]; then chk missing "" "git no responde: $(printf '%s' "$out" | head -1 | short_text 50)"; return; fi
  v="$(printf '%s' "$out" | first_version)"
  if [ -z "$v" ]; then chk missing "" "se instalará"
  elif ver_ge "$v" "$GIT_MIN"; then chk ok "$v" "ya instalado"; else chk update "$v" "versión menor a $GIT_MIN"; fi
}

check_node() {
  local v major npmv
  if ! have node; then chk missing "" "se instalará Node.js LTS"; return; fi
  v="$(node -v 2>/dev/null | first_version)"; major="${v%%.*}"
  npmv="$(npm -v 2>/dev/null | first_version)"
  if [ "${major:-0}" -lt "$NODE_MIN" ]; then chk update "$v" "menor a v$NODE_MIN ($(command -v node))"; return; fi
  if [ -z "$npmv" ]; then chk update "$v" "npm no responde"; return; fi
  chk ok "$v" "npm $npmv"
}

best_python() { # imprime "<versión> <binario>" de la mejor versión disponible
  local best="" bestbin="" c v
  for c in python3 python3.14 python3.13 python3.12 python3.11; do
    have "$c" || continue
    is_apple_stub "$c" && continue
    v="$("$c" --version 2>&1 | first_version)"; [ -z "$v" ] && continue
    if [ -z "$best" ] || ! ver_ge "$best" "$v"; then best="$v"; bestbin="$c"; fi
  done
  [ -n "$best" ] && echo "$best $bestbin"
}
check_python() {
  local r v
  r="$(best_python)"; v="${r%% *}"
  if [ -z "$r" ]; then chk missing "" "se instalará"
  elif ver_ge "$v" "$PY_MIN"; then chk ok "$v" "${r#* }"
  else chk update "$v" "versión menor a $PY_MIN"; fi
}

check_rg()     { if have rg; then chk ok "$(rg --version 2>/dev/null | first_version)" "ya instalado"; else chk missing "" "se instalará"; fi; }
check_ffmpeg() { if have ffmpeg; then chk ok "$(ffmpeg -version 2>/dev/null | head -1 | first_version)" "ya instalado"; else chk missing "" "se instalará"; fi; }
check_path() {
  local rc; rc="$(user_rc_file)"
  case ":$PATH_AT_START:" in *":$HOME/.local/bin:"*) chk ok "" "ya está en PATH"; return ;; esac
  if grep -qs '\.local/bin' "$rc"; then chk ok "" "configurado en $(tilde "$rc")"
  else chk missing "" "se agregará a $(tilde "$rc")"; fi
}

install_path() {
  mkdir -p "$HOME/.local/bin"
  # shellcheck disable=SC2016
  add_line_once "$(user_rc_file)" 'export PATH="$HOME/.local/bin:$PATH"'
  export PATH="$HOME/.local/bin:$PATH"
  PATH_AT_START="$PATH"
}

prime_sudo() {
  printf '\n   %s%s%s Algunos pasos necesitan tu contraseña de administrador (sudo).\n' "$C_CYN" "$G_TODO" "$C_R"
  if [ "$HAS_DEVTTY" = "1" ]; then sudo -v </dev/tty || return 1; else sudo -n -v 2>/dev/null || return 1; fi
  ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) >/dev/null 2>&1 &
}

# Ejecuta el instalador oficial. Si falla (típico: "Connection reset by peer" / "early EOF"
# al clonar), ofrece reintentar forzando HTTP/1.1 solo para ese proceso, sin tocar ~/.gitconfig.
HERMES_TRIES=3
run_hermes_installer() { # run_hermes_installer <script> <intento>
  local -a pre=()
  [ "$2" -gt 1 ] && pre=(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1)
  if [ "$HAS_DEVTTY" = "1" ]; then ${pre[@]+"${pre[@]}"} bash "$1" </dev/tty; else ${pre[@]+"${pre[@]}"} bash "$1"; fi
}
HERMES_LOG="${HERMES_HOME:-$HOME/.hermes}/logs/install.log"
HERMES_NET_RE='Connection reset|early EOF|RPC failed|curl [0-9]+|unexpected disconnect|timed out|Could not resolve host|SSL_ERROR|gnutls_handshake'
# ¿Por qué falló el instalador? Lee lo que escribió en su log desde la línea $1.
#   net = corte de red (vale la pena reintentar) · other = otra causa · unknown = sin log
hermes_failure_kind() {
  [ -f "$HERMES_LOG" ] || { echo unknown; return; }
  if tail -n "+$1" "$HERMES_LOG" 2>/dev/null | grep -Eqi "$HERMES_NET_RE"; then echo net; else echo other; fi
}
# Carpeta donde el instalador oficial deja el código (mismas variables que él usa).
HERMES_DIR="${HERMES_INSTALL_DIR:-${HERMES_HOME:-$HOME/.hermes}/hermes-agent}"
# Si esa carpeta existe pero no es un clon de git usable (p. ej. quedó de un intento manual con
# el .tar.gz o de un clon cortado), el instalador oficial se detiene: "exists and is not a Hermes
# git checkout". Se borra, con confirmación, para que pueda clonar de nuevo.
clean_broken_hermes_dir() {
  [ -e "$HERMES_DIR" ] || return 0
  if [ -L "$HERMES_DIR" ]; then
    printf ' %s%s %s es un enlace simbólico; no se toca.%s\n' "$C_YEL" "$G_WARN" "$(tilde "$HERMES_DIR")" "$C_R"; return 0
  fi
  [ -d "$HERMES_DIR/.git" ] && git -C "$HERMES_DIR" rev-parse --verify HEAD >/dev/null 2>&1 && return 0
  [ -d "$HERMES_DIR" ] && [ -z "$(ls -A "$HERMES_DIR" 2>/dev/null)" ] && return 0
  echo
  printf ' %s%s %s existe pero no es una instalación válida de Hermes%s (sin clon de git usable).\n' \
    "$C_YEL" "$G_WARN" "$(tilde "$HERMES_DIR")" "$C_R"
  printf '   Quedó de un intento anterior y el instalador oficial no puede continuar con ella.\n'
  if ! ask_yes "¿Borrarla para instalar Hermes desde cero?"; then
    printf '   No se borró. Hazlo a mano con:  rm -rf %s\n' "$(tilde "$HERMES_DIR")"; return 1
  fi
  log "HERMES: se borra carpeta inválida $HERMES_DIR"
  rm -rf "$HERMES_DIR" || { printf '   %s%s No se pudo borrar %s.%s\n' "$C_RED" "$G_ERR" "$(tilde "$HERMES_DIR")" "$C_R"; return 1; }
  printf '   %s%s Borrada.%s\n' "$C_GRN" "$G_OK" "$C_R"
}
launch_hermes() {
  local tmp rc attempt=1 from kind=""
  clean_broken_hermes_dir || return 1
  tmp="$(mktemp)"
  curl -fsSL "$HERMES_INSTALL_URL" -o "$tmp" || { echo "No se pudo descargar $HERMES_INSTALL_URL"; rm -f "$tmp"; return 1; }
  while :; do
    log "HERMES: intento $attempt de $HERMES_TRIES"
    from=1; [ -f "$HERMES_LOG" ] && from=$(( $(wc -l <"$HERMES_LOG") + 1 ))
    run_hermes_installer "$tmp" "$attempt"; rc=$?
    [ $rc -eq 0 ] && { log "HERMES: RC=0"; break; }
    kind="$(hermes_failure_kind "$from")"
    log "HERMES: RC=$rc causa=$kind"
    # Ctrl+C, una falla que no es de red o el último intento: no tiene sentido repetir.
    [ $rc -eq 130 ] && break
    [ "$kind" = "other" ] && break
    [ $attempt -ge $HERMES_TRIES ] && break
    echo
    if [ "$kind" = "net" ]; then
      printf ' %s%s El instalador de Hermes se cortó por la red%s (código %s); reintentar suele bastar.\n' "$C_YEL" "$G_WARN" "$C_R" "$rc"
    else
      printf ' %s%s El instalador de Hermes falló (código %s)%s y no se pudo leer su log para saber por qué.\n' "$C_YEL" "$G_WARN" "$rc" "$C_R"
    fi
    attempt=$((attempt+1))
    ask_yes "¿Reintentar (intento $attempt de $HERMES_TRIES, con HTTP/1.1)?" || break
  done
  rm -f "$tmp"
  if [ $rc -ne 0 ]; then
    echo
    printf ' %s%s Hermes Agent no se pudo instalar.%s Los requisitos sí quedaron listos.\n' "$C_RED" "$G_ERR" "$C_R"
    if [ "$kind" = "net" ]; then
      printf '   Fue un corte de red. Prueba con otra red (o cable) y vuelve a ejecutar:  curl -fsSL %s | bash\n' "$HERMES_INSTALL_URL"
      printf '   Si se repite, ejecuta antes:  git config --global http.version HTTP/1.1\n'
    elif [ "$kind" = "other" ]; then
      printf '   Revisa el log del instalador oficial: %s\n' "$(tilde "$HERMES_LOG")"
    fi
  fi
  return $rc
}

# ============================================================================
#  FIN DEL BLOQUE COMÚN
# ============================================================================

# ----------------------------------------------------------------------------
#  Detección de distribución y gestor de paquetes
# ----------------------------------------------------------------------------
OS_ID=""; OS_VER=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi
PM=""
if have apt-get; then PM=apt; elif have dnf; then PM=dnf; elif have pacman; then PM=pacman; fi
IS_WSL=0; grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1
SUDO=""; [ "$(id -u)" != "0" ] && SUDO="sudo"
PLATFORM_NAME="Linux"; [ -n "$OS_ID" ] && PLATFORM_NAME="Linux · $OS_ID $OS_VER"
[ "$IS_WSL" = "1" ] && PLATFORM_NAME="$PLATFORM_NAME (WSL)"

# ----------------------------------------------------------------------------
#  Requisitos de Linux
#  id | etiqueta | obligatorio(1) / recomendado(0)
# ----------------------------------------------------------------------------
REQ_IDS=(os sudo disk net base curl git build libatomic libstdcxx node python rg ffmpeg path)
REQ_LABELS=("Sistema y gestor" "Permisos (sudo)" "Espacio en disco" "Conexión a internet" "Utilidades base" "curl" "Git" "Compiladores" "libatomic" "libstdc++" "Node.js + npm" "Python 3.11+" "ripgrep" "FFmpeg" "PATH ~/.local/bin")
REQ_REQUIRED=(1 1 1 1 1 1 1 0 1 1 1 0 0 0 1)

NODE_MIN=20; NODE_MAJOR_INSTALL=24; PY_MIN=3.11; GIT_MIN=2.25; DISK_MIN_GB=5; DISK_FAIL_GB=3
PATH_AT_START="$PATH"


check_os() {
  local arch; arch="$(uname -m)"
  if [ "$(uname -s)" != "Linux" ]; then chk fail "$(uname -s)" "este script es solo para Linux"; return; fi
  case "$arch" in x86_64|amd64|aarch64|arm64) ;; *) chk fail "$arch" "arquitectura no soportada por Hermes"; return ;; esac
  if [ -z "$PM" ]; then chk fail "$OS_ID $OS_VER" "gestor no soportado (se soporta apt, dnf y pacman)"; return; fi
  if ldd --version 2>&1 | grep -qi musl; then chk fail "$OS_ID $OS_VER" "musl (Alpine) no está soportado por este script"; return; fi
  local extra=""; [ "$IS_WSL" = "1" ] && extra=" · WSL"
  chk ok "$OS_ID $OS_VER" "gestor: $PM · $arch$extra"
}

check_sudo() {
  if [ "$(id -u)" = "0" ]; then chk ok "root" "ejecutando como root"
  elif have sudo; then chk ok "sudo" "se pedirá tu contraseña al instalar"
  else chk fail "" "instala sudo o ejecuta como root"; fi
}



ca_bundle() { for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do [ -s "$f" ] && return 0; done; return 1; }
BASE_MISSING=""
check_base() {
  BASE_MISSING=""
  local c
  for c in tar xz unzip gzip sha256sum; do have "$c" || BASE_MISSING="$BASE_MISSING $c"; done
  ca_bundle || BASE_MISSING="$BASE_MISSING ca-certificates"
  if [ -z "$BASE_MISSING" ]; then chk ok "" "tar, xz, unzip, gzip, sha256sum, certificados"
  else chk missing "" "faltan:$BASE_MISSING"; fi
}



check_build() {
  local miss="" c
  for c in gcc g++ make; do have "$c" || miss="$miss $c"; done
  if [ -z "$miss" ]; then chk ok "gcc $(gcc -dumpversion 2>/dev/null)" "gcc, g++, make"
  else chk missing "" "faltan:$miss"; fi
}

has_lib() {
  { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q "$1" && return 0
  ls /lib/"$1"* /lib64/"$1"* /usr/lib/"$1"* /usr/lib64/"$1"* /usr/lib/*-linux-gnu/"$1"* /lib/*-linux-gnu/"$1"* >/dev/null 2>&1
}
check_libatomic() { if has_lib libatomic.so.1; then chk ok "" "requerida por Node.js"; else chk missing "" "requerida por Node.js; se instalará"; fi; }
check_libstdcxx() { if has_lib libstdc++.so.6; then chk ok "" "requerida por Node.js"; else chk missing "" "requerida por Node.js; se instalará"; fi; }




# ----------------------------------------------------------------------------
#  Instaladores
# ----------------------------------------------------------------------------
NEED_SUDO_IDS=" base curl git build libatomic libstdcxx node python rg ffmpeg "
PM_REFRESHED=0

# pacman 7 descarga con un usuario "sandbox" que falla en algunos contenedores
# (seccomp); en ese caso se reintenta sin sandbox.
pacman_cmd() {
  $SUDO pacman "$@" && return 0
  grep -q "sandbox" "$LOG_FILE" 2>/dev/null || return 1
  $SUDO pacman --disable-sandbox "$@"
}
pm_refresh() {
  [ "$PM_REFRESHED" = "1" ] && return 0
  PM_REFRESHED=1
  case "$PM" in
    apt)    spin "actualizando índice de paquetes" $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
    dnf)    spin "actualizando índice de paquetes" $SUDO dnf makecache -y ;;
    pacman) spin "sincronizando paquetes (pacman -Syu)" pacman_cmd -Syu --noconfirm ;;
  esac
}
pkg() { # pkg paquete...
  pm_refresh
  case "$PM" in
    apt)    spin "apt install $*" $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    spin "dnf install $*" $SUDO dnf install -y "$@" ;;
    pacman) spin "pacman -S $*" pacman_cmd -S --needed --noconfirm "$@" ;;
  esac
}

install_base() {
  local p="" c
  for c in $BASE_MISSING; do
    case "$c:$PM" in
      xz:apt) p="$p xz-utils" ;;
      sha256sum:*) p="$p coreutils" ;;
      *) p="$p $c" ;;
    esac
  done
  # shellcheck disable=SC2086
  pkg $p
}
install_curl() { pkg curl; }
install_git()  { pkg git; }
install_build() {
  case "$PM" in
    apt) pkg build-essential ;;
    dnf) pkg gcc gcc-c++ make ;;
    pacman) pkg base-devel ;;
  esac
}
install_libatomic() { case "$PM" in apt) pkg libatomic1 ;; dnf) pkg libatomic ;; pacman) pkg gcc-libs ;; esac; }
install_libstdcxx() { case "$PM" in apt) pkg libstdc++6 ;; dnf) pkg libstdc++ ;; pacman) pkg gcc-libs ;; esac; }

# Ubuntu/Debian empaquetan nodejs + npm + libnode*; el nodejs de NodeSource choca
# con ellos ("Conflicts: npm"). Se quitan solo si el Node instalado no es de NodeSource.
remove_distro_node() {
  local v pkgs
  v="$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null)"
  [ -z "$v" ] && return 0
  case "$v" in *nodesource*) return 0 ;; esac
  pkgs="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' nodejs npm 'libnode*' 2>/dev/null | awk '$1 ~ /^ii/ {print $2}' | tr '\n' ' ')"
  [ -z "$pkgs" ] && return 0
  # shellcheck disable=SC2086
  spin "quitando Node $v de la distro" $SUDO env DEBIAN_FRONTEND=noninteractive apt-get remove -y $pkgs
}

nodesource() { # nodesource deb|rpm
  local tmp; tmp="$(mktemp)"
  have curl || pkg curl
  spin "descargando repositorio NodeSource" curl -fsSL -o "$tmp" "https://$1.nodesource.com/setup_${NODE_MAJOR_INSTALL}.x" || { rm -f "$tmp"; return 1; }
  spin "configurando NodeSource ${NODE_MAJOR_INSTALL}.x" $SUDO bash "$tmp"; local rc=$?
  rm -f "$tmp"; return $rc
}
install_node() {
  case "$PM" in
    apt)
      remove_distro_node
      nodesource deb || return 1
      spin "apt install nodejs" $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs ;;
    dnf)
      pkg nodejs npm; hash -r; check_node
      if [ "$CHK_STATUS" != "ok" ]; then
        nodesource rpm || return 1
        spin "dnf install nodejs" $SUDO dnf install -y nodejs
      fi ;;
    pacman) pkg nodejs npm ;;
  esac
  hash -r
}
install_python() {
  case "$PM" in
    apt)
      pkg python3 python3-venv python3-pip; hash -r; check_python
      if [ "$CHK_STATUS" != "ok" ] && [ "$OS_ID" = "ubuntu" ]; then
        pkg software-properties-common
        spin "agregando PPA deadsnakes" $SUDO add-apt-repository -y ppa:deadsnakes/ppa || return 1
        spin "actualizando índice de paquetes" $SUDO apt-get update -y
        pkg python3.12 python3.12-venv
      fi ;;
    dnf)    pkg python3 python3-pip ;;
    pacman) pkg python python-pip ;;
  esac
  hash -r
}
install_rg() { pkg ripgrep || { CHK_MSG="no disponible en tus repositorios (en RHEL habilita EPEL)"; return 1; }; }
install_ffmpeg() {
  case "$PM" in
    dnf) pkg ffmpeg-free || pkg ffmpeg || { CHK_MSG="no disponible; habilita RPM Fusion"; return 1; } ;;
    *)   pkg ffmpeg ;;
  esac
}
install_os()   { return 1; }
install_sudo() { return 1; }
install_disk() { return 1; }
install_net()  { return 1; }



# ============================================================================
#  MOTOR COMÚN (diagnóstico → instalación → verificación)
#  (idéntico en prepare-macos.sh y prepare-linux.sh)
# ============================================================================
RES_STATUS=(); RES_VER=(); RES_MSG=()

# Revisiones que la instalación no puede cambiar: en la verificación final se reutilizan.
STATIC_IDS=" os sudo disk net "

run_diagnosis() { # run_diagnosis "<título>" [reuse]
  local n=${#REQ_IDS[@]} i id
  ui_section "$1" "($n verificaciones)"
  for ((i=0; i<n; i++)); do
    id="${REQ_IDS[$i]}"
    CUR_POS=$((i+1)); CUR_TOTAL=$n; CUR_LABEL="${REQ_LABELS[$i]}"
    draw_progress "$CUR_POS" "$n" "${SPIN_ARR[0]}" "$CUR_LABEL" "revisando…"
    case "${2:-}:$STATIC_IDS" in
      reuse:*" $id "*) CHK_STATUS="${RES_STATUS[$i]}"; CHK_VER="${RES_VER[$i]}"; CHK_MSG="${RES_MSG[$i]}" ;;
      *) "check_$id" ;;
    esac
    RES_STATUS[$i]="$CHK_STATUS"; RES_VER[$i]="$CHK_VER"; RES_MSG[$i]="$CHK_MSG"
    ui_row "$CHK_STATUS" "${REQ_LABELS[$i]}" "$CHK_VER" "$CHK_MSG"
  done
  if [ "$IS_TTY" = "1" ]; then printf '   %s %s%d/%d%s\n' "$(bar "$n" "$n" 40)" "$C_B" "$n" "$n" "$C_R"; fi
  CUR_LABEL=""
}

count_status() { local s="$1" c=0 x; for x in "${RES_STATUS[@]}"; do [ "$x" = "$s" ] && c=$((c+1)); done; echo $c; }

recommended_issues() { # cuántos recomendados no quedaron listos
  local i c=0 n=${#REQ_IDS[@]}
  for ((i=0; i<n; i++)); do
    [ "${REQ_REQUIRED[$i]}" = "0" ] && [ "${RES_STATUS[$i]}" != "ok" ] && c=$((c+1))
  done
  echo $c
}

blocking_fails() { # imprime índices obligatorios que no están ok/warn
  local i n=${#REQ_IDS[@]}
  for ((i=0; i<n; i++)); do
    [ "${REQ_REQUIRED[$i]}" = "1" ] || continue
    case "${RES_STATUS[$i]}" in ok|warn) ;; *) echo "$i" ;; esac
  done
}

print_diag_summary() {
  local ok up mi fa wa
  ok=$(count_status ok); up=$(count_status update); mi=$(count_status missing); fa=$(count_status fail); wa=$(count_status warn)
  echo
  printf '   Resultado: %s%d listos%s · %s%d por actualizar%s · %s%d por instalar%s · %s%d avisos%s · %s%d bloqueantes%s\n' \
    "$C_GRN" "$ok" "$C_R" "$C_YEL" "$up" "$C_R" "$C_YEL" "$mi" "$C_R" "$C_YEL" "$wa" "$C_R" "$C_RED" "$fa" "$C_R"
}

show_resume_notice() {
  local st last pos total lbl i
  st="$(state_get run_status)"; last="$(state_get last_step)"
  pos="$(state_get last_pos)"; total="$(state_get last_total)"
  case "$st" in running|interrupted|incomplete) ;; *) return ;; esac
  [ -z "$last" ] && return
  lbl="$last"
  for ((i=0; i<${#REQ_IDS[@]}; i++)); do [ "${REQ_IDS[$i]}" = "$last" ] && lbl="${REQ_LABELS[$i]}"; done
  echo
  printf ' %s%s Se detectó una ejecución anterior sin terminar%s en [%s/%s] %s (%s).\n' \
    "$C_YEL" "$G_WARN" "$C_R" "${pos:-?}" "${total:-?}" "$lbl" "$(state_get last_run)"
  printf '   Continuando desde ahí: lo que ya se instaló se omitirá.\n'
}

# Mensaje de un paso que falló. step_error <línea-inicial-del-log> <estado> <mensaje-del-check>
#  - "update": el check explica qué sigue mal (p. ej. otro Node antes en el PATH) → se conserva.
#  - si no, la primera línea de error que dejó el paso en el log (la causa real);
#  - si no hay, el mensaje del check salvo que sea el genérico de diagnóstico ("se instalará…").
step_error() {
  local e
  [ "$2" = "update" ] && [ -n "$3" ] && { printf '%s' "$3"; return; }
  e="$(tail -n "+$1" "$LOG_FILE" 2>/dev/null | grep -m1 -E '^(Error|error|E|fatal):' | short_text 70)"
  if [ -n "$e" ]; then printf 'falló: %s' "$e"; return; fi
  case "$3" in ""|"se "*) printf 'falló la instalación' ;; *) printf '%s' "$3" ;; esac
}

install_pending() {
  local n=${#REQ_IDS[@]} i id idxs="" total=0 pos=0 needs_sudo=0
  for ((i=0; i<n; i++)); do
    case "${RES_STATUS[$i]}" in update|missing)
      idxs="$idxs $i"; total=$((total+1))
      case "$NEED_SUDO_IDS" in *" ${REQ_IDS[$i]} "*) needs_sudo=1 ;; esac ;;
    esac
  done
  [ $total -eq 0 ] && return 0

  if [ "$needs_sudo" = "1" ] && [ "$(id -u)" != "0" ] && have sudo; then
    prime_sudo || { printf '   %s%s No se obtuvo permiso de sudo.%s\n' "$C_RED" "$G_ERR" "$C_R"; return 1; }
  fi

  ui_section "INSTALACIÓN" "(solo los $total pendientes)"
  state_set run_status running
  state_set last_run "$(date '+%Y-%m-%d %H:%M')"
  for ((i=0; i<n; i++)); do
    case " $idxs " in *" $i "*) ;; *) ui_row skip "${REQ_LABELS[$i]}" "${RES_VER[$i]}" "ya estaba listo"; continue ;; esac
    id="${REQ_IDS[$i]}"; pos=$((pos+1))
    CUR_POS=$pos; CUR_TOTAL=$total; CUR_LABEL="${REQ_LABELS[$i]}"
    state_set last_step "$id"; state_set last_pos "$pos"; state_set last_total "$total"
    state_set "step_$id" running
    draw_progress "$pos" "$total" "${SPIN_ARR[0]}" "$CUR_LABEL" "preparando…"

    # ¿Lo resolvió un paso anterior? (p. ej. Xcode CLT trae git)
    "check_$id"
    if [ "$CHK_STATUS" = "ok" ]; then
      RES_STATUS[$i]=ok; RES_VER[$i]="$CHK_VER"; state_set "step_$id" ok
      ui_row "done" "$CUR_LABEL" "$CHK_VER" "resuelto por un paso anterior"; continue
    fi

    CHK_MSG=""; local log_from; log_from=$(( $(wc -l <"$LOG_FILE") + 1 ))
    if "install_$id"; then "check_$id"; else local imsg="$CHK_MSG"; "check_$id"; [ "$CHK_STATUS" != "ok" ] && CHK_MSG="${imsg:-$(step_error "$log_from" "$CHK_STATUS" "$CHK_MSG")}"; fi
    RES_STATUS[$i]="$CHK_STATUS"; RES_VER[$i]="$CHK_VER"; RES_MSG[$i]="$CHK_MSG"
    if [ "$CHK_STATUS" = "ok" ] || [ "$CHK_STATUS" = "warn" ]; then
      state_set "step_$id" ok
      ui_row "done" "$CUR_LABEL" "$CHK_VER" "instalado"
    else
      [ "$(state_get "step_$id")" = "pending_restart" ] || state_set "step_$id" failed
      RES_STATUS[$i]=fail
      ui_row fail "$CUR_LABEL" "$CHK_VER" "${CHK_MSG:-falló la instalación} (ver log)"
      tail -n 4 "$LOG_FILE" | sed "s/^/        ${C_D}│${C_R} /"
    fi
  done
  if [ "$IS_TTY" = "1" ]; then printf '   %s %s100%%%s\n' "$(bar "$total" "$total" 40)" "$C_B" "$C_R"; fi
  CUR_LABEL=""
}

main() {
  if [ "$RESET" = "1" ]; then rm -f "$STATE_FILE"; echo " Estado reiniciado."; fi
  printf '===== %s · hermes-prep %s · %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PREP_VERSION" "$PLATFORM_NAME" >>"$LOG_FILE"
  log_system_info
  ui_banner "Preparación para Hermes Agent · $PLATFORM_NAME $(uname -m)"
  printf '   %sv%s · log: %s%s\n' "$C_D" "$PREP_VERSION" "$(tilde "$LOG_FILE")" "$C_R"

  show_resume_notice
  run_diagnosis "1) DIAGNÓSTICO"
  print_diag_summary

  if [ "$CHECK_ONLY" = "1" ]; then
    echo; echo "   Modo --check-only: no se instaló nada."
    log "RESULTADO: check-only"; show_log_path
    [ -z "$(blocking_fails)" ] && exit 0 || exit 1
  fi

  local pending; pending=$(( $(count_status update) + $(count_status missing) ))
  local hardfail="" i
  for i in $(blocking_fails); do [ "${RES_STATUS[$i]}" = "fail" ] && hardfail="$hardfail $i"; done
  if [ -n "$hardfail" ]; then
    echo
    printf ' %s%s Hay requisitos que el script no puede resolver solo:%s\n' "$C_RED" "$G_ERR" "$C_R"
    for i in $hardfail; do printf '     • %s: %s\n' "${REQ_LABELS[$i]}" "${RES_MSG[$i]}"; done
    echo "   Corrígelos y vuelve a ejecutar."; state_set run_status incomplete
    log "RESULTADO: bloqueado"; show_log_path; exit 1
  fi

  if [ "$pending" -gt 0 ]; then
    echo
    if ! ask_yes "¿Instalar/actualizar los $pending pendientes?"; then echo "   Cancelado. No se instaló nada."; log "RESULTADO: cancelado"; show_log_path; exit 0; fi
    install_pending
    run_diagnosis "2) VERIFICACIÓN FINAL" reuse
  else
    echo; printf '   %s%s Todo lo necesario ya estaba instalado.%s\n' "$C_GRN" "$G_OK" "$C_R"
  fi

  local blockers; blockers="$(blocking_fails)"
  echo
  if [ -z "$blockers" ]; then
    state_set run_status "done"
    printf ' %s%s %s TODO LISTO: el equipo cumple los requisitos de Hermes Agent %s%s\n' "$C_GRN" "$C_B" "$G_OK" "$G_OK" "$C_R"
    local rec; rec="$(recommended_issues)"
    if [ "$rec" -gt 0 ]; then
      printf '   %s%s %d elemento(s) recomendado(s) no quedaron listos; no impiden instalar Hermes:%s\n' "$C_YEL" "$G_WARN" "$rec" "$C_R"
      for ((i=0; i<${#REQ_IDS[@]}; i++)); do
        [ "${REQ_REQUIRED[$i]}" = "0" ] && [ "${RES_STATUS[$i]}" != "ok" ] && printf '     • %s: %s\n' "${REQ_LABELS[$i]}" "${RES_MSG[$i]}"
      done
    fi
    echo
    if [ "$NO_HERMES" = "1" ]; then
      echo "   Para instalar Hermes Agent:  curl -fsSL $HERMES_INSTALL_URL | bash"
    elif ask_yes "¿Instalar Hermes Agent ahora?"; then
      if ! launch_hermes; then
        echo "   Abre una terminal nueva (o ejecuta: source $(tilde "$(user_rc_file)")) para cargar el PATH."
        log "RESULTADO: requisitos listos, falló el instalador de Hermes"; show_log_path; exit 1
      fi
      printf '\n   %sAbre una terminal nueva para que el comando %shermes%s%s quede disponible.%s\n' "$C_D" "$C_B" "$C_R" "$C_D" "$C_R"
    else
      echo "   Cuando quieras:  curl -fsSL $HERMES_INSTALL_URL | bash"
    fi
    echo "   Abre una terminal nueva (o ejecuta: source $(tilde "$(user_rc_file)")) para cargar el PATH."
    log "RESULTADO: todo listo"; show_log_path
    exit 0
  else
    state_set run_status incomplete
    printf ' %s%s %s Faltan requisitos obligatorios:%s\n' "$C_RED" "$C_B" "$G_ERR" "$C_R"
    for i in $blockers; do printf '     • %s: %s\n' "${REQ_LABELS[$i]}" "${RES_MSG[$i]}"; done
    echo "   Vuelve a ejecutar: continuará donde se quedó."
    log "RESULTADO: faltan requisitos"; show_log_path
    exit 1
  fi
}

main
