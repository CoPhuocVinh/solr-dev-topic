# Tech Spec: Tự Động Reshard Topic Collection Cho SolrCloud 9

## 1. Tóm Tắt

Hệ thống cần một cơ chế tự động phát hiện và reshard các topic collection trong SolrCloud 9 khi topic lớn vượt ngưỡng dữ liệu. Hiện tại mỗi topic là một collection riêng, ví dụ `topic_100001`, ban đầu có thể chỉ có `1` shard. Khi topic tăng lên khoảng 40 triệu mentions/documents, một shard dễ trở thành bottleneck và khó scale tiếp.

Hướng triển khai khuyến nghị là **không split shard trực tiếp trên collection cũ**, mà tạo một collection mới với số shard phù hợp hơn, migrate dữ liệu sang collection mới, validate, rồi cutover bằng alias. Vì production có nhiều app đang gọi thẳng collection name và khó đổi read/write endpoint, hướng thực tế cho lần đầu là dùng **shadow alias** cùng tên với collection cũ. Collection cũ được giữ lại để rollback.

Flow tổng quát:

```text
detect topic lớn
  -> tính số shard mới
  -> tạo target collection version mới
  -> full copy dữ liệu
  -> delta sync bằng _version_ watermark
  -> validate dữ liệu
  -> cutover bằng shadow alias hoặc alias switch
  -> final reconcile
  -> giữ old collection để rollback
```

## 2. Hiện Trạng

### 2.1 Hiện trạng production

- Mỗi topic là một physical collection riêng, ví dụ `topic_100001`.
- Collection dùng `router.name=compositeId`.
- `uniqueKey=id`.
- Ban đầu collection có thể chỉ có `numShards=1`.
- Production hiện tại **chưa có alias**.
- Có nhiều app/service đang read/write trực tiếp vào `/solr/topic_xxx`, nên không thể giả định sẽ đổi app sang alias name mới.
- Khi topic đạt ngưỡng lớn, ví dụ 40 triệu records, một shard không còn phù hợp vì dễ nghẽn IO/CPU/query/update.

### 2.2 Hiện trạng repo

Repo hiện tại là local SolrCloud sandbox, chưa phải production job service.

Đang có:

- Docker Compose chạy SolrCloud `9.8.1` và ZooKeeper.
- Configset `topic_conf` trong `mentions_conf/`.
- Script `scripts/solr-init.sh` để upload configset, tạo collection `topic_4777`, import sample data.
- Schema có `uniqueKey=id`.
- Schema có field `_version_` indexed/stored.
- Update handler hiện tại dùng `SkipExistingDocumentsProcessorFactory` với `skipInsertIfExists=true`.

Chưa có:

- Scheduler/nightly job.
- DB history.
- Migration worker.
- Alias bootstrap/cutover.
- Validate/reconcile/rollback automation.

### 2.3 Topic Collection Schema

Schema hiện tại nằm trong configset `topic_conf`, file `mentions_conf/managed-schema.xml`.

Thông tin chính:

```text
schema name: topics
schema version: 1.6
uniqueKey: id
required fields chính: id, domain
```

Các field quan trọng cho reshard/migration:

- `id`: `string`, indexed/stored, required, dùng làm unique key và sort ổn định khi full copy bằng cursor.
- `_version_`: `long`, indexed/stored, dùng làm technical watermark cho delta insert/update.
- `updated_at`, `man_updated_at`, `copied_at`, `last_activity`, `last_sentiment`: các timestamp liên quan đến reconcile/conflict policy. Nếu cutover từ lần 2 không pause, cần chốt field nào là timestamp đáng tin để compare-before-upsert.
- `search_text`, `sound`, `effect`: text fields stored/indexed, có thể copy trực tiếp khi full copy.
- `search_text_exactly`, `sound_exactly`, `effect_exactly`: `stored=false`, không lấy trực tiếp được khi copy qua `/select`; các field này cần được regenerate bằng `copyField`.

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

Lưu ý cho migration:

- Target collection phải dùng cùng configset `topic_conf` trong v1 để tránh schema drift.
- Full copy qua `/select` chỉ lấy được stored fields; các indexed-only/copy fields phải được schema regenerate.
- Không gửi `_version_` của source sang target; để Solr target tự sinh `_version_` mới.
- `solrconfig.xml` hiện có update chain `SkipExistingDocumentsProcessorFactory` với `skipInsertIfExists=true`. Migration/reconcile cần endpoint hoặc update chain riêng cho upsert nếu muốn overwrite doc mới hơn.

## 3. Mục Tiêu Và Phạm Vi

### 3.1 Mục tiêu

- Tự động phát hiện topic collection vượt ngưỡng cần tăng shard.
- Lưu history từng lần detect/migrate/cutover/rollback vào DB.
- Tạo collection mới với số shard phù hợp.
- Migrate dữ liệu an toàn bằng full copy + delta sync.
- Validate trước khi cutover.
- Cutover có khả năng rollback.
- Không xóa collection cũ ngay sau cutover.

### 3.2 Không làm trong v1

- Không tự động hard-delete collection cũ.
- Không đảm bảo rollback sạch tuyệt đối nếu đã có write vào collection mới sau cutover mà hệ thống không có write log/dual-write.
- Không đổi schema/analyzer trong lúc reshard, trừ khi có migration riêng.
- Không xử lý hard delete bằng `_version_` nếu hệ thống không có tombstone hoặc change log.

## 4. Kiến Trúc Đề Xuất

### 4.1 Các thành phần chính

1. **Detector job**
   - Chạy mỗi đêm.
   - List topic collections/aliases.
   - Lấy doc count và shard count.
   - Tạo candidate nếu topic vượt threshold.

2. **Planner**
   - Tính `target_num_shards`.
   - Tạo target collection name, ví dụ `topic_100001_v2`.
   - Kiểm tra không có migration nào đang chạy cho cùng topic.

3. **Migration worker**
   - Tạo collection mới.
   - Full copy từ old sang new.
   - Delta sync bằng `_version_`.
   - Persist progress/watermark để resume được nếu worker restart.

4. **Validator**
   - So sánh count.
   - Sample compare theo `id`.
   - Chạy smoke test query/facet quan trọng.
   - Kiểm tra cluster health.

5. **Cutover controller**
   - Pause write ngắn nếu làm được.
   - Chạy final delta.
   - Lần đầu: tạo shadow alias cùng tên collection cũ để giữ nguyên endpoint cho app.
   - Từ lần 2 trở đi: update alias sang collection version mới.
   - Resume write.

6. **Reconcile worker**
   - Chạy thêm một vòng delta sau cutover.
   - Mark migration `DONE`.

7. **Rollback controller**
   - Lần đầu: rollback nhanh bằng cách delete shadow alias để physical collection cũ hiện lại.
   - Từ lần 2 trở đi: rollback bằng cách update alias về collection version trước.
   - Ghi history và alert.

### 4.2 Quy ước đặt tên

Mục tiêu dài hạn nên là:

```text
logical topic name:     topic_100001
old physical v1:        topic_100001_v1
new physical v2:        topic_100001_v2
alias:                  topic_100001
```

Tuy nhiên production hiện tại chưa có alias và physical collection đang tên `topic_100001`, nên cần một bước chuyển đổi alias riêng.

## 5. Vấn Đề Quan Trọng: Production Chưa Có Alias Và App Không Đổi Endpoint Được

Đây là điểm rủi ro lớn nhất của thiết kế.

Hiện tại production có nhiều app/service đang gọi trực tiếp:

```text
App read/write -> physical collection topic_100001
```

Mục tiêu sau khi mature:

```text
App read/write -> alias topic_100001 -> physical collection topic_100001_v2
```

Vấn đề là `topic_100001` hiện đã là tên physical collection. Nếu tạo alias cũng tên `topic_100001`, đây là **shadow alias**: cùng một string vừa là tên physical collection cũ, vừa là alias trỏ sang collection mới.

Solr ưu tiên alias hơn physical collection cho regular query/update request. Sau khi có shadow alias:

```text
physical collection: topic_100001
physical collection: topic_100001_v2
alias:               topic_100001 -> topic_100001_v2
```

Khi app gọi:

```text
/solr/topic_100001/select
/solr/topic_100001/update
```

Request sẽ đi vào alias `topic_100001` và tới `topic_100001_v2`. Physical collection cũ `topic_100001` vẫn tồn tại nhưng bị alias che đi. Đây là lý do shadow alias dùng được để giữ nguyên endpoint cho app, nhưng rủi ro vận hành cao hơn alias bình thường.

### 5.1 Option A: Tạo alias logical name mới

Flow:

```text
current app -> topic_100001 physical

create alias topic_100001_current -> topic_100001
change app read/write -> topic_100001_current

reshard:
topic_100001 physical -> topic_100001_v2
cutover alias topic_100001_current -> topic_100001_v2
```

Ưu điểm:

- Ít rủi ro hơn.
- Giữ được collection cũ `topic_100001` để rollback.
- Không cần giải phóng tên `topic_100001`.

Nhược điểm:

- App/config phải đổi sang alias name mới, ví dụ `topic_100001_current`.
- Tên logical topic trong app không còn trùng với collection name cũ.
- Không phù hợp với constraint hiện tại nếu nhiều app không thể đổi read/write endpoint.

### 5.2 Option B: Dùng shadow alias để giữ nguyên endpoint `topic_100001`

Mục tiêu:

```text
alias topic_100001 -> topic_100001_v2
```

Vấn đề:

- Hiện `topic_100001` đang là physical collection.
- Tạo alias cùng tên sẽ che physical collection cũ khỏi regular query/update.
- Các script vận hành/admin dễ nhầm giữa alias và collection thật.
- Không nên hiểu “đổi tên collection” là rename vật lý an toàn. Cutover nên được xem là alias switch.

Flow khả thi cho lần đầu:

```text
1. Tạo topic_100001_v2.
2. Migrate dữ liệu từ topic_100001 sang topic_100001_v2.
3. Pause write.
4. Final sync.
5. Validate nhanh.
6. Tạo shadow alias topic_100001 -> topic_100001_v2.
7. Resume write.
```

Ưu điểm:

- App không cần đổi code/config.
- Endpoint `/solr/topic_100001` vẫn giữ nguyên.
- Cutover nhanh nếu alias creation/update thành công.

Nhược điểm:

- Physical old collection `topic_100001` bị alias che đi.
- Post-cutover reconcile từ old bằng path `/solr/topic_100001` không còn dùng được, vì path đó đã vào new.
- Rollback lần đầu thường là delete alias `topic_100001` để old physical collection hiện lại.
- Nếu new đã nhận writes sau cutover, rollback bằng delete alias có thể làm app quay lại old nhưng old thiếu writes mới.

### 5.3 Từ lần reshard thứ 2 trở đi

Sau lần đầu:

```text
alias topic_100001 -> topic_100001_v2
old physical topic_100001 vẫn tồn tại nhưng bị che
```

Lần reshard tiếp theo sẽ sạch hơn:

```text
source physical: topic_100001_v2
target physical: topic_100001_v3
alias before:    topic_100001 -> topic_100001_v2
alias after:     topic_100001 -> topic_100001_v3
```

Từ lần 2 trở đi:

- Không còn tạo shadow alias mới.
- Old physical collection, ví dụ `topic_100001_v2`, vẫn gọi trực tiếp được.
- Rollback là update alias về `topic_100001_v2`, không phải delete alias.
- Có thể không pause nếu chấp nhận eventual consistency và có post-cutover reconcile đúng conflict policy.

### 5.4 Khuyến nghị

Vì production có nhiều app không đổi read/write endpoint được, V1 nên đi theo **Option B: shadow alias lần đầu**, nhưng phải xem đây là flow rủi ro cao hơn và cần write pause mạnh khi cutover lần đầu.

Sau lần đầu, topic đã vào alias model. Các lần reshard sau nên update alias từ version cũ sang version mới; có thể bỏ pause nếu có post-cutover reconcile và conflict policy đáng tin.

### 5.5 Group Alias Khi Member Là Shadow Alias

Production có thể có alias cấp cao trỏ tới nhiều topic, ví dụ:

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

Trong case này, `topic_100011` là group alias nhiều collections. Khi query:

```text
/solr/topic_100011/select
```

Solr có thể resolve theo chuỗi:

```text
topic_100011
  -> topic_100001,topic_100002,topic_100003
  -> topic_100001_v2,topic_100002,topic_100003
```

Điều này có nghĩa là sau khi `topic_100001` trở thành shadow alias, group alias `topic_100011` sẽ đọc current version `topic_100001_v2`, không còn đọc old physical `topic_100001`. Đây có thể là behavior mong muốn nếu group alias luôn phải đọc latest/current topic data, nhưng phải được ghi rõ trong runbook.

Không nên dùng group alias standard nhiều collections làm write target:

```text
/solr/topic_100011/update
```

Standard alias nhiều collections không có routing logic rõ ràng để phân phối documents như routed alias. `topic_100011` nên chỉ dùng cho query/search aggregated.

Có 2 policy cho group alias:

```text
Policy A: group alias trỏ logical topic aliases
topic_100011 -> topic_100001,topic_100002,topic_100003
topic_100001 -> topic_100001_v2
```

Ưu điểm: group alias tự đi theo current version của topic con sau cutover.

Nhược điểm: tạo multi-level alias, cần cẩn thận với collection admin commands và `followAliases=true`.

```text
Policy B: group alias trỏ physical collections
topic_100011 -> topic_100001_v2,topic_100002,topic_100003
```

Ưu điểm: rõ ràng hơn, tránh multi-level alias trong query path.

Nhược điểm: mỗi lần reshard topic con phải tìm và update tất cả group aliases có chứa topic đó.

Khuyến nghị v1:

- Cho phép group alias trỏ logical topic alias nếu mục tiêu là group query luôn đọc current version.
- Không dùng group alias cho writes.
- Audit `LISTALIASES` trước/sau cutover để biết alias nào bị ảnh hưởng.
- Validate lại các group aliases chứa topic vừa reshard sau cutover.
- Tránh dùng `followAliases=true` cho collection admin commands trong case multi-level alias + shadow alias.

## 6. Data Flow End-To-End

### 6.1 Trước reshard

Hiện tại:

```text
App read/write -> old physical collection topic_100001
```

Nếu đã adopt alias:

```text
App read/write -> alias topic_100001 -> physical collection topic_100001_v2
```

### 6.2 Detect

Nightly job chạy mỗi đêm:

```text
GET /solr/topic_100001/select?q=*:*&rows=0&wt=json
```

Job lấy:

- `numFound`.
- Shard count hiện tại từ `CLUSTERSTATUS`.
- Alias mapping nếu collection đã có alias.

Candidate rule ví dụ:

```text
doc_count >= 40_000_000
and current_num_shards < desired_num_shards
and no active migration for same topic
```

Shard planning ví dụ:

```text
target_docs_per_shard = 20_000_000
desired_num_shards = ceil(doc_count / target_docs_per_shard)
desired_num_shards = clamp(desired_num_shards, min=2, max=16)
```

Với `topic_100001` có 40M docs:

```text
current_num_shards = 1
desired_num_shards = 2
target collection = topic_100001_v2
```

### 6.3 Tạo target collection

Tạo collection mới:

```text
CREATE collection topic_100001_v2
  collection.configName=topic_conf
  router.name=compositeId
  numShards=desired_num_shards
  replicationFactor=current_or_policy_replication_factor
```

Lưu ý:

- Dùng cùng configset để tránh schema drift.
- Không đổi analyzer/schema trong flow reshard v1.
- Nếu `id` không có route prefix của `compositeId`, Solr vẫn hash `id` để route docs. Phân phối có thể chấp nhận được nếu `id` đủ ngẫu nhiên.

### 6.4 Capture initial watermark

Trước khi full copy, lấy max `_version_` trên old collection:

```text
q=*:*
rows=1
sort=_version_ desc
fl=_version_
```

Gọi giá trị này là:

```text
initial_watermark = max_old_version_before_full_copy
```

Watermark này dùng để bắt các insert/update phát sinh trong lúc full copy đang chạy.

### 6.5 Full copy

Full copy toàn bộ docs từ old sang new bằng cursor pagination:

```text
source: topic_100001
target: topic_100001_v2
query:  q=*:*
sort:   id asc
fl:     stored fields needed for reindex
cursor: cursorMark
batch:  500-5000 docs, tùy heap/network
```

Khuyến nghị:

- Sort full copy bằng `id asc`, vì `id` là uniqueKey và ổn định.
- Không gửi `_version_` của source sang target. Target sẽ tự sinh `_version_` mới.
- Nếu copy qua `/select`, chỉ lấy được stored fields. Các field `stored=false` cần được regenerate qua `copyField` hoặc lấy từ nguồn gốc.
- Commit theo batch lớn hoặc time-based, tránh commit mỗi batch nhỏ.
- Persist `cursorMark`, copied count, last batch time vào DB để resume.

### 6.6 Delta sync

Sau full copy, chạy delta từ old sang new:

```text
q=_version_:{last_watermark TO *]
sort=_version_ asc,id asc
fl=stored fields
```

Mỗi batch:

```text
1. Read docs from old where _version_ > last_watermark.
2. Upsert docs into new.
3. Update last_watermark = max(_version_) in processed batch.
4. Persist progress.
```

Lặp đến khi:

- Delta backlog nhỏ.
- Hoặc thời gian migrate vượt SLA.
- Hoặc sẵn sàng vào cutover window.

Lưu ý:

- `_version_` bắt được insert/update còn tồn tại trong Solr.
- `_version_` không bắt được hard delete, vì doc đã bị xóa thì không còn query được.

### 6.7 Validate trước cutover

Validation tối thiểu:

1. Count check:

```text
old_count ~= new_count
```

2. Sample id check:

```text
Lấy N ids từ old theo hash/range/random.
Fetch old và new theo id.
Compare các field quan trọng.
```

3. Query smoke test:

```text
q=*:* rows=0
q=<top keyword> rows=10
facet/query business-critical nếu có
```

4. Cluster health:

```text
All target shards ACTIVE.
Replica count đúng policy.
No recovery/down replica.
```

Validation tolerance:

- Count có thể lệch tạm thời trong lúc write còn chạy.
- Trước cutover phải final sync và count difference nằm trong ngưỡng cho phép, tốt nhất là `0` nếu pause write được.

### 6.8 Cutover lần đầu bằng shadow alias

Vì app không đổi endpoint được, lần đầu cần giữ nguyên `/solr/topic_100001`. Cutover khuyến nghị:

```text
1. Pause/block writes for topic_100001.
2. Run final delta sync old -> new.
3. Validate count nhanh.
4. Create shadow alias topic_100001 -> topic_100001_v2.
5. Resume writes.
6. Writes now go to topic_100001_v2 through alias topic_100001.
```

Trạng thái trước cutover:

```text
App -> /solr/topic_100001 -> physical collection topic_100001
```

Trạng thái sau cutover:

```text
App -> /solr/topic_100001 -> alias topic_100001 -> physical collection topic_100001_v2
```

Lưu ý:

- Lần đầu nên pause write mạnh vì old physical collection `topic_100001` sẽ bị shadow alias che đi.
- Không nên phụ thuộc vào post-cutover reconcile từ `/solr/topic_100001`, vì path này sau cutover đã đi vào new.
- Nếu cần reconcile sau cutover lần đầu, worker phải có cách truy cập old collection bằng tên/đường riêng không bị alias resolve, hoặc phải dùng write log/change log ngoài Solr.

### 6.9 Cutover từ lần reshard thứ 2 trở đi

Sau lần đầu, alias đã tồn tại:

```text
alias topic_100001 -> topic_100001_v2
```

Lần sau:

```text
source physical: topic_100001_v2
target physical: topic_100001_v3
```

Có 2 mode cutover:

**Mode strong consistency, có pause ngắn**

```text
1. Pause/block writes.
2. Final delta sync topic_100001_v2 -> topic_100001_v3.
3. Validate nhanh.
4. Update alias topic_100001 -> topic_100001_v3.
5. Resume writes.
```

**Mode eventual consistency, không pause**

```text
1. Delta sync topic_100001_v2 -> topic_100001_v3 đến khi backlog nhỏ.
2. Capture last_watermark_before_cutover.
3. Update alias topic_100001 -> topic_100001_v3.
4. App writes mới đi vào topic_100001_v3.
5. Post-cutover reconcile từ physical topic_100001_v2 sang topic_100001_v3.
6. Validate lại.
```

Mode không pause chỉ nên dùng nếu có conflict policy rõ ràng khi cùng một `id` được update ở cả old và new quanh thời điểm cutover.

### 6.10 Post-cutover reconcile không pause

Post-cutover reconcile từ lần 2 trở đi có thể làm được vì old physical collection vẫn có tên riêng, ví dụ `topic_100001_v2`.

Flow:

```text
1. Query old physical collection:
   topic_100001_v2 where _version_ > last_watermark_before_cutover
2. Với mỗi doc, fetch/check doc tương ứng ở new topic_100001_v3 nếu cần.
3. Apply conflict policy.
4. Upsert hoặc skip.
5. Validate lại.
```

Không được reconcile kiểu blind upsert nếu có khả năng app update cùng một doc sau cutover.

Race condition:

```text
T1: doc A update vào topic_100001_v2 ngay trước alias switch
T2: alias switch sang topic_100001_v3
T3: doc A update tiếp vào topic_100001_v3
T4: reconcile copy bản doc A từ v2 sang v3
```

Nếu blind upsert ở T4, bản cũ từ `v2` có thể ghi đè bản mới hơn trong `v3`. `_version_` của `v2` và `_version_` của `v3` không so sánh trực tiếp được vì mỗi collection sinh version riêng.

Conflict policy khuyến nghị:

```text
if doc id does not exist in new:
  insert into new
else if source.updated_at > target.updated_at:
  overwrite target
else:
  skip source doc
```

Điều kiện:

- Phải có application timestamp/version đáng tin, ví dụ `updated_at`, `man_updated_at`, hoặc một field version từ source-of-truth.
- Nếu không có timestamp/version đáng tin, không-pause sẽ có rủi ro stale overwrite hoặc miss update.

### 6.11 Rollback

Nếu chưa có write vào new sau cutover:

```text
Lần đầu: delete alias topic_100001 để physical old topic_100001 hiện lại.
Lần 2 trở đi: update alias topic_100001 -> previous physical collection.
```

Nếu đã có write vào new:

- Rollback thẳng về old có thể làm mất hoặc lệch data mới.
- Cần một trong các cơ chế:
  - pause write trước rollback,
  - replay write log new -> old,
  - dual-write tạm thời trong cutover window,
  - chấp nhận rollback chỉ là routing rollback và cần reconcile ngược.

## 7. DB History Design

### 7.1 Bảng `topic_reshard_runs`

Mục đích: một row cho một lần reshard một topic.

Suggested fields:

```text
id
topic_id
logical_name
source_collection
target_collection
alias_name
source_num_shards
target_num_shards
source_doc_count_at_detect
threshold_doc_count
target_docs_per_shard
cutover_mode
conflict_policy
status
initial_watermark
last_watermark
full_copy_cursor
full_copy_copied_count
delta_copied_count
validation_result
error_code
error_message
created_at
started_at
cutover_at
finished_at
updated_at
```

Suggested statuses:

```text
DETECTED
PLANNED
CREATING_TARGET
TARGET_READY
FULL_COPYING
DELTA_SYNCING
VALIDATING
READY_FOR_CUTOVER
CUTOVER_IN_PROGRESS
CUTOVER_DONE
RECONCILING
DONE
FAILED
ROLLBACK_IN_PROGRESS
ROLLED_BACK
```

### 7.2 Bảng `topic_reshard_events`

Mục đích: audit trail từng step.

Suggested fields:

```text
id
run_id
event_type
status
message
payload_json
created_at
```

Event examples:

```text
DETECT_MATCHED
TARGET_CREATE_REQUESTED
TARGET_CREATE_SUCCEEDED
FULL_COPY_BATCH_DONE
DELTA_BATCH_DONE
VALIDATION_FAILED
CUTOVER_ALIAS_UPDATED
ROLLBACK_ALIAS_UPDATED
```

### 7.3 Locking

Cần đảm bảo chỉ có một migration active cho một topic:

```text
unique active lock on topic_id where status not in (DONE, FAILED, ROLLED_BACK)
```

Hoặc dùng distributed lock nếu có nhiều workers.

## 8. Lưu Ý Về Solr Update Path

Current config có update chain:

```text
SkipExistingDocumentsProcessorFactory
skipInsertIfExists=true
```

Rủi ro:

- Khi final sync/reconcile, nếu doc đã tồn tại trong target nhưng source có version mới hơn, update có thể bị skip.
- Điều này không đúng với upsert migration.

Khuyến nghị:

- Tạo update handler/chain riêng cho migration, ví dụ `/update/migrate`.
- Chain migration phải cho phép upsert theo `id`.
- Migration worker dùng endpoint này thay vì endpoint default nếu default đang skip existing.

Expected behavior:

```text
same id not exists in target -> insert
same id exists in target -> overwrite/upsert latest source doc
```

Nếu business muốn “bỏ qua doc đã tồn tại” ở final reconcile, cần ghi rõ đây là data policy, nhưng policy này có rủi ro bỏ sót updates.

## 9. Xử Lý Deletes

`_version_` không đủ để detect hard delete.

Nếu production có delete:

Option recommended:

```text
soft delete field, ví dụ is_deleted=true
```

Delta sync sẽ copy update `is_deleted=true` sang target.

Alternative:

```text
app-level change log / tombstone table
```

Trong v1, nếu không có delete handling:

```text
Assumption: không có hard delete trong migration window
```

Assumption này cần được validate với ingestion/app team.

## 10. Độ Khả Thi

### 10.1 Local PoC

Khả thi cao.

Repo đã có:

- SolrCloud local.
- Configset.
- Sample collection.
- Script tạo collection.
- Schema có `_version_`.

Có thể thêm script PoC:

```text
topic_4777 -> topic_4777_v2
copy sample docs
create alias
switch alias
validate count
```

### 10.2 Production

Khả thi trung bình-cao.

Phụ thuộc vào:

- Shadow alias có được chấp nhận như cơ chế giữ nguyên endpoint app không.
- Có DB để lưu history không.
- Có scheduler/worker runtime không.
- Lần đầu có pause write đủ mạnh không.
- Từ lần 2 có pause write, hoặc có post-cutover reconcile + conflict policy đáng tin không.
- Có hard delete không.

### 10.3 Zero downtime

Khả thi trung bình.

Read downtime có thể gần 0 nếu alias switch nhanh.

Write consistency mới là điểm khó:

- Lần đầu nên pause write mạnh khi tạo shadow alias.
- Từ lần 2 có thể không pause nếu có post-cutover reconcile và compare-before-upsert bằng timestamp/version đáng tin.
- Nếu không có timestamp/version đáng tin, vẫn nên pause write ngắn.

## 11. Risks Và Mitigations

### Risk 1: Production chưa có alias và app không đổi endpoint được

Impact:

- Cutover và rollback khó hơn.
- Lần đầu phải dùng shadow alias nếu muốn giữ nguyên `/solr/topic_100001`.
- Shadow alias làm physical old collection bị che bởi alias cùng tên.

Mitigation:

- Lần đầu pause write mạnh, final sync, validate rồi mới create shadow alias.
- Ghi runbook rõ: sau shadow alias, `/solr/topic_100001` là alias, không còn là path vào physical old collection.
- Từ lần 2 trở đi dùng alias update bình thường.

### Risk 2: `_version_` không track hard delete

Impact:

- New collection có thể giữ docs đã bị xóa ở old.

Mitigation:

- Soft delete.
- Tombstone/change log.
- Cấm hard delete trong migration window.

### Risk 3: Update chain skip existing

Impact:

- Delta/final sync có thể không update doc mới hơn vào target.

Mitigation:

- Dùng migration update handler/chain riêng cho upsert.

### Risk 4: Full copy 40M docs tốn tài nguyên

Impact:

- Tăng load source Solr.
- Tăng network IO.
- Có thể ảnh hưởng query latency.

Mitigation:

- Batch size có config.
- Rate limit.
- Chạy giờ thấp điểm.
- Retry/backoff.
- Theo dõi QPS, latency, heap, GC, replica health.

### Risk 5: Rollback sau khi new đã nhận writes

Impact:

- Old collection thiếu writes mới.
- Lần đầu rollback bằng delete shadow alias có thể đưa app về old nhưng old không có writes đã vào new sau cutover.

Mitigation:

- Pause write khi rollback.
- Replay write log.
- Dual-write tạm thời.
- Định nghĩa rollback window ngắn.

### Risk 6: Không pause từ lần 2 có thể stale overwrite

Impact:

- Post-cutover reconcile từ old sang new có thể ghi đè bản mới hơn đã được app update vào new sau alias switch.

Mitigation:

- Không dùng blind upsert khi reconcile không pause.
- Dùng application timestamp/version đáng tin để compare-before-upsert.
- Nếu không có timestamp/version đáng tin, vẫn nên pause ngắn ở cutover.

### Risk 7: Validation không đủ sau migrate

Impact:

- Cutover sang collection thiếu/lệch data.

Mitigation:

- Count + sample id compare + query smoke test.
- Lưu validation result vào DB.
- Không cho cutover nếu validation fail.

### Risk 8: Group alias bị đổi dữ liệu ngầm sau cutover topic con

Impact:

- Group alias như `topic_100011 -> topic_100001,topic_100002,topic_100003` có thể bắt đầu đọc `topic_100001_v2` sau khi `topic_100001` trở thành shadow alias.
- Nếu team vận hành nghĩ `topic_100011` vẫn đọc old physical `topic_100001`, validate/query result có thể bị hiểu sai.
- Multi-level alias + shadow alias làm admin commands với `followAliases=true` khó dự đoán hơn.

Mitigation:

- Audit `LISTALIASES` trước và sau cutover.
- Ghi rõ policy group alias dùng logical topic alias hay physical collection version.
- Validate lại các group aliases có chứa topic vừa reshard sau cutover.
- Không dùng standard group alias nhiều collections cho update/write.
- Tránh dùng `followAliases=true` với collection admin commands trong case multi-level alias + shadow alias.

## 12. Execution Phases

### Phase 1: Design và local PoC

- Viết script tạo target collection `topic_4777_v2`.
- Copy docs local từ `topic_4777` sang `topic_4777_v2`.
- Test shadow alias cùng tên collection để mô phỏng production không đổi endpoint.
- Test rollback lần đầu bằng delete shadow alias.
- Validate count.
- Document Solr API commands.

Exit criteria:

- Demo được full flow trên local SolrCloud.
- Biết rõ update chain nào sẽ dùng cho migration.

### Phase 2: Production readiness design

- Chốt shadow alias strategy cho lần đầu.
- Chốt flow từ lần 2: pause ngắn hay không pause + post-cutover reconcile.
- Chốt DB schema.
- Chốt scheduler/worker runtime.
- Chốt delete handling.
- Chốt conflict policy khi reconcile không pause.

Exit criteria:

- Design được review bởi app, ingestion, infra team.

### Phase 3: Implement worker

- Implement detector.
- Implement collection planner.
- Implement migration worker.
- Implement validation.
- Implement cutover/rollback controller.
- Implement metrics/alerts.

Exit criteria:

- Chạy được dry-run trên staging.
- Resume/retry được khi worker restart.

### Phase 4: Staging load test

- Tạo topic staging size lớn.
- Chạy full copy + delta.
- Đo source Solr impact.
- Test fail/retry.
- Test rollback.

Exit criteria:

- Có throughput estimate.
- Có SLA cutover window.
- Có runbook.

### Phase 5: Production rollout

- Bắt đầu với một topic risk thấp.
- Chạy detect dry-run trước.
- Chạy migrate không cutover.
- Manual approve cutover.
- Sau vài lần ổn định mới cân nhắc auto-cutover.

Exit criteria:

- Topic đầu tiên reshard thành công.
- Old collection được giữ theo retention.
- Metrics và alert hoạt động.

## 13. Operational Metrics

Cần expose/log:

```text
reshard detected candidates
active migrations
full copy docs/sec
delta docs/sec
delta backlog
last watermark lag
source query latency
target update latency
validation failures
cutover duration
rollback count
post cutover reconcile docs
reconcile skipped stale docs
reconcile conflicts
```

Alert examples:

```text
migration stuck > X hours
delta backlog increasing for Y minutes
target replica down
validation failed
cutover failed
rollback triggered
```

## 14. Acceptance Criteria

Cho topic example `topic_100001`:

```text
Given topic_100001 has 1 shard and >= 40M docs
When nightly detect job runs
Then a reshard run is created in DB
And target collection topic_100001_v2 is created with desired shard count
And all source docs are copied to target
And updates during migration are delta synced
And validation passes
And first cutover creates shadow alias topic_100001 -> topic_100001_v2 without requiring app endpoint changes
And old collection is retained
And first rollback can delete shadow alias within defined rollback window
And later reshard runs can update alias from vN to vN+1
```

## 15. Open Decisions

Cần chốt trước khi implement production:

1. Lần đầu có chấp nhận shadow alias cùng tên collection để giữ nguyên endpoint app không?
2. Hệ thống có hard delete mentions trong migration window không?
3. Lần đầu có thể pause writes cho từng topic trong vài giây/phút khi cutover không?
4. Worker sẽ viết bằng ngôn ngữ/runtime nào?
5. DB nào sẽ lưu history?
6. Target docs per shard là bao nhiêu: 10M, 20M, 40M?
7. Replication factor khi tạo target collection sẽ giữ như old hay tăng theo policy mới?
8. Từ lần 2 có cho phép không pause không, và nếu có thì dùng field nào làm conflict policy?
9. Group alias policy sẽ dùng logical topic aliases hay physical collection versions?
10. Cutover v1 manual approval hay auto-cutover?

## 16. Research Keywords

```text
Solr shadow alias
Solr alias same name as collection
Solr collection alias hides collection
Solr alias multiple collections
Solr multi-level aliases
Solr standard alias updates multiple collections
Solr ExactStatsCache multiple collections alias
Solr CREATEALIAS DELETEALIAS
Solr followAliases true
SolrCloud reindex collection with more shards
SolrCloud splitshard vs reindex
Solr cursorMark pagination
Solr _version_ watermark delta sync
Solr hard delete tombstone soft delete
Solr update request processor chain upsert
Solr post cutover reconcile
Solr alias cutover zero downtime
```

## 17. References

- Solr Collection Management: https://solr.apache.org/guide/solr/latest/deployment-guide/collection-management.html
- Solr Aliases: https://solr.apache.org/guide/solr/latest/deployment-guide/aliases.html
- Solr Cursor Pagination: https://solr.apache.org/guide/solr/latest/query-guide/pagination-of-results.html
- Solr Partial Updates and `_version_`: https://solr.apache.org/guide/solr/latest/indexing-guide/partial-document-updates.html
