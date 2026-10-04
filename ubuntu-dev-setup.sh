#!/usr/bin/env bash
# ubuntu-dev-setup.sh - Ubuntu dev environment setup
#
# - Re-runnable: tools that are already installed are skipped.
# - Every tool ends up system-wide: apt, snap and Ollama install globally on their own;
#   per-user installs (uv, Rust, Node via nvm, Claude Code, pipx apps) are symlinked into
#   /usr/local/bin by the `relink-global` helper this script installs. Re-run it after
#   installing a new Node version, `npm i -g`, `cargo install` or `pipx install`.
# - Output is also saved to ~/setup.log (override with SETUP_LOG=/some/file).
#
# Run with: bash ubuntu-dev-setup.sh   (as your normal user, not root; it calls sudo itself)
set -Eeuo pipefail

LOG="${SETUP_LOG:-$HOME/setup.log}"
LINK_DIR="${LINK_DIR:-/usr/local/bin}"
SQLITE_PREFIX="${SQLITE_PREFIX:-/opt/sqlite}"
PYTORCH_VENV="${PYTORCH_VENV:-$HOME/.venvs/pytorch}"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]; }

on_err() { printf '\nERROR: setup failed (exit %s) at line %s: %s\nFull log: %s\n' "$1" "$2" "$3" "$LOG" >&2; }
arm_err_trap() { trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR; }

cleanup() {
  [ -z "${KEEPALIVE_PID:-}" ] || kill "$KEEPALIVE_PID" 2>/dev/null || true
  # 'make install' runs as root and can leave root-owned files in the build tree
  [ -z "${TMP:-}" ] || rm -rf "$TMP" 2>/dev/null || sudo rm -rf "$TMP" 2>/dev/null || true
}

# run_remote SHELL URL [ARGS...]: download to a file first so a partial download never runs
run_remote() {
  local shell="$1" url="$2" f
  shift 2
  f="$(mktemp "$TMP/installer.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL -o "$f" "$url"
  "$shell" "$f" "$@"
}

# ensure LABEL CHECK CMD...: run CMD unless CHECK (command name or absolute path) exists
ensure() {
  local label="$1" check="$2"
  shift 2
  if have "$check"; then
    printf '\n==> %s already installed, skipping\n' "$label"
  else
    say "Installing $label"
    "$@"
  fi
}

ppa_has() {
  curl --proto '=https' --tlsv1.2 -fsSL -o /dev/null "https://ppa.launchpadcontent.net/$1/ubuntu/dists/$CODENAME/Release"
}

# Build the newest SQLite from sqlite.org into $SQLITE_PREFIX (tarball SHA3-256 verified) and
# link the CLI into $LINK_DIR. Returns non-zero on any failure.
# Every step needs "|| return 1" because this runs inside an `if`, where set -e is off.
sqlite_from_source() {
  local page="$TMP/sqlite-download.html" log="$TMP/sqlite-build.log"
  local line ver rel sha tarball f got dir installed

  curl --proto '=https' --tlsv1.2 -fsSL -o "$page" https://www.sqlite.org/download.html || return 1
  # machine-readable block on the page: PRODUCT,<version>,<year>/<file>,<bytes>,<sha3-256>
  line="$(grep -m1 -oE 'PRODUCT,[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?,[0-9]{4}/sqlite-autoconf-[0-9]+\.tar\.gz,[0-9]+,[0-9a-fA-F]{64}' "$page")" || return 1
  IFS=, read -r _ ver rel _ sha <<< "$line"
  sha="${sha,,}"

  installed="$("$SQLITE_PREFIX/bin/sqlite3" --version 2>/dev/null | cut -d' ' -f1)" || installed=""
  if [ "$installed" = "$ver" ]; then
    echo "SQLite $ver is already the newest release, skipping the build"
    sudo ln -sfn "$SQLITE_PREFIX/bin/sqlite3" "$LINK_DIR/sqlite3" || return 1
    return 0
  fi

  tarball="${rel#*/}"
  f="$TMP/$tarball"
  curl --proto '=https' --tlsv1.2 -fsSL -o "$f" "https://www.sqlite.org/$rel" || return 1
  got="$(python3 -c 'import hashlib,sys; print(hashlib.sha3_256(open(sys.argv[1],"rb").read()).hexdigest())' "$f")" || return 1
  if [ "$got" != "$sha" ]; then
    warn "SQLite tarball hash mismatch (got $got, expected $sha); not building it."
    return 1
  fi

  say "Building SQLite $ver into $SQLITE_PREFIX (a minute or two)"
  tar -xzf "$f" -C "$TMP" || return 1
  dir="$TMP/${tarball%.tar.gz}"
  # rpath keeps this sqlite3 on its own library, so Ubuntu's libsqlite3 is never replaced
  # shellcheck disable=SC2024  # only 'make install' needs root
  if ! ( cd "$dir" && LDFLAGS="-Wl,-rpath,$SQLITE_PREFIX/lib" ./configure --prefix="$SQLITE_PREFIX" && make -j"$(nproc)" ) >"$log" 2>&1 \
     || ! sudo make -C "$dir" install >>"$log" 2>&1; then
    warn "SQLite build failed; last lines of the build log:"
    tail -n 30 "$log" >&2
    return 1
  fi

  sudo ln -sfn "$SQLITE_PREFIX/bin/sqlite3" "$LINK_DIR/sqlite3" || return 1
  got="$("$LINK_DIR/sqlite3" -batch :memory: 'select sqlite_version();' 2>/dev/null)" || got=""
  if [ "$got" != "$ver" ]; then
    warn "Built sqlite3 reports '${got:-nothing}' instead of $ver; removing it."
    sudo rm -f "$LINK_DIR/sqlite3"
    return 1
  fi
}

install_sqlite() {
  if sqlite_from_source; then return 0; fi
  warn "Couldn't install the newest SQLite from sqlite.org, so installing Ubuntu's sqlite3 package instead (an older version)."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3 libsqlite3-dev
}

# PyTorch goes in its own venv (PEP 668 blocks system-wide pip). The default wheels bundle CUDA;
# without an NVIDIA GPU the much smaller CPU wheels are used instead.
install_pytorch() {
  local uv="$HOME/.local/bin/uv" index=()
  if "$PYTORCH_VENV/bin/python" -c 'import torch' 2>/dev/null; then
    echo "PyTorch already installed in $PYTORCH_VENV, skipping"
    return 0
  fi
  have nvidia-smi || index=(--index-url https://download.pytorch.org/whl/cpu)
  "$uv" venv "$PYTORCH_VENV"
  "$uv" pip install --python "$PYTORCH_VENV/bin/python" "${index[@]}" torch torchvision torchaudio
}

write_relink_helper() {
cat > "$1" <<'HELPER'
#!/usr/bin/env bash
# relink-global - symlink per-user tool installs into /usr/local/bin so they run from any
# directory. Safe to re-run. Run it as your normal user (it calls sudo itself) after you:
#   nvm install <version> / change the default Node, npm i -g <pkg>,
#   cargo install <pkg>, pipx install <pkg>, go install <pkg>
LINK_DIR="${LINK_DIR:-/usr/local/bin}"

if [ "$(id -u)" -eq 0 ]; then
  echo "Run relink-global as your normal user (it uses sudo itself), not as root." >&2
  exit 1
fi

SUDO=sudo
[ -w "$LINK_DIR" ] && SUDO=""

# bin dir of the nvm *default* Node version (empty if nvm/Node isn't installed)
NODE_BIN=""
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
  node_path="$(nvm which default 2>/dev/null)" && [ -x "$node_path" ] && NODE_BIN="$(dirname "$node_path")"
fi

# Stale = dangling link into $HOME, or link into an nvm Node version that is no longer the default
is_stale() {
  local t
  t="$(readlink "$1")"
  case "$t" in "$HOME"/*) ;; *) return 1 ;; esac      # not ours: leave alone
  [ -e "$1" ] || return 0                              # dangling
  if [ -n "$NODE_BIN" ]; then
    case "$t" in
      "$NVM_DIR"/versions/node/*) [ "$(dirname "$t")" = "$NODE_BIN" ] || return 0 ;;
    esac
  fi
  return 1
}

for l in "$LINK_DIR"/*; do
  [ -L "$l" ] || continue
  if is_stale "$l"; then
    echo "removing stale link: $l -> $(readlink "$l")"
    $SUDO rm -f "$l"
  fi
done

# link SRC: never shadows a system command or clobbers a real file
link() {
  local src="$1" name dest d
  { [ -e "$src" ] && [ ! -d "$src" ] && [ -x "$src" ]; } || return 0
  name="$(basename "$src")"
  case "$name" in env|env.fish) return 0 ;; esac       # uv drops a sourced 'env' script in ~/.local/bin
  dest="$LINK_DIR/$name"
  for d in /usr/bin /bin /usr/sbin /sbin /snap/bin; do
    if [ -e "$d/$name" ]; then
      echo "skip $name: it would shadow $d/$name"
      return 0
    fi
  done
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo "skip $name: $dest already exists and is not a symlink"
    return 0
  fi
  [ "$(readlink "$dest" 2>/dev/null)" = "$src" ] && return 0
  $SUDO ln -sfn "$src" "$dest"
  echo "linked $dest -> $src"
}

for f in "$HOME"/.local/bin/* "$HOME"/.cargo/bin/* "$HOME"/go/bin/*; do link "$f"; done
if [ -n "$NODE_BIN" ]; then
  for f in "$NODE_BIN"/*; do link "$f"; done
fi
echo "relink-global: done"
exit 0
HELPER
}

main() {
  TMP="$(mktemp -d)"
  trap cleanup EXIT
  arm_err_trap

  say "Checking system"
  [ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root (it uses sudo where needed)."
  [ -r /etc/os-release ] || die "Can't read /etc/os-release."
  . /etc/os-release
  [ "${ID:-}" = ubuntu ] || die "This script is for Ubuntu (found: ${PRETTY_NAME:-unknown})."
  CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [ -n "$CODENAME" ] || die "Couldn't work out the Ubuntu codename."
  echo "Ubuntu $CODENAME, log: $LOG"

  # Ask for the sudo password once and keep the timestamp fresh so long installs don't re-prompt
  sudo -v
  local main_pid=$BASHPID
  (
    # on TERM (sent by cleanup) kill the pending sleep so nothing lingers
    trap '[ -z "${sp:-}" ] || kill "$sp" 2>/dev/null; exit 0' TERM
    while true; do
      sudo -n true
      sleep 50 & sp=$!
      wait "$sp"
      kill -0 "$main_pid" 2>/dev/null || exit 0
    done
  ) >/dev/null 2>&1 &
  KEEPALIVE_PID=$!

  say "Base packages"
  # Wireshark asks an interactive question on install; preseed "no" (root-only capture)
  echo "wireshark-common wireshark-common/install-setuid boolean false" | sudo debconf-set-selections
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg software-properties-common
  sudo install -m 0755 -d /etc/apt/keyrings

  say "Docker (docker-ce from Docker's official apt repo)"
  DOCKER_PKGS=()
  if curl --proto '=https' --tlsv1.2 -fsSL -o /dev/null "https://download.docker.com/linux/ubuntu/dists/$CODENAME/Release"; then
    # Remove conflicting packages (images and containers in /var/lib/docker are kept)
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
      if pkg_installed "$pkg"; then sudo apt-get remove -y "$pkg"; fi
    done
    sudo curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  else
    warn "Docker has no apt repo for Ubuntu '$CODENAME' yet, so docker-ce is being skipped. Re-run this script later."
  fi

  say "Apache and PHP (newest, from the Ondřej Surý PPAs)"
  # A PPA is only added if it publishes for this release; otherwise Ubuntu's own packages are used
  for ppa in php apache2; do
    if ppa_has "ondrej/$ppa"; then
      sudo add-apt-repository -y "ppa:ondrej/$ppa"
    else
      warn "ppa:ondrej/$ppa has no packages for Ubuntu '$CODENAME', so Ubuntu's own $ppa packages will be used."
    fi
  done

  sudo apt-get update

  # eza is in Ubuntu 24.04+; older releases need the eza project's repo
  if ! apt-cache show eza >/dev/null 2>&1; then
    say "eza isn't in this release's apt repos; adding the eza project repo"
    curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
      | sudo gpg --yes --dearmor -o /etc/apt/keyrings/gierens.gpg
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
      | sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null
    sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    sudo apt-get update
  fi

  say "apt packages"
  # build-essential + gcc/g++/make = C/C++ toolchain; libreadline-dev, zlib1g-dev = SQLite CLI build deps
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget git git-lfs unzip build-essential gcc g++ make cmake ninja-build \
    python3 python3-pip python3-venv pipx \
    gh eza btop nvtop wireshark nmap httpie ffmpeg jq ripgrep fd-find shellcheck \
    gnome-system-monitor torbrowser-launcher \
    apache2 php php-cli libapache2-mod-php php-sqlite3 php-curl php-mbstring php-xml php-zip \
    libreadline-dev zlib1g-dev \
    "${DOCKER_PKGS[@]}"
  pipx ensurepath || warn "pipx ensurepath failed"
  # Ubuntu installs fd-find as 'fdfind' to avoid a name clash
  sudo ln -sfn "$(command -v fdfind)" "$LINK_DIR/fd"

  ensure "VS Code" /snap/bin/code sudo snap install code --classic

  # Go via snap to track the latest stable release
  ensure "Go" /snap/bin/go sudo snap install go --classic

  say "SQLite"
  install_sqlite

  # Ollama installs to /usr/local/bin itself
  ensure "uv" "$HOME/.local/bin/uv" run_remote sh https://astral.sh/uv/install.sh
  ensure "Ollama" ollama run_remote sh https://ollama.com/install.sh

  ensure "Rust" "$HOME/.cargo/bin/rustc" run_remote sh https://sh.rustup.rs -y

  # Large download; only warns on failure so the rest of the setup still runs
  say "PyTorch (venv at $PYTORCH_VENV)"
  install_pytorch || warn "PyTorch install failed. Re-run this script to retry."

  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    say "nvm already installed, skipping"
  else
    say "Installing nvm"
    run_remote bash https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh
  fi

  say "Node (via nvm)"
  # nvm isn't written for set -e / set -u (or our ERR trap), so relax them while it runs
  trap - ERR
  set +eu
  export NVM_DIR="$HOME/.nvm"
  . "$NVM_DIR/nvm.sh"
  if ! nvm which default >/dev/null 2>&1; then
    nvm install --lts || die "nvm install --lts failed"
    nvm alias default 'lts/*' >/dev/null
  fi
  nvm use default >/dev/null || die "nvm use default failed"
  set -eu
  arm_err_trap
  echo "Node $(node --version), npm $(npm --version)"

  ensure "Claude Code" "$HOME/.local/bin/claude" run_remote bash https://claude.ai/install.sh

  # Only warns on failure (e.g. private package, needs `npm login`) so linking and the report still run
  say "@neddyp/encryptor (npm, global)"
  npm install -g @neddyp/encryptor || warn "@neddyp/encryptor failed to install. If it's private, run 'npm login' then: npm install -g @neddyp/encryptor"

  say "Linking per-user tools into $LINK_DIR (via relink-global)"
  write_relink_helper "$TMP/relink-global"
  sudo install -m 0755 "$TMP/relink-global" "$LINK_DIR/relink-global"
  "$LINK_DIR/relink-global"
  hash -r

  echo
  echo "=== Commands (full path  ->  real location) ==="
  for cmd in curl wget git git-lfs unzip gcc g++ make cmake ninja python3 pip3 pipx gh eza btop nvtop docker wireshark nmap http ffmpeg jq rg fd shellcheck \
             gnome-system-monitor torbrowser-launcher code go gofmt sqlite3 apache2 php uv uvx ollama \
             cargo rustc rustup node npm npx claude relink-global; do
    if p="$(command -v "$cmd" 2>/dev/null)"; then
      printf '%-24s %s  ->  %s\n' "$cmd" "$p" "$(readlink -f "$p")"
    else
      printf '%-24s NOT FOUND\n' "$cmd"
    fi
  done

  echo
  echo "=== Versions ==="
  { go version; sqlite3 --version; apache2 -v | head -n 1; php --version | head -n 1; } 2>&1 | sed 's/^/  /' || true

  echo
  echo "=== Per-user installs linked into $LINK_DIR ==="
  for l in "$LINK_DIR"/*; do
    [ -L "$l" ] || continue
    case "$(readlink "$l")" in
      "$HOME"/*) printf '%-24s %s  ->  %s\n' "$(basename "$l")" "$l" "$(readlink -f "$l")" ;;
    esac
  done

  echo
  echo "Done. Log saved to $LOG"
  echo "After installing a new Node version, 'npm i -g', 'cargo install', 'go install' or 'pipx install', run: relink-global"
  echo "Apache runs as a system service on port 80 (manage it with: sudo systemctl stop|start|disable apache2). PHP is loaded into it via mod_php."
  if [ "$(readlink "$LINK_DIR/sqlite3" 2>/dev/null)" = "$SQLITE_PREFIX/bin/sqlite3" ]; then
    echo "SQLite: the sqlite3 command is the newest release; its library and headers are in $SQLITE_PREFIX (PHP and other system programs keep using Ubuntu's libsqlite3)."
  fi
  echo "Re-running this script skips anything already installed; update tools with their own updaters (uv self update, rustup update, nvm install --lts, ...)."
  echo "PyTorch: source $PYTORCH_VENV/bin/activate   # or run $PYTORCH_VENV/bin/python directly. NVIDIA GPUs need the driver (sudo ubuntu-drivers install); AMD/ROCm needs a different wheel index."
  echo "Tor Browser downloads itself the first time you run torbrowser-launcher."
  echo "Optional: sudo usermod -aG docker \$USER   # run docker without sudo (effectively root access)"
  echo "Optional: sudo usermod -aG wireshark \$USER # only useful if you re-preseed install-setuid to true"
  echo "Note: run 'source ~/.bashrc' in your terminal (or open a new one) to pick up PATH changes."
}

printf '\n===== ubuntu-dev-setup.sh run %s =====\n' "$(date -Is)" >> "$LOG"
main 2>&1 | tee -a "$LOG"
