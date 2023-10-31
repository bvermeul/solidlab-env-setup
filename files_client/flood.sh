#!/bin/bash -e

base_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "${base_dir}"

# stderr to stdout for all of script
exec 2>&1

# Load environment variables from flood.env
#   (allexport adds "export" to all of them)
set -o allexport
source "${base_dir}/flood.env"
set +o allexport

if echo "$PATH" | grep -q '/usr/local/bin'
then
    echo '$PATH OK'
else
    echo 'Adding /usr/local/bin to $PATH'
    PATH="/usr/local/bin:$PATH"
    export PATH="/usr/local/bin:$PATH"
fi

CLIENT_PUBLIC_DNS_NAME="$(cat /etc/client_dns_name)"

if [ -z "${ATC_URLS}" ]
then
  echo "ATC_URLS must contain at least one active test config URL"
  exit 1
fi

if [ -z "$GENERATED_FILES_NEST_DEPTH" ]
then
  echo 'Missing env var GENERATED_FILES_NEST_DEPTH. Defaulting to GENERATED_FILES_NEST_DEPTH=0'
  GENERATED_FILES_NEST_DEPTH=0
  export GENERATED_FILES_NEST_DEPTH=0
fi

NESTED_POD_FILENAME="${POD_FILENAME}"
if [ "${GENERATED_FILES_NEST_DEPTH}" != '0' ]
then
  for i in $(seq 1 "${GENERATED_FILES_NEST_DEPTH}");
  do
      NESTED_POD_FILENAME="data/${NESTED_POD_FILENAME}"
  done
fi

if [ -z "$CONTENT_FILES_RDF_SIZE" ]
then
  # default 100k
  CONTENT_FILES_RDF_SIZE='100_000'
  export CONTENT_FILES_RDF_SIZE='100_000'
fi
CONTENT_FILES_RDF_SIZE=$(echo "${CONTENT_FILES_RDF_SIZE}" | tr -d '_\n')
CONTENT_FILES_RDF_SIZE_NICK=$(echo "${CONTENT_FILES_RDF_SIZE}" | sed -e 's/000$/k/' | sed -e 's/000k$/M/' | sed -e 's/000M$/G/' )


AUTH_CACHE_FILE="/tmp/auth-cache.json"
ACCOUNTS_FILE="/tmp/accounts.json"

for ATC_URL in ${ATC_URLS}
do
  # TODO support multiple servers
  #      requires merging accounts.json and auth-cache.json
  echo "Fetching active test server info from ${ATC_URL}"

  curl "${ATC_URL}/accounts.json" > "${ACCOUNTS_FILE}"
  echo "  Downloaded auth-cache.json from ${ATC_URL}/auth-cache.json: $(ls -l ${AUTH_CACHE_FILE})"

  curl "${ATC_URL}/auth-cache.json" > "${AUTH_CACHE_FILE}"
  echo "  Downloaded accounts.json from ${ATC_URL}/accounts.json: $(ls -l ${ACCOUNTS_FILE})"
done

if [ "$FLOOD_TOOL" == 'ARTILLERY' ]
then
  export ARTILLERY_DISABLE_TELEMETRY='true'
  # Vars from PerfTest:
  #ARTILLERY_SCENARIO="fixed arrivalRate" or "rampUp"
  #ARTILLERY_ARRIVAL_RATE=100  # or 1000 or ...   -> artillery will read this var from env itself.

  TEMPLATE_ARTILLERY_CONFIG='unknown'
  if [ "$AUTHENTICATED_CALLS" == 'true' ]
  then
    if [ "$ARTILLERY_SCENARIO" == 'fixed arrivalRate' ]
    then
       TEMPLATE_ARTILLERY_CONFIG='artillery-with-solid-auth-fixedRate.yaml'
    fi

    if [ "$ARTILLERY_SCENARIO" == 'rampUp' ]
    then
       TEMPLATE_ARTILLERY_CONFIG='artillery-with-solid-auth-rampUp.yaml'
    fi
  else
    if [ "$ARTILLERY_SCENARIO" == 'fixed arrivalRate' ]
    then
       TEMPLATE_ARTILLERY_CONFIG='todo'
    fi

    if [ "$ARTILLERY_SCENARIO" == 'rampUp' ]
    then
       TEMPLATE_ARTILLERY_CONFIG='todo'
    fi
  fi

  if [ ! -e "${TEMPLATE_ARTILLERY_CONFIG}" ]
  then
    echo "TEMPLATE_ARTILLERY_CONFIG not found: TEMPLATE_ARTILLERY_CONFIG=${TEMPLATE_ARTILLERY_CONFIG} (ARTILLERY_SCENARIO=$ARTILLERY_SCENARIO)"
    exit 1
  fi

{% raw %}
  ARTILLERY_CONFIG='active-artillery-config.yaml'
  # ARTILLERY has templates between double curly brackets, like jinja2, but these are very limited
  # We need to pre-process some things ourselves  (not ideal to do it here in bash... but it works for now.)
  sed -e 's#{{ $processEnvironment.ARTILLERY_ARRIVAL_RATE // 10 }}#'$(echo "${ARTILLERY_ARRIVAL_RATE}/10"|bc)'#g' \
      -e 's#{{ $processEnvironment.ARTILLERY_ARRIVAL_RATE // 5 }}#'$(echo "${ARTILLERY_ARRIVAL_RATE}/5"|bc)'#g' \
      -e 's#{{ $processEnvironment.ARTILLERY_ARRIVAL_RATE // 2 }}#'$(echo "${ARTILLERY_ARRIVAL_RATE}/2"|bc)'#g' \
      -e 's#{{ $processEnvironment.ARTILLERY_ARRIVAL_RATE }}#'"${ARTILLERY_ARRIVAL_RATE}"'#g' \
        < "${TEMPLATE_ARTILLERY_CONFIG}" > "${ARTILLERY_CONFIG}"
{% endraw %}

{% if cookiecutter.perftest_start_agent|string|lower == 'true' %}
  if [ -n "$PERFTEST_UPLOAD_ENDPOINT" ]
  then
    echo "Uploading artillery conf file to: '${PERFTEST_UPLOAD_ENDPOINT}' with auth '{${PERFTEST_UPLOAD_AUTH_TOKEN}}'"
    solidlab-perftest-upload "${PERFTEST_UPLOAD_ENDPOINT}" "$ARTILLERY_CONFIG" \
              --auth-token "${PERFTEST_UPLOAD_AUTH_TOKEN}" \
              --type OTHER --sub-type 'artillery config' --mime-type 'text/yaml' \
              --description "Artillery config $ARTILLERY_CONFIG"
  fi
{% endif %}


  OUTPUT_FILE="${base_dir}/artillery.json"
  if [ -e "$OUTPUT_FILE" ]
  then
    rm "$OUTPUT_FILE"
  fi

  CHATTER_FILE="${base_dir}/artillery-stdout.txt"
  if [ -e "$CHATTER_FILE" ]
  then
    rm "$CHATTER_FILE"
  fi

  echo "ARTILLERY_ARRIVAL_RATE=${ARTILLERY_ARRIVAL_RATE}"
  echo "POD_FILENAME=${POD_FILENAME}"
  echo "NESTED_POD_FILENAME=${NESTED_POD_FILENAME}"

  set -vx
  # artillery config specifies test of 90 seconds (10s + 20s + 60s)
  # but these can take a lot longer, as they wait for everything to finish
  # this was set to 180s, but that wasn't enough.
  # sadly, artillery doesn't write it's output file when you send SIGINT
  # --quiet
  /usr/bin/timeout -v -k '15s' --signal=INT '360s' \
         artillery run -e "$SERVER_UNDER_TEST" \
                       --output "$OUTPUT_FILE" "$ARTILLERY_CONFIG" 2>&1 | head -c 4M > "$CHATTER_FILE"
  artillery_ret_code=${PIPESTATUS[0]}
  set +vx
  echo
  echo "artillery exited with exit code ${artillery_ret_code}" >> "$CHATTER_FILE"
  echo

{% if cookiecutter.perftest_start_agent|string|lower == 'true' %}
  if [ -n "$PERFTEST_UPLOAD_ENDPOINT" ]
  then
    if [ -e "$OUTPUT_FILE" ]
    then
      echo "Output file '$OUTPUT_FILE' created:"
      ls -l "$OUTPUT_FILE" || true  # show output file

      echo "Uploading artillery output file to: '${PERFTEST_UPLOAD_ENDPOINT}' with auth '{${PERFTEST_UPLOAD_AUTH_TOKEN}}'"
      solidlab-perftest-upload "${PERFTEST_UPLOAD_ENDPOINT}" "$OUTPUT_FILE" \
                --auth-token "${PERFTEST_UPLOAD_AUTH_TOKEN}" \
                --type OTHER --sub-type 'artillery report' \
                --description "Artillery report $OUTPUT_FILE"
    else
      echo "Output file '$OUTPUT_FILE' not found after running artillery."
    fi

    echo "Uploading artillery stdout chatter file to: '${PERFTEST_UPLOAD_ENDPOINT}'"
    solidlab-perftest-upload "${PERFTEST_UPLOAD_ENDPOINT}" "$CHATTER_FILE" \
              --auth-token "${PERFTEST_UPLOAD_AUTH_TOKEN}" \
              --type OTHER --sub-type 'artillery debug' \
              --description "Artillery stdout $CHATTER_FILE"
  fi
{% endif %}
  exit "${artillery_ret_code}"
fi

if [ "$FLOOD_TOOL" == 'CSS-FLOOD' ]
then
  OUTPUT_FILE="${base_dir}/css-flood-output.txt"
  if [ -e "$OUTPUT_FILE" ]
  then
    rm "$OUTPUT_FILE"
  fi
  SOLID_FLOOD_REPORT="${base_dir}/css-flood-report.json"
  if [ -e "$SOLID_FLOOD_REPORT" ]
  then
    rm "$SOLID_FLOOD_REPORT"
  fi

  AUTH_COMMANDLINE=''
  if [ "$AUTHENTICATED_CALLS" == 'true' ]
  then
    AUTH_COMMANDLINE='--authenticate'
    echo 'Will use authenticated solidlab calls'
  else
    echo 'Will use UNauthenticated solidlab calls'
  fi

  if [ -n "$AUTHENTICATE_CACHE" ]
  then
    AUTH_COMMANDLINE="${AUTH_COMMANDLINE} --authenticateCache ${AUTHENTICATE_CACHE}"
    echo "Will use authenticateCache ${AUTHENTICATE_CACHE}"
  fi

  if [ -z "${SOLID_FLOOD_SINGLE_TIMEOUT_MS}" ]
  then
    SOLID_FLOOD_SINGLE_TIMEOUT_MS=4000
  fi

  STOP_CONDITION_COMMANDLINE="--error "
  if [ -z "${SOLID_FLOOD_STOP_CONDITION}" ] || [ "${SOLID_FLOOD_STOP_CONDITION}" = 'time' ]
  then
    # default
    STOP_CONDITION_COMMANDLINE="--duration ${SOLID_FLOOD_DURATION} "
  elif [ "${SOLID_FLOOD_STOP_CONDITION}" = 'count' ]
  then
    STOP_CONDITION_COMMANDLINE="--fetchCount ${SOLID_FLOOD_FILECOUNT} "
  else
    echo "Unsupported SOLID_FLOOD_STOP_CONDITION='${SOLID_FLOOD_STOP_CONDITION}'. Must be 'time' or 'count'."
    exit 1
  fi

  if [ -z "${SOLID_FLOOD_SCENARIO}" ]
  then
    SCENARIO_COMMANDLINE="--scenario BASIC"
  else
    SCENARIO_COMMANDLINE="--scenario ${SOLID_FLOOD_SCENARIO}"
  fi

  if [ "${SOLID_FLOOD_HTTP_VERB}" = 'PUT' ]
  then
    if [ "${SOLID_FLOOD_STOP_CONDITION}" = 'time' ]
    then
       # Always the same file to PUT
       VERB_COMMANDLINE="--verb PUT --uploadSizeByte ${SOLID_FLOOD_UPLOAD_FILESIZE} "
    else
       # PUT a different file each time
       VERB_COMMANDLINE="--verb PUT --filenameIndexing --uploadSizeByte ${SOLID_FLOOD_UPLOAD_FILESIZE} "
    fi
  fi
  if [ "${SOLID_FLOOD_HTTP_VERB}" = 'POST' ]
  then
    VERB_COMMANDLINE="--verb POST --filenameIndexing --uploadSizeByte ${SOLID_FLOOD_UPLOAD_FILESIZE} "
  fi
  if [ "${SOLID_FLOOD_HTTP_VERB}" = 'DELETE' ]
  then
    VERB_COMMANDLINE="--verb DELETE --filenameIndexing"
  fi
  if [ "${SOLID_FLOOD_HTTP_VERB}" = 'PATCH' ]
  then
    # this implies that ${SCENARIO_COMMANDLINE} contains: --scenario N3_PATCH
     if [ "${CONTENT_FILES_RDF_SIZE}" == '100000' ]
     then
        VERB_COMMANDLINE="--verb PATCH --n3PatchGenFile ${base_dir}/infobox-properties_lang\=nl__head750_100kB.nt"
     elif [ "${CONTENT_FILES_RDF_SIZE}" == '1000000' ]
     then
        VERB_COMMANDLINE="--verb PATCH --n3PatchGenFile ${base_dir}/infobox-properties_lang\=nl__head7500_1MB.nt"
     elif [ "${CONTENT_FILES_RDF_SIZE}" == '10000000' ]
     then
        VERB_COMMANDLINE="--verb PATCH --n3PatchGenFile ${base_dir}/infobox-properties_lang\=nl__head75000_10MB.nt"
     else
        echo "RDF file size ${CONTENT_FILES_RDF_SIZE} (${CONTENT_FILES_RDF_SIZE_NICK}) not supported"
        exit 1
     fi
  fi

  echo "AUTH_COMMANDLINE: $AUTH_COMMANDLINE"

  echo
  set -v
  /usr/bin/timeout -v -k '15s' --signal=INT "${SOLID_FLOOD_TIMEOUT}s" /usr/local/bin/css-flood \
                    --accounts USE_EXISTING --account-source FILE --account-source-file ${ACCOUNTS_FILE} \
                    --reportFile "${SOLID_FLOOD_REPORT}" \
                    --steps 'loadAC,validateAC,flood' \
                    ${STOP_CONDITION_COMMANDLINE} \
                    --userCount ${SOLID_FLOOD_USER_COUNT} \
                    --parallel ${SOLID_FLOOD_PARALLEL_DOWNLOADS} \
                    --processCount ${SOLID_FLOOD_WORKERS} \
                    ${SCENARIO_COMMANDLINE} \
                    ${AUTH_COMMANDLINE} \
                    ${VERB_COMMANDLINE} \
                     --fetchTimeoutMs "${SOLID_FLOOD_SINGLE_TIMEOUT_MS}" \
                    --filename "${NESTED_POD_FILENAME}" --authCacheFile ${AUTH_CACHE_FILE} \
                     2>&1 | head -c 4M | tee "$OUTPUT_FILE" | head -c 500K
  flood_ret_code=${PIPESTATUS[0]}
  set +v
  echo
  echo "css-flood exited with exit code $flood_ret_code" | tee -a "$OUTPUT_FILE"
  echo

  if [ -e "$SOLID_FLOOD_REPORT" ]
  then
    echo "css-flood report '$SOLID_FLOOD_REPORT' created:"
    ls -l "$SOLID_FLOOD_REPORT" || true  # show output file
  else
    echo "css-flood report '$SOLID_FLOOD_REPORT' not found after running css-flood"
  fi

  if [ -e "$OUTPUT_FILE" ]
  then
    echo "css-flood stdout+stderr output file '$OUTPUT_FILE' created:"
    ls -l "$OUTPUT_FILE" || true  # show output file
  else
    echo "css-flood stdout+stderr output file '$OUTPUT_FILE' not found after running css-flood"
  fi

{% if cookiecutter.perftest_start_agent|string|lower == 'true' %}
  if [ -n "$PERFTEST_UPLOAD_ENDPOINT" ]
  then
    echo "Uploading css-flood output to: '${PERFTEST_UPLOAD_ENDPOINT}' with auth '{${PERFTEST_UPLOAD_AUTH_TOKEN}}'"
    solidlab-perftest-upload "${PERFTEST_UPLOAD_ENDPOINT}" "$OUTPUT_FILE" \
              --auth-token "${PERFTEST_UPLOAD_AUTH_TOKEN}" \
              --type OTHER --sub-type 'css-flood output' \
              --description "CSS Flood test stdout+stderr"

    if [ -e "$SOLID_FLOOD_REPORT" ]
    then
      echo "Uploading css-flood report to: '${PERFTEST_UPLOAD_ENDPOINT}' with auth '{${PERFTEST_UPLOAD_AUTH_TOKEN}}'"
      solidlab-perftest-upload "${PERFTEST_UPLOAD_ENDPOINT}" "$SOLID_FLOOD_REPORT" \
                --auth-token "${PERFTEST_UPLOAD_AUTH_TOKEN}" \
                --type OTHER --sub-type 'css-flood report' \
                --mime-type 'application/json' \
                --description "CSS Flood Report"
    fi
  fi
{% endif %}
  exit $flood_ret_code
fi
