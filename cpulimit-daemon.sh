#!/usr/bin/env bash

# make sure we exit on CTRL-C
trap '
  trap - INT # restore default INT handler
  # wait for limit loops to exit
  color_echo "${Red}" "Shutting down..."
  wait
  rm -f "$LIMITED_PIDS_PATH"
  rm -f "$DB_LOCK"
  rm -f "$WORKER_PROCESSES_PATH"
  rm -f "$WORKER_LOCK"
  kill -s INT "$$"
' INT

# check for root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# check for cpulimit binary
if ! command -v cpulimit &> /dev/null
then
    echo "cpulimit binary not found"
    exit 1
fi

# exit script on error
# TODO: does not work because pgrep exists with 1 if no process was found
#set -e
# exit on undeclared variable
# set -u

## Colors for console output
# Reset
Color_Off='\033[0m'       # Text Reset

# Regular Colors
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow

f_flag=''
searchterm=''
percentage=''

# print a given text entirely in a given color
function color_echo () {
    color=$1
    text=$2
    echo -e "${color}${text}${Color_Off}"
}

function print_usage() {
  echo "Usage: cpulimit-daemon [-f] -e \"myprocess.*-some -process -arguments\" -p 100"
}

# Read command line arguments
while getopts 'fe:p:' flag; do
  case "${flag}" in
    f) f_flag="True" ;;
    e) searchterm="${OPTARG}" ;;
    p) percentage="${OPTARG}" ;;
    *) echo "Unknown Flag: ${flag}"
       print_usage
       exit 1 ;;
  esac
done

# Check arguments
if [ -z "$searchterm" ]; then
  color_echo "${Red}" "Please enter an executable search term using the \"-e\" parameter."
  print_usage
  exit 1
fi

declare -A LOCK_FDS=()                        # store FDs in an associative array
getLock() {
  local file=$(readlink -f "$1")              # declare locals; canonicalize name
  local op=$2
  case $op in
    LOCK_UN)
      [[ ${LOCK_FDS[$file]} ]] || return      # if not locked, do nothing
      eval "exec ${LOCK_FDS[$file]}>&-"       # close the FD, releasing the lock
      unset LOCK_FDS[$file]                   # ...and clear the map entry.
      ;;
    LOCK_EX)
      [[ ${LOCK_FDS[$file]} ]] && return      # if already locked, do nothing
      local new_lock_fd                       # don't leak this variable
      exec {new_lock_fd}>"$file"              # open the file...
      flock -x "$new_lock_fd"                 # ...lock the fd...
      LOCK_FDS[$file]=$new_lock_fd            # ...and store the locked FD.
      ;;
  esac
}

function run_limit_loop() {
  local pid=$1

  if ps -p "$pid" > /dev/null
  then
    color_echo "${Green}" "Limit for $pid STARTED..."
    # note: cpulimit blocks while the application is running
    cpulimit -p "$pid" -l "$percentage" -z > /dev/null
    color_echo "${Red}" "Limit for $pid STOPPED"
  fi

  ### remove pid from "database" file
  # aquire file lock
  getLock "$DB_LOCK" "LOCK_EX"
    sed -i "/$pid/d" "$LIMITED_PIDS_PATH"
  getLock "$DB_LOCK" "LOCK_UN"

  ### remove ourselfs from the "worker" list
  getLock "$WORKER_LOCK" "LOCK_EX"
    this_pid="$$"
    sed -i "/$this_pid/d" "$WORKER_PROCESSES_PATH"
  getLock "$WORKER_LOCK" "LOCK_UN"
}

function contains() {
    local n=$#
    local value=${!n}
    for ((i=1;i < $#;i++)) {
        if [ "${!i}" == "${value}" ]; then
            echo "y"
            return 0
        fi
    }
    echo "n"
    return 1
}

## Main function

# file to memorize our "worker" processes
WORKER_LOCK="/var/lock/cpulimit_worker_lock.$$"
WORKER_PROCESSES_PATH="/dev/shm/worker_pids.$$"
rm -f $WORKER_PROCESSES_PATH
touch $WORKER_PROCESSES_PATH

# put ourselfs into the worker process list to not get limited
echo -e "$$" >> "$WORKER_PROCESSES_PATH"

# setup "database" file in shared memory to keep track of running cpulimit instances
DB_LOCK="/var/lock/cpulimit_lock.$$"
LIMITED_PIDS_PATH="/dev/shm/limited_pids.$$"
rm -f $LIMITED_PIDS_PATH
touch $LIMITED_PIDS_PATH

# Let the user know that we start...
color_echo "${Yellow}" "Limiting '$searchterm' to $percentage% usage..."

count=0

while :
do
  # read list of currently limited processes
  getLock "$DB_LOCK" "LOCK_EX"
    readarray -t limited_pids < "$LIMITED_PIDS_PATH"
  
    # Find process ids to limit
    pids=
    if [ -z "$f_flag" ]; then
      pids=$(pgrep    -a "$searchterm" | grep -vf "$WORKER_PROCESSES_PATH" | grep -vE ".*bash .*cpulimit-daemon.*" | awk '{print $1}')
    else
      pids=$(pgrep -f -a "$searchterm" | grep -vf "$WORKER_PROCESSES_PATH" | grep -vE ".*bash .*cpulimit-daemon.*" | awk '{print $1}')
    fi

    new_count=$(echo "$pids" | wc -w)
    if [[ "$new_count" != "$count" ]]; then
      count=$new_count
      color_echo "${Yellow}" "$count matching process(es)"
    fi
    
    # for each pid (that is not yet limited) run a limit loop in the background
    for pid in $pids
    do
      if [ "$(contains "${limited_pids[@]}" "$pid")" == "n" ]; then
        # our "database" does not contain the pid yet
        
        # write pid to our "database" file
        echo -e "${pid}" >> "$LIMITED_PIDS_PATH"

        run_limit_loop "$pid" &

        # memorize pid of the "limiter" process
        getLock "$WORKER_LOCK" "LOCK_EX"
          echo -e "$!" >> "$WORKER_PROCESSES_PATH"
        getLock "$WORKER_LOCK" "LOCK_UN"
      fi

    done

  getLock "$DB_LOCK" "LOCK_UN"

  # sleep before checking for new processes
  sleep 0.1
done
