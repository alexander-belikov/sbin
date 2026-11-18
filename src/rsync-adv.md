# rsync-adv.sh

Mirrors a list of paths to an rsync target, uploads an `age`-encrypted bundle of secrets, and reads the mirror back without touching live files.

## Config

```json
{
  "local_root": "~",
  "remote_root": "user@host:backup.dir",
  "paths": [
    ".bashrc",
    {"path": ".claude", "exclude": ["projects/**/*.jsonl", "cache/"]}
  ],
  "exclude": ["node_modules/", "*.log"],
  "secrets": {
    "paths": [".ssh", ".secrets", ".gnupg"],
    "recipients": "~/.config/age/backup.pub",
    "identity": "~/.config/age/identity.age"
  }
}
```

- `paths`: files or directories under `local_root`. They land at the same relative path under `remote_root`, and parents are created.
- `exclude` (global): rsync patterns, unanchored. They apply at any depth in every path.
- `exclude` inside a path object: patterns relative to that path. They never affect other paths.
- `secrets`: optional. Each `backup` uploads `secrets/secrets.tar.zst.age`, encrypted to `recipients`. The file at `identity` is uploaded beside it as `secrets/identity.age`, so the bundle can be recovered with a passphrase alone.

## Commands

| Command | Does |
| --- | --- |
| `backup <conf>` | Mirrors `paths` with `--delete --delete-excluded`, then uploads the secrets bundle. Exit 24 (files vanished) is a warning. |
| `dry-run <conf>` | Itemizes what `backup` would change, deletions included. Writes nothing. |
| `restore <conf>` | Pulls `paths` back over `local_root`. Updates only files that are newer on the remote, and never deletes. |
| `snapshots <conf>` | Lists remote ZFS snapshots (`daily_YYYY-MM-DD`). |
| `ls <conf> [path] [--snapshot D]` | Lists a remote directory or file. |
| `fetch <conf> <path> [--snapshot D] [--to DIR]` | Copies a remote path into `~/restore/<live\|D>/` (or `DIR`), keeping its relative path. |
| `restore-secrets <conf> [--snapshot D] [--identity F] [--to DIR]` | Downloads and decrypts the bundle into `~/restore/<live\|D>/secrets/files/`. Asks for the identity passphrase unless `--identity` is given. |
| `index <conf> [--snapshot D]` | Saves a listing of every remote file as `$STATE_DIR/index-<conf>-<date>.zst`. |
| `find <conf> <regex>` | Greps the newest index offline. |
| `mount <conf> [DIR]` / `umount [DIR]` | Read-only sshfs mount of the remote account at `~/mnt/backup`. The live mirror is under `<remote dir>/`, snapshots under `.zfs/snapshot/*/<remote dir>/`. |

Options: `--limit 20M`, `--burst` (no limit; default 1M), `-c` (checksum), `--snapshot D` (a date or a full snapshot name), `--to DIR`.

Write commands take a lock and log to `$STATE_DIR` (`~/.local/state/rsync-adv/`, newest 30 kept). A successful backup writes `last-success-<conf>`.

## Secrets key, one-time setup

```bash
mkdir -p ~/.config/age && cd ~/.config/age
age-keygen -o key.txt
age-keygen -y key.txt > backup.pub        # used by backup, unattended
age -p key.txt > identity.age             # passphrase-protected copy, uploaded with the bundle
shred -u key.txt                          # the passphrase now recovers everything
```

Test recovery once: `rsync-adv.sh restore-secrets <conf>`.

## Browsing with rclone

```bash
rclone config create rsyncnet sftp host=<host> user=<user> key_file=~/.ssh/<key>
rclone ncdu rsyncnet:<remote dir>                       # interactive size explorer
rclone lsf -R --include '*.pdf' rsyncnet:<remote dir>/library
rclone copy rsyncnet:<remote dir>/work/notes ~/restore/notes --include '*.md'
rclone copy rsyncnet:.zfs/snapshot/daily_2026-11-17/<remote dir>/work/notes ~/restore/notes-1117
```

## Scheduling

`~/.config/systemd/user/rsync-adv-backup.{service,timer}` run `backup` daily at about 13:00, only on AC power and only when the host answers. A missed run catches up at next login.

```bash
systemctl --user daemon-reload && systemctl --user enable --now rsync-adv-backup.timer
journalctl --user -u rsync-adv-backup
```
