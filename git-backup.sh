#! /bin/bash
: "${_MAXPACKSIZE:=16m}"
: "${BACKUP_REPO:=BACKUP}"
: "${ORIG_REPO:=origin}"
: "${GIT_TRACE2_REPACK:=}"

err() {
    trap - ERR
    echo "error in $BASH_COMMAND" >&2
    exit 1
}
trap err ERR
set -E

make_keep_files() {
    local clone=$1

    for x in "$clone"/objects/pack/*.pack; do
	touch "${x%.pack}.keep"
    done
}

realsize() {
    size=$1
    case $size in
	*g) size=$((${size%g} * 1024 * 1024 * 1024));;
	*m) size=$((${size%m} * 1024 * 1024));;
	*k) size=$((${size%k} * 1024));;
    esac
    printf "%d\n" "$size"
}

git_path() {
    local dir=$1 file=$2 d
    for d in "$dir/.git" "$dir"; do
	[[ -e "$d/$file" ]] || continue
	echo "$d/$file"
    done
}

init_backup_repo() {
    local x orig=$1 clone=$2 ref=$3

    [[ $orig && -d "$orig" ]]
    [[ $ref && -d "$ref" ]]
    [[ $clone && ! -d "$clone" ]]
    echo "-- $0: updating $ref ..." >&2
    git -C "$ref" fetch --all --no-auto-maintenance

    echo "-- $0: configuring backup repo $clone for $orig ..." >&2
    mkdir -p "$clone"
    [[ -d "$clone" ]]
    git -C "$clone" init --bare -q
    echo "$(git_path "$ref" objects)" >"$clone"/objects/info/alternates

    git -C "$orig" remote add --mirror=push "$BACKUP_REPO" "$clone"
    git -C "$orig" config "remote.$BACKUP_REPO.skipFetchAll" true
    git -C "$orig" config "remote.$BACKUP_REPO.mirror" true

    # Map local hierachy of original repo to backup/$ORIG_REPO
    git -C "$orig" config "remote.$BACKUP_REPO.push" "+refs/*:refs/backup/$ORIG_REPO/*"
    git -C "$orig" config "remote.$BACKUP_REPO.fetch" "refs/backup/$ORIG_REPO/*:refs/*"

    git -C "$clone" remote add "$ORIG_REPO" "$orig"
    git -C "$clone" config "remote.$ORIG_REPO.fetch" "+refs/*:refs/backup/$ORIG_REPO/*"
    git -C "$clone" config "remote.$ORIG_REPO.push" "refs/backup/$ORIG_REPO/*:refs/*"

    # Don't generate stuff we don't need in backup
    git -C "$clone" config core.commitGraph false
    git -C "$clone" config core.multiPackIndex false
    git -C "$clone" config fetch.writeCommitGraph false

    git -C "$clone" config receive.autogc false
    git -C "$clone" config receive.denyDeletes false
    git -C "$clone" config receive.denyDeleteCurrent false
    git -C "$clone" config receive.denyCurrentBranch false
    git -C "$clone" config receive.denyNonFastForwards false
    git -C "$clone" config receive.updateServerInfo false
    git -C "$clone" config receive.shallowUpdate true

    git -C "$clone" config pack.packSizeLimit "$MAXPACKSIZE"
    # don't repack objects in kept packs
    git -C "$clone" config repack.packKeptObjects false

    # No automatic maintenance
    git -C "$clone" config maintenance.strategy none
    git -C "$clone" config gc.auto false
    git -C "$clone" config gc.autoPackLimit 0

    # no bitmaps - useful for fetch and clone only
    git -C "$clone" config repack.writeBitmaps false

    echo "-- $0: pushing  ..." >&2
    git -C "$orig" push "$BACKUP_REPO"

    # In the future, store objects unpacked, we'll repack later
    # doing this before initial push will slow down stuff too much
    git -C "$clone" config receive.unpackLimit 1000000

    # -l: don't bother about alternate objects
    # -f: recompute deltas
    # -a: all
    # -d: remove old stuff
    # -n: don't update server info
    echo "-- $0: repacking $clone ..." >&2
    GIT_TRACE2=$GIT_TRACE2_REPACK git -C "$clone" repack -a -l -f -d -n
    make_keep_files "$clone"
    # this seems to be generated despite the config setting above
    rm -fv "$clone/objects/info/commit-graph"
}

usage() {
    echo "Usage: $0 [options] orig [backup reference]"
    printf "%s/%s %s\t%s\n" \
	   "-h" "--help" "" "print this help" \
	   "-m" "--max-pack-size" "SIZE" "set max pack size" \
	   "-n" "--name" "NAME" "set origin name in backup repo"
}

git_path() {
    local dir=$1 file=$2 d

    [[ -d "$dir" ]] || return
    for d in "$dir/.git" "$dir"; do
	[[ -e "$d/$file" ]] || continue
	echo "$d/$file"
	return
    done
    return
}

set -- $(getopt -ohm:n: -l help -l max-pack-size: -l name: -- "$@")
while [[ $# -gt 0 ]]; do
    case $1 in
	-h|--help)
	    usage
	    exit 0;;
	-m|--max-pack-size)
	    shift
	    eval "_MAXPACKSIZE=$1"
	    ;;
	-n|--name)
	    shift
	    eval "ORIG_REPO=$1"
	    ;;
	--)
	    shift
	    break
	    ;;
	*)
	    usage
	    exit 1
	    ;;
    esac
    shift
done
eval "ORIG=$1"
shift
[[ $ORIG && -d "$ORIG" ]]
MAXPACKSIZE=$(realsize "$_MAXPACKSIZE")

check_alternates() {
    local orig=$1 ref=$2 ALT l bad= lines
    ALT=$(git_path "$1" objects/info/alternates)
    case $ref in
	/*);;
	*) ref=$PWD/$ref;;
    esac
    if [[ $ALT ]]; then
	mapfile -t lines <"$ALT"
	for l in "${lines[@]}"; do
	    l=${l%/objects}
	    l=${l%/.git}
	    case $l in
		$ref) continue;;
		*) bad=yes
		   break;;
	    esac
	done
	if [[ $bad ]]; then
	    echo "$0: $ORIG uses alternates: $l. Exiting!" >&2
	    exit 1
	fi
    fi
}

CLONE=$(git -C "$ORIG" config "remote.$BACKUP_REPO.url") || true
if [[ $CLONE ]]; then
    [[ $# -eq 0 ]]
    echo "=== $0: Updating backup repo $CLONE ..." >&2
    ALT=$(cat $CLONE/objects/info/alternates)
    if [[ $ALT ]]; then
	ALT=${ALT%/objects}
	ALT=${ALT%/.git}
	echo "-- $0: updating $ALT ..." >&2
	git -C "$ALT" fetch --all --no-auto-maintenance || true
    fi
    echo "-- $0: pushing to $CLONE ..." >&2
    git -C "$ORIG" push "$BACKUP_REPO"

    MAXPACKSIZE=$(git -C "$CLONE" config pack.packSizeLimit)
    MAXPACKSIZE=${MAXPACKSIZE:-"$_MAXPACKSIZE"}
    MAXPAXKSIZE=$(realsize "$MAXPACKSIZE")

    echo "-- $0: repacking $CLONE ..." >&2
    GIT_TRACE2=$GIT_TRACE2_REPACK git -C "$CLONE" repack -l -f -d -n
    make_keep_files "$CLONE"
else
    [[ $# -eq 2 ]]
    eval "CLONE=$1"
    eval "REF=$2"
    echo "=== $0: Creating backup repo $1 ..." >&2
    check_alternates "$ORIG" "$REF"
    init_backup_repo "$ORIG" "$CLONE" "$REF"
fi
echo "=== %0: Done." >&2
