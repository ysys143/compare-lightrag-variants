# RAG-Anything: Memory & Disk Access Pattern Analysis

대용량 문서 ingest/query 시 메모리 사용 패턴과 디스크 접근 패턴을 분석한 문서.

---

## 1. Memory Usage Patterns

### 1.1 Ingest Pipeline Memory Flow

#### Phase 1: 문서 파싱 (`processor.py:280-456`)

| 단계 | 메모리 특성 | 위험도 |
|------|------------|--------|
| PDF 파싱 (`asyncio.to_thread`) | 전체 파싱 결과 `content_list`를 메모리에 일괄 로드 | HIGH |
| 캐시 저장 (`_store_cached_result`) | `content_list` 전체를 JSON으로 직렬화하여 KV 저장소에 저장 | HIGH |
| doc_id 생성 (`_generate_content_based_doc_id`) | 모든 content_list 항목의 텍스트를 `"\n".join()`으로 합침 | MEDIUM |

핵심 문제: `content_list`가 한 번에 메모리에 올라옴. 100페이지 PDF라면 수백 개의 content block이 리스트로 상주. 스트리밍/제너레이터 패턴 없음.

#### Phase 2: 콘텐츠 분리 (`utils.py:13-56`)

```python
text_parts = []          # 모든 텍스트를 리스트에 축적
multimodal_items = []    # 모든 멀티모달 항목을 리스트에 축적
text_content = "\n\n".join(text_parts)  # 전체 텍스트를 하나의 거대 문자열로 합침
```

`content_list` + `text_parts` + `text_content` + `multimodal_items` 가 동시에 메모리에 존재하여 원본 데이터의 약 3배 메모리를 사용한다.

#### Phase 3: LightRAG 텍스트 삽입 (`utils.py:146-178`)

- `lightrag.ainsert(input=text_content)` — 합쳐진 전체 텍스트를 LightRAG에 전달
- LightRAG 내부에서 chunking, embedding, entity extraction 수행
- 이 시점에서 `text_content`(거대 문자열) + LightRAG 내부 chunk들이 동시 상주

#### Phase 4: 멀티모달 처리 (`processor.py:458-528`, `modalprocessors.py`)

각 멀티모달 아이템마다:
1. `content_source`(전체 `content_list`)를 `context_extractor`에 설정 — 원본 유지
2. 이미지: base64 인코딩 — 원본 파일 크기의 약 1.33배 문자열 생성
3. LLM 호출 — 응답 문자열
4. entity/chunk 생성 — VDB에 upsert

이미지 메모리 스파이크: `_encode_image_to_base64()`가 이미지를 읽고 base64 문자열을 생성. 10MB 이미지는 약 13.3MB 문자열이 됨. 다행히 각 이미지는 개별 처리 후 참조가 사라지므로 GC 대상이 됨.

#### Phase 5: Batch 처리 (`batch.py`, `batch_parser.py`)

| 방식 | 동시성 제어 | 메모리 영향 |
|------|-----------|------------|
| `process_folder_complete` | `asyncio.Semaphore(max_workers)` | semaphore가 동시 파일 수를 제한하지만, 모든 Task 객체는 즉시 생성 |
| `BatchParser.process_batch` | `ThreadPoolExecutor(max_workers)` | 스레드풀이 제한하지만, `future_to_file` 딕셔너리에 모든 future가 즉시 할당 |
| `process_documents_with_rag_batch` | 순차 처리 (`for file_path in ...`) | RAG 삽입은 직렬 — 안전하지만 느림 |

핵심 문제: `max_workers=4`라도 모든 파일에 대한 future/task 객체가 한 번에 생성됨. 1000개 파일이면 1000개 Task 객체.

---

### 1.2 Query Pipeline Memory

#### 텍스트 쿼리 (`query.py:100-161`)
메모리 부담 낮음. LightRAG에 위임, 결과 문자열만 반환.

#### 멀티모달 쿼리 (`query.py:163-301`)

| 단계 | 메모리 사용 |
|------|-----------|
| 캐시 키 생성 | `multimodal_content` 전체를 JSON 직렬화 후 MD5 |
| `_process_multimodal_query_content` | 각 콘텐츠에 대해 LLM 호출, description 문자열 축적 |
| enhanced_query 조립 | `"\n".join(enhanced_parts)` — 모든 description을 하나로 합침 |
| 캐시 저장 | 결과를 `llm_response_cache`에 저장 |

일반적으로 안전: 쿼리 시 멀티모달 콘텐츠 수는 적음 (1~5개).

#### VLM 강화 쿼리 (`query.py:303-370`, `539-740`)

```python
self._current_images_base64 = []  # 인스턴스 변수에 축적

for each image match:
    image_base64 = encode_image_to_base64(image_path)
    self._current_images_base64.append(image_base64)    # 메모리에 축적
```

문제점:
1. `_current_images_base64`가 인스턴스 변수로 저장 — 쿼리 완료 후에도 GC되지 않음 (다음 쿼리 시 `delattr`로 해제)
2. `_build_vlm_messages_with_images`에서 base64를 `data:image/jpeg;base64,...` URL로 재구성 — 추가 문자열 할당
3. 검색 결과에 이미지가 10개면 수십~수백 MB의 base64 문자열이 인스턴스에 상주

---

### 1.3 Memory Hotspot Summary

```
위험도 순위:

1. [HIGH]   content_list 일괄 로드 (파싱)
            대용량 PDF -> 수천 개 블록이 한 번에 메모리
            스트리밍/제너레이터 패턴 없음

2. [HIGH]   텍스트 합침 ("\n\n".join)
            content_list + text_parts + text_content 3중 복사
            500페이지 논문 -> 수 MB ~ 수십 MB 문자열

3. [MEDIUM] 이미지 base64 인코딩
            개별 처리되지만 VLM 쿼리 시 인스턴스에 축적
            _current_images_base64가 명시적 해제 전까지 상주

4. [MEDIUM] 배치 처리 시 전체 Task/Future 즉시 생성
            Semaphore가 실행은 제한하지만 객체 생성은 제한 안 함

5. [LOW]    캐시 저장
            content_list 전체를 JSON 직렬화하여 KV 저장소에 upsert
            저장 후 원본이 해제되지 않음

6. [LOW]    쿼리 파이프라인
            일반적으로 소량 데이터 처리, 안전
```

---

## 2. Filesystem Access Patterns

### 2.1 Ingest 시 파일시스템 접근

#### 파싱 단계

```
[READ] 원본 문서 (PDF/이미지/Office)
  processor.py:347  -> asyncio.to_thread(doc_parser.parse_pdf, ...)
  processor.py:366  -> asyncio.to_thread(doc_parser.parse_image, ...)
  processor.py:397  -> asyncio.to_thread(doc_parser.parse_office_doc, ...)

[WRITE] 파서 출력 디렉토리
  parser.py:69-88   -> _unique_output_dir(): base_dir/stem_hash8/ 생성
  MinerU/Docling 내부 -> 이미지 추출, JSON, MD 출력 파일 생성

[READ/WRITE] Office -> PDF 변환 (parser.py:91-228)
  tempfile.TemporaryDirectory() -> 임시 PDF 생성
  subprocess(libreoffice --headless) -> 외부 프로세스
  shutil.copy2() -> 최종 PDF를 output_dir로 복사

[READ/WRITE] Text -> PDF 변환 (parser.py:230-461)
  open(text_path, "r") -> 전체 텍스트 읽기
  SimpleDocTemplate.build() -> PDF 파일 쓰기
```

#### 멀티모달 처리

```
[READ] 이미지 base64 인코딩
  modalprocessors.py:817  -> open(image_path, "rb").read() -> 전체 파일 한번에
  utils.py:70             -> 동일 패턴

[STAT] 이미지 검증 (utils.py:78-143)
  path.exists()      -> 존재 확인
  path.is_symlink()  -> 심볼릭 링크 차단
  path.stat().st_size -> 크기 확인 (max 50MB)
```

#### 캐시/스토리지

```
[READ/WRITE] KV 스토리지 (LightRAG 내부)
  parse_cache.upsert()                     -> content_list JSON 저장
  parse_cache.get_by_id()                  -> 캐시 조회
  parse_cache.index_done_callback()        -> 디스크 flush
  text_chunks_db.upsert()                  -> chunk 저장
  chunks_vdb.upsert()                      -> 벡터 DB 저장
  entities_vdb.upsert()                    -> 엔티티 벡터 저장
  relationships_vdb.upsert()               -> 관계 벡터 저장
  knowledge_graph_inst.upsert_node/edge()  -> 그래프 저장

[STAT] 캐시 유효성 검사
  processor.py:157 -> file_path.stat().st_mtime -> 파일 수정 시간 비교
```

### 2.2 Query 시 파일시스템 접근

```
[READ] VLM 강화 쿼리 (query.py:539-656)
  validate_image_file()     -> stat() 3회 (exists, is_symlink, st_size)
  Path.resolve()            -> 절대 경로 해석
  Path.is_relative_to()     -> 보안 검사 (CWD, working_dir, parser_output_dir)
  encode_image_to_base64()  -> open("rb") + read() 전체 파일

[READ] 캐시 조회
  llm_response_cache.get_by_id() -> 캐시 히트 시 파일 접근 없음
```

### 2.3 Batch 시 파일시스템 접근

```
[READ] 파일 탐색
  batch.py:87         -> folder_path_obj.glob("**/*{ext}") -> 재귀 탐색
  batch_parser.py:138 -> path.rglob("*") -> 재귀 탐색
  batch_parser.py:146 -> path.glob("*")  -> 단일 레벨

[WRITE] 출력 디렉토리
  batch.py:99         -> output_path.mkdir(parents=True, exist_ok=True)
  batch_parser.py:179 -> file_output_dir.mkdir(parents=True, exist_ok=True)
```

### 2.4 Access Pattern 특성 요약

| 패턴 | 위치 | 특성 |
|------|------|------|
| 전체 파일 일괄 읽기 | 이미지 base64, 텍스트 변환 | `read()` 한 번에 전체 — 대용량 파일 시 메모리 스파이크 |
| Stat 폭풍 | VLM 쿼리 이미지 검증 | 이미지당 `exists()` + `is_symlink()` + `stat()` = 3회 syscall |
| 재귀 glob | 배치 파일 탐색 | 폴더 구조 깊으면 느림, 결과를 리스트로 즉시 수집 |
| 임시 파일 + 복사 | Office -> PDF 변환 | `TemporaryDirectory` + `shutil.copy2` — 디스크 I/O 2배 |
| 동기 I/O in async | 파싱 | `asyncio.to_thread()`로 감싸서 이벤트 루프 블로킹은 방지 |
| 캐시 mtime 검사 | 파싱 캐시 | 매 호출마다 `stat().st_mtime` — 파일 수 많으면 syscall 누적 |

---

## 3. Disk Random Access 분석

### 3.1 Random Access 발생 지점

#### KV Storage (JSON 기반)

LightRAG의 KV 저장소는 JSON 파일 기반. 모든 `upsert`/`get_by_id`가 파일 단위 read-modify-write.

```
modalprocessors.py:491  -> text_chunks_db.upsert({chunk_id: data})
modalprocessors.py:503  -> chunks_vdb.upsert(chunk_vdb_data)
modalprocessors.py:529  -> entities_vdb.upsert(entity_vdb_data)
modalprocessors.py:766  -> relationships_vdb.upsert(relation_vdb_data)
modalprocessors.py:515  -> knowledge_graph_inst.upsert_node(name, data)
modalprocessors.py:749  -> knowledge_graph_inst.upsert_edge(src, tgt, data)
modalprocessors.py:703  -> text_chunks_db.get_by_id(chunk_id)

processor.py:152        -> parse_cache.get_by_id(cache_key)
processor.py:273        -> parse_cache.upsert(cache_data)
processor.py:483        -> doc_status.get_by_id(doc_id)
```

#### 1개 멀티모달 아이템 처리 시 최소 Random Access 횟수

```
text_chunks_db.upsert()        -> [SEEK+WRITE] x1
chunks_vdb.upsert()            -> [SEEK+WRITE] x1
entities_vdb.upsert()          -> [SEEK+WRITE] x1
knowledge_graph.upsert_node()  -> [SEEK+WRITE] x1
text_chunks_db.get_by_id()     -> [SEEK+READ]  x1  (extraction)
chunks_vdb.upsert()            -> [SEEK+WRITE] x1  (중복: 같은 chunk 재 upsert)
extract_entities()             -> [SEEK+READ/WRITE] xN  (LLM 캐시 조회/저장)
merge_nodes_and_edges()        -> [SEEK+WRITE] xM  (엔티티/관계 수에 비례)
knowledge_graph.upsert_edge()  -> [SEEK+WRITE] xK  (belongs_to 관계 수)
relationships_vdb.upsert()     -> [SEEK+WRITE] xK
_insert_done()                 -> [FSYNC] x1       (모든 스토리지 flush)
---------------------------------------------------------------
최소 ~10회 + (N+M+K)회 random I/O per multimodal item
```

#### Vector DB (벡터 인덱스)

```
chunks_vdb.upsert()         -> 벡터 인덱스 업데이트 (HNSW/FAISS 등)
entities_vdb.upsert()       -> 벡터 인덱스 업데이트
relationships_vdb.upsert()  -> 벡터 인덱스 업데이트
```

벡터 인덱스 특성상 인접 노드 탐색 = random access. upsert마다:
1. 기존 인덱스 로드 (또는 mmap)
2. 새 벡터 삽입 위치 탐색 (HNSW: 다단계 hop)
3. 인접 리스트 업데이트

인덱스 크기가 메모리 초과 시 페이지 폴트 + disk random read 폭발.

#### Graph Storage (Knowledge Graph)

```
modalprocessors.py:515  -> upsert_node(entity_name, node_data)
modalprocessors.py:749  -> upsert_edge(src, tgt, relation_data)
modalprocessors.py:703  -> get_by_id() (chunk 재조회)
```

그래프 저장소는 본질적으로 random access 구조:
- 노드 조회: hash lookup -> 디스크 상 임의 위치
- 엣지 삽입: src 노드, tgt 노드 양쪽 인접 리스트 업데이트
- 노드 수 증가 -> locality 악화

#### 이미지 파일 읽기

```python
# modalprocessors.py:817-819
with open(image_path, "rb") as image_file:
    encoded_string = base64.b64encode(image_file.read())
```

- 파서 출력 디렉토리에 추출된 이미지들은 파일명이 해시 기반 (`stem_hash8/`)
- 이미지 처리 순서가 content_list 순서(페이지 순)이므로 디렉토리 내 순차적이지만, 디스크 상 물리 위치는 랜덤
- HDD에서 다수 작은 이미지 파일 읽기 = random seek 폭풍

---

### 3.2 Random Access I/O 흐름

```
시간 -->

[문서 파싱]
  ========== (sequential read: 원본 PDF)
  ========== (sequential write: 파서 출력)

[텍스트 삽입 - LightRAG]
  -X-X-X-X-  (random: chunk KV upsert)
  --X--X--X  (random: vector index upsert)
  ---X---X-  (random: graph node/edge)
  ==========  (sequential: LLM 캐시 조회/저장 - 벌크)

[멀티모달 처리 - 아이템별 반복]
  ==         (sequential: 이미지 파일 read)
  -X-X-X-X-  (random: chunk KV)
  --X--X---  (random: entity VDB)
  ---X---X-  (random: relationship VDB)
  ----X----  (random: graph node)
  -----X---  (random: graph edge xK)
  ==========  (random: extract_entities - LLM캐시 + merge)
  F          (fsync: _insert_done)
  [다음 아이템... 위 패턴 반복]

[캐시 저장]
  FFF        (random write: parse_cache.upsert)
  F          (fsync: index_done_callback)

범례: = sequential, X random access, F write/flush, - idle/wait
```

---

### 3.3 규모별 Random Access 추정

#### Case: 100페이지 PDF, 이미지 50장, 테이블 20개, 수식 30개

| Phase | Random Access 횟수 (추정) |
|-------|--------------------------|
| 텍스트 chunking | ~50회 (chunk 수에 비례) |
| 텍스트 entity extraction | ~200회 (entity/relation 추출) |
| 이미지 x50 | 50 x ~15 = ~750회 |
| 테이블 x20 | 20 x ~15 = ~300회 |
| 수식 x30 | 30 x ~15 = ~450회 |
| 캐시 저장 | ~5회 |
| doc_status 체크 | ~100회 (아이템마다 체크) |
| **합계** | **~1,855회 random disk I/O** |

---

### 3.4 중복/불필요 Random Access

| 위치 | 문제 | 낭비 |
|------|------|------|
| `chunks_vdb.upsert()` 이중 호출 | `_create_entity_and_chunk()` (line 503)에서 한 번, `_process_chunk_for_extraction()` (line 719)에서 같은 `chunk_id`로 다시 upsert | 아이템당 1회 불필요 |
| `text_chunks_db.get_by_id()` | `_process_chunk_for_extraction()`에서 방금 upsert한 chunk를 즉시 다시 읽음 (line 703) | 아이템당 1회 불필요 |
| `doc_status.get_by_id()` | `_process_multimodal_content()`에서 매번 상태 확인 (processor.py:483) — 동일 doc_id를 아이템마다 반복 조회 | (N-1)회 불필요 |
| `_insert_done()` per item | 배치 모드가 아닌 경우 아이템마다 flush (line 791) | (N-1)회 불필요 |

제거 가능한 불필요 random access (100 아이템 기준):
```
아이템당 3회 x 100 아이템 = 300회 절약 가능
+ _insert_done 99회 절약 (100 -> 1)
= 약 ~400회 random I/O 절감 가능 (전체의 ~22%)
```

---

## 4. Improvement Recommendations

### 4.1 Memory

| 문제 | 개선 방향 | 예상 효과 |
|------|----------|----------|
| content_list 일괄 로드 | 스트리밍 파싱: 제너레이터/이터레이터로 블록 단위 yield | 피크 메모리 대폭 감소 |
| 텍스트 3중 복사 | `separate_content()`에서 text_content를 리스트 유지, join은 insert 직전에만 | 중간 메모리 ~33% 절감 |
| 이미지 base64 축적 | 처리 후 즉시 `del`, 또는 디스크 기반 임시 파일 사용 | VLM 쿼리 메모리 스파이크 제거 |
| 배치 Task 즉시 생성 | `asyncio.as_completed()` + 동적 Task 생성, 또는 `asyncio.TaskGroup` with bounded semaphore | 대규모 배치 시 객체 메모리 절감 |
| 캐시 직렬화 | 대용량 content_list는 디스크에 직접 저장하고 참조만 캐시 | 캐시 메모리 사용 감소 |
| VLM `_current_images_base64` | 쿼리 완료 시 `finally` 블록에서 확실히 해제, 또는 지역 변수로 전달 | 잔류 메모리 제거 |

### 4.2 Disk Access

| 문제 | 개선 방향 | 예상 효과 |
|------|----------|----------|
| chunk 이중 upsert | `_process_chunk_for_extraction()`에서 `chunks_vdb.upsert()` 제거 | 아이템당 -1 random write |
| 방금 쓴 chunk 재읽기 | `_create_entity_and_chunk()`에서 chunk_data를 리턴하여 전달 | 아이템당 -1 random read |
| doc_status 반복 조회 | `_process_multimodal_content()` 진입 시 1회만 조회, 결과 캐싱 | (N-1)회 절감 |
| 아이템별 `_insert_done()` | `batch_mode=True`로 처리 후 마지막에 1회만 flush | (N-1)회 fsync 절감 |
| KV upsert 개별 호출 | write-behind 버퍼링: 메모리에 모아두고 배치 flush | random -> sequential 전환 |
| 벡터 인덱스 개별 upsert | 임베딩 배치 수집 후 `bulk_upsert` | 인덱스 재구축 횟수 감소 |
| stat 중복 호출 | `validate_image_file()`에서 3회 + `_process_image_paths_for_vlm()`에서 `Path.resolve()` — 같은 파일에 4~5회 syscall | 결과 캐싱으로 1회로 줄임 |
| 이미지 이중 읽기 | 파싱 시 MinerU가 이미지 추출 후, 멀티모달 처리 시 같은 이미지를 다시 `open("rb")` | 파싱 단계에서 base64 캐싱 |
| glob 즉시 materialize | `list(path.rglob("*"))` -> 수만 파일이면 Path 객체 리스트가 메모리 점유 | 이터레이터로 유지 |
| Office 변환 이중 쓰기 | temp dir에 PDF 생성 후 `shutil.copy2`로 output dir에 복사 | 직접 output dir에 생성 |
| 캐시 flush 빈도 | `parse_cache.index_done_callback()` — 파일마다 flush | 배치 완료 시 1회 flush |
