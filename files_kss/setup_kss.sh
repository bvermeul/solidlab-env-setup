#!/bin/bash -e

# Configure and start KSS

##################################################################################################################

# First: handle env vars

exe_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "${exe_dir}"
# exe_dir should be /usr/local/bin/

# stderr to stdout for all of script
exec 2>&1

env_file_base="setup_kss.env"
source "${exe_dir}/setup_ss_init.sh"

KSS_SERVICE_ENV_FILE="${etc_dir}/kss_service.env"
KSS_USERS_ENV_FILE="${etc_dir}/kss_users.env"
KSS_USERS_JSON_FILE="${etc_dir}/kss_users.json"
USERS_JSON="${etc_dir}/kss_created_users.json"

NICK='latest'
#echo "Using SS commit: $GIT_CHECKOUT_ARG"
#
#NICK=$(echo "$GIT_CHECKOUT_ARG" | tr -d -c '[:alnum:]')
#SERVER_SOURCE_DIR="/usr/local/src/css-$NICK/"
##SERVER_DATA_CLEAN_DIR="/srv/css-$NICK-clean/"
#INSTALL_PREFIX="/usr/local/css-$NICK"
#CONFIG_DIR="/etc/css/$NICK"
#CONFIG_FILE="${CONFIG_DIR}/perftest.json"

HTTPS_CERT_FILE="${etc_dir}/css/server_cert.pem"
HTTPS_KEY_FILE="${etc_dir}/css/server_key.pem"

## Exe can be in 2 places, and both are fine
#if [ -e "${INSTALL_PREFIX}/bin/community-solid-server" ]
#then
#  EXE="${INSTALL_PREFIX}/bin/community-solid-server"
#else
#  EXE="${SERVER_SOURCE_DIR}/bin/community-solid-server"
#fi

#echo "    NICK=$NICK"

make_content_id  # sets CONTENT_ID see generate_content.sh

# Dir to store metadata (account info and auth cache) for this NICK+CONTENT_ID
KSS_NICKCONT_METADATA_DIR="/srv/kss-commit-$NICK-${CONTENT_ID}-meta/"

# Actual dir used by running KSS (which means it can get "dirty" during testing)
# For KSS, this dir is only used to flag errors. KSS itself does not store data here!
SERVER_DATA_DIR="/srv/kss-$NICK-${CONTENT_ID}/"

KSS_NICKCONT_AUTH_CACHE_FILE="${KSS_NICKCONT_METADATA_DIR}auth-cache.json"
KSS_NICKCONT_USER_JSON_FILE="${KSS_NICKCONT_METADATA_DIR}accounts.json"

##################################################################################################################
##################################################################################################################

function start_kss() {
  # Start currently configured KSS
  #
  # Assumptions:
  #   - /etc/systemd/system/kss.service is setup as needed
  #   - /etc/systemd/system/kss.service points to the correct server dir and config file

  systemctl daemon-reload
  _USED_SS_PORT="${USED_SS_PORT}"
#  _USED_SS_PORT=$(sed -n -e 's/^ExecStart.*--port \([0-9][0-9]*\).*/\1/p' /etc/systemd/system/kss.service)
#  echo "USED_SS_PORT in kss.service=${_USED_SS_PORT}"

  systemctl start kss

  echo "   Waiting until KSS is ready"

  #wait until KSS is ready
  _SS_READY=false
  for wait in $(seq 1 120)  # wait max 2 minutes, then just give up
  do
    if ss -Hlnp --tcp sport "${_USED_SS_PORT}" | grep -q '*:'"${_USED_SS_PORT}"
    then
       echo "      OK: Something seems to be listening on port ${_USED_SS_PORT}!"
       _SS_READY=true
#       sleep 0.1
       break
    fi
    sleep 1  #wait until SS is ready
    echo "   Waiting for SS to listen to port ${_USED_SS_PORT} ($wait)..."
  done

  if ! ${_SS_READY}
  then
    echo 'ERROR: SS did not start correctly'
    exit 1
  fi

  if [ "${IS_HTTPS_SERVER,,}" == "true" ]
  then
    # Wait until server under test has a valid cert
    #   (in most cases, that is from the start, but in the case of traefik, it might have to be fetched from letsencrypt)
    # Or SS to be ready with SSL
    _SS_CERT_READY=false
    for wait in $(seq 1 240)  # wait max 4 minutes, then just give up
    do
      if echo -n | openssl s_client -connect "${SS_PUBLIC_DNS_NAME}:${_USED_SS_PORT}" -verify_return_error > /dev/null 2>&1;
      then
        echo "      OK: Got a valid certificate from ${SS_PUBLIC_DNS_NAME}:${_USED_SS_PORT}"
        _SS_CERT_READY=true
        sleep 0.2
        break
      else
        echo "      Not (yet) OK: Failed to get valid cert on ${SS_PUBLIC_DNS_NAME}:${_USED_SS_PORT}"
      fi
      sleep 1  #wait until cert is ready
      echo "   Waiting for a valid certificate ($wait)..."
    done

    if ! ${_SS_CERT_READY}
    then
      echo 'ERROR: KSS did not start correctly'
      exit 1
    fi
  else
    sleep 5
  fi

  echo
  echo -n "   Test KSS at ${HTTP_PROTO_PREFIX}://${SS_PUBLIC_DNS_NAME}:${_USED_SS_PORT}/ ..."
  _SS_TEST_OUTPUT="$(curl -s -I "${HTTP_PROTO_PREFIX}://${SS_PUBLIC_DNS_NAME}:${_USED_SS_PORT}/" || true)"

  if ! echo "${_SS_TEST_OUTPUT}" | grep -i -q 'x-powered-by: Kvasir'
  then
    echo " FAILED"
    echo 'ERROR: KSS Test failed.'
    echo "       Ran command: curl -s -I ${HTTP_PROTO_PREFIX}://${SS_PUBLIC_DNS_NAME}:${_USED_SS_PORT}/"
    echo "       Hint: check KSS service log for more info"
    echo '       Output:'
    echo "${_SS_TEST_OUTPUT}"
    echo
    echo
    exit 1
  else
    echo " SUCCESS"
  fi

  return 0
}

##################################################################################################################
##################################################################################################################

function update_kss_service_file() {
  # Rewrite kss.service with the correct settings
  #
  # Input env vars:
  #   $GLOBAL_BASE_URL
  #   $SS_PUBLIC_DNS_NAME
  #   $env_file
  #   $EXE
  #
  # parameters:
  #   $1 = CONFIG_FILE
  #   $2 = SERVER_DATA_DIR
  #   $3 = SS_PORT_TO_USE

  echo "Updating SS systemd service to use config '$1' and root '$2'"

  BASE_URL="${GLOBAL_BASE_URL}"
  env_file="/usr/local/etc/kss_service.env"

#  cp -v "/etc/systemd/system/kss.service.template" /etc/systemd/system/
  sed -e "s/<<SS_DNS_NAME>>/${SS_PUBLIC_DNS_NAME}/g" \
      -e "s#<<SS_BASE_URL>>#${BASE_URL}#g" \
      -e "s#<<ENV_FILE>>#${env_file}#g" \
      -e "s#<<SS_EXE>>#${EXE}#g" \
      -e "s#<<SS_ROOT_PATH>>#${2}#g" \
      -e "s#<<SS_CONFIG_FILE>>#${1}#g" \
      -e "s/--port [0-9][0-9]*/--port ${3}/" \
        < "/etc/systemd/system/kss.service.template" \
        > "/etc/systemd/system/kss.service"

  systemctl daemon-reload
  return 0
}

##################################################################################################################
##################################################################################################################

function install_kss() {
  # Install a specific KSS version

  # Input env vars:
  #   $GIT_REPO_URL
  #   $GIT_CHECKOUT_ARG
  #   $SERVER_SOURCE_DIR
  #   $INSTALL_PREFIX
  #   $EXE
  #   HTTPS_CERT_FILE
  #   HTTPS_KEY_FILE
  #
  # Output env vars:
  #

  mkdir -p /usr/local/src/
  cd /usr/local/src/

  rm -rf "${SERVER_SOURCE_DIR}" "${INSTALL_PREFIX}"

  git clone "${GIT_REPO_URL}" "${SERVER_SOURCE_DIR}"
  cd "${SERVER_SOURCE_DIR}"
  git checkout "$GIT_CHECKOUT_ARG"

  # TODO BUILD if needed

  return 0
}

##################################################################################################################
##################################################################################################################

function generate_kss_users() {
  if [ "${GENERATE_USERS,,}" != "true" ]
  then
    # Nothing to do
    return 0;
  fi

  if [ -z "${CONTENT_USER_COUNT}" ]
  then
     echo 'CONTENT_USER_COUNT is required'
     exit 1
  fi

  echo '' > "${KSS_USERS_ENV_FILE}"
  echo '[' > "${KSS_USERS_JSON_FILE}"

  for i in $(seq 0 $(( CONTENT_USER_COUNT - 1 )) )
  do
    cat >>"${KSS_USERS_ENV_FILE}" <<EOF
KVASIR_DEMO_SETUP_PODS_${i}__URI=http://${SS_PUBLIC_DNS_NAME}/ldp/user${i}/
KVASIR_DEMO_SETUP_PODS_${i}__OIDC_ISSUER=http://localhost:3000/
KVASIR_DEMO_SETUP_PODS_${i}__EMAIL=user${i}@example.org
KVASIR_DEMO_SETUP_PODS_${i}__PASSWORD=password${i}

EOF

    cat >>"${KSS_USERS_JSON_FILE}" <<EOF
        {
          "index": ${i},
          "username": "user${i}",
          "password": "password${i}",
          "email": "user${i}@example.org",
          "podName": "user${i}",
          "oidcIssuer": "http://${SS_PUBLIC_DNS_NAME}:3000/",
          "webID": "https://${SS_PUBLIC_DNS_NAME}/ldp/user${i}/profile/card#me",
          "podUri": "http://${SS_PUBLIC_DNS_NAME}/ldp/user${i}/",
          "machineLoginUri": "https://${SS_PUBLIC_DNS_NAME}/ldp/.account/",
          "machineLoginMethod": "CSS_V7"
        }
EOF
    if [ $i -lt $(( CONTENT_USER_COUNT - 1 )) ]
    then
      echo ',' >> "${KSS_USERS_JSON_FILE}"
    fi

  done

  echo ']' >> "${KSS_USERS_JSON_FILE}"
}

##################################################################################################################
##################################################################################################################

function collect_access_tokens() {
  # Collect access tokens for all users, and store them in cache in well known location
  #
  # Input env vars:
  #   $SS_PUBLIC_DNS_NAME

  # Parameters:
  #   $1 = running KSS server data dir (only used to store ERROR)
  #   $2 = target auth cache file
  local _KSS_DATA_DIR="$1"
  local _AUTH_CACHE_FILE="$2"
  local _ACCOUNTS_FILE="$3"

  if [ -e "${_KSS_DATA_DIR}/ERROR" ]
  then
    echo "Cannot collect access tokens: ${_KSS_DATA_DIR}/ERROR exists before start!"
    exit 1
  fi

  echo "Collecting access tokens for all users"
  set -x
  solid-flood --accounts USE_EXISTING --account-source FILE --account-source-file "${_ACCOUNTS_FILE}" \
            --duration 1 --parallel 1 \
            --authenticate --authenticateCache all --filename dummy.txt \
            --steps 'loadAC,fillAC,validateAC,saveAC' \
            --ensure-auth-expiration 600 \
            --authCacheFile "${_AUTH_CACHE_FILE}" || touch "${_KSS_DATA_DIR}/ERROR"
  set +x

  if [ -e "${_KSS_DATA_DIR}/ERROR" ]
  then
    echo 'Failed to collect access tokens'
    exit 1
  fi

  return 0
}

##################################################################################################################
##################################################################################################################

function generate_kss_data() {
  # Users have already been generated
  GENERATE_USERS=false

  generate_ss_data "${SERVER_DATA_DIR}" "${USED_SS_PORT}" https "${USERS_JSON}" "${KSS_USERS_JSON_FILE}"
  _GEN_RET="$?"

  return ${_GEN_RET}
}

##################################################################################################################
##################################################################################################################

echo "Stopping KSS"
systemctl stop kss || echo 'ignoring stop failed'


echo '#########################################################'

echo "Starting KSS"
systemctl stop redis-server || echo 'ignoring stop failed'
generate_kss_users
start_kss

echo '#########################################################'

if [ -d "${SERVER_DATA_DIR}" ]
then
  echo "Cleaning ${SERVER_DATA_DIR}"
  rm -r "${SERVER_DATA_DIR}"
fi
mkdir "${SERVER_DATA_DIR}"

echo "Need to generate data for $NICK-${CONTENT_ID}"
generate_kss_data

if [ -e "${SERVER_DATA_DIR}/ERROR" ]
then
  echo "Failed to generate data for KSS in ${SERVER_DATA_DIR}"
  exit 1
fi

echo '#########################################################'

if [ ! -e "${KSS_NICKCONT_AUTH_CACHE_FILE}" ]
then
   echo "Need to make an auth-cache for $NICK-${CONTENT_ID} in ${KSS_NICKCONT_AUTH_CACHE_FILE}"
   collect_access_tokens "${SERVER_DATA_DIR}" "${KSS_NICKCONT_AUTH_CACHE_FILE}" "${KSS_NICKCONT_USER_JSON_FILE}"
fi

echo '#########################################################'

if [ "${GENERATE_USERS,,}" == "true" ]
then
  # Make the auth cache available
  cp -v "${KSS_NICKCONT_AUTH_CACHE_FILE}" '/usr/local/share/active_test_config/auth-cache.json'
  #Make the account info available
  cp -v "${USERS_JSON}" '/usr/local/share/active_test_config/accounts.json'
else
  echo '[]' > '/usr/local/share/active_test_config/auth-cache.json'

  if [ "${GENERATE_USERS,,}" == "true" ] && [ -e "${USERS_JSON}" ]
  then
     echo "Making '${USERS_JSON}' available as accounts file"
     cp -v "${USERS_JSON}" '/usr/local/share/active_test_config/accounts.json'
  else
     echo "Making empty accounts file available because '${USERS_JSON}' does not exist"
     echo '[]' > '/usr/local/share/active_test_config/accounts.json'
  fi
fi

echo '#########################################################'

echo '*****************************************************'
echo "* KSS is configured and running for your Experiment *"
echo "* at ${GLOBAL_BASE_URL} "
echo "* "
echo "* Downloads to get started with the test server: "
echo "*   - http://${SS_PUBLIC_DNS_NAME}:8888/accounts.json "
echo "*   - http://${SS_PUBLIC_DNS_NAME}:8888/auth-cache.json "
echo '*****************************************************'

echo "${GLOBAL_BASE_URL}" > "${share_dir}ss_url"

exit 0
