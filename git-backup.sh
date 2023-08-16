#! /bin/bash
: "${_MAXPACKSIZE:=2m}"
: "${BACKUP_REPO:=BACKUP}"
: "${ORIG_REPO:=$(hostname)}"
: "${GIT_TRACE2_REPACK:=}"
: "${UPSTREAM:=origin}"
# ref categories to backup / restore (except heads)
: "${REF_CATEGORIES:=tags notes replace}"
: "${RECONFIGURE:=}"

MYDIR=$(dirname "$0")
. "$MYDIR"/git-backup-functions.sh
ME=$(basename "$0")

trap err ERR
set -E

copy_reflog() {
    local orig=$1 repo=$2 clone refdir head tree

    head=$(git_path "$orig" logs/HEAD)
    clone=$(git -C "$orig" config "remote.$repo.url")
    refdir=$(git -C "$orig" config "remote.$repo.push" | \
		 sed -E 's,.*.:refs/(.*)/\*,\1,')

    [[ $clone && $refdir ]] || return 0

    mkdir -p "$clone/logs/$refdir"
    if [[ $head ]]; then
	rsync -c "$head" "$clone/logs/$refdir"
    fi

    local wt=$(git_path "$orig" worktrees)
    [[ $wt ]] || return 0

    for tree in "$wt"/*; do
	tree=$(basename "$tree")
	if [[ -f "$wt/$tree/logs/HEAD" ]]; then
	    mkdir -p "$clone/logs/$refdir/$tree"
	    rsync -c "$wt/$tree/logs/HEAD" "$clone/logs/$refdir/$tree"
	fi
    done
}

push_to_backup( ) {
    local orig=$1 repo=$2

    echo "-- $ME: pushing to $repo in $orig ..." >&2
    git -C "$orig" push "$repo"
    copy_reflog "$orig" "$repo"
}

configure_backup_repo() {
    local clone=$1

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
    git -C "$clone" config gc.auto 0
    git -C "$clone" config gc.autoPackLimit 0

    # no bitmaps - useful for fetch and clone only
    git -C "$clone" config repack.writeBitmaps false

}

configure_fetch_push() {
    local orig=$1 clone=$2 cat

    echo "-- $ME: configuring backup repo $clone for $orig ..." >&2

    git -C "$orig" remote add "$BACKUP_REPO" "$clone" || true
    git -C "$orig" config "remote.$BACKUP_REPO.skipFetchAll" true
    git -C "$orig" config "remote.$BACKUP_REPO.mirror" false

    git -C "$clone" remote add "$ORIG_REPO" "$orig" || true
    git -C "$clone" config "remote.$ORIG_REPO.skipFetchAll" false
    git -C "$clone" config "remote.$ORIG_REPO.mirror" false

    # Map local hierachy of original repo to refs/backup/$ORIG_REPO
    # refs fetched back will be under refs/restore
    # use e.g. git-restore-refs.sh to restore them
    git -C "$orig"  config --replace-all "remote.$BACKUP_REPO.fetch" "+refs/backup/$ORIG_REPO/heads/*:refs/restore/heads/*"
    git -C "$clone" config --replace-all "remote.$ORIG_REPO.push"    "+refs/backup/$ORIG_REPO/heads/*:refs/restore/heads/*"
    git -C "$orig"  config --replace-all "remote.$BACKUP_REPO.push"  "+refs/heads/*:refs/backup/$ORIG_REPO/heads/*"
    git -C "$clone" config --replace-all "remote.$ORIG_REPO.fetch"   "+refs/heads/*:refs/backup/$ORIG_REPO/heads/*"
    for cat in $REF_CATEGORIES; do
	git -C "$orig"  config --add "remote.$BACKUP_REPO.fetch" "+refs/backup/$ORIG_REPO/$cat/*:refs/restore/$cat/*"
	git -C "$clone" config --add "remote.$ORIG_REPO.push"    "+refs/backup/$ORIG_REPO/$cat/*:refs/restore/$cat/*"
	git -C "$orig"  config --add "remote.$BACKUP_REPO.push"  "+refs/$cat/*:refs/backup/$ORIG_REPO/$cat/*"
	git -C "$clone" config --add "remote.$ORIG_REPO.fetch"   "+refs/$cat/*:refs/backup/$ORIG_REPO/$cat/*"
    done
}

init_backup_repo() {
    local x orig=$1 clone=$2 ref=$3 remote cat

    [[ $orig && -d "$orig" ]]
    [[ $clone ]]
    if [[ -d "$clone" ]]; then
	remote=$(git -C "$clone" config remote."$ORIG_REPO".url) || true
	if [[ $remote ]]; then
	    echo "$ME: ERROR: remote $ORIG_REPO exists in $clone" >&2
	    exit 1
	fi
    else
	mkdir -p "$clone"
	[[ -d "$clone" ]]
	git -C "$clone" init --bare -q
	configure_backup_repo "$clone"
    fi

    if [[ $ref ]]; then
	[[ -d "$ref" ]]
	local p=$(git_path "$ref" objects)

	[[ $p ]]
	echo "$p" >"$clone"/objects/info/alternates
	echo "-- $ME: updating $ref ..." >&2
	git -C "$ref" fetch --all --no-auto-maintenance
    fi

    configure_fetch_push "$orig" "$clone"
    push_to_backup "$orig" "$BACKUP_REPO"

    # In the future, store objects unpacked, we'll repack later
    # doing this before initial push will slow down stuff too much
    git -C "$clone" config receive.unpackLimit 1000000

    # -l: don't bother about alternate objects
    # -f: recompute deltas
    # -a: all
    # -d: remove old stuff
    # -n: don't update server info
    echo "-- $ME: repacking $clone ..." >&2
    GIT_TRACE2=$GIT_TRACE2_REPACK git -C "$clone" repack -a -l -f -d -n
    make_keep_files "$clone" "$MAXPACKSIZE"
    create_remotes "$clone"
}

usage() {
    printf "Usage: %s [options] orig [backup]\nOptions:\n" "$ME"
    printf "%s/%s %s\t%s\n" \
	   "-h" "--help" "" "print this help" \
	   "-c" "--configure" "" "apply backup repo configuration" \
	   "-m" "--max-pack-size" SIZE "set max pack size" \
	   "-n" "--name" NAME "set origin name in backup repo" \
	   "-r" "--reference" PATH "set reference repository" \
	   "-u" "--upstream" REMOTE "upstream remote for reference repo, default 'origin'"
}

REF=
set -- $(getopt -ohcm:n:r:u: \
		-l help -l configure -l max-pack-size: -l name: \
		-l reference: -l upstream: \
		-- "$@")

while [[ $# -gt 0 ]]; do
    case $1 in
	-h|--help)
	    usage
	    exit 0
	    ;;
	-c|--configure)
	    RECONFIGURE=yes
	    ;;
	-m|--max-pack-size)
	    shift
	    eval "_MAXPACKSIZE=$1"
	    ;;
	-n|--name)
	    shift
	    eval "ORIG_REPO=$1"
	    ;;
	-r|--reference)
	    shift
	    eval "REF=$1"
	    ;;
	-u|--upstream)
	    shift
	    eval "UPSTREAM=$1"
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
[[ "$ORIG" == /* ]] || ORIG=$PWD/$ORIG
MAXPACKSIZE=$(realsize "$_MAXPACKSIZE")

create_reference_repo() {
    local repo=$1 origin=$2

    echo "-- $ME: creating reference repo $repo for $origin ..." >&2
    git clone --mirror "$origin" "$repo"

    git -C "$repo" config protocol.version 2
    git -C "$repo" config gc.auto 0
    # Don't prune unreachable objects, they may still be in use in original repo
    git -C "$repo" config gc.pruneExpire never
    git -C "$repo" config gc.worktreePruneExpire never
    # this prunes just remote-tracking refs (no objects), should be safe
    git -C "$repo" config fetch.prune true
    git -C "$repo" config fetch.pruneTags false
    # fetch objects in packs
    git -C "$repo" config fetch.unpackLimit 1
    # commit graph is taken care of by git maintenance
    git -C "$repo" config fetch.writeCommitGraph false
    # speed up fetches
    git -C "$repo" maintenance start || true
    git -C "$repo" config maintenance.auto false
}


CLONE=$(git -C "$ORIG" config "remote.$BACKUP_REPO.url") || true
if [[ $CLONE ]]; then
    echo "=== $ME: Updating backup repo $CLONE ..." >&2
    [[ $# -eq 0 ]]
    ALT=$(cat $CLONE/objects/info/alternates) || true
    if [[ $ALT ]]; then
	ALT=${ALT%/objects}
	ALT=${ALT%/.git}
	echo "-- $ME: updating $ALT ..." >&2
	[ "$RECONFIGURE" ] || 
	    git -C "$ALT" fetch --all --no-auto-maintenance || true
    fi

    if [ "$RECONFIGURE" ]; then
	configure_fetch_push "$ORIG" "$CLONE"
    else
	echo "-- $ME: updating $ORIG ..." >&2
	git -C "$ORIG" fetch --all --no-auto-maintenance || true
	push_to_backup "$ORIG" "$BACKUP_REPO"

	echo "-- $ME: repacking $CLONE ..." >&2
	GIT_TRACE2=$GIT_TRACE2_REPACK git -C "$CLONE" repack -l -f -d -n
	make_keep_files "$CLONE" "$MAXPACKSIZE"
    fi
else
    echo "=== $ME: Creating backup repo $1 ..." >&2
    [[ $# -eq 1 ]]
    eval "CLONE=$1"

    if [[ $REF ]]; then
	[[ $REF == /* ]] || REF=$PWD/$REF
	if [[ ! -d "$REF" ]]; then
	    URL=$(git -C "$ORIG" config remote."$UPSTREAM".url)
	    create_reference_repo "$REF" "$URL"
	    INFO=$(git_path $ORIG objects/info)
	    [[ -f "$INFO"/alternates ]] || {
		echo "-- $ME: configuring $REF as alternate repo in $ORIG and doing gc" >&2
		echo "$REF/objects" >"$INFO"/alternates
		git -C "$ORIG" gc --aggressive
	    }
	fi
    else
	ALT=$(git_path "$ORIG" objects/info/alternates)
	if [[ $ALT ]]; then
	    REF=$(cat "$ALT") || true
	    if [[ $REF ]]; then
		REF=${REF%/objects}
		REF=${REF%/.git}
	    fi
	fi
    fi

    [[ $CLONE == /* ]] || CLONE=$PWD/$CLONE
    check_alternates "$ORIG" "$REF"
    init_backup_repo "$ORIG" "$CLONE" "$REF"
fi
echo "=== $ME: Done." >&2
