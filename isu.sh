#!/bin/bash

readonly LOG_SIZE_MIN=1000

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
  local ssh_host=$1; shift 1
  local cmd=$*

  ssh "${ssh_host}" "${cmd}"
}

function execute_command_ssh_with_prefix()
{
  execute_command_ssh "$@" 2>&1 | sed  "s/^/[${ssh_host}] /"
  return "${PIPESTATUS[0]}"
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
  ssh_hosts=("${SSH_HOSTS[@]}")
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
    print_and_execute "${ssh_host}" "cat /etc/hosts"
    echo ""
    print_and_execute "${ssh_host}" "cat /etc/os-release"
    echo ""
    print_and_execute "${ssh_host}" "sudo systemctl list-units -t service -l --no-pager"
    echo ""
    print_and_execute "${ssh_host}" "sudo lsof -i"
    echo ""
  done
}

function rsync_directory()
{
  local ssh_hosts
  ssh_hosts=("${SSH_HOSTS[@]}")
  if [[ $1 != "all" && -n $1 ]]; then
    ssh_hosts=("$1")
  fi

  for ssh_host in "${ssh_hosts[@]}"; do
    rsync -avzhc --exclude='.git' --filter="dir-merge,- .gitignore" -e ssh "${BASE_DIR}" "${ssh_host}:~/" &
  done
  wait
}

function setup_initial_files()
{
  # initialize git repository
  if [[ -f "${BASE_DIR}/.gitignore" ]]; then
    rm -rf "${BASE_DIR}/.gitignore" "${BASE_DIR}/.git"
    (cd "${BASE_DIR}" && git init)
  fi

  for ssh_host in "${SSH_HOSTS[@]}"; do
    if [[ -d "${BASE_DIR}/${ssh_host}" ]]; then
      echo "skip creating '${ssh_host}'"
      continue
    fi

    local deploy_file="${BASE_DIR}/${ssh_host}/deploy.sh"

    mkdir -p "${BASE_DIR}/${ssh_host}"
    cat << END > "${deploy_file}"
#!/bin/bash

set -ex

# individual deploy script for ${ssh_host}
# this script will be executed on remote host

# sudo cp -rf ~/${DIR_NAME}/isu1/etc/nginx/nginx.conf /etc/nginx

# sudo systemctl restart nginx
# sudo systemctl restart redis
# sudo systemctl restart mysql
# sudo systemctl restart isucondition.go

# sudo logrotate -f /etc/logrotate.d/nginx
# sudo logrotate -f /etc/logrotate.d/mysql-server

END
    chmod +x "${deploy_file}"
  done
}

function copy_remote_file()
{
  if [[ $# -lt 2 ]]; then
    print_error "missing required parameters: usage: ${SCRIPT_NAME} link <host> <remote file path>"
    exit 1
  fi

  local ssh_host=$1
  local remote_path=$2
  local link_flag=$3

  # store remote files under <host>/ (e.g. /etc/nginx/nginx.conf will be stored to <host>/etc/nginx/nginx.conf)
  local local_path_relative=${ssh_host}/${remote_path}
  local local_path=${BASE_DIR}/${local_path_relative}

  # remove suffix / and assign base path (e.g. isu1/etc/nginx/ -> isu1/etc/)
  local local_base_dir=${local_path}
  local_base_dir=${local_base_dir%/}
  local_base_dir=${local_base_dir%/*}
  local remote_base_dir=${remote_path}
  remote_base_dir=${remote_base_dir%/}
  remote_base_dir=${remote_base_dir%/*}

  mkdir -p "${local_base_dir}"

  if ! scp -r "${ssh_host}:${remote_path}" "${local_base_dir}"; then
    print_error "faild to copy a file from the remote host"
    exit $?
  fi

  # FIXME: detect failure
  rsync_directory "${ssh_host}"

  if [[ ${link_flag} == 1 ]]; then
    # TODO: remove fetched file if failed
    execute_command_ssh_with_prefix "${ssh_host}" \
      "sudo rm -rf ${remote_path} && sudo ln -sf ~/${DIR_NAME}/${local_path_relative} ${remote_path%/}"
  else
    echo ""
    echo "Copying the file from remote host has been succeeded!"
    echo "Please add the following line to the 'deploy.sh': "
    echo "sudo cp -rf ~/${DIR_NAME}/${local_path_relative} ${remote_base_dir}"
  fi
}

# FIXME: nested link may cause problems (e.g. link /etc/nginx/ after linking /etc/nginx/nginx.conf)
# TODO: verify linking directory or file directly under /
# TODO: delete symbolic link and restore files
function link_remote_file()
{
  copy_remote_file "$@" 1
}

function deploy_all()
{
  # FIXME: detect failure
  rsync_directory

  (
    cd "${BASE_DIR}" || exit 1

    if ! "${BASE_DIR}/deploy.sh"; then
      print_error "executing 'deploy.sh' exited with error"
      exit 1
    fi

    for ssh_host in "${SSH_HOSTS[@]}"; do
        execute_command_ssh_with_prefix "${ssh_host}" "~/${DIR_NAME}/${ssh_host}/deploy.sh" &
    done
    wait
  )
}

function check_remote_file_size()
{
  local ssh_host=$1
  local path=$2
  local file_size

  file_size=$(execute_command_ssh "${ssh_host}" "wc -c < '${path}'" || echo 0)
  [[ ${file_size} -gt ${LOG_SIZE_MIN} ]]
  return $?
}

function log_collection_and_analysis()
{
  local target_dir=${BASE_DIR}/logs/
  local date_prefix
  date_prefix=$(date "+%H%M%S")

  for ssh_host in "${SSH_HOSTS[@]}"; do
    mkdir -p "${target_dir}"

    local prefix="${date_prefix}-${ssh_host}"

    # copy files from remote
    # TODO: remove if the file size is too small
    (
      local remote_path="/tmp/access.log"

      # log analysis on remote
      local access_log_path="/var/log/nginx/access.log"
      execute_command_ssh_with_prefix "${ssh_host}" \
        "sudo chmod 777 ${access_log_path} && alp json -c ${RSYNC_DEST}/alp.yml --file=${access_log_path} > /tmp/${prefix}-alp.log"
      scp "${ssh_host}:/tmp/${prefix}-alp.log" "${target_dir}"
    ) &
    (
      # log analysis on remote
      local slow_log_path="/tmp/mysql-slow.log"
      execute_command_ssh_with_prefix "${ssh_host}" \
        "sudo cp /var/log/mysql/mysql-slow.log ${slow_log_path} && sudo chmod 777 ${slow_log_path} && pt-query-digest ${slow_log_path} > /tmp/${prefix}-pt-query-digest.log"
      scp "${ssh_host}:/tmp/${prefix}-pt-query-digest.log" "${target_dir}"
    ) &
  done
  wait
}

function log_collection_and_analysis_local()
{
  local target_dir=${BASE_DIR}/logs/
  local date_prefix
  date_prefix=$(date "+%H%M%S")

  for ssh_host in "${SSH_HOSTS[@]}"; do
    mkdir -p "${target_dir}"

    local prefix="${date_prefix}-${ssh_host}"

    # copy files from remote
    # TODO: remove if the file size is too small
    (
      local remote_path="/tmp/access.log"

      # log analysis on local
      execute_command_ssh_with_prefix "${ssh_host}" "sudo cp /var/log/nginx/access.log ${remote_path} && sudo chmod 777 ${remote_path}" && \
      if check_remote_file_size "${ssh_host}" "${remote_path}"; then
       scp "${ssh_host}:/tmp/access.log" "${target_dir}/${prefix}-access.log" && \
       alp json -c "${BASE_DIR}/alp.yml" --file="${target_dir}/${prefix}-access.log" > "${target_dir}/${prefix}-alp.log"
      else
       echo "skipping ${remote_path} on '${ssh_host}'"
      fi
    ) &
    (
      # log analysis on local
      local remote_path="/tmp/mysql-slow.log"
      execute_command_ssh_with_prefix "${ssh_host}" "sudo cp /var/log/mysql/mysql-slow.log ${remote_path} && sudo chmod 777 ${remote_path}" && \
      if check_remote_file_size "${ssh_host}" "${remote_path}"; then
       scp "${ssh_host}:/tmp/mysql-slow.log" "${target_dir}/${prefix}-mysql-slow.log" && \
       pt-query-digest "${target_dir}/${prefix}-mysql-slow.log" > "${target_dir}/${prefix}-pt-query-digest.log"
      else
       echo "skipping ${remote_path} on '${ssh_host}'"
      fi
    ) &
  done
  wait
}

function reboot_host()
{
  local ssh_hosts
  ssh_hosts=("${SSH_HOSTS[@]}")
  if [[ $1 != "all" && -n $1 ]]; then
    ssh_hosts=("$1")
  fi

  for ssh_host in "${ssh_hosts[@]}"; do
    execute_command_ssh_with_prefix "${ssh_host}" "sudo reboot" &
  done
  wait
}

function execute_all_ssh()
{
  for ssh_host in "${SSH_HOSTS[@]}"; do
    execute_command_ssh_with_prefix "${ssh_host}" "$@" &
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
  cp)
    copy_remote_file "$@"
    ;;

  deploy)
    deploy_all "$@"
    ;;

  exec)
    execute_all_ssh "$@"
    ;;

  help)
    print_help
    ;;

  info)
    print_info "$@"
    ;;

  init)
    setup_initial_files
    ;;

  link)
    link_remote_file "$@"
    ;;
  
  log)
    log_collection_and_analysis "$@"
    ;;
  
  llog)
    log_collection_and_analysis_local "$@"
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
