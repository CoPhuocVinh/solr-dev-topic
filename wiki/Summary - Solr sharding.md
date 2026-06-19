# SolrCloud Topic Collection Resharding Research & Implementation Plan

## 1. Mục tiêu

Xây dựng cơ chế tự động reshard cho các topic collection trong SolrCloud 9 khi dữ liệu của một topic tăng vượt ngưỡng, ví dụ topic đạt khoảng 40 triệu records và `numShards=1` không còn phù hợp.

Mục tiêu chính:

- Tự động detect topic lớn cần tăng shard.
- Tạo collection version mới với số shard phù hợp hơn.
- Migrate dữ liệu bằng cursor copy, upsert buffer và cursor progress lưu trong DB.
- Resume an toàn khi worker requeue hoặc retry message.
- Giữ endpoint cũ `/solr/topic_xxx` cho các app hiện tại.
- Cutover bằng alias create/switch.
- Giữ old collection để rollback.

Bối cảnh quan trọng của production:

- Có nhiều app/service đang gọi trực tiếp `/solr/topic_xxx`.
- Không thể giả định sẽ đổi app sang alias name mới.
- Vì vậy lần cutover đầu tiên cần dùng **shadow alias** để giữ nguyên endpoint cũ.

Flow tổng quát:

```text
detect topic lớn
-> tính số shard mới
-> tạo target collection version mới
-> copy theo cursor + upsert buffer
-> save cursor sau upsert
-> requeue/resume khi cần
-> alias create/switch
-> mark DONE
-> giữ old collection để rollback
```

## 2. Hiện trạng

### 2.1 Production

- Mỗi topic đang là một physical Solr collection riêng.
- Ví dụ: `topic_100001`.
- Collection dùng `router.name=compositeId`.
- Collection dùng `uniqueKey=id`.
- Ban đầu collection có thể chỉ có `numShards=1`.
- Production hiện chưa có alias theo logical topic name.
- Nhiều app/service read/write trực tiếp vào `/solr/topic_100001`.
- Khi topic tăng dữ liệu lớn, một shard dễ trở thành bottleneck cho query/indexing.

### 2.2 Repo local

Repo local hiện là SolrCloud sandbox, chưa phải production job service.

Đang có:

- SolrCloud local với Solr `9.8.1`.
- ZooKeeper.
- Configset `topic_conf`.
- Sample collection `topic_4777`.
- Script bootstrap `scripts/solr-init.sh`.
- Schema trong `mentions_conf/managed-schema.xml`.
- Solr config trong `mentions_conf/solrconfig.xml`.

Chưa có:

- Nightly job.
- DB history.
- Migration worker.
- Cutover automation.
- Validate/reconcile/rollback automation.

## 3. Topic Collection Schema

Schema topic collection hiện nằm trong configset `topic_conf`.

Thông tin chính:

```text
schema name: topics
schema version: 1.6
uniqueKey: id
required fields chính: id, domain
```

Các field quan trọng cho reshard/migration:

| Field | Ý nghĩa với migration |
|---|---|
| `id` | Unique key, indexed/stored, dùng cho idempotent upsert và làm tie-breaker khi sort cursor. |
| `domain` | Required field chính trong schema. |
| `_version_` | Indexed/stored, có thể dùng cho version cursor nếu implementation chọn hướng này; không copy sang target. |
| `updated_at` | Optional candidate timestamp cho reconcile/risk path, không phải main migration path. |
| `man_updated_at` | Candidate timestamp khác cho manual/business updates. |
| `copied_at` | Timestamp liên quan copy/index pipeline. |
| `last_activity` | Candidate timestamp cho activity freshness. |
| `last_sentiment` | Candidate timestamp liên quan sentiment update. |

Một số field `stored=false`:

```text
search_text_exactly
sound_exactly
effect_exactly
```

Khi copy bằng `/select`, các field `stored=false` không lấy trực tiếp được. Các field này cần được regenerate bằng `copyField`.

`copyField` hiện có:

```text
search_text -> search_text_exactly
effect      -> effect_exactly
sound       -> sound_exactly
```

Dynamic fields hiện có:

```text
engage_* -> int
random_* -> random
```

Lưu ý update chain:

```text
SkipExistingDocumentsProcessorFactory
skipInsertIfExists=true
```

Nếu migration/reconcile cần overwrite doc mới hơn trong target, không nên đi qua update path đang skip existing. Cần endpoint hoặc update chain riêng cho upsert migration.

## 4. Flow Tổng Quát

Không chọn hướng split shard trực tiếp trên collection cũ làm flow chính. Hướng production an toàn hơn là tạo collection mới rồi migrate.

Flow:

```text
1. Nightly detect topic vượt ngưỡng.
2. Tính số shard cần thiết.
3. Tạo target collection version mới, ví dụ topic_100001_v2.
4. Worker copy old -> new bằng cursor, upsert buffer và save cursor sau upsert.
5. Worker requeue/resume khi copied đạt khoảng `1M docs/message`.
6. Khi copy hết old collection, worker alias create/switch.
7. Worker mark job `DONE`.
8. Giữ old collection để rollback.
```

Ví dụ:

```text
topic_100001
current_shards = 1
doc_count = 40M
target_shards = 2 hoặc 4 tùy policy
target_collection = topic_100001_v2
```

### 4.1 Part 1 - Detect Resharding Topic Layer

Part 1 chạy định kỳ, tìm collection cần reshard, tạo job `NEW` trong DB, rồi push message qua queue.

1. Schedule detect job lúc `00:00` mỗi ngày.
2. Get list collection and num shards on Solr.
3. Query Active Jobs For Solr Collection List status IN [NEW, RUNNING], chunk `1000 collections/query`.
4. Classify collections:
   - Active job collections -> skip detect.
   - Candidate collections -> lấy numDocs.
5. Get num documents per candidate collection, batch `100 per request`.
6. Check need reshard bằng `targetShards = ceil(numDocs / 10M)`.
7. Nếu `targetShards <= currentShards` thì skip detect.
8. Insert Init Resharding Of Collection With Status NEW Into DB nếu `targetShards > currentShards`.
9. Build message.
10. Push queue `data.resharding_solr_topic`, batch `1 topic per message`.

### 4.2 Part 2 - Resharding Solr Topic Layer

Part 2 worker consume message, xử lý job `NEW/RUNNING/DONE`, copy data theo cursor, upsert theo buffer, requeue nếu đạt mốc 1M docs/message, cutover alias, rồi mark `DONE`.

1. Consume message từ queue `data.resharding_solr_topic`, batch `10 per handle or 30s`.
2. Load Resharding Job From DB từ MongoDB `Resharding Job Collection`.
3. Check status:
   - Job Status Is NEW: acquire job lock, set `RUNNING`.
   - Job Status Is RUNNING: resume job đang xử lý dở.
   - `DONE`: skip duplicate message.
4. Check target collection exists.
5. Nếu target chưa tồn tại, create target collection with new shards.
6. Read old collection by cursor, batch `200 docs/query`.
7. Append docs to upsert buffer.
8. Nếu buffer `>= 10,000 docs`, upsert buffer sang target.
9. Nếu buffer `< 10,000 docs`:
   - còn docs thì đọc tiếp.
   - hết docs thì upsert buffer cuối.
10. Sau upsert thành công, save cursor progress vào DB.
11. Copied >= 1M Docs In This Message: build resume message và push lại queue.
12. Nếu chưa đạt 1M và còn docs, tiếp tục copy trong cùng message.
13. Nếu hết docs, alias cutover:
   - alias chưa có thì create topic alias.
   - alias đã có thì switch alias sang target collection.
14. Mark Job DONE And Save Final Cursor.

Payload queue tối thiểu:

```json
{
  "collection": "topic_100001",
  "target_collection": "topic_100001_v2",
  "current_shards": 1,
  "target_shards": 5
}
```

## 5. Lần Init Đầu Tiên

Đây là lần khó nhất vì production chưa có alias, nhưng app vẫn gọi `/solr/topic_100001`.

### 5.1 Initial state

```text
physical:
  topic_100001

alias:
  none

app:
  /solr/topic_100001 -> physical topic_100001
```

### 5.2 Migration flow

```text
1. Detect topic_100001 đạt ngưỡng.
2. Insert job NEW và push message vào data.resharding_solr_topic.
3. Worker load job, lock job và set RUNNING.
4. Worker tạo target collection topic_100001_v2 nếu chưa tồn tại.
5. Worker đọc topic_100001 theo cursor, batch 200 docs/query.
6. Worker append docs vào upsert buffer và upsert sang target khi buffer đạt 10,000 docs.
7. Worker save cursor vào DB sau khi upsert thành công.
8. Worker requeue resume message khi copied đạt 1M docs/message.
9. Khi old collection hết docs, worker create shadow alias topic_100001 -> topic_100001_v2.
10. Worker mark job DONE và lưu final_cursor.
```

### 5.3 After state

```text
physical:
  topic_100001      # old, vẫn tồn tại nhưng bị alias che
  topic_100001_v2   # current active collection

alias:
  topic_100001 -> topic_100001_v2

app:
  /solr/topic_100001 -> alias -> topic_100001_v2
```

Solr ưu tiên alias hơn physical collection cho regular query/update. Sau khi tạo shadow alias, request `/solr/topic_100001/select` và `/solr/topic_100001/update` sẽ đi vào `topic_100001_v2`, không còn đi vào physical old `topic_100001`.

### 5.4 Rollback init

Nếu chưa có write mới vào `topic_100001_v2`, rollback lần đầu có thể là:

```text
DELETEALIAS topic_100001
```

Sau khi delete alias:

```text
/solr/topic_100001 -> physical topic_100001
```

Nếu `topic_100001_v2` đã nhận writes mới, rollback về old có thể thiếu data. Khi đó cần replay write log, dual-write, reconcile ngược, hoặc quy định rollback window ngắn theo runbook.

## 6. Lần 2, Lần 3, Lần N

Sau lần init, topic đã vào alias model.

### 6.1 Lần 2

Trạng thái trước lần 2:

```text
physical:
  topic_100001       # old init, bị che
  topic_100001_v2    # current

alias:
  topic_100001 -> topic_100001_v2
```

Reshard lần 2:

```text
source: topic_100001_v2
target: topic_100001_v3
cutover: update alias topic_100001 -> topic_100001_v3
rollback: update alias topic_100001 -> topic_100001_v2
```

### 6.2 Lần 3

```text
source: topic_100001_v3
target: topic_100001_v4
cutover: update alias topic_100001 -> topic_100001_v4
rollback: update alias topic_100001 -> topic_100001_v3
```

### 6.3 Lần N

```text
source: topic_100001_vN
target: topic_100001_vN+1
cutover: update alias topic_100001 -> topic_100001_vN+1
rollback: update alias topic_100001 -> topic_100001_vN
```

### 6.4 Worker resume and idempotency

- Worker chỉ save `last_cursor` sau khi upsert buffer sang target thành công.
- Nếu worker crash sau upsert nhưng trước khi save cursor, batch có thể được upsert lại; target phải idempotent theo unique key `id`.
- Nếu message duplicate tới sau khi job đã `DONE`, worker load job từ DB và skip.
- Nếu copied trong message hiện tại đạt khoảng `1M docs`, worker build resume message, push lại queue và giữ job status `RUNNING`.
- `FAILED` là terminal error status cho lỗi cần retry/manual intervention.

## 7. Optional No-Pause Reconcile Risk

Đây là risk path tùy chọn, không phải main flow production v1. Nếu cần reconcile giữa source và target sau alias switch, không được blind upsert.

Race condition:

```text
T1: doc A update vào topic_100001_v2 ngay trước alias switch
T2: alias switch topic_100001 -> topic_100001_v3
T3: doc A update tiếp vào topic_100001_v3
T4: reconcile copy bản doc A từ v2 sang v3
```

Nếu T4 blind upsert, bản cũ từ `v2` có thể ghi đè bản mới hơn trong `v3`.

Lưu ý quan trọng:

```text
_version_ của topic_100001_v2 và topic_100001_v3 không so sánh trực tiếp được
```

Vì mỗi collection sinh `_version_` riêng.

Conflict policy khuyến nghị:

```text
if doc id does not exist in new:
  insert
else if source.updated_at > target.updated_at:
  overwrite
else:
  skip
```

Nếu `updated_at` không đáng tin, cần chọn application version/timestamp khác hoặc thiết kế change log riêng trước khi dùng no-pause reconcile.

## 8. Alias Behavior

### 8.1 Shadow Alias

Shadow alias là alias có cùng tên với một physical collection đang tồn tại.

```text
physical:
  topic_100001
  topic_100001_v2

alias:
  topic_100001 -> topic_100001_v2
```

Sau khi shadow alias tồn tại:

```text
/solr/topic_100001/select -> topic_100001_v2
/solr/topic_100001/update -> topic_100001_v2
```

Physical old `topic_100001` vẫn tồn tại nhưng bị alias che khỏi regular query/update bằng path cũ.

### 8.2 Multi-level Alias

Multi-level alias là alias trỏ đến alias khác:

```text
alias A -> alias B -> collection
```

Multi-level alias có thể hoạt động cho query thường, nhưng cần cẩn thận với collection admin commands và `followAliases=true`.

### 8.3 Không dùng temp alias trỏ vào shadow name

Không nên tạo:

```text
topic_100001_temp -> topic_100001
```

Sau khi có shadow alias:

```text
topic_100001 -> topic_100001_v2
```

`topic_100001_temp` có thể resolve thành:

```text
topic_100001_temp -> topic_100001 -> topic_100001_v2
```

Tức là tưởng trỏ old, nhưng thực tế lại trỏ new. Điều này có thể làm audit hoặc rollback nhầm.

## 9. Group Alias

Production có thể có alias cấp cao trỏ tới nhiều topic.

Ví dụ:

```text
physical:
  topic_100001
  topic_100001_v2
  topic_100002
  topic_100003

aliases:
  topic_100001 -> topic_100001_v2
  topic_100011 -> topic_100001,topic_100002,topic_100003
```

Khi query:

```text
/solr/topic_100011/select
```

Solr có thể resolve:

```text
topic_100011
  -> topic_100001,topic_100002,topic_100003
  -> topic_100001_v2,topic_100002,topic_100003
```

Điều này có nghĩa là sau cutover, `topic_100011` có thể đọc current version `topic_100001_v2`, không còn đọc old physical `topic_100001`.

### 9.1 Update/write vào group alias

Không nên dùng standard group alias nhiều collections cho write/update:

```text
/solr/topic_100011/update
```

Standard alias nhiều collections không có routing logic rõ ràng để phân phối documents như routed alias. `topic_100011` nên chỉ dùng cho query/search aggregated.

### 9.2 Policy A: group alias trỏ logical topic aliases

```text
topic_100011 -> topic_100001,topic_100002,topic_100003
topic_100001 -> topic_100001_v2
```

Ưu điểm:

- Group alias tự đi theo current version của topic con sau cutover.
- Không cần update mọi group alias khi một topic con reshard.

Nhược điểm:

- Tạo multi-level alias.
- Cần audit kỹ với `LISTALIASES`.
- Tránh dùng với collection admin commands và `followAliases=true`.

### 9.3 Policy B: group alias trỏ physical collection versions

```text
topic_100011 -> topic_100001_v2,topic_100002,topic_100003
```

Ưu điểm:

- Query path rõ ràng hơn.
- Tránh multi-level alias trong query path.

Nhược điểm:

- Mỗi lần reshard topic con phải tìm và update tất cả group aliases chứa topic đó.
- Dễ sót alias nếu không có inventory/audit tốt.

### 9.4 Khuyến nghị v1

- Cho phép group alias trỏ logical topic alias nếu mục tiêu là group query luôn đọc current version.
- Không dùng group alias cho writes.
- Audit `LISTALIASES` trước/sau cutover.
- Check lại các group aliases chứa topic vừa reshard sau cutover.
- Nếu ranking/relevance qua alias nhiều collections quan trọng, research thêm `ExactStatsCache`.

## 10. Data Migration Details

### 10.1 Read old collection by cursor

Khuyến nghị:

- Worker đọc old collection theo cursor hiện tại.
- Batch size: `200 docs/query`.
- Cursor có thể là `cursorMark` hoặc `_version_` cursor tùy implementation.
- Nếu chọn `_version_` cursor, sort theo `_version_ asc,id asc`.
- Nếu dùng `cursorMark`, vẫn cần sort ổn định để resume không bị lệch.
- Không copy `_version_` sang target.
- Chỉ copy stored fields khi dùng `/select`.
- Các copy fields/indexed-only fields được regenerate bởi schema target.

Ví dụ:

```text
q=*:*
sort=_version_ asc,id asc
cursorMark=*
rows=200
```

### 10.2 Upsert buffer

- Docs đọc từ old collection được append vào upsert buffer.
- Khi buffer đạt `10,000 docs`, upsert buffer sang target collection.
- Nếu old collection hết docs và buffer cuối nhỏ hơn `10,000 docs`, vẫn upsert buffer cuối.
- Block nên gọi là `Upsert Buffer To Target Collection` vì dùng cho cả batch đầy và batch cuối.

```text
200 docs/query
50 queries => buffer 10,000 docs
```

### 10.3 Save cursor after upsert

Chỉ save cursor sau khi upsert thành công. Không save cursor ngay sau query, vì nếu worker chết trước khi upsert thì có thể mất dữ liệu.

```json
{
  "last_cursor": "cursor_of_last_successfully_upserted_doc",
  "copied_count": 123456,
  "status": "RUNNING",
  "updated_at": "..."
}
```

### 10.4 Requeue threshold

- Worker không giữ một message quá lâu.
- Nếu copied trong message hiện tại đạt khoảng `1M docs`, worker build resume message và push lại queue.
- Job vẫn giữ status `RUNNING`; lần sau worker resume từ cursor đã lưu.

### 10.5 Deletes

Cursor copy không bắt được hard delete nếu doc đã biến mất khỏi source trước khi worker đọc tới.

Các hướng xử lý:

- Soft delete, ví dụ `is_deleted=true`.
- Tombstone table.
- Change log từ DB/app.
- Cấm hard delete trong migration window.

### 10.6 Operational constants

- Read old collection: `200 docs/query`.
- Upsert buffer: `10,000 docs/upsert`.
- Requeue threshold: `1M docs/message`.
- Queue consume: `10 messages/handle or 30s`.

## 11. SPLITSHARD Research

`SPLITSHARD` là Collections API built-in của Solr để split một shard hiện có thành các sub-shards nhỏ hơn.

Ví dụ API:

```text
GET /solr/admin/collections?action=SPLITSHARD&collection=topic_100001&shard=shard1&async=split-topic-100001-shard1
```

Hoặc V2 API:

```text
POST /api/collections/topic_100001/shards
{
  "split": {
    "shard": "shard1",
    "async": "split-topic-100001-shard1"
  }
}
```

Cơ chế:

- Solr chia hash range của shard gốc thành các sub-ranges nhỏ hơn.
- Documents trong shard gốc được phân phối sang sub-shards theo hash range mới.
- Original shard vẫn giữ data as-is, nhưng sau split request được route sang sub-shards.
- Sub-shards mới có số replica tương tự shard gốc.
- Có thể chạy async và track bằng `REQUESTSTATUS`.
- Dùng được cho collection tạo bằng `numShards`, tức hash-based routing như `compositeId`.

Pros:

- Built-in trong Solr.
- Không cần tự viết custom copy worker.
- Không cần đổi app endpoint vì vẫn là cùng collection.
- Solr tự xử lý hash range split.

Cons:

- Là in-place operation trên production collection.
- Rollback khó hơn alias switch.
- Không có target collection riêng để kiểm soát độc lập.
- Không giúp chuyển production sang alias model.
- Ít kiểm soát DB history, cursor progress và rollback policy.
- Với topic 40M docs có thể ảnh hưởng disk IO, CPU, recovery và query/update latency.

Kết luận:

```text
SPLITSHARD đáng PoC/staging research.
Production chính vẫn nên dùng custom migration nếu cần DB history, cursor progress, alias rollback rõ hơn và chuyển sang alias model.
```

PoC tối thiểu:

```text
SPLITSHARD topic_4777 shard1
track async status
measure IO / query latency / update latency / recovery time / replica health
validate docs still queryable
```

## 12. REINDEXCOLLECTION Research

`REINDEXCOLLECTION` là option built-in đáng research/PoC, nhưng không nên chọn làm production flow chính nếu topic vẫn nhận writes liên tục.

Pros:

- Built-in trong Solr.
- Có thể tạo target collection với shard mới.
- Có thể hỗ trợ reindex/cutover qua alias.

Cons:

- Source collection bị read-only trong lúc reindex.
- Với 40M docs, thời gian read-only có thể rất dài.
- Có thể lossy nếu field cần reindex không stored.
- Ít kiểm soát copy cursor, DB history, resume và rollback hơn custom migration.

Kết luận:

```text
REINDEXCOLLECTION phù hợp để PoC/staging research.
Production chính nên dùng custom migration nếu topic vẫn nhận writes liên tục.
```

## 13. DB History

### 13.1 `topic_reshard_runs`

| Field | Ý nghĩa |
|---|---|
| `id` | ID của run |
| `collection` | Old/source collection cần reshard |
| `target_collection` | Collection target |
| `current_shards` | Số shard hiện tại của old collection |
| `target_shards` | Số shard target cần tạo |
| `status` | `NEW` là job chờ worker; `RUNNING` là đang copy hoặc chờ resume; `DONE` là alias đã create/switch và job hoàn tất; `FAILED` là terminal error cần retry/manual intervention |
| `last_cursor` | Cursor của doc cuối cùng đã upsert thành công |
| `copied_count` | Số docs đã copy sang target |
| `final_cursor` | Cursor cuối cùng khi job hoàn tất |
| `created_at` | Thời gian tạo job |
| `updated_at` | Thời gian cập nhật job gần nhất |
| `completed_at` | Thời gian mark job `DONE` |
| `error_message` | Lỗi nếu có |

### 13.2 `topic_reshard_events`

Events nên lưu:

- `DETECTED`
- `JOB_CREATED_NEW`
- `MESSAGE_PUSHED`
- `JOB_RUNNING`
- `TARGET_CREATED`
- `COPY_BATCH_UPSERTED`
- `CURSOR_SAVED`
- `MESSAGE_REQUEUED`
- `ALIAS_CREATED`
- `ALIAS_SWITCHED`
- `DONE`
- `FAILED`

## 14. Risks Và Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Shadow alias che old physical | Ops có thể tưởng `/solr/topic_100001` vẫn là old | Runbook rõ, audit aliases, check alias mapping trước/sau cutover |
| Rollback init sau new writes | Old thiếu writes mới | Rollback window ngắn, replay log/dual-write/reconcile ngược nếu có |
| Save cursor trước khi upsert | Worker chết giữa query và upsert có thể làm mất data | Chỉ save cursor sau khi upsert buffer thành công |
| Duplicate message | Worker có thể xử lý lại message đã hoàn tất | Load job từ DB và skip nếu status đã `DONE` |
| Worker crash sau upsert trước save cursor | Batch có thể được upsert lại khi resume | Upsert target phải idempotent theo unique key `id` |
| Message xử lý quá lâu | Worker giữ message lớn, khó retry/resume | Requeue khi copied đạt khoảng `1M docs/message` |
| Hard delete trong lúc copy | Target có thể giữ doc đã bị xóa khỏi source | Soft delete/tombstone/change log/cấm hard delete trong migration window |
| SPLITSHARD in-place operation | Split tác động trực tiếp collection production, rollback khó hơn alias switch | Chỉ PoC/staging trước; nếu dùng production thì maintenance window, async request, monitor IO/latency/recovery |
| Group alias đổi data ngầm | Group alias đọc current version sau cutover topic con | Audit `LISTALIASES`, check group alias, ghi policy rõ |
| Alias nhiều collections ảnh hưởng scoring | Ranking/relevance có thể lệch | Research `ExactStatsCache` nếu ranking quan trọng |
| Copy 40M docs tốn tài nguyên | Tăng load Solr/network/heap | Batch size, rate limit, off-peak, retry/backoff |
| REINDEXCOLLECTION read-only lâu | Write downtime dài | Chỉ PoC/research nếu không chấp nhận read-only lâu |

## 15. Research Checklist

- Có chấp nhận shadow alias lần đầu không?
- Có hard delete trong migration window không?
- Nếu chọn optional reconcile/no-pause risk path, `updated_at` hoặc field/version nào là source-of-truth?
- Group aliases hiện đang dùng logical topic names hay physical collection names?
- Có app nào write vào group alias nhiều collections không?
- Có cần `ExactStatsCache` cho query qua alias nhiều collections không?
- SPLITSHARD có cần PoC trên `topic_4777` hoặc staging để đo IO/latency/recovery không?
- REINDEXCOLLECTION có thể PoC trên staging không?
- DB history dùng DB nào?
- Scheduler/worker runtime dùng gì?
- Retention old collection là bao lâu?

## 16. Kết Luận

Production v1 nên dùng custom migration thay vì SPLITSHARD trực tiếp hoặc REINDEXCOLLECTION.

Khuyến nghị:

```text
Part 1:
  detect topic cần reshard
  insert job NEW
  push queue data.resharding_solr_topic

Part 2:
  consume message
  load job from DB
  handle NEW/RUNNING/DONE
  create target collection if needed
  read old by cursor
  upsert buffer to target
  save cursor after upsert success
  requeue at 1M docs/message
  alias create/switch
  mark DONE
```

Group alias cần được audit trước/sau cutover. Wiki này là bản share/research chi tiết; `docs/reshard-topic-collection-tech-spec.md` là source of truth kỹ thuật trong repo.
