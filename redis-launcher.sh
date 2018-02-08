#!/bin/bash
# Copyright 2017 Ismail KABOUBI
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script determines whether the pod that executes it will be a Redis Sentinel, Master, or Slave
# The redis-ha Helm chart signals Sentinel status with environment variables. If they are not set, the newly
# launched pod will scan K8S to see if there is an active master. If not, it uses a deterministic means of
# sensing whether it should launch as master then writes master or slave to the label called redis-role
# appropriately. It's this label that determines which LB a pod can be seen through.
#
# The redis-role=master pod is the key for the cluster to get started. Sentinels will wait for it to appear
# in the LB before they finish launching. All other pods wait for the Sentinels to ID the master.
#
# Pods also set the labels podIP and runID. RunID is the first few characters of the unique run_id value
# generated by each Redis sever.
#
# During normal operation, there should be only one redis-role=master pod. If it fails, the Sentinels
# will nominate a new master and change all the redis-role values appropriately.

echo "Starting redis launcher"
echo "Setting labels"
label-updater.sh & plabeler=$!

echo "Selecting proper service to execute"
# Define config file locations
SENTINEL_CONF=/etc/redis/sentinel.conf
MASTER_CONF=/etc/redis/master.conf
SLAVE_CONF=/etc/redis/slave.conf

# Adapt to dynamically named env vars
ENV_VAR_PREFIX=`echo $REDIS_CHART_PREFIX|awk '{print toupper($0)}'|sed 's/-/_/g'`
PORTVAR="${ENV_VAR_PREFIX}MASTER_SVC_SERVICE_PORT"
HOSTVAR="${ENV_VAR_PREFIX}MASTER_SVC_SERVICE_HOST"
MASTER_LB_PORT="${!PORTVAR}"
MASTER_LB_HOST="${!HOSTVAR}"
QUORUM=${QUORUM:-2}
MASTER_NAME=${SENTINEL_MASTER_NAME:-mymaster}
AUTH_PASS=${SENTINEL_AUTH_PASS}

# Launch master when `MASTER` environment variable is set
function launchmaster() {
  # If we know we're a master, update the labels right away
  kubectl label --overwrite pod $HOSTNAME redis-role="master"
  echo "Using config file $MASTER_CONF"
  if [[ ! -e /redis-master-data ]]; then
    echo "Redis master data doesn't exist, data won't be persistent!"
    mkdir /redis-master-data
  fi
  MASTER_IP=$(hostname -i)
  SENTINEL_IPS=$(kubectl get pod -o jsonpath='{range .items[*]}{.metadata.name} {..podIP} {.status.containerStatuses[0].state}{"\n"}{end}' -l redis-role=sentinel|grep running|awk '{print $2}')
  echo "$SENTINEL_IPS" | xargs -n1 -I% sh -c "redis-cli -h % -p 26379 SENTINEL REMOVE ${MASTER_NAME} && redis-cli -h % -p 26379 sentinel monitor ${MASTER_NAME} ${MASTER_IP} ${MASTER_LB_PORT} ${QUORUM}"
  redis-server $MASTER_CONF --protected-mode no $@
}

# Launch sentinel when `SENTINEL` environment variable is set
function launchsentinel() {
  echo "Using config file $SENTINEL_CONF"

  while true; do
    # The sentinels must wait for a load-balanced master to appear then ask it for its actual IP.
    MASTER_IP=$(kubectl get pod -o jsonpath='{range .items[*]}{.metadata.name} {..podIP} {.status.containerStatuses[0].state}{"\n"}{end}' -l redis-role=master|grep running|grep $REDIS_CHART_PREFIX|awk '{print $2}'|xargs)
    echo "Current master is $MASTER_IP"

    if [[ -z ${MASTER_IP} ]]; then
      continue
    fi

    timeout -t 3 redis-cli -h ${MASTER_IP} -p ${MASTER_LB_PORT} INFO
    if [[ "$?" == "0" ]]; then
      break
    fi
    echo "Connecting to master failed.  Waiting..."
    sleep 10
  done

  echo "sentinel monitor ${MASTER_NAME} ${MASTER_LB_HOST} ${MASTER_LB_PORT} ${QUORUM}" > ${SENTINEL_CONF}
  echo "sentinel down-after-milliseconds ${MASTER_NAME} 10000" >> ${SENTINEL_CONF}
  echo "sentinel failover-timeout ${MASTER_NAME} 5000" >> ${SENTINEL_CONF}
  echo "sentinel parallel-syncs ${MASTER_NAME} 10" >> ${SENTINEL_CONF}
  echo "bind 0.0.0.0" >> ${SENTINEL_CONF}
  echo "sentinel client-reconfig-script ${MASTER_NAME} /usr/local/bin/promote.sh" >> ${SENTINEL_CONF}
  if [ -z "$AUTH_PASS" ]; then
    echo "sentinel auth-pass ${MASTER_NAME} ${AUTH_PASS}" >> ${SENTINEL_CONF}
  fi

  kubectl label --overwrite pod $HOSTNAME redis-role="sentinel"

  redis-sentinel ${SENTINEL_CONF} --protected-mode no $@
}

# Launch slave when `SLAVE` environment variable is set
function launchslave() {
  kubectl label --overwrite pod $HOSTNAME redis-role="slave"
  echo "Using config file $SLAVE_CONF"
  if [[ ! -e /redis-master-data ]]; then
    echo "Redis master data doesn't exist, data won't be persistent!"
    mkdir /redis-master-data
  fi

  i=0
  while true; do
    master=${MASTER_LB_HOST}
    timeout -t 3 redis-cli -h ${master} -p ${MASTER_LB_PORT} INFO
    if [[ "$?" == "0" ]]; then
      break
    fi
    i=$((i+1))
    if [[ "$i" -gt "30" ]]; then
      echo "Exiting after too many attempts"
      kill $plabeler
      exit 1
    fi
    echo "Connecting to master failed.  Waiting..."
    sleep 1
  done
  sed -i "s/%master-ip%/${MASTER_LB_HOST}/" $SLAVE_CONF
  sed -i "s/%master-port%/${MASTER_LB_PORT}/" $SLAVE_CONF
  redis-server $SLAVE_CONF --protected-mode no $@
}

# Check if MASTER environment variable is set
if [[ "${MASTER}" == "true" ]]; then
  echo "Launching Redis in Master mode"
  launchmaster $@
  exit 0
fi

# Check if SENTINEL environment variable is set
if [[ "${SENTINEL}" == "true" ]]; then
  echo "Launching Redis Sentinel"
  launchsentinel $@
  echo "Launcsentinel action completed"
  exit 0
fi

# Determine whether this should be a master or slave instance
echo "Looking for pods running as master"
MASTERS=`kubectl get pod -o jsonpath='{range .items[*]}{.metadata.name} {..podIP} {.status.containerStatuses[0].state}{"\n"}{end}' -l redis-role=master|grep running|grep $REDIS_CHART_PREFIX`
SLAVE1_IP=`kubectl get pod -o jsonpath='{range .items[*]}{.metadata.name} {..podIP} {.status.containerStatuses[0].state} {"\n"} {end}' -l redis-role=slave |grep running|grep $REDIS_CHART_PREFIX|grep -v $HOSTNAME|sort|awk '{print $2}'|head -n1`
SLAVE1_NAME=`kubectl get pod -o jsonpath='{range .items[*]}{.metadata.name} {..podIP} {.status.containerStatuses[0].state} {"\n"} {end}' -l redis-role=slave |grep running|grep $REDIS_CHART_PREFIX|grep -v $HOSTNAME|sort|awk '{print $1}'|head -n1`
if [[ "$MASTERS" == "" ]] && [[ "$SLAVE1_IP" == "" ]]; then
  echo "No masters or slaves found: \"$MASTERS\" Taking master role..."
  launchmaster $@
  exit 0
else
  if [[ "$MASTERS" != "" ]]; then
    echo "Found master $MASTERS"
    echo "Launching Redis in Slave mode"
  else
    SENTINEL_IPS=$(kubectl get pod -o jsonpath='{range .items[*]}{.metadata.name} {..podIP} {.status.containerStatuses[0].state}{"\n"}{end}' -l redis-role=sentinel|grep running|awk '{print $2}')
    SENTINEL_LIST=( $SENTINEL_IPS )
    if [[ "${#SENTINEL_LIST[@]}" -lt $((QUORUM+1)) ]]; then
      echo "No master found, not enough sentinels, slaves available"
      echo "promote slave to master"
      redis-cli -h $SLAVE1_IP -p 6379 SLAVEOF NO ONE
      kubectl label --overwrite pod $SLAVE1_NAME redis-role="master"
      echo "$SENTINEL_IPS" | xargs -n1 -I% sh -c "redis-cli -h % -p 26379 SENTINEL REMOVE ${MASTER_NAME} && redis-cli -h % -p 26379 sentinel monitor ${MASTER_NAME} ${SLAVE1_IP} ${MASTER_LB_PORT} ${QUORUM}"
    fi
  fi
  launchslave $@
  exit 0
fi

echo "Launching Redis in Slave mode"
launchslave $@
echo "Launchslave action completed"
