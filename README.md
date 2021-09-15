# ISUCON tool

## Prepare
1. Setup each remote host in `~/.ssh/config`
1. Copy `env.sample.sh` to `env.sh`
1. Edit `env.sh` corresponding to the each `Host` value of the remote hosts

## Initial setup
This command will setup directories and files for deployment, log-analysis and other operations.

```bash
$ ./isu.sh init
```

The structure of directories and the purpose of each file are as follows.

TODO: edit
```
.
├── README.md
└── isu.sh
```

## Usage

Each subcommand specify which remote host to apply the operation. If no host specified, the operation may be applied to all hosts.

### Print information of each host

Print host specific information like number of cpus and memory capacity of each remote host.

```bash
$ ./isu.sh info [all|host]
```

### Push files to remote

Sync entire project directory using rsync on the remote host under `~/`.

```bash
$ ./isu.sh push [all|host]
```

### Manage remote file

Fetch a file from remote host and make it managed by git. Also, this will replace the specified remote file to a symbolic link pointing to the copied file under this directory. Specifying a directory path also work in the same way.

If no local file path specified, then the default file path will is used. The default path is under `<host>/` or, if the remote path is under `/etc/` like `/etc/nginx/nginx.conf`, it will be `<host>/nginx/nginx.conf`.

```bash
$ ./isu.sh link <host> <remote file path> [local file path]
```

### Deployment

Sync entire project directory to remote hosts (same as `push` subcommand) and executes each deployment script.

```bash
$ ./isu.sh deploy
```

### Log collection and analysis

Collects log files from each remote host and execute analysis command like `pt-query-digest` and `alp`.

If target log file doesn't exist on the remote host, it will be ignored.

Fetched log files will be stored under `logs/<YYYYMMDD-hhmmss>/<host>/` and analysis output is also saved in it.

```bash
$ ./isu.sh log
```

### Reboot

Reboot host

```bash
$ ./isu.sh reboot [all|host]
```
