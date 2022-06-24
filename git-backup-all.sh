#! /bin/bash
MYDIR=$(dirname "$0")
. "$MYDIR"/git-backup-functions.sh

trap err ERR
set -E

: "${BASE_DIR:=/mnt/git}"
: "${BACKUP_DIR:=/net/zeus.local/mnt/git/backup}"
: "${REF_DIR:=/mnt/git/ref}"
: "${NAME:=apollon}"
: "${UPSTREAM:=origin}"
ME=$(basename "$0")
PATH=$PATH:$MYDIR

is_valid_upstream() {
    local orig=$(git -C "$1" config remote."$2".url)
    case $orig in
	/*|*.local*|*.arch.suse.de|l3mule.suse.de)
	    echo "+ $0: $1: skipping local origin $2=$orig" >&2
	    return 1
    esac
    return 0
}

for DIR in "$BASE_DIR"/*; do
    if [[ $DIR == *.git ]] || ! is_git_dir "$DIR"; then
	echo "+++ $ME: skipping $DIR" >&2
	continue
    fi
    if backup_url "$DIR" >/dev/null; then
	echo "+++ $ME: $DIR: backup already configured" >&2
	git-backup.sh "$DIR"
	continue
    fi

    INFO=$(git_path "$DIR" objects/info)
    ALT=$INFO/alternates
    REF=
    if [[ -f "$ALT" ]]; then
	mapfile -t ALTERNATES <"$ALT"
	if [[ "${#ALTERNATES[@]}" > 1 ]]; then
	    echo "+++ $ME: $DIR has multiple alternates, skipping" >&2
	    continue
	elif [[ "${#ALTERNATES[@]}" == 1 ]]; then
	    REF=${ALTERNATES[0]%/objects}
	fi
    fi

    UPS=
    if [[ ! $REF ]]; then
	mapfile -t REMOTES < <(git -C "$DIR" remote)
	for REM in ${REMOTES[@]}; do
	    case $REM in
		origin)
		    if is_valid_upstream "$DIR" "$REM"; then
			UPS=$REM
			break
		    fi
		    ;;
	    esac
	done
	if [[ ! $UPS ]]; then
	    for REM in ${REMOTES[@]}; do
		case $REM in
		    github|gitlab)
			if is_valid_upstream "$DIR" "$REM"; then
			    UPS=$REM
			    break
			fi
			;;
		esac
	    done
	fi
	if [[ ! $UPS ]]; then
	    for REM in ${REMOTES[@]}; do
		if is_valid_upstream "$DIR" "$REM"; then
		    UPS=$REM
		fi
	    done
	fi
	if [[ $UPS ]]; then
	    REF=$REF_DIR/$(basename "$DIR")
	    REF=${REF%.git}.git
	else
	    echo "+ $0: no valid upstream found in $DIR" >&2
	fi
    fi

    BAK=$BACKUP_DIR/$(basename "$DIR")
    BAK=${BAK%.git}.git
    if [[ -d "$BAK" ]]; then
	is_git_dir "$BAK" || {
	    echo "+++ $ME: ERROR: BAK=$BAK exists and is not git" >&2
	    continue
	}
	while true; do
	    OLD=$(git -C "$BAK" config remote."$NAME".url) || break
	    [[ $OLD != $DIR ]] || break
	    echo "+ $ME: $NAME exists in $BAK as $OLD" >&2
	    NAME="${NAME}X"
	done
    fi
    echo "+++ $ME: $DIR -> $BAK ${REF:+(ref $REF: $UPS)}" >&2
    echo git-backup.sh -n "$NAME" -u "$UPS" ${REF:+-r "$REF"} "$DIR" "$BAK" >&2
    git-backup.sh -n "$NAME" -u "$UPS" ${REF:+-r "$REF"} "$DIR" "$BAK" >&2
done
