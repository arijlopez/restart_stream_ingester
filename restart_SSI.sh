#!/bin/bash
### BEGIN restart_SSI.sh INFO
#Script that restarts streaming app if
#Cron that runs this script
#0-59 * * * * /scripts/restart_SSI.sh 2>&1 >> /var/log/restart_SSI.log
### END restart_SSI.sh INFO
# Author: Ari Lopez

JQ_HOME=/mnt/ephemeral/sparkling/scripts
FILES_HOME=/var/run/sparkling
JUST_RESTARTED_SCRIPT=streamingester_just_restarted.sh

# Checks if the streaming app has been just restarted by init sparkling
# Init sparkling will run streamingester_just_restarted.sh when streaming app starts
is_restarted(){
  restarted=$(/bin/ps aux | grep -v grep | grep $JUST_RESTARTED_SCRIPT | wc -l)
  if [[ $restarted -gt '0' ]]; then
    return 0
  else
    return 1
  fi
}

# find a pid
find_pid(){
  process=$1
  local pid=$(/bin/ps -ef | grep $process | grep -v grep | awk '{print $2}' | head -n1)
  echo $pid
}

# kill just restarted script
kill_pid() {
  process=$1
  if is_restarted; then
    local pid=$(find_pid $process)
    kill -9 $pid
  fi
}

# Get the value of the unprocessed batches from graphite
# The value is the moving average of the last 5 data points
get_unprocessed_batches_value() {
  local unprocessed_batches=$(curl -s 'http://graphite.arijlopez.com/render/?target=movingAverage(averageSeries(casp.prod.sparkling.ingester.unprocessed.batches),5)&format=json')
  local last_unprocessed_value=$(/bin/echo $unprocessed_batches | $JQ_HOME/jq-linux64 . | tail -n6 | head -n1 | sed 's/,//g')
  /bin/echo "$last_unprocessed_value"
}

# Unprocessed batches value recorded to be compared
record_ub_value(){
  /bin/echo $ub_value > $FILES_HOME/un_batches.value
  /bin/echo "`date` : Unprocessed batches value: $ub_value"
}

# truncate count when required
truncate_count() {
  if [ -f $FILES_HOME/sparkling_restarter.count ]; then
    rm $FILES_HOME/sparkling_restarter.count
  fi
}

# remove flag when streaming app recovers
remove_flag_manual_intervention_email(){
  if [ -f $FILES_HOME/email_flag ]; then
    rm $FILES_HOME/email_flag
  fi
}

# count if there is error
record_count(){
  /bin/echo 1 >> $FILES_HOME/sparkling_restarter.count
}

# flag email has been sent
flag_manual_intervention_email() {
if [[ $restarted -gt '0' ]]; then
    return 0
  else
    return 1
  fi
}

# email sent to support when streaming app is restarted
email_on_restart() {
cat > /dev/tcp/127.0.0.1/25 <<EOF
HELO
MAIL FROM: restart_SSI@casp01
RCPT TO: arijlopez@gmail.com
DATA
Subject: Restarting streaming app
streaming app unprocessed batches have errored 5 times consecutively, we are going to restart the service.

Regards,

Your friendly robot
.

EOF
}

# email sent to support when streaming app can't recover from unprocessed batches after restart
# unprocessed batches will keep on increasing in this case. Manual intervention is required
email_on_unprocessed_batches_increasing() {
cat > /dev/tcp/127.0.0.1/25 <<EOF
HELO
MAIL FROM: restart_SSI@casp01
RCPT TO: arijlopez@gmail.com
DATA
Subject: Unprocessed batches continue increasing, manual intervention required.
Manual intervention is required as soon as possible to diminish the loss of data in assetstore.
streaming app unprocessed batches continue increasing after the automatic restart.
It has gone over 300 batches now. This means that manual intervention is required
since the restart script cannot fix this problem anymore.
Regards,

Your friendly robot
.

EOF
}

# Restart the service and send email.
restart_service() {
  /bin/echo "`date` restarting service"
  record_ub_value
  email_on_restart
  /sbin/service sparkling restart 2>&1 > /dev/null &
}

# count how many times seyren is in error state consecutively
# if it is 5 times, return true, else return false
run_count(){
  if [ ! -f $FILES_HOME/sparkling_restarter.count ]; then
    /bin/echo 1 >> $FILES_HOME/sparkling_restarter.count
  fi
  count=$(wc -l $FILES_HOME/sparkling_restarter.count | awk '{print $1}')
  if [[ $count -gt '4' ]]; then
    return 0
  else
    return 1
  fi
}

# Check the state
check_state() {
  ub_value=$(get_unprocessed_batches_value)
  if [[ -z "$ub_value" ]] || [[ $ub_value == *"null"* ]]; then
    echo "batches value is empty, there has been a problem to retrieving it from graphite "
    exit
  fi
  if (( $(echo $ub_value ">=" 300 | bc -l) )); then
     if [ ! -f $FILES_HOME/email_flag ]; then
        echo "email asking for manual intervention has been sent"
        email_on_unprocessed_batches_increasing
        echo "1" > $FILES_HOME/email_flag
     fi
  fi
  local check=$(cat $FILES_HOME/sparkling_restarter.check)
  # check the status of the streaming app
  if [[ $check == 'restarting' || $check == 'stopping' ]]; then
    /bin/echo "`date` service is already being restarted"
    truncate_count
  elif [[ $check == 'running' ]]; then
    if (( $(echo $ub_value "<=" 4 | bc -l) )); then
      /bin/echo "`date` : Unprocessed batches status: OK, with value: $ub_value"
      # kill just_restarted script pid when status goes back to ok
      # so that scripts starts detecting errors again
      kill_pid $JUST_RESTARTED_SCRIPT
      truncate_count
      remove_flag_manual_intervention_email
      exit 0
    else
      /bin/echo "`date` : Unprocessed batches status: ERROR, with value: $ub_value"
      if is_restarted; then
        if [ ! -f $FILES_HOME/un_batches.value ]; then
          record_ub_value
        else
          un_batches_value=$(cat $FILES_HOME/un_batches.value)
          previous_ub_value=$un_batches_value
          if (( $(echo  $previous_ub_value ">=" $ub_value | bc -l) )); then
            /bin/echo "`date` : streaming app recovering from the unprocessed batches"
          else
            /bin/echo "`date` : streaming app NOT recovering from the unprocessed batches"
          fi
          record_ub_value
        fi
      else
        if [ -f $FILES_HOME/un_batches.value ]; then
          rm -rf $FILES_HOME/un_batches_progress.count
          rm -rf $FILES_HOME/un_batches.value
        fi
        if run_count; then
          /bin/echo ""
          restart_service
          truncate_count
        fi
        record_count
      fi
    fi
  else
    /bin/echo "`date` : streaming app is stopped or in error. streaming app needs to be checked, sparkling deployment may be running or there is some maintanance"
    truncate_count
  fi
}

check_state
