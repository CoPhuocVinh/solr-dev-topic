# SolrCloud topic configset

This directory is kept as the local production-like config source for the
`topic_4777` collection.

## Runtime

- Solr: 9.8.1
- Lucene: 9.11.1
- Java: OpenJDK 17
- Mode: SolrCloud

## Bootstrap behavior

The local folder remains named `mentions_conf/`, but `scripts/solr-init.sh`
uploads its contents to ZooKeeper as the `topic_conf` configset.

The init flow is:

1. Wait for SolrCloud to be reachable.
2. Upload `topic_conf` if it does not already exist.
3. Create `topic_4777` with `numShards=1` and `replicationFactor=1` if it does
   not already exist.
4. Import `data/sample-mentions.json` only when `topic_4777` is empty.

No alias is created by the local bootstrap flow.

## Configset files

The configset includes production parity files such as `admin-extra*.html`,
`scripts.conf`, `mapping-FoldToASCII.txt`, `mapping-ISOLatin1Accent.txt`,
`synonyms.txt`, `spellings.txt`, `stopwords.txt`, and `wdfftypes.txt`.

`dataimport.properties` is included for production parity only. Solr 9 does not
run DataImportHandler by default, and the local sample import uses Solr's JSON
Update API instead.

The old ICU and hyphen analyzer experiment is no longer part of this runtime.
