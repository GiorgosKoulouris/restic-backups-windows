# Getting started

## What this tool does

Backs up this Windows server to its own restic repository in an S3 bucket.
All servers share one bucket; each gets the folder `<bucket>/<COMPUTERNAME>`.

- A scheduled task runs daily as SYSTEM: backs up all enabled jobs, then runs due maintenance (forget, prune, check).
- The main window (`Restic-ManageSnapshots.bat`) and the console menu (`-Mode Menu`) do everything else: back up now, restore, forget, Setup.
- Servers without a desktop get the console menu. It has every function of the window except the snapshot grid and the restore tree.
- Everything needs Administrator. The .bat asks for elevation.

Terms:

- **Snapshot**: one backup of one job at one point in time.
- **Job**: a named set of paths. Each snapshot is tagged `job:<name>`.
- **Forget**: removes snapshots from the list. Their data stays in S3.
- **Prune**: deletes data no snapshot uses. Frees S3 space.
- **Check**: verifies the repository's integrity.

## First-time setup

AWS, once for all servers:

1. Create an S3 bucket. Keep "Block all public access" on. Storage class S3 Standard (no Glacier: restic must read the repository).
2. Optional: protect it against deletion. See **Security**.

Each server:

1. Create an IAM user with access keys and attach this policy. Replace `BUCKET`, and `HOSTNAME` with the computer name (`$env:COMPUTERNAME`, same case: S3 prefixes are case-sensitive), e.g. `FILESRV01`:

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:GetBucketLocation",
      "Resource": "arn:aws:s3:::BUCKET"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::BUCKET",
      "Condition": { "StringLike": { "s3:prefix": "HOSTNAME/*" } }
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET/HOSTNAME/*"
    }
  ]
}
```

2. Download `Install-Restic.bat` and run it. Accept the default folder (`C:\Program Files\Restic`). See **Install and update**.
3. Run `Restic-ManageSnapshots.bat` in that folder. With no configuration, Settings opens.
4. General tab: AWS region of the bucket (e.g. `eu-central-1`), bucket, this server's AWS keys, restic password.
5. Jobs tab: add at least one job with its paths.
6. Click **Run Setup**.

Setup installs restic, stores the secrets, creates the repository and registers the scheduled task. See **Setup**.

Restic password: one per repository. Store it outside the server (password manager). Without it the backups can't be read.

No internet on the server: put `restic_<version>_windows_amd64.zip` (official release) in the `ResticTools` folder before Setup.

Console-only server: copy `restic-config.json` from another server, edit it in Notepad (see **Settings**), then menu `8. Setup`.

## Everyday use

Main window:

- **Health**: configuration, restic, secrets, repository. A red item disables the buttons that need it; hover a disabled button to see why.
- **Task**: scheduled task state, next and last run.
- **Maintenance**: last successful forget, prune and check.
- **Jobs**: newest snapshot per job. Red = enabled job with no snapshot in the last 48 hours.
- **Refresh** re-reads the repository from S3. Other actions refresh local state only.
- One action runs at a time. **Cancel** stops it and removes restic's lock.
- **Open last log** opens the log of the last action.

Buttons and menu entries:

| Window | Menu | Does |
|---|---|---|
| Back up now | 1 | Back up chosen jobs, also disabled. No maintenance. |
| List snapshots | 2 | Show all snapshots. |
| Restore | 3 | Restore a folder or file. See **Restore files**. |
| Forget | 4 | Remove snapshots. See **Forget and prune**. |
| Prune | 5 | Free unused space in S3. |
| Check | 6 | Verify the repository. |
| Run due maintenance | 7 | Forget, prune, check: each only if due. |
| Settings, Run Setup | 8 | Setup. |
| Enable/Disable task | 9 | Pause or resume scheduled backups. |
| Clean up | 10 | Snapshots of removed or renamed jobs. |
| Help (F1) | H | This help. |

Settings: changes to red fields (region, bucket, data directory, schedule) apply only after Setup. Saving offers to run it.

The menu has no settings editor: edit `restic-config.json` in Notepad. See **Settings**.

## Restore files

Window: **Restore**.

1. Pick a snapshot (newest first).
2. Pick a folder or file in the tree. Nothing selected = the whole snapshot.
3. Pick the target:
   - **New folder** (default): `<restore root>\<snapshot id>-<time>\<folder>`. Nothing is overwritten. Admins only, see **Restore details**.
   - **In place**: overwrites the original folder or file. Files not in the snapshot are left alone. Type `YES` to confirm. Not for the whole snapshot, drive roots or system folders. Refused if the target holds file links. See **Restore details**.
4. Click **Restore**. Progress shows in Output.

Menu: `3`, pick the snapshot number, type the folder or file path (e.g. `C:\Data\Reports`), then `1` (new folder) or `2` (in place).

Snapshots of removed jobs (grey) can be restored the same way.

## Forget and prune

Scheduled runs apply the retention policy every `forgetEveryDays` and prune every `pruneEveryDays`. Manual forgetting is only needed for exceptions.

**Forget** offers four scopes:

- **Retention policy**: what the scheduled run would forget.
- **All snapshots of a job**: type the job name to confirm.
- **Selected snapshots**: from the Snapshots tab (window) or by number (menu).
- **Everything**: type the computer name to confirm.

It always shows what goes first and warns when a job loses its newest or last snapshot. It forgets exactly the snapshots shown. Forgotten snapshots can't be restored.

Afterwards it offers to prune. Without it, the space is freed at the next scheduled prune. Prune can take long and blocks other actions on this repository.

## Logs and exit codes

Logs: `<data directory>\logs\yyyyMMdd-HHmmss-<mode>.log`, one per run. Deleted after `logRetentionDays`.

Exit codes (also the task's "Last Run Result"):

- `0` (0x0): success.
- `1` (0x1): failure. See the log.
- `3` (0x3): warnings, e.g. some files couldn't be read, or a path is missing.

# Reference

## Install and update

`Install-Restic.bat` installs and updates the tool from S3. Run it on its own; it asks for elevation.

```
<install folder>\Restic-ManageSnapshots.bat   launcher
<install folder>\ResticTools\                  everything else
```

`ResticTools` holds the script, `HELP.md`, `version.txt`, `restic-config.json` and its `.bak`, and the restic zip if you add one.

- Default folder: `C:\Program Files\Restic`. Any folder works if its parent exists.
- The task runs `ResticTools\Restic-ManageSnapshots.ps1` as SYSTEM. Non-admins may create files in the install folder. They must not own, rename, delete from or change permissions on it, `ResticTools`, or a folder above them.
- Refused: a folder above with such rights for non-admins. An existing `ResticTools` that non-admins own or can change, that is a junction, or that contains links (reparse points).
- Install folder with such rights, e.g. one made under `C:\` (inherits Authenticated Users: Modify): offered for locking. A new folder is always locked.
- Locking: owner Administrators; SYSTEM and Administrators full control; Users read and execute; nothing inherited. Contents that inherit get the same. Every install and update locks `ResticTools`, its contents and the launcher.
- Existing installation: shows installed and available versions. Choose Update, another folder, or Cancel.
- Update replaces only the shipped files. The configuration, its `.bak` and other files stay.
- All files are downloaded before anything changes. A failed download leaves the installation as it was.
- After an update, if the window or menu says to run Setup, run it.

## Settings

The configuration is `ResticTools\restic-config.json`. Settings edits it; hand-editing is supported. Settings keeps keys it doesn't know and saves the previous file as `restic-config.json.bak`.

Keys (default in brackets):

- `repository.region`: AWS region of the bucket, e.g. `eu-central-1`. Setup required.
- `repository.bucket`: bucket name. Setup required.
- `dataDirectory` [`C:\ProgramData\Restic`]: restic, secrets, state, logs. Full local path; no system folder, see **Moving the folder**. Setup required.
- `restoreRoot` [`C:\Restore`]: parent of new-folder restores. Full local path. See **Restore details**.
- `logRetentionDays` [30]: 0 = keep logs forever.
- `useVss` [true]: back up from a shadow copy, so open files are consistent.
- `schedule.taskName` [`Restic Backup`]: task name. Letters, digits, spaces, `.`, `_`, `-`, `(`, `)`. Setup required.
- `schedule.dailyAt` [`02:00`]: local time, HH:mm. Setup required.
- `schedule.maxRuntimeHours` [12]: Task Scheduler stops the run after this. Setup required.
- `retention.keepLast`, `keepHourly`, `keepDaily`, `keepWeekly`, `keepMonthly`, `keepYearly` [0 = off]. See **Retention**.
- `retention.keepWithin` [empty = off]: e.g. `30d`, `1y6m` (y, m, d, h).
- `maintenance.forgetEveryDays`, `pruneEveryDays`, `checkEveryDays` [0 = never].
- `maintenance.checkReadDataSubset` [empty]: data to download and verify per check, e.g. `2.5%`, `1/10`, `500M`. Empty = metadata only. Costs S3 egress.
- `globalExcludes`: patterns for every job, case-insensitive (`--iexclude`).
- `jobs[]`: `name` (letters, digits, `.`, `_`, `-`), `enabled` [true], `paths`, `tags` (extra tags, no spaces or commas, not starting with `job:`), `excludes` (on top of the global ones).

Secrets are never in this file. Setup stores them in `<data directory>\secrets.dat`.

Saving checks the same rules as every run. Also refused:

- Forget scheduled with no retention rule.
- A save that removes or renames jobs and also changes the region or bucket. Do it in two saves.

Removing or renaming a job: Settings asks what to do with its snapshots. See **Snapshots outside retention**.

## Setup

Run it on first install and after changing a red field, moving the folder, renaming the task, or updating the tool's restic version.

Steps, in order. A failure stops Setup there:

1. Creates the data directory and locks it: owner Administrators, SYSTEM and Administrators only, also for what's already in it. Refuses a link, or a folder holding other files (see **Moving the folder**). Installs restic into `bin`. Source: the zip in `ResticTools`, else GitHub. Both zip and exe are checked against pinned hashes.
2. Stores the secrets (only when entered; otherwise keeps the stored ones).
3. Opens the repository, or creates it if missing (option "Initialize").
4. Copies snapshots from the old repository, if switching. See **Switching repositories**.
5. Records the repository URL in `state.json`.
6. Creates or updates the scheduled task (option). Removes old tasks of this tool if you agree. See **Scheduled task**.

Setup checks the task name first: if another program's task has it, Setup stops before changing anything.

Only Setup installs restic, creates repositories and creates the task. Scheduled runs never download anything.

Re-running Setup is safe. Existing repository, task state (enabled/disabled) and secrets stay.

## Retention

One policy for all jobs, applied per job and host (`forget --tag job:<name> --group-by host`).

Rules (restic semantics), combined: a snapshot is kept if any rule keeps it.

- `keepLast N`: the newest N snapshots.
- `keepDaily N`: the newest snapshot of each of the last N days that have snapshots. Same for hourly, weekly, monthly, yearly.
- `keepWithin 30d`: every snapshot within 30 days of the newest snapshot.

Example: daily 7, weekly 4, monthly 12 keeps about 7 + 4 + 12 snapshots per job, covering one year.

- Disabled jobs still get retention.
- Snapshots without a `job:` tag, or of a job not in the configuration, are never forgotten by it.
- Job names are case-sensitive in tags.
- No rule set: the preview warns, a real forget refuses to run.

Forgetting only removes the snapshot. Prune frees the space.

## Snapshots outside retention

Snapshots whose job tag matches no configured job (removed or renamed jobs, different case), plus snapshots without a job tag.

They are shown grey, counted under Jobs ("outside retention") and can be restored. Keeping them is valid; nothing forgets them automatically.

**Clean up** (menu 10), per group:

- **Keep**: no change.
- **Forget all**.
- **Keep only the newest** (per host).
- **Assign to a job**: retags them, so that job's retention applies. restic rewrites the snapshots: their IDs change.

Settings asks the same when a save removes or renames a job. Renames are detected, so assigning to the new name is the default.

Forget them all and prune to free their space.

## Switching repositories

The repository URL is `s3:s3.<region>.amazonaws.com/<bucket>/<COMPUTERNAME>`. Changing the region, the bucket or the computer name points to a new repository.

Until Setup runs, every action except Setup fails ("The repository changed"). The scheduled backup fails too. To undo, change the configuration back.

Setup then:

- Asks whether to copy snapshots from the old repository: nothing, the newest of each job, or all.
- Reads the old repository with the old password (from `secrets.dat`, before new secrets replace it) and the new AWS keys. The new keys must be able to read the old repository. With the per-server policy they can't after a computer rename (the prefix changes): update the policy to the new prefix and add read access (`s3:GetObject`, `s3:ListBucket`) to the old prefix until Setup is done, or copy nothing.
- Creates the new repository with the old one's chunker settings, so copied data deduplicates.
- If the copy fails, Setup stops before recording the new URL or changing the task. Fix it and re-run; restic skips snapshots already copied.

The old repository is never deleted, and this tool can't browse it in place. To restore from it, see **Restore on another machine**. Delete it in S3 when no longer needed.

## Moving the folder

The install folder can be moved or renamed. Keep the launcher and `ResticTools` together. Only the scheduled task stores an absolute path.

After a move, the window shows "points to a different location" and the task runs the old path (or fails). Run Setup from the new location.

The data directory doesn't move with the folder. To move it, change `dataDirectory` and run Setup: it installs restic there and asks for the secrets. To keep them and the maintenance dates, copy `secrets.dat` and `state.json` over first (same machine only).

Setup locks the data directory and everything in it. Allowed: a new or empty folder, or one holding only `bin`, `logs`, `secrets.dat` and `state.json`.

Always refused (every run fails until fixed):

- Drive roots.
- The Windows folder and everything in it.
- `Program Files`, `Program Files (x86)` and `ProgramData` themselves.
- `C:\Users` and everything in it.
- The install folder and everything in it.

## Scheduled task

- Task Scheduler root folder, name `schedule.taskName`.
- Runs as SYSTEM with highest privileges, daily at `dailyAt` local time (stays the same across DST).
- Starts late if the machine was off. Needs a network. Stopped after `maxRuntimeHours`. A run never starts while one is running.
- Runs `-Mode Backup`: all enabled jobs, then due maintenance. Maintenance is skipped if a job failed.

Enable/Disable (button or menu 9) only changes Task Scheduler. It isn't in the configuration. Setup keeps a disabled task disabled.

Another program's task with the same name is never replaced. The window shows it red; change `taskName`, then run Setup.

Old tasks: any other task that runs this script with `-Mode Backup` (e.g. after renaming the task or moving the folder) is shown red as "also found". Setup offers to remove them after the new task is registered. A new task stays disabled if an old one it replaces was disabled.

## Restore details

New folder:

- restic restores each item's explicit permissions. Inherited ones come from the restore root.
- A missing restore root is created for SYSTEM and Administrators only. So restored files are admin-only, except explicit permissions from the snapshot.
- An existing restore root must not be a link, owned by another account or changeable by one. Otherwise the restore fails. Fix: move earlier restores out and delete it (the next restore creates it locked), or set `restoreRoot` to a new folder.
- Handing files back to users: copy them to the destination (copies take its permissions), or grant access with `icacls`.

In place:

- Refused for drive roots, the Windows folder and everything in it, and `Program Files`, `Program Files (x86)`, `ProgramData` and `C:\Users` themselves.
- The target is scanned first. Refused if it holds a file symbolic link or a file with more than one hard link: restic would write through it into the other file. The error names them. Remove them, or restore to a new folder.
- Folder links are fine: restic replaces them with real folders.
- Deduplicated and cloud placeholder files aren't links: restored normally.
- The scan opens every file: large folders take a while.

## Restore on another machine

Needed when a server is lost, or to read an old repository after switching.

Rebuilt server with the same computer name: run `Install-Restic.bat`, same configuration, run Setup with the same restic password. It reuses the existing repository.

Any other machine, with restic directly (any restic build; e.g. `restic-<version>.exe` from a data directory's `bin`). Use the lost server's IAM keys, or keys with read access to its prefix:

```
$env:AWS_ACCESS_KEY_ID     = '<key id>'
$env:AWS_SECRET_ACCESS_KEY = '<secret>'
$env:RESTIC_PASSWORD       = '<that server's restic password>'
$repo = 's3:s3.<region>.amazonaws.com/<bucket>/<COMPUTERNAME>'
restic -r $repo snapshots
restic -r $repo ls <snapshot id> /C/Data
restic -r $repo restore <snapshot id>:/C/Data --target C:\Restore\Data
```

Paths inside snapshots look like `/C/Users/...`.

## Updating restic

Each tool version uses one fixed restic version, checked by hash. Servers never pick a newer one themselves. A new restic version comes with a tool update.

1. Run `Install-Restic.bat` on each server, choose Update. See **Install and update**.
2. Run Setup on each server. It installs the new version and removes the old one.

Between steps 1 and 2, every run on that server fails with "Run Setup", scheduled backups included. Do both in one go.

## Security

- **AWS keys per server**: each server's IAM user can only read, write and delete its own prefix. A compromised server can delete its own backups, not the others'.
- **Encryption**: restic encrypts everything before upload. Without the password the data is unreadable, also for you.
- **Secrets on the server**: `secrets.dat`, encrypted with DPAPI for the machine. Anyone who can read the file can decrypt it: its permissions are the protection. Bound to the machine: a copy on another machine can't be decrypted.
- **Data directory**: SYSTEM and Administrators only; Setup locks it. Every run checks the folder, `bin`, restic and `secrets.dat`, and fails if another account owns them, can change them, or one is a link. Fix: run Setup. restic is checked against its hash before each start and can't be replaced while it runs.
- **Restores**: new-folder restores are readable by admins only, apart from explicit permissions from the snapshot. See **Restore details**.
- **Tool folder**: the task runs the script as SYSTEM. Anyone who can edit `ResticTools`, or rename it or a folder above it, can run code as SYSTEM. `Install-Restic.bat` locks it and refuses unsafe folders (see **Install and update**). After moving the folder or changing permissions by hand, keep it that way.
- **Installer downloads**: from a public S3 folder. It holds only the tool, no secrets or configuration.

Protecting the bucket against deletion (choose per your needs):

- **Versioning + lifecycle rule**: deleted or overwritten objects stay as old versions. The policy above doesn't grant `s3:DeleteObjectVersion`, so the keys can't remove old versions. Add a lifecycle rule that expires noncurrent versions after N days; otherwise pruned data keeps costing storage. Recovery means restoring old versions in S3.
- **Object Lock**: object versions can't be deleted at all until their retention period ends, even by an admin (compliance mode). Requires versioning. Prune's deletes only add delete markers; storage is freed when the lock and a lifecycle rule allow it.

## Troubleshooting

Problems show in the window's Health line and in the menu header. Details are in the log (Open last log).

- **restic not installed / doesn't match its hash**: run Setup. If there is no internet, put the release zip in `ResticTools` first.
- **No secrets stored / can't be decrypted**: run Setup and enter them. Happens after a new data directory or a machine clone.
- **Unsafe permissions**: another account owns or can change the data directory, `bin`, restic or `secrets.dat`. Run Setup to reset them. See **Security**.
- **Is a link (reparse point)**: the data directory or `logs` is a junction or symlink. Remove it (not its target), then run Setup.
- **Repository not initialized**: run Setup with "Initialize" checked.
- **Repository can't be accessed**: wrong keys or password, IAM policy prefix not exactly the computer name (case), wrong region, proxy or firewall (HTTPS to S3), wrong system clock.
- **The repository changed**: see **Switching repositories**.
- **Task not registered / points to a different location**: run Setup. See **Moving the folder**.
- **Another program's task**: a task named `taskName` exists that doesn't run this tool. Change the task name in Settings, then run Setup.
- **dataDirectory refused**: see **Moving the folder**.
- **Restore refused**: see **Restore details**.
- **Job red under Jobs**: no snapshot for 48 hours. Check the task's last result and the log.
- **Warnings (exit 3)**: some files couldn't be read or a path is missing. The snapshot was still made.
- **Repository locked**: a crashed or killed run left a lock. restic ignores stale locks after 30 minutes. Cancel in the window removes the lock right away.
- **Help file missing**: `HELP.md` must be in `ResticTools`, next to the script. Run `Install-Restic.bat` and choose Update.
- **Installer: can't download**: proxy or firewall (HTTPS to S3).
