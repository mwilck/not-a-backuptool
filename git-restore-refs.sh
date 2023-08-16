#! /bin/bash
# run after "git fetch BACKUP" to restore refs
# after this
set -e
: "${DEBUG:=}"
: "${DRY_RUN:=}"

print_or_do() {
    if [[ "$DRY_RUN" ]]; then
	cat
    else
	git update-ref --stdin
    fi
}

# don't want to overwrite existing branches or tags from backup
prune_existing() {
    echo === pruning existing $1 === >&2
    git for-each-ref \
	--format "delete refs/restore/$1/%(refname:strip=2)" \
	"refs/$1"
}

add_restored() {
    echo === restoring $1 === >&2
    git for-each-ref \
	--format="update refs/$1/%(refname:strip=3) refs/restore/$1/%(refname:strip=3)" \
	"refs/restore/$1"
}

for cat in heads tags notes replace; do
    prune_existing "$cat"
    add_restored "$cat"
done | print_or_do
