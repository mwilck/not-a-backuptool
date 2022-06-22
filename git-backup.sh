#! /bin/bash
: "${_MAXPACKSIZE:=16m}"
: "${BACKUP_REPO:=BACKUP}"

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

init_backup_repo() {
    local x orig=$1 clone=$2 ref=$3

    [[ $orig && -d "$orig" ]]
    [[ $ref && -d "$ref" ]]
    [[ $clone && ! -d "$clone" ]]
    git -C "$ref" fetch --all --no-auto-maintenance || true
    git clone --mirror --reference "$ref" "$orig" "$clone"
    [[ -d "$clone" ]]

    git -C "$orig" remote add --mirror=push "$BACKUP_REPO" "$clone"
    git -C "$orig" config "remote.$BACKUP_REPO.skipFetchAll" true

    git -C "$clone" config pack.packSizeLimit "$MAXPACKSIZE"
    git -C "$clone" config repack.packKeptObjects false
    git -C "$clone" config core.commitGraph false
    # useful for fetch and clone only
    git -C "$clone" config repack.writeBitmaps false
    # -l: don't bother about alternate objects
    # -f: recompute deltas
    # -a: all
    # -d: remove old stuff
    # -n: don't update server info
    git -C "$clone" repack -a -l -f -d -n
    make_keep_files "$clone"
    # this seems to be generated despite the config setting above
    rm -f "$clone/objects/info/commit-graph"
}

usage() {
    echo "Usage: $0 [options] orig [backup reference]"
    printf "%s/%s %s\t%s\n" \
	   "-h" "--help" "" "print this help" \
	   "-m" "--max-pack-size" "SIZE" "set max pack size"
}

git_path() {
    local dir=$1 file=$2 d
    for d in "$dir/.git" "$dir"; do
	[[ ! -e "$d/$file" ]] || continue
	echo "$d/$file"
	return 0
    done
    return 1
}

set -- $(getopt -ohm: -l help -l max-pack-size: -- "$@")
while [[ $# -gt 0 ]]; do
    case $1 in
	-h|--help)
	    usage
	    exit 0;;
	-m|--max-pack-size)
	    shift
	    eval "_MAXPACKSIZE=$1"
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

git_path() {
    local dir=$1 file=$2 d
    for d in "$dir/.git" "$dir"; do
	[[ -e "$d/$file" ]] || continue
	echo "$d/$file"
    done
}

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
    echo === $0: Updating backup repo $CLONE ... >&2
    ALT=$(cat $CLONE/objects/info/alternates)
    if [[ $ALT ]]; then
	ALT=${ALT%/objects}
	ALT=${ALT%/.git}
	git -C "$ALT" fetch --all --no-auto-maintenance || true
    fi
    git -C "$ORIG" push "$BACKUP_REPO"
    git -C "$CLONE" repack -l -f -d -n

    MAXPACKSIZE=$(git -C "$CLONE" config pack.packSizeLimit)
    MAXPACKSIZE=${MAXPACKSIZE:-"$_MAXPACKSIZE"}
    MAXPAXKSIZE=$(realsize "$MAXPACKSIZE")
    make_keep_files "$CLONE"
else
    [[ $# -eq 2 ]]
    echo === $0: Creating backup repo $1 ... >&2
    eval "check_alternates \"$ORIG\" $2"
    eval "init_backup_repo \"$ORIG\" $1 $2"
fi
