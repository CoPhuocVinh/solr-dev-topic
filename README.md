# SolrCloud topic local dev

Local Docker setup for bootstrapping a SolrCloud collection named `topic_4777`
with the production-like config files in `mentions_conf/`.

## Runtime

- Solr: `9.8.1`
- Lucene: `9.11.1`
- Java: OpenJDK 17 from the Solr image
- Mode: SolrCloud
- ZooKeeper: `zookeeper:3.9`
- Configset name: `topic_conf`
- Collection name: `topic_4777`
- Shards/replicas: `numShards=1`, `replicationFactor=1`

No alias is created by this local bootstrap flow.

## Repository layout

```text
.
├── docker-compose.yml
├── data/
│   └── sample-mentions.json
├── docs/
│   └── reshard-topic-collection-tech-spec.md
├── mentions_conf/
│   ├── managed-schema.xml
│   ├── solrconfig.xml
│   ├── protwords.txt
│   ├── stopwords.txt
│   ├── synonyms.txt
│   ├── spellings.txt
│   ├── wdfftypes.txt
│   ├── mapping-FoldToASCII.txt
│   ├── mapping-ISOLatin1Accent.txt
│   ├── dataimport.properties
│   ├── scripts.conf
│   └── admin-extra*.html
└── scripts/
    └── solr-init.sh
```

`mentions_conf/` keeps its local folder name, but the init script uploads its
contents to ZooKeeper as configset `topic_conf`.

## Topic resharding tech spec

Tài liệu thiết kế cơ chế tự động reshard topic collection nằm ở:

```text
docs/reshard-topic-collection-tech-spec.md
```

Bối cảnh production đang phân tích:

- Mỗi topic là một Solr collection riêng, ví dụ `topic_100001`.
- Collection dùng `router.name=compositeId` và `uniqueKey=id`.
- Production hiện tại chưa có alias, nhiều app đang read/write trực tiếp vào
  collection name.
- Khi topic lớn vượt ngưỡng, ví dụ khoảng 40M records, hệ thống cần tạo
  collection version mới nhiều shard hơn, migrate dữ liệu, validate, rồi
  cutover.

Flow khuyến nghị:

```text
detect topic lớn
  -> tính số shard mới
  -> tạo target collection, ví dụ topic_100001_v2
  -> full copy dữ liệu
  -> delta sync bằng _version_ watermark
  -> validate
  -> cutover bằng alias/app routing
  -> final reconcile
  -> giữ old collection để rollback
```

Lưu ý quan trọng:

- Vì production chưa có alias và nhiều app không đổi read/write được, phương án
  thực tế có thể phải dùng shadow alias cùng tên collection trong lần cutover
  đầu tiên.
- Shadow alias giữ nguyên endpoint `/solr/topic_100001` cho app, nhưng làm old
  physical collection bị alias che đi. Vì vậy lần đầu nên có write pause mạnh
  khi cutover.
- Từ lần reshard thứ 2 trở đi, alias đã tồn tại sẵn nên flow sạch hơn: update
  alias từ `topic_100001_v2` sang `topic_100001_v3`. Có thể không pause nếu có
  post-cutover reconcile và conflict policy dựa trên timestamp/application
  version đáng tin.
- `_version_` dùng được cho delta insert/update, nhưng không bắt được hard
  delete. Nếu production có hard delete, cần soft delete, tombstone, hoặc
  change log riêng.
- Update chain hiện tại có `skipInsertIfExists=true`; migration/reconcile cần
  một update path cho phép upsert nếu muốn ghi đè bản mới hơn.

Research keywords:

```text
Solr shadow alias
Solr alias same name as collection
Solr collection alias hides collection
Solr CREATEALIAS DELETEALIAS
Solr followAliases true
SolrCloud reindex collection with more shards
SolrCloud splitshard vs reindex
Solr cursorMark pagination
Solr _version_ watermark delta sync
Solr hard delete tombstone soft delete
Solr update request processor chain upsert
```

## Bootstrap flow

`docker compose up` starts:

1. `zookeeper` with persistent volumes for `/data` and `/datalog`.
2. `solr` in SolrCloud mode using `ZK_HOST=zookeeper:2181`.
3. `solr-init`, which:
   - waits for SolrCloud to be reachable
   - uploads `mentions_conf/` as configset `topic_conf` if missing
   - creates collection `topic_4777` if missing
   - imports `data/sample-mentions.json` only when the collection is empty

The configset ZIP is built from inside `mentions_conf/`, so `solrconfig.xml` and
`managed-schema.xml` are top-level entries in the uploaded ZIP. The ZIP excludes
`lib/*` and `*.jar`.

## Run

Start from a clean local cluster:

```sh
docker compose down -v
docker compose up --build
```

Start again while preserving ZooKeeper and Solr volumes:

```sh
docker compose down
docker compose up
```

Run only the idempotent init step against running services:

```sh
docker compose run --rm solr-init
```

Open Solr Admin:

```text
http://localhost:8983/solr
```

## Verify

Check SolrCloud:

```sh
curl -s "http://localhost:8983/solr/admin/collections?action=CLUSTERSTATUS&wt=json" | jq .
```

Check configset:

```sh
curl -s "http://localhost:8983/solr/admin/configs?action=LIST&wt=json" | jq .
```

Check collection:

```sh
curl -s "http://localhost:8983/solr/admin/collections?action=LIST&wt=json" | jq .
```

Check imported sample count:

```sh
curl -s "http://localhost:8983/solr/topic_4777/select?q=*:*&rows=0&wt=json" | jq '.response.numFound'
```

Expected result after a clean bootstrap: `10`.

Smoke test search:

```sh
curl -s "http://localhost:8983/solr/topic_4777/select?q=milo&rows=10&wt=json" | jq '.response.numFound'
```

## Static validation

```sh
python -m json.tool data/sample-mentions.json >/dev/null
```

```sh
python - <<'PY'
import xml.etree.ElementTree as ET
for path in ["mentions_conf/managed-schema.xml", "mentions_conf/solrconfig.xml"]:
    ET.parse(path)
    print(path, "OK")
PY
```

```sh
sh -n scripts/solr-init.sh
```

## Notes

- `dataimport.properties` is included for production parity only. Solr 9 does
  not run DataImportHandler by default; local sample import uses the JSON Update
  API.
- ICU / analysis-extras jars from the old Solr 7 setup are not needed by the
  current schema and are intentionally excluded from configset upload.
- If a collection already contains documents, `solr-init` skips sample import so
  repeated runs do not duplicate data.
