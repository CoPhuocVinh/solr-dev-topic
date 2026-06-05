# SolrCloud Topic Collection Resharding Research & Implementation Plan

## 1. Mục tiêu

Xây dựng cơ chế tự động reshard cho các topic collection trong SolrCloud 9 khi dữ liệu của một topic tăng vượt ngưỡng, ví dụ topic đạt khoảng 40 triệu records và `numShards=1` không còn phù hợp.

Mục tiêu chính:

- Tự động detect topic lớn cần tăng shard.
- Tạo collection version mới với số shard phù hợp hơn.
- Migrate dữ liệu bằng full copy + delta sync.
- Validate dữ liệu trước cutover.
- Giữ endpoint cũ `/solr/topic_xxx` cho các app hiện tại.
- Cutover an toàn bằng alias.
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
-> full copy dữ liệu
-> delta sync bằng _version_ watermark
-> validate dữ liệu
-> cutover bằng shadow alias hoặc alias switch
-> reconcile nếu cần
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
| `id` | Unique key, indexed/stored, dùng để sort ổn định khi full copy bằng cursor. |
| `domain` | Required field chính trong schema. |
| `_version_` | Indexed/stored, dùng làm technical watermark cho delta insert/update. |
| `updated_at` | Candidate timestamp cho conflict policy khi reconcile không pause. |
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

Khi full copy bằng `/select`, các field `stored=false` không lấy trực tiếp được. Các field này cần được regenerate bằng `copyField`.

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
4. Capture initial _version_ watermark.
5. Full copy old -> new.
6. Delta sync old -> new.
7. Validate old vs new.
8. Cutover bằng shadow alias hoặc alias switch.
9. Reconcile nếu cần.
10. Giữ old collection để rollback.
```

Ví dụ:

```text
topic_100001
current_shards = 1
doc_count = 40M
target_shards = 2 hoặc 4 tùy policy
target_collection = topic_100001_v2
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
2. Tạo physical collection mới topic_100001_v2 với số shard mới.
3. Full copy topic_100001 -> topic_100001_v2.
4. Delta sync bằng _version_ watermark.
5. Kéo delta backlog về gần 0.
6. Pause/block writes mạnh cho topic_100001.
7. Final sync topic_100001 -> topic_100001_v2.
8. Validate physical old vs physical new.
9. Create shadow alias topic_100001 -> topic_100001_v2.
10. Resume writes.
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

Nếu `topic_100001_v2` đã nhận writes mới, rollback về old có thể thiếu data. Khi đó cần pause write, replay write log, dual-write, hoặc reconcile ngược.

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

### 6.4 Cutover modes

Strong consistency mode:

```text
pause write ngắn
-> final delta sync
-> validate nhanh
-> update alias
-> resume write
```

Eventual consistency mode:

```text
delta sync đến khi backlog nhỏ
-> capture last_watermark_before_cutover
-> update alias
-> app writes mới vào target
-> post-cutover reconcile source -> target
-> validate lại
```

Từ lần 2 trở đi, no-pause mode khả thi hơn vì source physical version như `topic_100001_v2` vẫn gọi trực tiếp được sau alias switch.

## 7. No-Pause Reconcile Từ Lần 2

Nếu không pause từ lần 2, bắt buộc phải reconcile cẩn thận. Không được blind upsert.

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

Nếu `updated_at` không đáng tin, cần chọn application version/timestamp khác hoặc pause write ngắn.

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

Tức là tưởng trỏ old, nhưng thực tế lại trỏ new. Điều này có thể làm validate hoặc rollback nhầm.

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
- Validate lại các group aliases chứa topic vừa reshard sau cutover.
- Nếu ranking/relevance qua alias nhiều collections quan trọng, research thêm `ExactStatsCache`.

## 10. Data Migration Details

### 10.1 Full copy

Khuyến nghị:

- Dùng cursor pagination.
- Sort ổn định theo `id asc`.
- Batch size configurable.
- Không copy `_version_` sang target.
- Chỉ copy stored fields khi dùng `/select`.
- Các copy fields/indexed-only fields được regenerate bởi schema target.

Ví dụ:

```text
q=*:*
sort=id asc
cursorMark=*
rows=1000
```

### 10.2 Delta sync

Trước full copy, capture watermark:

```text
max(_version_) from source collection
```

Sau full copy:

```text
q=_version_:{last_watermark TO *]
sort=_version_ asc,id asc
```

Flow mỗi batch:

```text
read docs where _version_ > last_watermark
upsert into target
update last_watermark
persist progress
```

### 10.3 Deletes

`_version_` không bắt được hard delete. Nếu doc bị xóa khỏi source, doc đó không còn tồn tại để query delta.

Các hướng xử lý:

- Soft delete, ví dụ `is_deleted=true`.
- Tombstone table.
- Change log từ DB/app.
- Cấm hard delete trong migration window.

### 10.4 Validate

Checklist:

- Count source vs target.
- Sample ids theo hash/range/random.
- Business queries/facets quan trọng.
- Shard/replica health.
- Alias mapping.
- Group alias impacted queries nếu topic nằm trong group alias.

## 11. REINDEXCOLLECTION Research

`REINDEXCOLLECTION` là option built-in đáng research/PoC, nhưng không nên chọn làm production flow chính nếu topic vẫn nhận writes liên tục.

Pros:

- Built-in trong Solr.
- Có thể tạo target collection với shard mới.
- Có thể hỗ trợ reindex/cutover qua alias.

Cons:

- Source collection bị read-only trong lúc reindex.
- Với 40M docs, thời gian read-only có thể rất dài.
- Có thể lossy nếu field cần reindex không stored.
- Ít kiểm soát delta sync, reconcile, DB history và rollback hơn custom migration.

Kết luận:

```text
REINDEXCOLLECTION phù hợp để PoC/staging research.
Production chính nên dùng custom migration nếu topic vẫn nhận writes liên tục.
```

## 12. DB History

### 12.1 `topic_reshard_runs`

| Field | Ý nghĩa |
|---|---|
| `id` | ID của run |
| `topic_id` | Topic cần reshard |
| `source_collection` | Collection source |
| `target_collection` | Collection target |
| `alias_name` | Alias logical |
| `source_num_shards` | Số shard source |
| `target_num_shards` | Số shard target |
| `status` | Trạng thái run |
| `initial_watermark` | `_version_` watermark ban đầu |
| `last_watermark` | Watermark đã xử lý gần nhất |
| `full_copy_cursor` | CursorMark để resume full copy |
| `cutover_mode` | `shadow_alias`, `alias_switch_pause`, hoặc `alias_switch_no_pause` |
| `conflict_policy` | Policy reconcile khi không pause |
| `started_at` | Thời gian bắt đầu |
| `cutover_at` | Thời gian cutover |
| `finished_at` | Thời gian kết thúc |
| `error_message` | Lỗi nếu có |

### 12.2 `topic_reshard_events`

Events nên lưu:

- `DETECTED`
- `TARGET_CREATE_REQUESTED`
- `TARGET_CREATE_SUCCEEDED`
- `FULL_COPY_BATCH_DONE`
- `DELTA_BATCH_DONE`
- `VALIDATION_FAILED`
- `CUTOVER_ALIAS_UPDATED`
- `RECONCILE_DONE`
- `ROLLBACK_ALIAS_UPDATED`
- `DONE`
- `FAILED`

## 13. Risks Và Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Shadow alias che old physical | Ops có thể tưởng `/solr/topic_100001` vẫn là old | Runbook rõ, audit aliases, validate trước cutover |
| Rollback init sau new writes | Old thiếu writes mới | Rollback window ngắn, pause write, replay log/dual-write nếu có |
| No-pause reconcile stale overwrite | Bản cũ overwrite bản mới | Không blind upsert, compare bằng timestamp/version đáng tin |
| `_version_` không bắt hard delete | Target giữ docs đã bị xóa | Soft delete/tombstone/change log/cấm hard delete |
| Update chain skip existing | Reconcile bỏ sót update mới hơn | Dùng migration upsert endpoint/chain riêng |
| Group alias đổi data ngầm | Group alias đọc current version sau cutover topic con | Audit `LISTALIASES`, validate group alias, ghi policy rõ |
| Alias nhiều collections ảnh hưởng scoring | Ranking/relevance có thể lệch | Research `ExactStatsCache` nếu ranking quan trọng |
| Full copy 40M docs tốn tài nguyên | Tăng load Solr/network/heap | Batch size, rate limit, off-peak, retry/backoff |
| REINDEXCOLLECTION read-only lâu | Write downtime dài | Chỉ PoC/research nếu không chấp nhận read-only lâu |

## 14. Research Checklist

- Có chấp nhận shadow alias lần đầu không?
- Pause write lần đầu được bao lâu?
- Có hard delete trong migration window không?
- `updated_at` có đáng tin cho conflict policy không?
- Nếu `updated_at` không đáng tin, field/version nào là source-of-truth?
- Group aliases hiện đang dùng logical topic names hay physical collection names?
- Có app nào write vào group alias nhiều collections không?
- Có cần `ExactStatsCache` cho query qua alias nhiều collections không?
- REINDEXCOLLECTION có thể PoC trên staging không?
- DB history dùng DB nào?
- Scheduler/worker runtime dùng gì?
- Retention old collection là bao lâu?

## 15. Kết Luận

Production v1 nên dùng custom migration thay vì split shard trực tiếp hoặc REINDEXCOLLECTION.

Khuyến nghị:

```text
Lần init:
  custom full copy + delta sync
  pause write mạnh
  create shadow alias topic_100001 -> topic_100001_v2
  rollback bằng DELETEALIAS

Lần 2 trở đi:
  custom full copy + delta sync
  update alias topic_100001 -> topic_100001_vN+1
  rollback bằng update alias về version trước
  có thể no-pause nếu reconcile có conflict policy đáng tin
```

Group alias cần được audit trước/sau cutover. Wiki này là bản share/research chi tiết; `docs/reshard-topic-collection-tech-spec.md` là source of truth kỹ thuật trong repo.
