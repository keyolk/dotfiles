# dotfiles

The dotfiles URL for my warren workspaces. It holds no dotfiles: `install.sh`
fetches the portable part of my dots store (`keyolk/config`) and links it into
`$HOME`.

warren clones a dotfiles URL whole and runs its `install.sh` on every start.
The store also carries private keys, the GPG keyring and a kubeconfig in
clear, so its own URL would copy all of that onto the workspace volume.
`install.sh` fetches the store blobless and checks out only the paths it
lists, so no other file's contents reach the workspace.

## Use

In warren's new-workspace form (or Detail → dotfiles), set the dotfiles URL to
this repo. The workspace needs gh signed in as `keyolk`, the account that can
read the store (`gh auth login`, then `gh auth switch` back if you like: the
script asks for that account by name).

Sync: commit on the laptop (`dots save -M … --push`), then restart the
workspace, or run `~/.config/coderv2/dotfiles/install.sh` there.

## What comes over

| | paths |
|---|---|
| fish | `config.fish`, `conf.d/`, `functions/` |
| tmux | `.tmux.conf`, tpm |
| vim / nvim | `.vimrc`, `.vim/`, `.config/nvim/`, vim-plug |
| git | `.gitconfig` (as `~/.config/git/config`; the workspace's `~/.gitconfig` is left alone), `.themes.gitconfig`, `.gitconfig-keyolk` |
| prompt | `.config/starship.toml` |

Not: `.bashrc`/`.profile` (Homebrew and Kiro), `~/.claude` (warren and the org
config own it), `.gitconfig-mac`, and everything secret.

Tools the configs call and the image lacks (`starship fzf bat ripgrep`) are
installed with mise; vim and tmux plugins install in the background.

## Settings

| variable | default |
|---|---|
| `DOTFILES_STORE_URL` | `https://github.com/keyolk/config.git` |
| `DOTFILES_STORE_BRANCH` | `master` |
| `DOTFILES_GH_USER` | `keyolk` |
| `DOTFILES_STORE_DIR` | `~/.local/share/dotfiles-store` |
| `DOTFILES_TOOLS` | `starship fzf bat ripgrep` (empty: none) |
