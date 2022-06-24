# git-backup.sh: Backup of git work directories

The best way to backup git repos is — git! Sure. But sometimes it's helpful
to have work done in git in a regular backup. Just to be sure to have
everything important in one place, for example.

Git repos don't lend themselves well to ordinary backup tools:

 * More often than not, 99% of the content of the repo is publicly available
   on github or elsewhere.
 * Git repacks its data base often, in ways that are intransparent to backup tools.
   
My intention is to back up just my local commits and the associated objects, my
local work that I may or may not push to public repositories later, in a
format that's well suited for backup tools.

The approach I've come with involves (at least) 3 local repositories for any
given code base.

 * a "mirror" repository. This is usually a base repository, configured to
   mirror one or more public repositories. The public repositories should be
   of the sort that doesn't rebase, because we use this repository as
   reference repository (alternates) for local work repos. See
   **git-clone(1)** for a discussion of reference repositories.
 * one ore more local work repositories. These use the same remotes as the
   mirror repository (or a subset) and have the path to the mirror configured
   in `.git/objects/info/alternates`.
 * a backup repository. This will be created by **git-backup.sh** if it
   doesn't exist yet. The default remote name is `BACKUP`. It uses the
   mirror repository as alternate, like the work repository. Thus only objects
   that aren't available in the mirror repository's remotes will be stored
   here. By calling **git repack**, we make sure that non-local objects won't
   be stored. Work won't be done in the mirror repo, it's a bare repository.
   It uses the non-standard refspec `refs/backup/$NAME/*` for refs from
   working repo `$NAME`. By using `.keep` files on generated pack files, it
   prevents **git repack** from recreating large pack files. This wouldn't be
   useful for working repos for performance reasons, but it's backup-friendly.

## Usage

    Usage: git-backup.sh [options] work_repo [backup]
    Options:
    -h/--help 					print this help
    -m/--max-pack-size SIZE		set max pack size
    -n/--name NAME				set origin name in backup repo
    -r/--reference PATH			set reference repository
    -u/--upstream REMOTE		upstream remote for reference repo, default 'origin'

### First-time use

If the command is used on a work repo for the first time, the path to the
backup repo to be created must be given. The `-n` option determines the name
of the repository to be backed up in the remote list of the backup
repository. With `-r`, a reference repository can be defined. This isn't
mandatory and can be omitted for local-only repos. If the reference repository
doesn't exist yet, it will be created at the given path as a mirror of the
remote given with `-u`. **Note:** If a reference repository is to be creates
from several upstream repos, it needs to be set up manually beforehand. It
should be a bare repository that just mirrors remotes, see above.

The reference repo (if it exists) will be updated. If the reference repo was
just created, `git gc --aggressive` will be run on the working repository to
remove any objects that are already present in the reference repo. *This must
be done manually if a reference repository has been set up manually*. Finally
the backup repository is created at the given path, and `git push` is used to
copy all local objects to the backup repo.

### Later use

On later invocations, the backup repository is determined from the configured
remote `BACKUP` an should be omitted from the command line. The invocation is
now usually just

    git-backup.sh work_repo

## Backup recovery

Assuming the `linux.git` is a mirror of the Linux kernel repository
which will be used as the reference repository, and `/backup_dir/linux-backup.git`
is a backup repo from which we want to restore the backup named `myrepo`.

First, update the reference repo, create a fresh clone, and add the backup
repo as a remote:

    git -C linux.git fetch --all
    git clone --reference linux.git \
		git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git linux
	cd linux
	git remote add BACKUP /backup_dir/linux-backup.git
	
*Don't fetch yet!* Edit `.git/config` as follows:

    [remote "BACKUP"]
	    url = /backup_dir/linux-backup.git
	    fetch = refs/backup/myrepo/*:refs/*
		fetch = refs/backup/myrepo/tags/*:refs/tag_backup/*
		push = +refs/*:refs/backup/myrepo/*
		
Switch to a dummy branch to avoid errors from `git fetch`, and fetch:

    git switch -c __dummy
	git fetch --force
	rm -rf .git/refs/tags
	mv .git/refs/tag_backup .git/refs/tags
	
The `tag_backup` trick is necessary because I couldn't figure out how to make
git really pull every tag from the backup to `refs/tags` directly.

**Note:** this will not update the reflog. The reflogs (for HEAD only) are
stored in the backup repo under `logs`,
e.g. `/backup_dir/linux-backup.dir/logs/HEAD` and must be manually copied back
if desired.

