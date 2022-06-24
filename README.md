# git-backup.sh

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

