err() {
    trap - ERR
    echo "error in $BASH_COMMAND" >&2
    exit 1
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

is_git_dir() {
    [[ -d "$1/.git" || ( -d "$1/objects/info" && -d "$1/refs" ) ]]
}

backup_url() {
    git -C "$1" config remote.BACKUP.url
}

git_path() {
    local dir=$1 file=$2 d
    [[ -d "$dir" ]] || return 0
    for d in "$dir/.git" "$dir"; do
	[[ -e "$d/$file" ]] || continue
	echo "$d/$file"
    done
}

make_keep_files() {
    local clone=$1 maxkeep=$2 sz

    for x in "$clone"/objects/pack/*.pack; do
	[[ "$x" != "$clone/objects/pack/*.pack" ]] || continue
	sz=$(stat -c %s "$x")
	if [[ $sz -ge $((9 * maxkeep / 10)) ]]; then
	    touch "${x%.pack}.keep"
	else
	    rm -fv "${x%.pack}.keep"
	fi
    done
}

check_alternates() {
    local orig=$1 ref=$2 alt l bad= lines
    alt=$(git_path "$1" objects/info/alternates)
    if [[ $alt ]]; then
	mapfile -t lines <"$alt"
	for l in "${lines[@]}"; do
	    [[ $l ]] || continue
	    l=${l%/objects}
	    l=${l%/.git}
	    case $l in
		$ref) continue;;
		*) bad=yes
		   break;;
	    esac
	done
	if [[ $bad ]]; then
	    echo "$0: $orig uses alternates: $l. Exiting!" >&2
	    exit 1
	fi
    fi
}

create_remotes() {
    local dir=$1 info ALTERNATES alt REMOTES rem MYURLS

    info=$(git_path "$dir" objects/info)
    [[ $info && -d "$info" ]]
    [[ -f "$info/alternates" ]] || return 0

    mapfile -t MYURLS < \
	    <(git -C "$dir" remote | \
		  while read x; do git -C "$dir" config remote."$x".url; done)

    echo "$0: $dir: repo urls=(${MYURLS[@]})" >&2
    mapfile -t ALTERNATES <"$info/alternates"
    for alt in "${ALTERNATES[@]}"; do
	alt=${alt%/objects}
	alt=${alt%/.git}
	[[ -d "$alt" ]] && is_git_dir "$alt" || {
		echo "$0: ERROR: $dir: alternate $alt does not exist" >&2
		continue
	    }
	#echo "alt=$alt" >&2
	mapfile -t REMOTES < <(git -C "$alt" remote)
	for rem in "${REMOTES[@]}"; do
	    local url found x
	    url=$(git -C "$alt" config remote."$rem".url)
	    #echo "rem=$rem url=$url" >&2
	    found=
	    for x in "${MYURLS[@]}"; do
		if [[ "$x" == "$url" ]]; then
		    found=yes
		    break
		fi
	    done
	    if [[ "$found" != yes ]]; then
		git -C "$dir" remote add "alt-$rem" "$url" >&2
		git -C "$dir" config remote."alt-$rem".skipFetchAll true
	    fi
	done
    done
}

