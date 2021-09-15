#!/bin/bash

readonly SCRIPT_NAME=${0##*/}
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
readonly DIR_NAME=${BASE_DIR##*/}

function print_help()
{
  cat << END
Usage: ${SCRIPT_NAME} <command> [<args>]
Common commands:
     info            print information of the contestant machines
     help            print this help
END
}

function print_error()
{
  printf '%s\n' "${SCRIPT_NAME}: $*" 1>&2
}

function execute_command_ssh()
{
  local host=$1; shift 1
  local cmd=$*

  ssh "${host}" "${cmd}"
}

function print_and_execute()
{
  local ssh_host=$1; shift 1
  local cmd=$*

  echo "$ ${cmd}"
  execute_command_ssh "${ssh_host}" "${cmd}"
}

function print_info()
{
  local ssh_hosts
  ssh_hosts=${SSH_HOSTS}
  if [[ $1 != "all" && -n $1 ]]; then
    ssh_hosts=("$1")
  fi

  for ssh_host in "${ssh_hosts[@]}"; do
    echo "[${ssh_host}]"
    echo ""
    print_and_execute "${ssh_host}" "nproc"
    echo ""
    print_and_execute "${ssh_host}" 'free -h | grep -v "Swap"'
    echo ""
    print_and_execute "${ssh_host}" 'df -lh | grep -v "/dev/loop" | grep -v "tmpfs" | grep -v "udev"'
    echo ""
    print_and_execute "${ssh_host}" "ls ~"
    echo ""
    print_and_execute "${ssh_host}" "cat /etc/os-release"
    echo ""
    print_and_execute "${ssh_host}" "sudo systemctl list-unit-files -t service -l --no-pager"
    echo ""
    print_and_execute "${ssh_host}" "sudo lsof -i"
  done
}

function rsync_directory()
{
  local ssh_hosts
  ssh_hosts=${SSH_HOSTS}
  if [[ $1 != "all" && -n $1 ]]; then
    ssh_hosts=("$1")
  fi

  for ssh_host in "${ssh_hosts[@]}"; do
    rsync -avzh -e ssh "${BASE_DIR}" "${ssh_host}:~/" &
  done
  wait
}

function setup_initial_files()
{
  for ssh_host in "${SSH_HOSTS[@]}"; do
    if [[ -d "${BASE_DIR}/${ssh_host}" ]]; then
      echo "skip creating '${ssh_host}'"
      continue
    fi

    local deploy_file="${BASE_DIR}/${ssh_host}/deploy.sh"

    mkdir -p "${BASE_DIR}/${ssh_host}"
    touch "${deploy_file}"
    chmod +x "${deploy_file}"

    cat << END > "${deploy_file}"
#!/bin/bash

# individual deploy script for ${ssh_host}
# this file will be executed on remote

END
  done
}

function link_remote_file()
{
  if [[ $# -lt 2 ]]; then
    print_error "missing required parameters: usage: ${SCRIPT_NAME} link <host> <remote file path> [local file path]"
    exit 1
  fi

  local ssh_host=$1
  local remote_path=$2
  local local_path=$3

  if [[ -z ${local_path} ]]; then
    # if path is started with '/etc/', remove it.
    # e.g. /etc/nginx/nginx.conf -> nginx/nginx.conf
    # otherwise, just pick base path
    # e.g. /home/isucon/env.sh -> env.sh
    local relative_local_path=${remote_path#/etc/}
    if [[ ${relative_local_path} == "${remote_path}" ]]; then
      relative_local_path=${remote_path##*/}
    fi

    local_path=${BASE_DIR}/${ssh_host}/${relative_local_path}
  fi

  if [[ $(scp -r "${ssh_host}:${remote_path}" "${local_path}") != 0 ]]; then
    print_error "faild to copy a file from the remote host"
    exit $?
  fi

  # FIXME: detect failure
  rsync_directory "${ssh_host}"

  # TODO: remove fetched file if failed
  execute_command_ssh "${ssh_host}" \
    "sudo rm -rf ${remote_path} && sudo ln -sf ~/${DIR_NAME}/${ssh_host}/${relative_local_path} ${remote_path}"
}

function deploy_all()
{
  # FIXME: detect failure
  rsync_directory

  ${BASE_DIR}/deploy.sh

  for ssh_host in "${SSH_HOSTS[@]}"; do
    execute_command_ssh ${ssh_host} "~/${DIR_NAME}/${ssh_host}/deploy.sh" &
  done
  wait
}

function log_collection_and_analysis()
{
  local target_base_dir
  target_base_dir=${BASE_DIR}/logs/$(date "+%Y%m%d-%H%M%S")

  for ssh_host in "${SSH_HOSTS[@]}"; do
    local target_dir=${target_base_dir}/${ssh_host}

    mkdir -p "${target_dir}"

    # copy files from remote
    # TODO: remove if the file size is too small
    scp "${ssh_host}:/var/log/nginx/access.log ${target_dir}/access.log" &
    scp "${ssh_host}:/var/log/mysql/slow-query.log ${target_dir}/slow-query.log" &
  done
  wait

  for ssh_host in "${SSH_HOST[@]}"; do
    : #TODO
  done
  wait
}

function reboot_host()
{
  local ssh_hosts
  ssh_hosts=${SSH_HOSTS}
  if [[ $1 != "all" && -n $1 ]]; then
    ssh_hosts=("$1")
  fi

  for ssh_host in "${ssh_hosts[@]}"; do
    execute_command_ssh "${ssh_host}" "sudo reboot" &
  done
  wait
}


# load environment variable from env.sh if exists
if [[ -f ${BASE_DIR}/env.sh  ]]; then
  source "${BASE_DIR}/env.sh"
fi

# check SSH_HOSTS is not empty
if [[ -z ${SSH_HOSTS} ]]; then
  printf '%s\n' "Environment variable 'SSH_HOSTS' is required" 1>&2
  printf '%s\n' "Please copy env.sample.sh to env.sh and edit it" 1>&2
  exit 1
fi

# check if subcommand is specified
if [[ $# -lt 1 ]]; then
  print_error "missing subcommand"
  print_help
  exit 1
fi
sub_command=$1; shift 1

case "${sub_command}" in
  deploy)
    deploy_all "$@"
    ;;

  help)
    print_help
    ;;

  info)
    print_info "$@"
    ;;

  link)
    link_remote_file "$@"
    ;;
  
  log)
    log_collection_and_analysis "$@"
    ;;
  
  push)
    rsync_directory "$@"
    ;;
  
  reboot)
    reboot_host "$@"
    ;;

  *)
    print_error "no such subcommand '${sub_command}'"
    print_help
    exit 1
    ;;
esac
