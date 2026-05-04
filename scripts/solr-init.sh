#!/bin/sh
set -eu

SOLR_HOST="${SOLR_HOST:-solr}"
SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_URL="http://${SOLR_HOST}:${SOLR_PORT}/solr"
CONFIGSET_DIR="${CONFIGSET_DIR:-/opt/configsets/topic_conf}"
CONFIGSET_NAME="${CONFIGSET_NAME:-topic_conf}"
COLLECTION_NAME="${COLLECTION_NAME:-topic_4777}"
NUM_SHARDS="${NUM_SHARDS:-1}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-1}"
SAMPLE_FILE="${SAMPLE_FILE:-/opt/data/sample-mentions.json}"

TMP_ZIP="/tmp/${CONFIGSET_NAME}.zip"

echo "Installing bootstrap tools..."
apk add --no-cache curl jq zip > /dev/null

request() {
  method="$1"
  url="$2"
  body_file="${3:-}"
  content_type="${4:-application/octet-stream}"
  out_file="$(mktemp)"

  if [ -n "$body_file" ]; then
    status="$(curl -sS -o "$out_file" -w "%{http_code}" -X "$method" \
      -H "Content-Type:${content_type}" \
      --data-binary "@${body_file}" \
      "$url")"
  else
    status="$(curl -sS -o "$out_file" -w "%{http_code}" -X "$method" "$url")"
  fi

  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "Request failed with HTTP ${status}: ${url}"
    cat "$out_file"
    rm -f "$out_file"
    exit 1
  fi

  cat "$out_file"
  rm -f "$out_file"
}

wait_for_solrcloud() {
  echo "Waiting for Solr at ${SOLR_URL}..."
  until curl -sf "${SOLR_URL}/admin/info/system" > /dev/null 2>&1; do
    sleep 3
  done

  echo "Waiting for SolrCloud cluster status..."
  until curl -sf "${SOLR_URL}/admin/collections?action=CLUSTERSTATUS&wt=json" > /dev/null 2>&1; do
    sleep 3
  done
}

configset_exists() {
  curl -sf "${SOLR_URL}/admin/configs?action=LIST&wt=json" \
    | jq -e --arg name "$CONFIGSET_NAME" '.configSets // [] | index($name) != null' > /dev/null
}

upload_configset() {
  if configset_exists; then
    echo "Configset '${CONFIGSET_NAME}' already exists. Skipping upload."
    return
  fi

  echo "Uploading configset '${CONFIGSET_NAME}' from ${CONFIGSET_DIR}..."
  rm -f "$TMP_ZIP"
  (cd "$CONFIGSET_DIR" && zip -qr "$TMP_ZIP" . -x "lib/*" "*.jar")

  request "POST" \
    "${SOLR_URL}/admin/configs?action=UPLOAD&name=${CONFIGSET_NAME}&wt=json" \
    "$TMP_ZIP" > /dev/null
  rm -f "$TMP_ZIP"
}

collection_exists() {
  curl -sf "${SOLR_URL}/admin/collections?action=LIST&wt=json" \
    | jq -e --arg name "$COLLECTION_NAME" '.collections // [] | index($name) != null' > /dev/null
}

create_collection() {
  if collection_exists; then
    echo "Collection '${COLLECTION_NAME}' already exists. Skipping create."
    return
  fi

  echo "Creating collection '${COLLECTION_NAME}'..."
  request "GET" \
    "${SOLR_URL}/admin/collections?action=CREATE&name=${COLLECTION_NAME}&numShards=${NUM_SHARDS}&replicationFactor=${REPLICATION_FACTOR}&collection.configName=${CONFIGSET_NAME}&wt=json" \
    > /dev/null
}

collection_doc_count() {
  curl -sf "${SOLR_URL}/${COLLECTION_NAME}/select?q=*:*&rows=0&wt=json" \
    | jq -r '.response.numFound'
}

import_sample_if_empty() {
  count="$(collection_doc_count)"
  if [ "$count" -gt 0 ]; then
    echo "Collection '${COLLECTION_NAME}' already has ${count} documents. Skipping sample import."
    return
  fi

  echo "Importing sample data from ${SAMPLE_FILE}..."
  request "POST" \
    "${SOLR_URL}/${COLLECTION_NAME}/update?commit=true&wt=json" \
    "$SAMPLE_FILE" \
    "application/json" > /dev/null
}

wait_for_solrcloud
upload_configset
create_collection
import_sample_if_empty

final_count="$(collection_doc_count)"
echo "SolrCloud init completed. Configset='${CONFIGSET_NAME}', collection='${COLLECTION_NAME}', docs=${final_count}."
