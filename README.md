# disablekdewallet

A script that completely disables KDE Wallet on any Linux distro running KDE Plasma 5 or 6.

## What it does

1. Sets `Enabled=false` in `~/.config/kwalletrc`. This is the same as unticking "Enable the KDE wallet subsystem" in System Settings, and it works on every distro.
2. Stops any running wallet daemon (`kwalletd5`, `kwalletd6` or `ksecretd`).
3. Detects your distro and removes the kwallet PAM module package (the one that unlocks the wallet at login) with your package manager.

| Distro family | Examples | Removal command |
|---|---|---|
| Arch | Arch, Manjaro, EndeavourOS, CachyOS, Garuda | `pacman -Rns` |
| Debian | Debian, Ubuntu, Kubuntu, KDE neon, Mint, Pop!_OS | `apt-get remove` |
| Fedora | Fedora, Nobara | `dnf remove` |
| Fedora Atomic | Kinoite, Bazzite | `rpm-ostree override remove` (needs a reboot) |
| openSUSE | Tumbleweed, Leap, Kalpa | `zypper remove` / `transactional-update pkg remove` |
| Void | Void Linux | `xbps-remove -R` |
| NixOS | | Prints the `configuration.nix` option to set |
| SteamOS | | Skipped (read-only system) |

On other distros the script still runs steps 1 and 2. Step 1 alone is enough to stop the wallet from opening.

## Usage

```bash
git clone https://github.com/GiovMaggi/disablekdewallet.git
cd disablekdewallet
./disablekdewallet.sh
```

Run it as your normal user, not with `sudo`. The script asks for your password only when it removes the package. Log out and back in afterwards.

Options:

- `--dry-run` shows what the script would do without changing anything.
- `--skip-pam` only disables the wallet and leaves the PAM package installed.

Your package manager shows what it will remove and asks you to confirm. If it also wants to remove other packages, such as a desktop metapackage, answer no. The wallet is already disabled by step 1.

## Things to know

- **Your wallet file is kept.** It stays in `~/.local/share/kwalletd/`, so you can still export saved passwords with KWalletManager. Delete it yourself when you no longer need it.
- **Apps lose their password store.** Browsers and apps that kept secrets in KWallet will fall back to plain storage or ask for passwords again. Chrome and Electron apps can be launched with `--password-store=basic`.
- **The change is per user.** Other accounts on the same machine need to run the script themselves.

## Undo

```bash
kwriteconfig6 --file kwalletrc --group Wallet --key Enabled true   # kwriteconfig5 on Plasma 5
```

Then reinstall your distro's kwallet PAM package if you removed it, for example `kwallet-pam` on Arch.
