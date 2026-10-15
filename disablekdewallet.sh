#!/usr/bin/env bash
# disablekdewallet - completely disable KDE Wallet on any distro running KDE Plasma.
#
#   1. Sets Enabled=false in ~/.config/kwalletrc (works on every distro)
#   2. Stops any running wallet daemon (kwalletd5, kwalletd6, ksecretd)
#   3. Removes the kwallet PAM module package using your distro's package manager
#
# Run it as your normal user (not root); it calls sudo only for step 3.

set -euo pipefail

DRY_RUN=0
SKIP_PAM=0
OS_RELEASE_FILE=${OS_RELEASE_FILE:-/etc/os-release}

bold=$'\e[1m' green=$'\e[32m' yellow=$'\e[33m' red=$'\e[31m' reset=$'\e[0m'
[[ -t 1 ]] || bold='' green='' yellow='' red='' reset=''

info() { printf '%s==>%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s==> warning:%s %s\n' "$yellow" "$reset" "$*" >&2; }
die()  { printf '%s==> error:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

run() {
    if (( DRY_RUN )); then
        printf '    [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Completely disables KDE Wallet for the current user.

Options:
  --skip-pam   Only disable the wallet; don't remove the PAM module package
  --dry-run    Show what would be done without changing anything
  -h, --help   Show this help
EOF
}

# --- distro detection ------------------------------------------------------

# Prints one of: arch, debian, fedora, suse, void, nixos, unknown
detect_family() {
    local ID='' ID_LIKE=''
    [[ -r $OS_RELEASE_FILE ]] && . "$OS_RELEASE_FILE"
    local id
    for id in $ID $ID_LIKE; do
        case $id in
            steamos) echo steamos; return ;;
            arch|archlinux|manjaro|endeavouros|cachyos|garuda) echo arch; return ;;
            debian|ubuntu|neon|linuxmint|pop) echo debian; return ;;
            fedora|rhel|centos|nobara|bazzite) echo fedora; return ;;
            opensuse*|suse|sles) echo suse; return ;;
            void) echo void; return ;;
            nixos) echo nixos; return ;;
        esac
    done
    echo unknown
}

distro_name() {
    local PRETTY_NAME='' NAME=''
    [[ -r $OS_RELEASE_FILE ]] && . "$OS_RELEASE_FILE"
    echo "${PRETTY_NAME:-${NAME:-unknown distro}}"
}

root_is_readonly() {
    local opts
    opts=$(findmnt -no OPTIONS / 2>/dev/null) || return 1
    [[ ,$opts, == *,ro,* ]]
}

# --- step 1: disable the wallet ---------------------------------------------

disable_wallet() {
    local kwc
    if command -v kwriteconfig6 >/dev/null; then
        kwc=kwriteconfig6
    elif command -v kwriteconfig5 >/dev/null; then
        kwc=kwriteconfig5
    else
        die "kwriteconfig6/kwriteconfig5 not found. Is KDE Plasma installed?"
    fi

    info "Disabling KDE Wallet in ~/.config/kwalletrc (using $kwc)"
    run "$kwc" --file kwalletrc --group Wallet --key Enabled false
    run "$kwc" --file kwalletrc --group Wallet --key "First Use" false
}

# --- step 2: stop running daemons -------------------------------------------

stop_daemons() {
    local d stopped=0
    for d in kwalletd5 kwalletd6 ksecretd; do
        if pgrep -x -u "$(id -u)" "$d" >/dev/null; then
            info "Stopping $d"
            run pkill -x -u "$(id -u)" "$d" || true
            stopped=1
        fi
    done
    (( stopped )) || info "No wallet daemon running"
}

# --- step 3: remove the PAM module ------------------------------------------

# The PAM module plus its login autostart entry (a separate package on Debian/Ubuntu)
find_pam_files() {
    {
        find /usr/lib /usr/lib64 /lib /lib64 -maxdepth 3 -name 'pam_kwallet*.so' 2>/dev/null
        ls /etc/xdg/autostart/pam_kwallet_init.desktop 2>/dev/null
    } | xargs -r realpath | sort -u
}

# Prints the package(s) owning the given PAM module files
owning_packages() {
    local family=$1; shift
    local f
    for f in "$@"; do
        case $family in
            arch)   pacman -Qqo "$f" 2>/dev/null ;;
            debian) dpkg -S "$(basename "$f")" 2>/dev/null | cut -d: -f1 | tr ', ' '\n\n' ;;
            fedora|suse) rpm -qf --qf '%{NAME}\n' "$f" 2>/dev/null ;;
            void)   xbps-query -o "$f" 2>/dev/null | cut -d: -f1 | sed 's/-[^-]*$//' ;;
        esac
    done | grep -v '^$' | sort -u
}

remove_pam() {
    local family
    family=$(detect_family)
    info "Detected distro: $(distro_name) (family: $family)"

    case $family in
        nixos)
            warn "NixOS is configured declaratively. Add this to configuration.nix and rebuild:"
            echo '    security.pam.services.sddm.kwallet.enable = false;'
            return ;;
        steamos)
            warn "SteamOS has a read-only system; skipping PAM removal (step 1 is enough)."
            return ;;
    esac

    local modules
    mapfile -t modules < <(find_pam_files)
    if (( ${#modules[@]} == 0 )); then
        info "No kwallet PAM module installed, nothing to remove"
        return
    fi
    info "Found: ${modules[*]}"

    if [[ $family == unknown ]]; then
        warn "Unsupported distro; remove the package that owns ${modules[*]} manually."
        warn "Step 1 alone already stops the wallet from opening."
        return
    fi

    local pkgs
    mapfile -t pkgs < <(owning_packages "$family" "${modules[@]}")
    if (( ${#pkgs[@]} == 0 )); then
        warn "Couldn't determine which package owns the PAM module; skipping removal."
        return
    fi
    info "Removing package(s): ${pkgs[*]}"
    warn "Read the list your package manager shows before confirming. If it wants to"
    warn "remove other packages (e.g. a desktop metapackage), answer no; step 1 is enough."

    local cmd=()
    if [[ -e /run/ostree-booted ]]; then
        cmd=(sudo rpm-ostree override remove "${pkgs[@]}")
    elif [[ $family == suse ]] && root_is_readonly && command -v transactional-update >/dev/null; then
        cmd=(sudo transactional-update pkg remove "${pkgs[@]}")
    elif root_is_readonly; then
        warn "Root filesystem is read-only; skipping PAM removal (step 1 is enough)."
        return
    else
        case $family in
            arch)   cmd=(sudo pacman -Rns "${pkgs[@]}") ;;
            debian) cmd=(sudo apt-get purge "${pkgs[@]}") ;;
            fedora) cmd=(sudo dnf remove "${pkgs[@]}") ;;
            suse)   cmd=(sudo zypper remove "${pkgs[@]}") ;;
            void)   cmd=(sudo xbps-remove -R "${pkgs[@]}") ;;
        esac
    fi

    # When the script itself is piped in (curl ... | bash), stdin isn't the keyboard,
    # so let the package manager ask for confirmation on the terminal instead.
    local rc=0
    if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
        run "${cmd[@]}" </dev/tty || rc=$?
    else
        run "${cmd[@]}" || rc=$?
    fi
    if (( rc )); then
        warn "Package removal failed or was cancelled. The wallet is still disabled (step 1)."
        return
    fi
    if [[ ${cmd[1]} == rpm-ostree || ${cmd[1]} == transactional-update ]]; then
        info "Reboot to apply the package removal."
    fi
}

# --- main --------------------------------------------------------------------

main() {
    while (( $# )); do
        case $1 in
            --skip-pam) SKIP_PAM=1 ;;
            --dry-run)  DRY_RUN=1 ;;
            -h|--help)  usage; exit 0 ;;
            *) usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done

    (( EUID != 0 )) || die "Run this as your normal user, not root (it uses sudo when needed)."

    printf '%sStep 1/3:%s disable KDE Wallet\n' "$bold" "$reset"
    disable_wallet
    printf '%sStep 2/3:%s stop wallet daemons\n' "$bold" "$reset"
    stop_daemons
    printf '%sStep 3/3:%s remove kwallet PAM module\n' "$bold" "$reset"
    if (( SKIP_PAM )); then
        info "Skipped (--skip-pam)"
    else
        remove_pam
    fi

    echo
    info "Done. KDE Wallet is disabled; log out and back in to finish."
    info "Your old wallet file (if any) is still in ~/.local/share/kwalletd/."
}

main "$@"
