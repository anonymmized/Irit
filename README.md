# FastServer

`fastserver.sh` is a standalone bash orchestrator for remote Xray servers.

What it does:

- asks for `user`, `host`, and `password`;
- connects over SSH and uses `sudo` when needed;
- installs `VLESS + REALITY + Xray` on Ubuntu/Debian;
- creates a checkpoint before changes;
- runs rollback and retries once on failure;
- for an existing Xray server, prints a report with configured users, current and cumulative traffic, active connections, network speed, SSH sessions, and `journalctl` warnings.

Run:

```bash
bash fastserver.sh
```

Useful modes:

```bash
bash fastserver.sh --mode report --user root --host 203.0.113.10
bash fastserver.sh --mode setup --user root --host 203.0.113.10
bash fastserver.sh --mode rollback --user root --host 203.0.113.10
```

Local requirements:

- `bash`
- `ssh`
- `scp`
- `sshpass`

Remote requirements:

- Ubuntu or Debian
- root or `sudo`
- internet access on the server to download Xray

Notes and limits:

- the installer path is based on the official `XTLS/Xray-install` project;
- the automatic setup currently manages one primary `VLESS + REALITY` inbound;
- precise per-user traffic stats require the script-managed config because it enables `Xray API` and `stats`;
- reporting tries to stay careful with pre-existing third-party configs, but `reconfigure` replaces the config with one managed by this script.
