#!/usr/bin/env bash
# Applies the portable part of my dots store (github.com/keyolk/config) to a
# warren workspace. warren's dotfiles.sh clones this repo and runs this script
# from its root on every workspace start, so a change pushed to the store
# reaches the workspace at its next start (or when this script is run again).
#
# Why a separate repo: the store also holds private keys, the GPG keyring and
# a kubeconfig in clear. warren clones a dotfiles URL whole, so giving it the
# store's own URL would copy all of that onto the workspace volume. This
# script fetches the store as a blobless partial clone and checks out only
# PATHS below, so the contents of every other file never leave GitHub. Their
# names still do: a blobless clone carries every tree.
#
# What it does, each run:
#   1. clones or fast-forwards the store into $DOTFILES_STORE_DIR (sparse);
#   2. checks out the submodules the linked configs load (tpm, vim-plug);
#   3. symlinks every checked-out file into $HOME. A real file in the way is
#      kept once as <name>.bak (as warren's own linker does); a link this
#      script made earlier and no longer wants is removed;
#   4. links the store's .gitconfig as ~/.config/git/config, leaving
#      ~/.gitconfig (gh's credential helper, warren's GitHub sign-in) alone;
#   5. installs, with mise, the few tools the configs call that the image
#      lacks (best effort);
#   6. installs vim and tmux plugins in the background;
#   7. sets up the coordinator harness (~/.config/warren-coord/setup.sh).
# A failure in one step is reported and the others still run; warren never
# stops a start for dotfiles.
set -u

store_url="${DOTFILES_STORE_URL:-https://github.com/keyolk/config.git}"
branch="${DOTFILES_STORE_BRANCH:-master}"
# The GitHub account that can read the store. The workspace's active gh
# account is the work one, which cannot.
gh_user="${DOTFILES_GH_USER:-keyolk}"
dir="${DOTFILES_STORE_DIR:-$HOME/.local/share/dotfiles-store}"
state="$HOME/.local/state/dotfiles-store"
tools="${DOTFILES_TOOLS-starship fzf bat ripgrep}"

# Sparse-checkout patterns (gitignore syntax, rooted at the store's work
# tree, which is $HOME on the laptop). Only what is meant to work on Linux:
# .bashrc/.profile are brew- and Kiro-specific, and ~/.claude is managed by
# warren and the org config sync.
paths=(
	/.config/fish/config.fish
	/.config/fish/conf.d/
	/.config/fish/functions/
	/.config/nvim/
	/.config/starship.toml
	/.vimrc
	/.vim/
	/.tmux.conf
	/.tmux/
	/.gitconfig
	/.gitconfig-keyolk
	/.themes.gitconfig
	/.gitmodules
	/.config/warren-coord/
)
# Submodules the linked configs load. The rest (fisherman) are not needed.
submodules=(.tmux/plugins/tpm .vim/autoload/vim-plug)
# Files read in place rather than linked into $HOME (see step 4).
not_linked=(.gitconfig .gitmodules)

export GIT_TERMINAL_PROMPT=0

# gh comes from mise in the workspace image, and the start scripts that run
# this may not have mise's directories on PATH. The workspace's own
# ~/.gitconfig names one versioned gh path, which goes stale when mise moves
# gh to a new version, so it is not used either.
gh_bin=$(command -v gh 2>/dev/null || true)
if [ -z "$gh_bin" ]; then
	for c in "$HOME/.local/share/mise/shims/gh" "$HOME"/.local/share/mise/installs/github-cli/*/*/bin/gh "$HOME"/.local/share/mise/installs/github-cli/*/bin/gh; do
		[ -x "$c" ] && { gh_bin=$c; break; }
	done
fi
[ -n "$gh_bin" ] || echo "!! dotfiles-store: gh not found; git will have no GitHub credential"

# git with the store account's token. The helper asks gh at the moment git
# needs a credential, so the token never appears on a command line. When that
# account is not signed in here, it falls back to the active one.
helper='!f() { test "$1" = get || exit 0; t=$("'"$gh_bin"'" auth token --user '"$gh_user"' 2>/dev/null || "'"$gh_bin"'" auth token 2>/dev/null) || exit 0; echo username=x-access-token; echo "password=$t"; }; f'
sgit() {
	git -c credential.https://github.com.helper= \
		-c "credential.https://github.com.helper=$helper" \
		-C "$dir" "$@"
}

fail=0

# 1. Clone or update.
if [ -d "$dir/.git" ]; then
	echo "==> dotfiles-store: updating $dir"
	sgit sparse-checkout set --no-cone "${paths[@]}" || fail=1
	if ! sgit pull --ff-only --quiet origin "$branch"; then
		echo "!! dotfiles-store: pull failed; linking what is checked out"
		fail=1
	fi
else
	echo "==> dotfiles-store: cloning $store_url (blobless, sparse)"
	mkdir -p "$(dirname "$dir")"
	if ! git -c credential.https://github.com.helper= \
		-c "credential.https://github.com.helper=$helper" \
		clone --quiet --filter=blob:none --no-checkout --branch "$branch" "$store_url" "$dir"; then
		echo "!! dotfiles-store: clone failed. Is $gh_user signed in to gh here? (gh auth login)"
		exit 1
	fi
	# Patterns first, checkout second: the other order would fetch every blob.
	sgit sparse-checkout set --no-cone "${paths[@]}" || exit 1
	sgit checkout --quiet "$branch" || exit 1
fi

# The store's credential lives in the clone's own config too, so a plain git
# there (warren's Dotfiles status, `git -C <store> fetch`) can reach it.
git -C "$dir" config --replace-all credential.https://github.com.helper '' &&
	git -C "$dir" config --add credential.https://github.com.helper "$helper" || fail=1
# Tell warren's Dotfiles status about the store: this repo only installs it, so
# a `dots push` changes the store, not this repo, and would never show as an
# update otherwise. One line per repository: name, checkout, branch.
mkdir -p "$HOME/.local/state/warren"
printf 'keyolk/config\t%s\t%s\n' "$dir" "$branch" >"$HOME/.local/state/warren/dotfiles-sources"

# 2. Submodules.
sgit submodule update --init --quiet -- "${submodules[@]}" \
	|| { echo "!! dotfiles-store: submodule update failed"; fail=1; }

# 3. Links.
mkdir -p "$state"
want="$state/links.new"
: >"$want"
link() { # link <path relative to the store root>
	local rel="$1" src="$dir/$1" dst="$HOME/$1"
	printf '%s\n' "$rel" >>"$want"
	if [ -L "$dst" ]; then
		[ "$(readlink "$dst")" = "$src" ] && return 0
		rm -f "$dst"
	elif [ -e "$dst" ]; then
		local bak="$dst.bak"
		[ -e "$bak" ] && bak="$dst.bak.$(date +%s)"
		mv "$dst" "$bak" && echo "    kept $dst as $bak"
	fi
	mkdir -p "$(dirname "$dst")"
	ln -s "$src" "$dst"
}
skip() {
	local x
	for x in "${not_linked[@]}"; do [ "$1" = "$x" ] && return 0; done
	return 1
}
# H = checked out (not skip-worktree). A gitlink is linked as a directory,
# and only when it is one of the submodules above.
while read -r tag mode _ _ path; do
	[ "$tag" = H ] || continue
	skip "$path" && continue
	if [ "$mode" = 160000 ]; then
		case " ${submodules[*]} " in *" $path "*) link "$path" ;; esac
		continue
	fi
	link "$path"
done < <(sgit ls-files -s -t)
# Links made by an earlier run that the store no longer has.
if [ -f "$state/links" ]; then
	LC_ALL=C sort -u "$want" -o "$want"
	LC_ALL=C sort -u "$state/links" | LC_ALL=C comm -23 - "$want" | while read -r rel; do
		dst="$HOME/$rel"
		case "$(readlink "$dst" 2>/dev/null)" in
			"$dir"/*) rm -f "$dst" && echo "    removed stale link $dst" ;;
		esac
	done
fi
mv "$want" "$state/links"
echo "==> dotfiles-store: $(wc -l <"$state/links" | tr -d ' ') path(s) linked from $(sgit rev-parse --short HEAD)"

# 4. git: the store's .gitconfig becomes git's XDG config
# (~/.config/git/config), which git reads before ~/.gitconfig. ~/.gitconfig
# stays the workspace's: it holds gh's credential helper, and warren copies
# it between workspaces as the GitHub sign-in, so editing it would make
# warren treat it as signed in here and stop updating it. A store config
# that sets a credential helper would still replace gh's, so it is refused.
inc="$dir/.gitconfig"
xdg="$HOME/.config/git/config"
# What an earlier version of this script added to ~/.gitconfig.
git config --global --fixed-value --unset-all include.path "$inc" 2>/dev/null || true
if [ -f "$inc" ]; then
	if git config -f "$inc" --get-all credential.helper >/dev/null 2>&1; then
		echo "!! dotfiles-store: $inc sets credential.helper; not linking it"
		fail=1
	elif [ "$(readlink "$xdg" 2>/dev/null)" != "$inc" ]; then
		[ -e "$xdg" ] && [ ! -L "$xdg" ] && mv "$xdg" "$xdg.bak"
		mkdir -p "$(dirname "$xdg")"
		ln -sfn "$inc" "$xdg" && echo "    $xdg -> $inc"
	fi
fi

# 5. Tools.
if [ -n "$tools" ] && command -v mise >/dev/null; then
	for t in $tools; do
		bin=$t
		[ "$t" = ripgrep ] && bin=rg
		# mise which: installed but not on this script's PATH (no shims here).
		command -v "$bin" >/dev/null || mise which "$bin" >/dev/null 2>&1 && continue
		echo "==> dotfiles-store: installing $t with mise"
		mise use --global --quiet "$t@latest" </dev/null || { echo "!! dotfiles-store: mise could not install $t"; fail=1; }
	done
fi

# 6. Editor and tmux plugins, in the background: the first run clones a few
# dozen repositories, and a workspace start should not wait for that. Both
# installers skip what is already there, so every start runs them.
if command -v nvim >/dev/null && [ -f "$HOME/.vim/autoload/plug.vim" ]; then
	nohup nvim --headless "+PlugInstall --sync" +qa >"$state/plug.log" 2>&1 </dev/null &
	echo "    vim plugins: installing in the background ($state/plug.log)"
fi
if [ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]; then
	nohup "$HOME/.tmux/plugins/tpm/bin/install_plugins" >"$state/tpm.log" 2>&1 </dev/null &
	echo "    tmux plugins: installing in the background ($state/tpm.log)"
fi

# 7. The coordinator harness: a Claude Code session in tmux main:coord that
# hands long work to `warren task`. Linked by step 3; its script decides
# whether this is a warren workspace.
if [ -f "$HOME/.config/warren-coord/setup.sh" ]; then
	bash "$HOME/.config/warren-coord/setup.sh" || { echo "!! dotfiles-store: warren-coord setup failed"; fail=1; }
fi

exit "$fail"
