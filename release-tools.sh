#!/usr/bin/env bash
# Installs my harness TUIs from their GitHub releases into ~/.local/bin, for a
# warren workspace (Linux, no Rust/Go toolchains). The laptop builds them from
# source (`make install`, dots manifest) and never runs this.
#
# Every tool publishes <name>_<version>_<os>_<arch>.tar.gz + checksums.txt on a
# v* tag, binaries at the archive root. This takes the latest release, checks
# the archive's sha256 against checksums.txt, and links nothing it did not
# install: a binary already in ~/.local/bin that this script did not put there
# (a local build) is left alone.
#
#   release-tools.sh            install missing tools, update ones installed here
#   release-tools.sh status     what is installed and from which release
#   release-tools.sh <tool>...  only these
#
# A tool whose latest release has no archive for this platform is skipped with
# a note, not an error: it may simply not ship Linux yet.
set -u

# name  repo  gh-account  binaries...
# gh-account: the gh login that can read the repo (keyolk's repos are public,
# but the account avoids the anonymous rate limit; sendbird/* needs the work
# account, which is the workspace's active one, written as "-").
TOOLS='
tmc      keyolk/tmc      keyolk  tmc
ghx      keyolk/ghx      keyolk  ghx
gcl      keyolk/gcl      keyolk  gcl
okx      keyolk/okx      keyolk  okx
dots     keyolk/dots     keyolk  dots
kmd      keyolk/kmd      keyolk  kmd
narwhal  keyolk/narwhal  keyolk  narwhal
tweb     keyolk/tweb     keyolk  tweb twebd
ccx      sendbird/ccx    -       ccx
'

bin_dir="${RELEASE_TOOLS_BIN:-$HOME/.local/bin}"
state="${XDG_STATE_HOME:-$HOME/.local/state}/release-tools"
mkdir -p "$bin_dir" "$state"

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "release-tools: unsupported OS $(uname -s)"; exit 0 ;; esac
case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) echo "release-tools: unsupported arch $(uname -m)"; exit 0 ;; esac

gh_bin=$(command -v gh 2>/dev/null || true)
if [ -z "$gh_bin" ]; then
	for c in "$HOME/.local/share/mise/shims/gh" "$HOME"/.local/share/mise/installs/github-cli/*/*/bin/gh "$HOME"/.local/share/mise/installs/github-cli/*/bin/gh; do
		[ -x "$c" ] && { gh_bin=$c; break; }
	done
fi
[ -n "$gh_bin" ] || { echo "!! release-tools: gh not found"; exit 1; }

# gh as the account that can read <repo>. The token goes through the
# environment of this one call, never a command line.
ghr() { # ghr <account> <gh args...>
	local acct=$1; shift
	if [ "$acct" = - ]; then "$gh_bin" "$@"; return; fi
	GH_TOKEN="$("$gh_bin" auth token --user "$acct" 2>/dev/null || "$gh_bin" auth token 2>/dev/null)" "$gh_bin" "$@"
}

if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi

status() {
	printf '%-8s %-10s %s\n' tool installed source
	echo "$TOOLS" | while read -r name repo _ _; do
		[ -n "$name" ] || continue
		v=$(cat "$state/$name.version" 2>/dev/null || echo -)
		printf '%-8s %-10s %s\n' "$name" "$v" "$repo"
	done
}

install_one() { # install_one <name> <repo> <account> <bins...>
	local name=$1 repo=$2 acct=$3; shift 3
	local tag ver asset tmp ok b want have
	tag=$(ghr "$acct" release view --repo "$repo" --json tagName -q .tagName 2>/dev/null) ||
		{ echo "    $name: no release on $repo"; return 0; }
	ver=${tag#v}
	asset="${name}_${ver}_${os}_${arch}.tar.gz"
	if [ "$(cat "$state/$name.version" 2>/dev/null)" = "$tag" ]; then
		ok=1
		for b in "$@"; do [ -x "$bin_dir/$b" ] || ok=0; done
		[ $ok = 1 ] && return 0
	fi
	# A binary this script did not install is a local build: keep it.
	for b in "$@"; do
		if [ -e "$bin_dir/$b" ] && [ ! -f "$state/$name.$b.sha" ]; then
			echo "    $name: $bin_dir/$b was not installed by release-tools; leaving it"
			return 0
		fi
		if [ -f "$state/$name.$b.sha" ] && [ -e "$bin_dir/$b" ] && [ "$(sha "$bin_dir/$b")" != "$(cat "$state/$name.$b.sha")" ]; then
			echo "    $name: $bin_dir/$b changed since release-tools installed it; leaving it"
			return 0
		fi
	done
	tmp=$(mktemp -d)
	if ! ghr "$acct" release download "$tag" --repo "$repo" --dir "$tmp" --pattern "$asset" --pattern checksums.txt >/dev/null 2>&1 ||
		[ ! -f "$tmp/$asset" ]; then
		echo "    $name: $tag has no $asset; skipped"
		rm -rf "$tmp"
		return 0
	fi
	want=$(awk -v f="$asset" '$2 == f || $2 == "*"f {print $1}' "$tmp/checksums.txt" 2>/dev/null)
	have=$(sha "$tmp/$asset")
	if [ -z "$want" ] || [ "$want" != "$have" ]; then
		echo "!! release-tools: $name $tag: checksum mismatch or missing for $asset"
		rm -rf "$tmp"
		return 1
	fi
	mkdir "$tmp/x" && tar -xzf "$tmp/$asset" -C "$tmp/x" || { echo "!! release-tools: $name: bad archive"; rm -rf "$tmp"; return 1; }
	for b in "$@"; do
		if [ ! -f "$tmp/x/$b" ]; then
			echo "!! release-tools: $name $tag: $b is not in $asset"
			rm -rf "$tmp"
			return 1
		fi
	done
	for b in "$@"; do
		install -m 0755 "$tmp/x/$b" "$bin_dir/.$b.new" && mv -f "$bin_dir/.$b.new" "$bin_dir/$b"
		sha "$bin_dir/$b" >"$state/$name.$b.sha"
	done
	echo "$tag" >"$state/$name.version"
	rm -rf "$tmp"
	echo "    $name: installed $tag"
}

[ "${1:-}" = status ] && { status; exit 0; }
only=" $* "
fail=0
while read -r name repo acct bins; do
	[ -n "$name" ] || continue
	[ "$only" = "  " ] || case "$only" in *" $name "*) ;; *) continue ;; esac
	# shellcheck disable=SC2086 # bins is a word list
	install_one "$name" "$repo" "$acct" $bins || fail=1
done <<EOF
$TOOLS
EOF
exit $fail
