# Restic Windows Server Backup

Encrypted, scheduled backups of Windows servers to Amazon S3, built on [restic](https://restic.net).
One bucket for all servers, one repository per server.

**A point-and-click app for restic.** One window to configure, back up, browse snapshots, restore and check health, with no command line and no restic knowledge needed. Settings is a form with validation. Restores let you pick folders and files from a tree.

## Try it

Download the installer and run it on a test server (it asks for administrator rights):

**[Install-Restic.bat](https://tcop-tools.s3.eu-central-1.amazonaws.com/ResticBackups/Windows/Install-Restic.bat)**

Or from an elevated PowerShell:

```
Invoke-WebRequest https://tcop-tools.s3.eu-central-1.amazonaws.com/ResticBackups/Windows/Install-Restic.bat -OutFile $env:USERPROFILE\Downloads\Install-Restic.bat
& $env:USERPROFILE\Downloads\Install-Restic.bat
```

Accept the default folder, then open `Restic-ManageSnapshots.bat` there. Settings opens and walks you through the rest. You need a bucket and AWS keys first, see [Quick start](#quick-start).

## Why

- **A GUI, not a script to learn.** Everything runs from a desktop window: settings, backups, snapshots, restores, retention, maintenance. A console menu with the same functions covers servers without a desktop.
- **One tool per server, nothing else to install.** A single PowerShell script. No agents, no services, no external modules.
- **Isolated servers.** Each server writes to its own repository (`<bucket>/<COMPUTERNAME>`) with its own AWS keys. A compromised server can't touch the others' backups.
- **Encrypted end to end.** restic encrypts everything before upload. Secrets are stored on the server with machine-bound DPAPI, never in the configuration file.
- **Hands-off.** A daily scheduled task backs up all jobs, then applies retention, prunes and checks the repository on the schedule you set.
- **Safe by default.** restic is pinned to one version and verified by hash before every run. Tool and data folders are locked to SYSTEM and Administrators. Restores to a new folder never overwrite anything.
- **Works without a desktop.** Server Core and remote sessions get a console menu with the same functions as the window.

## Features

| Area | What you get |
|---|---|
| Backup | Named jobs with paths, tags and excludes. Volume Shadow Copy for open files. |
| Schedule | Daily Task Scheduler task running as SYSTEM, DST-safe, with a runtime limit. |
| Retention | Last, hourly, daily, weekly, monthly, yearly and keep-within rules, applied per job. |
| Maintenance | Forget, prune and integrity check, each on its own interval. |
| Restore | Browse snapshots, restore a folder or file to a new folder or in place. |
| Monitoring | Health overview, newest snapshot per job, stale-job warnings, per-run log files. |
| Settings | Form-based editor with validation, or edit the JSON by hand. |
| Migration | Switch bucket or region and copy existing snapshots to the new repository. |

## Requirements

- Windows Server or Windows 10/11, 64-bit.
- Windows PowerShell 5.1 (built in).
- Administrator rights.
- An S3 bucket (S3 Standard storage class) and one IAM user per server.
- HTTPS access to S3. Internet access to GitHub for the first restic download, or the official restic zip copied to the server.

## Quick start

1. **Create the bucket.** One for all servers. Keep "Block all public access" on.
2. **Create an IAM user per server.** Restrict it to `BUCKET/<COMPUTERNAME>/*`. The exact policy is in the user guide.
3. **Install.** Download [`Install-Restic.bat`](https://tcop-tools.s3.eu-central-1.amazonaws.com/ResticBackups/Windows/Install-Restic.bat) and run it. The default folder is `C:\Program Files\Restic`.
4. **Configure.** Run `Restic-ManageSnapshots.bat`. Settings opens on first launch: enter the AWS region, bucket, AWS keys and restic password, then add your backup jobs.
5. **Run Setup.** It installs restic, stores the secrets, creates the repository and registers the scheduled task.

Store the restic password outside the server. Without it, the backups can't be read.

## Everyday use

Open `Restic-ManageSnapshots.bat`. Everything below is a button in the main window. The window shows the health of the configuration, the repository and the scheduled task, and the newest snapshot of each job.

| Action | Purpose |
|---|---|
| Back up now | Run selected jobs immediately. |
| List snapshots | Show every snapshot in the repository. |
| Restore | Restore a folder or file from any snapshot. |
| Forget | Remove snapshots by policy, job, selection or all. Always previewed first. |
| Prune | Free unused space in S3. |
| Check | Verify repository integrity. |
| Enable or disable task | Pause or resume scheduled backups. |

On servers without a desktop, run `Restic-ManageSnapshots.bat` and use the console menu.

## Installed layout

```
C:\Program Files\Restic\
    Restic-ManageSnapshots.bat     launcher
    ResticTools\
        Restic-ManageSnapshots.ps1 the tool
        HELP.md                    user guide
        restic-config.json         this server's configuration

C:\ProgramData\Restic\             data directory (SYSTEM and Administrators only)
    bin\                           pinned restic executable
    secrets.dat                    encrypted AWS keys and restic password
    state.json                     repository and maintenance state
    logs\                          one log file per run
```

The install folder can be moved or renamed. Run Setup again afterwards.

## Updating

Run `Install-Restic.bat` again and choose Update. Only the shipped files are replaced; your configuration stays. If the window asks for Setup afterwards, run it. A new restic version always arrives with a tool update.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failure, see the log |
| 3 | Completed with warnings, for example unreadable files |

The scheduled task reports the same value as its last run result.

## Documentation

The full user guide is [ResticTools/HELP.md](ResticTools/HELP.md), also available in the tool with F1. It covers the IAM policy, every setting, retention rules, restore details, switching repositories, bucket protection with versioning or Object Lock, and troubleshooting.

## For maintainers

The installer downloads the tool from a public-read S3 folder that you host. Keep it separate from the backup bucket.

| Path | Purpose |
|---|---|
| `dev/Publish-Bundle.ps1` | Stage a release in `dist/<version>` and upload it to the distribution folder. |
| `dev/Install-Local.bat` | Install this machine from the working copy, without S3. |
| `dev/Get-ResticPin.ps1` | Produce the version and hashes for a new restic release. |

Publish a release:

```
powershell -File dev\Publish-Bundle.ps1 -Version 1.0.0 -BaseUrl https://<bucket>.s3.<region>.amazonaws.com/restic-tool/
```

Or set the URL once and run `dev\Publish-Bundle.bat`. It reads the URL from the `RESTIC_TOOL_BASE_URL` environment variable or from `dev\publish.local.cmd` (not committed):

```
set "BASE_URL=https://<bucket>.s3.<region>.amazonaws.com/restic-tool/"
```

The `Install-Restic.bat` in this repository has no download location. Distribute the copy that the publish step writes to `dist/<version>`.

## License

MIT. See [LICENSE](LICENSE). restic is a separate project, licensed under the BSD 2-Clause License.
