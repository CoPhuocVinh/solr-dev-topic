#!/usr/bin/env sh
# Download Solr 7.7.3 analysis-extras (ICU) JARs to mentions_conf/lib/
# Run once: ./scripts/download-icu-jars.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/mentions_conf/lib"
SOLR_URL="https://archive.apache.org/dist/lucene/solr/7.7.3/solr-7.7.3.tgz"
TMP_DIR="${TMPDIR:-/tmp}/solr-icu-download-$$"

mkdir -p "$LIB_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading Solr 7.7.3 (~50MB)..."
curl -fSL -o solr.tgz "$SOLR_URL"

echo "Extracting..."
tar xzf solr.tgz

echo "Copying ICU JARs to $LIB_DIR..."
# Solr 7.7.3: contrib/analysis-extras/lib (icu4j, morfologik, opennlp) + lucene-libs/ (lucene-analyzers-icu)
if [ -d solr-7.7.3/contrib/analysis-extras/lib ]; then
  cp solr-7.7.3/contrib/analysis-extras/lib/*.jar "$LIB_DIR/"
fi
if [ -d solr-7.7.3/contrib/analysis-extras/lucene-libs ]; then
  cp solr-7.7.3/contrib/analysis-extras/lucene-libs/lucene-analyzers-icu-7.7.3.jar "$LIB_DIR/" 2>/dev/null || true
fi
cp solr-7.7.3/dist/solr-analysis-extras-7.7.3.jar "$LIB_DIR/" 2>/dev/null || true

# ICUTokenizerFactory is in lucene-analyzers-icu (note: "analyzers" not "analysis")
if ! ls "$LIB_DIR"/lucene-analyzers-icu*.jar 1>/dev/null 2>&1; then
  found=$(find solr-7.7.3 -maxdepth 6 -name "lucene-analyzers-icu*.jar" 2>/dev/null | head -1)
  if [ -n "$found" ] && [ -f "$found" ]; then
    cp "$found" "$LIB_DIR/"
  fi
fi

if ! ls "$LIB_DIR"/lucene-analyzers-icu*.jar 1>/dev/null 2>&1; then
  echo "ERROR: lucene-analyzers-icu JAR not found."
  exit 1
fi

echo "Done. JARs in mentions_conf/lib:"
ls -la "$LIB_DIR"
