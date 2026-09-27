#!/usr/bin/env bash
# install.sh — installer for fixbuddy (https://github.com/Codevena/fixbuddy)
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/Codevena/fixbuddy/v0.9.0/install.sh | bash
#
# Options (pass after the URL as: | bash -s -- <options>):
#   --prefix PATH   Install into PATH instead of the auto-detected location
#   --ref TAG       Install from a specific git ref (default: v0.9.0).
#   --with-tui      Legacy v0.8.0 only; the current file already includes the UI.
#   --local         Install the single-file fixbuddy beside this installer.
#   -y, --yes       Skip the sudo confirmation prompt
#   -h, --help      Show this help and exit
#
# Requires: curl, bash. macOS and Linux (incl. WSL2).

set -euo pipefail

REPO_SLUG="Codevena/fixbuddy"
DEFAULT_REF="v0.9.0"
RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}"
SCRIPTS=(fixbuddy)

PREFIX=""
REF="$DEFAULT_REF"
ASSUME_YES=false
WITH_TUI=false
LOCAL=false
REF_SET=false

# -------- Output helpers --------
if [ -t 2 ]; then
  C_INFO=$'\033[36m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OK=$'\033[32m'; C_RST=$'\033[0m'
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_RST=""
fi
info() { printf "%s==>%s %s\n" "$C_INFO" "$C_RST" "$*" >&2; }
warn() { printf "%swarning:%s %s\n" "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf "%serror:%s %s\n" "$C_ERR" "$C_RST" "$*" >&2; }
ok()   { printf "%s\xe2\x9c\x93%s %s\n" "$C_OK" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat >&2 <<'EOF'
install.sh — installer for fixbuddy

  curl -fsSL https://raw.githubusercontent.com/Codevena/fixbuddy/v0.9.0/install.sh | bash

Options (pass as: | bash -s -- <options>):
  --prefix PATH   Install into PATH instead of the auto-detected location
  --ref TAG       Install fixbuddy from a specific git ref (default: v0.9.0;
                  use --ref main for the latest commit)
  --with-tui      Legacy v0.8.0 only; the current file already includes the UI
  --local         Install the single-file fixbuddy beside this installer
  -y, --yes       Skip the sudo confirmation prompt
  -h, --help      Show this help and exit
EOF
}

# -------- Arg parsing --------
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix requires a path}"; shift 2 ;;
    --ref)    REF="${2:?--ref requires a tag or branch name}"; REF_SET=true; shift 2 ;;
    --with-tui) WITH_TUI=true; shift ;;
    --local) LOCAL=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

if $LOCAL; then
  $REF_SET && die "--local cannot be combined with --ref."
  $WITH_TUI && die "--local already includes the terminal UI; omit --with-tui."
else
  command -v curl >/dev/null 2>&1 || die "curl is required but not installed. Install curl and re-run."
fi
SINGLE_FILE=true
case "$REF" in
  v0.7.*|v0.8.*) SINGLE_FILE=false; SCRIPTS=(fixbuddy.sh fixbuddy-wizard.sh) ;;
esac
if $WITH_TUI; then
  $SINGLE_FILE && die "The single-file release already includes the terminal UI; omit --with-tui."
  command -v python3 >/dev/null 2>&1 || die "--with-tui requires Python 3."
  SCRIPTS+=(fixbuddy-tui.py)
fi

# -------- Helpers --------
in_path() {
  case ":${PATH}:" in
    *":$1:"*) return 0 ;;
    *)        return 1 ;;
  esac
}

# Run a command, elevating with sudo only when the destination needs it.
as_root() {
  if [ -n "$SUDO" ]; then
    sudo "$@"
  else
    "$@"
  fi
}

script_version() {
  # Extract VERSION="x.y.z" from a fixbuddy.sh file; empty if not found.
  awk -F'"' '/^VERSION=/ {print $2; exit}' "$1" 2>/dev/null || true
}

# -------- Destination detection --------
if [ -n "$PREFIX" ]; then
  DEST="$PREFIX"
elif [ -d "$HOME/.local/bin" ] || in_path "$HOME/.local/bin"; then
  DEST="$HOME/.local/bin"
else
  DEST="/usr/local/bin"
fi

# Decide whether we need sudo. If the directory does not exist yet, try to
# create it unprivileged first — that also confirms writability.
SUDO=""
if [ -d "$DEST" ]; then
  [ -w "$DEST" ] || SUDO="sudo"
elif ! mkdir -p "$DEST" 2>/dev/null; then
  SUDO="sudo"
fi

if [ -n "$SUDO" ]; then
  command -v sudo >/dev/null 2>&1 || \
    die "Installing to $DEST needs elevated privileges, but sudo is unavailable. Re-run with --prefix pointing at a writable directory."
  if [ "$ASSUME_YES" != true ]; then
    if [ -e /dev/tty ]; then
      printf "Install to %s requires sudo. Continue? [y/N] " "$DEST" >&2
      read -r reply < /dev/tty || reply=""
      case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) die "Aborted." ;;
      esac
    else
      die "Installing to $DEST requires sudo, but no terminal is available to confirm. Re-run with -y or with --prefix."
    fi
  fi
fi

# -------- Download into a temp dir --------
if $LOCAL; then
  installer_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  source_file="$installer_dir/fixbuddy"
  [ -f "$source_file" ] || die "No fixbuddy file beside install.sh. Build it with python3 scripts/build.py first."
  [ "$(head -n 1 "$source_file")" = '#!/usr/bin/env bash' ] || die "Local fixbuddy has an unexpected shebang."
  bash -n "$source_file" || die "Local fixbuddy failed Bash syntax validation."
  if [ -f "$installer_dir/SHA256SUMS" ]; then
    expected="$(awk '$2 == "fixbuddy" || $2 == "*fixbuddy" {print $1; exit}' "$installer_dir/SHA256SUMS")"
    [ -n "$expected" ] || die "Local SHA256SUMS has no fixbuddy entry."
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$source_file" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$source_file" | awk '{print $1}')"
    else
      die "Local checksum verification requires sha256sum or shasum."
    fi
    [ "$actual" = "$expected" ] || die "Local fixbuddy checksum mismatch. Rebuild SHA256SUMS."
  fi
  [ -d "$DEST" ] || as_root mkdir -p "$DEST"
  stage="$DEST/.fixbuddy.install.$$"
  trap 'as_root rm -f "$stage" 2>/dev/null || true' EXIT
  as_root cp "$source_file" "$stage"
  as_root chmod +x "$stage"
  as_root mv "$stage" "$DEST/fixbuddy"
  trap - EXIT
  ok "Installed single-file fixbuddy to $DEST"
  if in_path "$DEST"; then
    printf '\nRun:  fixbuddy\n' >&2
  else
    warn "$DEST is not in your PATH. Run: $DEST/fixbuddy"
  fi
  exit 0
fi

TMP_DL="$(mktemp -d "${TMPDIR:-/tmp}/fixbuddy-install.XXXXXX")"
STAGE1=""
STAGE2=""
STAGE3=""
cleanup() {
  rm -rf "$TMP_DL"
  if [ -n "$STAGE1" ]; then as_root rm -f "$STAGE1" 2>/dev/null || true; fi
  if [ -n "$STAGE2" ]; then as_root rm -f "$STAGE2" 2>/dev/null || true; fi
  if [ -n "$STAGE3" ]; then as_root rm -f "$STAGE3" 2>/dev/null || true; fi
}
trap cleanup EXIT

info "Downloading fixbuddy ($REF) ..."
for script in "${SCRIPTS[@]}"; do
  url="$RAW_BASE/$REF/$script"
  if ! curl -fsSL "$url" -o "$TMP_DL/$script"; then
    die "Failed to download $script from $url (is the ref '$REF' valid?)"
  fi
  # Reject HTML error pages: the file must start with the expected shebang.
  first_line="$(head -n 1 "$TMP_DL/$script")"
  case "$script" in
    *.py)
      [ "$first_line" = "#!/usr/bin/env python3" ] || die "Downloaded $script has an unexpected shebang."
      python3 -m py_compile "$TMP_DL/$script" 2>/dev/null || die "Downloaded $script failed Python syntax validation."
      ;;
    *)
      [ "$first_line" = "#!/usr/bin/env bash" ] || die "Downloaded $script is not a bash script."
      bash -n "$TMP_DL/$script" 2>/dev/null || die "Downloaded $script failed Bash syntax validation."
      ;;
  esac
done

# -------- Optional checksum verification --------
if curl -fsSL "$RAW_BASE/$REF/SHA256SUMS" -o "$TMP_DL/SHA256SUMS" 2>/dev/null; then
  if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | awk '{print $1}'; }
  elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
  else
    sha256() { return 1; }
  fi
  if sha256 "$TMP_DL/${SCRIPTS[0]}" >/dev/null 2>&1; then
    for script in "${SCRIPTS[@]}"; do
      expected="$(awk -v f="$script" '$2 == f || $2 == "*"f {print $1; exit}' "$TMP_DL/SHA256SUMS")"
      if [ -z "$expected" ]; then
        die "SHA256SUMS exists at ref '$REF' but has no entry for $script — refusing to install an unverifiable script."
      fi
      actual="$(sha256 "$TMP_DL/$script")"
      [ "$expected" = "$actual" ] || \
        die "Checksum mismatch for $script (expected $expected, got $actual). Aborting."
    done
    ok "Checksums match SHA256SUMS (download integrity only, not a signature)."
    case "$REF" in
      v[0-9]*) ;;  # tagged release — SHA256SUMS is expected to match
      *) warn "Ref '$REF' is not a release tag; the bundled SHA256SUMS may not match these scripts." ;;
    esac
  else
    { $WITH_TUI || $SINGLE_FILE; } && die "Installing FixBuddy requires sha256sum or shasum to verify its checksum."
    warn "No sha256 tool (sha256sum/shasum) found — skipping checksum verification."
  fi
else
  { $WITH_TUI || $SINGLE_FILE; } && die "Installing FixBuddy requires SHA256SUMS at ref '$REF'."
  warn "No SHA256SUMS published at ref '$REF' — skipping checksum verification."
fi

# -------- Install atomically --------
if $SINGLE_FILE; then
  [ -d "$DEST" ] || as_root mkdir -p "$DEST"
  STAGE1="$DEST/.fixbuddy.install.$$"
  as_root cp "$TMP_DL/fixbuddy" "$STAGE1"
  as_root chmod +x "$STAGE1"
  as_root mv "$STAGE1" "$DEST/fixbuddy"
  STAGE1=""
  ok "Installed single-file fixbuddy ($REF) to $DEST"
  if in_path "$DEST"; then
    printf '\nRun:  fixbuddy\n' >&2
  else
    warn "$DEST is not in your PATH. Run: $DEST/fixbuddy"
  fi
  exit 0
fi

new_version="$(script_version "$TMP_DL/fixbuddy.sh")"
[ -n "$new_version" ] || new_version="$REF"

if [ -f "$DEST/fixbuddy.sh" ]; then
  old_version="$(script_version "$DEST/fixbuddy.sh")"
  if [ -n "$old_version" ] && [ "$old_version" != "$new_version" ]; then
    info "Updating fixbuddy $old_version -> $new_version"
  else
    info "Reinstalling fixbuddy $new_version"
  fi
fi

[ -d "$DEST" ] || as_root mkdir -p "$DEST"
# Stage all selected scripts into the destination under temp names, then swap each
# into place with an atomic per-file rename. If staging a later file
# fails, the first is still only a temp file, so the destination is never
# left with a half-applied install.
STAGE1="$DEST/.fixbuddy.sh.install.$$"
STAGE2="$DEST/.fixbuddy-wizard.sh.install.$$"
as_root cp "$TMP_DL/fixbuddy.sh" "$STAGE1"
as_root cp "$TMP_DL/fixbuddy-wizard.sh" "$STAGE2"
if $WITH_TUI; then
  STAGE3="$DEST/.fixbuddy-tui.py.install.$$"
  as_root cp "$TMP_DL/fixbuddy-tui.py" "$STAGE3"
fi
as_root chmod +x "$STAGE1" "$STAGE2"
[ -z "$STAGE3" ] || as_root chmod +x "$STAGE3"
as_root mv "$STAGE1" "$DEST/fixbuddy.sh"
as_root mv "$STAGE2" "$DEST/fixbuddy-wizard.sh"
[ -z "$STAGE3" ] || as_root mv "$STAGE3" "$DEST/fixbuddy-tui.py"
STAGE1=""
STAGE2=""
STAGE3=""

ok "Installed fixbuddy $new_version to $DEST"

# -------- PATH hint --------
if in_path "$DEST"; then
  printf '\nRun:  fixbuddy-wizard.sh\n' >&2
  if $WITH_TUI; then printf '      fixbuddy-tui.py\n' >&2; fi
else
  warn "$DEST is not in your PATH."
  rc_file="$HOME/.profile"
  case "$(basename "${SHELL:-}")" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash) rc_file="$HOME/.bashrc" ;;
  esac
  printf '  Add it to your PATH:\n' >&2
  # shellcheck disable=SC2016  # literal $PATH is intentional in the printed hint
  printf '    echo '\''export PATH="%s:$PATH"'\'' >> %s\n' "$DEST" "$rc_file" >&2
  printf '  Then restart your shell. Until then, run it directly:\n' >&2
  printf '    %s/fixbuddy-wizard.sh\n' "$DEST" >&2
  if $WITH_TUI; then printf '    %s/fixbuddy-tui.py\n' "$DEST" >&2; fi
fi
