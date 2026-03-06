# 3개 프레임워크 Ingestion 파이프라인 상세 비교

> LightRAG vs RAG-Anything vs EdgeQuake — 소스코드 레벨 분석

---

## 1. LightRAG (원본)

### 1-1. 청킹 (Chunking)

**파일**: `lightrag/operate.py:99` — `chunking_by_token_size()`

```
기본값: chunk_token_size=1200, chunk_overlap_token_size=100
```

- 토큰 기반 슬라이딩 윈도우: `tokens[start : start + chunk_token_size]`, stride = `chunk_token_size - overlap`
- 선택적 `split_by_character` 지원 (특정 구분자로 먼저 분할 후 토큰 제한 초과 시 재분할)
- 출력: `{"tokens": int, "content": str, "chunk_order_index": int}` 딕셔너리 리스트

### 1-2. 엔티티 추출 (Entity Extraction)

**파일**: `lightrag/operate.py:2768` — `extract_entities()`

**프롬프트**: `lightrag/prompt.py:11` — `entity_extraction_system_prompt`

**구조**:
- **System prompt**: "You are a Knowledge Graph Specialist..." 로 시작, 8개 지침 포함
- **User prompt**: `entity_extraction_user_prompt` (line 63) — 입력 텍스트를 `<Input Text>` 블록으로 감싸서 전달
- **포맷**: 튜플 기반 (`<|#|>` 구분자)
  ```
  entity<|#|>entity_name<|#|>entity_type<|#|>entity_description
  relation<|#|>source<|#|>target<|#|>keywords<|#|>description
  <|COMPLETE|>
  ```

**기본 엔티티 타입** (`lightrag/constants.py:27`):
```
Person, Creature, Organization, Location, Event,
Concept, Method, Content, Data, Artifact, NaturalObject
```
- **11개 타입**, 동적 (사용자 `.env`에서 `ENTITY_TYPES` 오버라이드 가능)

**Few-shot 예시**: 3개 (캐릭터 관계, 주식시장, 육상 기록)

**LLM 호출 방식** (`operate.py:2847`):
```python
final_result, timestamp = await use_llm_func_with_cache(
    entity_extraction_user_prompt,
    use_llm_func,
    system_prompt=entity_extraction_system_prompt,
    llm_response_cache=llm_response_cache,  # 캐싱 지원
)
```
- `llm_model_max_async` (기본 4)개 청크 동시 처리 (세마포어)

### 1-3. 글리닝 (Gleaning)

**파일**: `lightrag/operate.py:2872`

- `entity_extract_max_gleaning` (기본값 `DEFAULT_MAX_GLEANING=1`, `constants.py:15`)
- **글리닝 프롬프트**: `entity_continue_extraction_user_prompt` (prompt.py:84)
  - "Based on the last extraction task, identify and extract any **missed or incorrectly formatted** entities..."
  - 이전 대화를 `history_messages`로 전달하여 컨텍스트 유지
- **머지 전략** (`operate.py:2894-2923`): description 길이 비교 → 더 긴 description 유지

### 1-4. 추출 결과 파싱

**파일**: `lightrag/operate.py:910` — `_process_extraction_result()`

1. `\n`으로 레코드 분리
2. LLM이 `<|#|>`를 레코드 구분자로 잘못 쓴 경우 자동 보정 (`fix_tuple_delimiter_corruption`)
3. 각 레코드를 `_handle_single_entity_extraction()` 또는 `_handle_single_relationship_extraction()`으로 파싱
4. 엔티티 이름 길이 제한: `DEFAULT_ENTITY_NAME_MAX_LENGTH=256` (constants.py:16)

**출력**: `(maybe_nodes: dict[str, list], maybe_edges: dict[tuple, list])`

### 1-5. 노드/엣지 머지 & 그래프 삽입

**파일**: `lightrag/operate.py:2398` — `merge_nodes_and_edges()`

**3-Phase 머지**:

**Phase 1 — 엔티티 머지** (`_merge_nodes_then_upsert`, line 1593):
1. 기존 노드 조회 (`knowledge_graph_inst.get_node(entity_name)`)
2. source_id 머지 (`merge_source_ids`) — FIFO 또는 KEEP 전략
3. entity_type 결정: Counter로 최다 출현 타입 선택 (line 1696)
4. description 중복 제거: 동일 description 필터링 후 timestamp 기준 정렬 (line 1704-1718)
5. **LLM 요약 호출** (`_handle_entity_relation_summary`, line 165): description 수가 `DEFAULT_FORCE_LLM_SUMMARY_ON_MERGE=8`개 초과 시 LLM으로 요약
   - 프롬프트: `summarize_entity_descriptions` (prompt.py:185) — "You are a Knowledge Graph Specialist, proficient in data curation and synthesis..."
   - 요약 길이: `DEFAULT_SUMMARY_LENGTH_RECOMMENDED=600` 토큰
6. 그래프에 upsert + entities_vdb에 임베딩 저장

**Phase 2 — 관계 머지** (`_merge_edges_then_upsert`, line 1871):
1. 기존 엣지 조회 (`has_edge` → `get_edge`)
2. weight 누적 합산 (line 2014)
3. keywords 집합 합침 (line 2017)
4. description LLM 요약 (엔티티와 동일 로직)
5. 그래프에 upsert + relationships_vdb에 임베딩 저장

**Phase 3**: `full_entities_storage`, `full_relations_storage` (문서별 엔티티/관계 목록) 갱신

### 1-6. 커뮤니티 디텍션 & 프루닝

- **커뮤니티 디텍션**: ingestion 시 **수행하지 않음**. 쿼리 시 동적으로 처리
- **프루닝**: `source_ids_limit` 방식으로 간접 프루닝
  - `max_source_ids_per_entity=300`, `max_source_ids_per_relation=300`
  - FIFO (기본): 오래된 source_id 제거
  - KEEP: 새 source_id 추가 차단

---

## 2. RAG-Anything (LightRAG 확장)

### 2-1. 진입점 & 문서 파싱

**파일**: `raganything/processor.py:1759` — `insert_content_list()`

```
User → process_document_complete() → parse_document() → insert_content_list()
```

**문서 파싱** (`processor.py:280-456`):
- PDF → MinerU 2.0 (기본), Docling, PaddleOCR 선택 가능
- 이미지 → MinerU fallback으로 VLM 분석
- Office 문서 → LibreOffice 변환
- 출력: `content_list` = `[{"type": "text|image|table|equation", ...}]`

**콘텐츠 분리** (`utils.py:13` — `separate_content()`):
- `type == "text"` → 텍스트 누적
- `type != "text"` → 멀티모달 아이템 목록으로 분리

### 2-2. 텍스트 경로 (LightRAG 표준)

**파일**: `utils.py:146` — `insert_text_content()`

```python
await lightrag.ainsert(input=text_content, file_paths=file_name)
```

→ **LightRAG 표준 파이프라인 그대로** 실행 (청킹 → 엔티티 추출 → 글리닝 → 머지)

### 2-3. 멀티모달 경로 (RAG-Anything 고유)

**파일**: `processor.py:706` — `_process_multimodal_content_batch_type_aware()`

#### Stage 1: VLM Description 생성

프로세서별 `generate_description_only()` 호출 (세마포어로 동시성 제어):

| 프로세서 | 클래스 위치 | 시스템 프롬프트 | 분석 프롬프트 |
|---------|----------|-------------|-----------|
| **이미지** | `modalprocessors.py:796` | "You are an expert image analyst" | vision_prompt: 이미지를 base64로 VLM에 전송, JSON 응답 요구 |
| **테이블** | `modalprocessors.py:1032` | "You are an expert data analyst" | table_prompt: HTML/markdown 테이블 구조 + 캡션 전달 |
| **수식** | `modalprocessors.py:1226` | "You are an expert mathematician" | equation_prompt: LaTeX 수식 + 형식 정보 전달 |
| **일반** | `modalprocessors.py:1410` | "You are an expert content analyst" | generic_prompt: 콘텐츠 타입별 동적 프롬프트 |

**프롬프트 구조** (`prompt.py`): 모든 프로세서가 동일한 JSON 응답 구조 요구:
```json
{
  "detailed_description": "...",
  "entity_info": {
    "entity_name": "자동 생성",
    "entity_type": "image|table|equation",
    "summary": "100단어 이내"
  }
}
```

**컨텍스트 추출** (`modalprocessors.py:49-309` — `ContextExtractor`):
- `context_window=1` (전후 1페이지), `max_context_tokens=2000`
- 페이지 기반 또는 청크 기반 주변 텍스트 추출 → 프롬프트에 추가

#### Stage 2: LightRAG 청크 형식 변환

**파일**: `processor.py:883` — `_convert_to_lightrag_chunks_type_aware()`

각 모달리티별 **청크 템플릿** 적용 (`prompt.py`):
- 이미지: `"Image Content Analysis:\nImage Path: {}\nCaptions: {}\nVisual Analysis: {}"`
- 테이블: `"Table Analysis:\nCaption: {}\nStructure: {}\nAnalysis: {}"`
- 수식: `"Mathematical Equation Analysis:\nEquation: {}\nFormat: {}\nAnalysis: {}"`

→ chunk_id = `compute_mdhash_id(formatted_content, prefix="chunk-")`

#### Stage 3: 스토리지 저장

**파일**: `processor.py:1006` — `_store_chunks_to_lightrag_storage_type_aware()`

```python
await lightrag.text_chunks.upsert(chunks)      # KV 저장
await lightrag.chunks_vdb.upsert(chunks)        # 벡터 임베딩 저장
```

#### Stage 4: 메인 엔티티 노드 생성 (RAG-Anything 고유)

**파일**: `processor.py:1023` — `_store_multimodal_main_entities()`

각 멀티모달 아이템에 대해 **별도 엔티티 노드** 생성:
```python
# 그래프에 노드 삽입
await knowledge_graph.upsert_node(entity_name, {
    "entity_id": entity_name,
    "entity_type": "image|table|equation",  # 모달리티 타입
    "description": summary,
    "source_id": chunk_id,
})
# 벡터DB에 엔티티 임베딩
await entities_vdb.upsert({entity_id: entity_data})
```

#### Stage 5: 엔티티 추출 (LightRAG 재사용)

**파일**: `processor.py:1176` — `_batch_extract_entities_lightrag_style_type_aware()`

```python
from lightrag.operate import extract_entities
chunk_results = await extract_entities(chunks=lightrag_chunks, ...)
```

→ 멀티모달 청크에 대해서도 LightRAG 표준 엔티티 추출 실행

#### Stage 6: belongs_to 관계 추가 (RAG-Anything 고유)

**파일**: `processor.py:1205` — `_batch_add_belongs_to_relations_type_aware()`

추출된 텍스트 엔티티를 멀티모달 메인 엔티티에 연결:
```
SARAH_CHEN --belongs_to--> Image_Figure_1
  keywords: "belongs_to,part_of,contained_in"
  weight: 10.0  (높은 가중치로 강한 연결)
```

#### Stage 7: 머지 (LightRAG 재사용)

**파일**: `processor.py:1269` — `_batch_merge_lightrag_style_type_aware()`

```python
from lightrag.operate import merge_nodes_and_edges
await merge_nodes_and_edges(chunk_results=enhanced_chunk_results, ...)
```

### 2-4. 전체 데이터 흐름 요약

```
PDF/이미지/Office 문서
    | parse_document() [MinerU/Docling/PaddleOCR]
    v
content_list: [{type: text, ...}, {type: image, ...}, ...]
    | separate_content()
    |-- 텍스트 --> lightrag.ainsert() --> [LightRAG 표준 파이프라인]
    |               +-- 청킹(1200t) --> 엔티티추출(LLM) --> 글리닝(1회) --> 머지(LLM요약)
    |
    +-- 멀티모달 아이템 --> 타입별 프로세서
        |-- Stage 1: VLM description 생성 (모달리티별 프롬프트)
        |-- Stage 2: 청크 템플릿 적용
        |-- Stage 3: text_chunks + chunks_vdb 저장
        |-- Stage 4: 메인 엔티티 노드 생성 (그래프 + 벡터)  [고유]
        |-- Stage 5: extract_entities() (LightRAG 재사용)
        |-- Stage 6: belongs_to 관계 추가                   [고유]
        +-- Stage 7: merge_nodes_and_edges() (LightRAG 재사용)
```

---

## 3. EdgeQuake (Rust 재구현)

### 3-1. 진입점 & PDF 처리

**파일**: `edgequake-api/src/processor/pdf_processing.rs`

**Vision 모드** (기본, `Cargo.toml` `default = ["postgres", "vision"]`):
```
PDF 업로드 --> edgequake-pdf2md::convert_from_bytes() --> Markdown
```

**적응형 파라미터**:

| 페이지 수 | 동시성 | DPI | 타임아웃 |
|----------|-------|-----|---------|
| <50 | 10 | 150 | 60s + 5s/page |
| 50-200 | 8 | 150 | 상동 |
| 200-500 | 5 | 120 | 상동 |
| 500+ | 3 | 100 | min 600s |

**체크포인트**: `FileCheckpointStore` (SHA-256 기반, 중단 후 재개 가능)

### 3-2. 청킹

**파일**: `edgequake-pipeline/src/chunker/mod.rs`

**적응형 청크 사이즈** (`ingestion.rs:42-64`):

| 문서 크기 | 청크 사이즈 | 오버랩 |
|----------|-----------|-------|
| <50KB | 1200 토큰 | 100 토큰 (8%) |
| 50-100KB | 800 토큰 | 66 토큰 |
| >100KB | 600 토큰 | 50 토큰 |

**토큰 추정**: 1 토큰 ≈ 4 characters (LightRAG의 tiktoken과 다른 방식)

**4가지 전략**: TokenBased (기본), SentenceBoundary, ParagraphBoundary, CharacterBased

**출력**: `TextChunk { id: "{doc_id}-chunk-{index}", content, index, start_offset, end_offset }`

### 3-3. 엔티티 추출

**파일**: `edgequake-pipeline/src/prompts/entity_extraction.rs`

**프롬프트**: LightRAG와 **거의 동일** (Rust로 포팅). 차이점:

| 항목 | LightRAG | EdgeQuake |
|-----|---------|----------|
| **기본 엔티티 타입** | 11개 (Person, Creature, Organization, Location, Event, Concept, Method, Content, Data, Artifact, NaturalObject) | **9개** (PERSON, ORGANIZATION, LOCATION, EVENT, CONCEPT, TECHNOLOGY, PRODUCT, DATE, DOCUMENT) |
| **타입 표기** | Title Case (Person) | UPPERCASE (PERSON) |
| **Few-shot 예시** | 3개 (캐릭터, 주식, 육상) | 3개 (캐릭터, 주식, 연구) — 내용 약간 다름 |
| **구분자** | `<\|#\|>` (동일) | `<\|#\|>` (동일) |
| **완료 신호** | `<\|COMPLETE\|>` (동일) | `<\|COMPLETE\|>` (동일) |

**핵심 차이**: EdgeQuake는 `Method, Content, Data, Artifact, NaturalObject, Creature` 제거하고 `TECHNOLOGY, PRODUCT, DATE, DOCUMENT` 추가 → **실용적 도메인에 최적화**

**설정** (`pipeline/mod.rs`):
```rust
extraction_batch_size: 10
max_concurrent_extractions: 16
chunk_extraction_timeout_secs: 180  // 로컬 LLM 고려
chunk_max_retries: 3
initial_retry_delay_ms: 1000
```

### 3-4. 글리닝 (Gleaning)

**파일**: `edgequake-pipeline/src/extractor/gleaning.rs`

```rust
GleaningConfig {
    max_gleaning: 1,       // 기본 1회
    always_glean: false,   // 첫 패스에서 엔티티 없으면 스킵
}
```

**프롬프트**: `continue_extraction_prompt()` (entity_extraction.rs:144)
- "Based on the last extraction task, identify and extract any **missed or incorrectly formatted** entities..."
- LightRAG 글리닝 프롬프트와 거의 동일

**머지 전략** (`gleaning.rs:175-217`):
- 엔티티: description 길이 비교 → 더 긴 것 유지
- 관계: description 길이 비교 → 더 긴 것 유지
- 중복 제거: normalized name 기준 (case-insensitive)

### 3-5. 엔티티 정규화 (EdgeQuake 고유)

**파일**: `edgequake-pipeline/src/prompts/normalizer.rs`

`normalize_entity_name()` (line 44):
```
1. 공백 trim
2. 접두사 제거: "The ", "A ", "An " (대소문자 무시)
3. 소유격 제거: "'s", "\u2019s"
4. Title case 변환
5. 공백 --> 언더스코어
6. 전체 대문자 변환
```

**예시**:
```
"John Doe"            --> "JOHN_DOE"
"The Company"         --> "COMPANY"
"Company's Products"  --> "COMPANY_PRODUCTS"
"  Sarah  Chen  "     --> "SARAH_CHEN"
"New-York"            --> "NEW-YORK"  (하이픈 보존)
"C++"                 --> "C++"       (특수문자 보존)
```

**효과**: 그래프 노드 중복 36-40% 감소 (동일 엔티티의 표기 변형 통합)

**LightRAG 비교**: LightRAG는 프롬프트에서 "title case" 지시만 하고 **코드 레벨 정규화 없음** → LLM 출력에 의존

### 3-6. 노드/엣지 머지

**파일**: `edgequake-pipeline/src/merger/mod.rs`

**3-Stage 프로세스** (line 118-158):

1. **엔티티 머지** (`entity.rs`):
   - normalized name으로 기존 노드 조회
   - description 머지: `use_llm_summarization=true` (기본) → LLM 요약, 실패 시 simple merge
   - importance: max 값 유지
   - source spans: 최대 `max_sources=10`개
   - `max_description_length=4096`

2. **관계 머지**: 동일 (src, tgt) 쌍의 description/keywords 통합

3. **통계 추적**:
   ```rust
   MergeStats {
       entities_created, entities_updated,
       relationships_created, relationships_updated, errors
   }
   ```

**Simple Merge 로직** (LLM 실패 시 fallback):
1. 기존 description 비어있으면 → 새 description 사용
2. 새 description이 기존에 포함되면 → 기존 유지
3. 새 description을 문장 단위로 분리 → 기존에 없는 문장만 추가
4. `max_description_length=4096`에서 문장 경계로 잘라냄

### 3-7. 벡터 임베딩

**파일**: `edgequake-core/src/orchestrator/ingestion.rs:284-309`

청크와 엔티티 모두 pgvector에 저장:
```json
// 청크 메타데이터
{"type": "chunk", "document_id": "...", "index": 0, "content": "..."}
// 엔티티 메타데이터
{"type": "entity", "entity_name": "...", "entity_type": "...", "description": "..."}
```

모든 벡터에 `tenant_id`, `workspace_id` 포함 → 멀티테넌시 격리

### 3-8. 커뮤니티 디텍션 (EdgeQuake 고유)

**파일**: `edgequake-storage/src/community.rs`

**3가지 알고리즘**:
1. **Louvain** (기본): 모듈러리티 최적화, `resolution` 파라미터로 커뮤니티 크기 조절
2. **Label Propagation**: 이웃 레이블 전파, 반복 수렴
3. **Connected Components**: 기본 연결 컴포넌트 (결정적)

```rust
CommunityConfig {
    algorithm: Louvain,
    min_community_size: 2,
    max_iterations: 100,
    resolution: 1.0,
}
```

**LightRAG/RAG-Anything 비교**: ingestion 시 커뮤니티 디텍션 **없음**

### 3-9. 비용/통계 추적 (EdgeQuake 고유)

**파일**: `edgequake-pipeline/src/pipeline/mod.rs:199-296`

```rust
ProcessingStats {
    chunk_count, successful_chunks, failed_chunks,
    entity_count, relationship_count,
    llm_calls, total_tokens, input_tokens, output_tokens,
    cost_usd, cost_breakdown,
    processing_time_ms,
    llm_model, embedding_model, embedding_dimensions,
    entity_types: Vec<String>,     // 추출된 엔티티 타입 목록
    relationship_types: Vec<String>,
    error_details,
}
```

### 3-10. 전체 데이터 흐름 요약

```
PDF 업로드 (REST API)
    | pdf_processing.rs
    | edgequake-pdf2md (pdfium --> 이미지 --> Vision LLM --> Markdown)
    | [적응형: 동시성/DPI/타임아웃, 체크포인트 지원]
    v
Markdown 텍스트
    | chunker/mod.rs
    | 적응형 청킹 (1200/800/600 토큰, 문서 크기 기반)
    v
TextChunk[]
    | entity_extraction.rs (LLM 호출, batch_size=10, max_concurrent=16)
    | 튜플 파싱: entity<|#|>name<|#|>type<|#|>desc
    |
    | normalizer.rs: UPPERCASE_UNDERSCORE 정규화  [고유]
    |
    | gleaning.rs: 1회 추가 추출 (놓친 엔티티)
    v
ExtractedEntity[] + ExtractedRelationship[]
    | merger/mod.rs (LLM 요약 + simple merge fallback)
    | 엔티티 중복 통합, 관계 weight 누적
    v
Knowledge Graph (Apache AGE)  [고유: 정규화된 이름으로 노드 저장]
    +
pgvector (청크 + 엔티티 벡터)  [고유: 멀티테넌시 메타데이터]
    +
Community Detection (Louvain)  [고유: ingestion 시 수행]
    +
ProcessingStats (비용/토큰 추적)  [고유]
```

---

## 4. 청킹 전략 상세 & 청크 저장 구조

### 4-1. 청크 저장: 5개 독립 저장소

세 프레임워크 모두 LLM이 추출한 엔티티/관계와 **별도로 원본 텍스트 청크를 저장**한다. Ingestion 시 생성되는 5개 저장소:

```
┌─────────────────────────────────────────────────────────────┐
│  1. text_chunks_db (KV)         ← 청크 원문 저장            │
│     key: "doc-abc-chunk-0"                                   │
│     value: { content: "원본 텍스트...", tokens: 850 }        │
│                                                              │
│  2. chunks_vdb (Vector DB)      ← 청크 임베딩 저장          │
│     embedding: embed("원본 텍스트...")                        │
│     metadata: { chunk_id, document_id, file_path }           │
│                                                              │
│  3. entities_vdb (Vector DB)    ← 엔티티 임베딩 저장        │
│     embedding: embed("GPT-4 is a large language model...")   │
│     metadata: { entity_name, entity_type, source_id }        │
│                                                              │
│  4. relationships_vdb (Vector DB) ← 관계 임베딩 저장        │
│     embedding: embed("GPT-4 was developed by OpenAI")        │
│     metadata: { src_id, tgt_id, description }                │
│                                                              │
│  5. knowledge_graph (Graph DB)  ← 노드/엣지 구조 저장       │
│     (n:GPT-4)-[DEVELOPED_BY]->(m:OpenAI)                     │
└─────────────────────────────────────────────────────────────┘
```

쿼리 시 모드에 따라 다른 저장소를 조회:

| 모드 | 조회 저장소 |
|------|-----------|
| NAIVE | `chunks_vdb`만 |
| LOCAL | `entities_vdb` → `knowledge_graph` (1-hop) → `text_chunks_db` |
| GLOBAL | `relationships_vdb` → `knowledge_graph` (역추출) → `text_chunks_db` |
| MIX | LOCAL/GLOBAL + `chunks_vdb` (직접 벡터 검색 추가) |

### 4-2. 청킹 전략: 세 프레임워크 모두 규칙 기반 (시맨틱 청킹 아님)

**중요:** 세 프레임워크 모두 LLM이나 임베딩 모델을 청킹에 사용하지 않는다. 모두 **규칙 기반 고정 크기 청킹**이다.

#### LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:99-162`

```python
def chunking_by_token_size(
    content,
    chunk_token_size=1200,        # 고정 1200 토큰
    chunk_overlap_token_size=100,  # 고정 100 토큰 오버랩 (~8.3%)
    split_by_character=None,       # 선택적 구분자
):
    # 순수 토큰 카운트 기반 슬라이딩 윈도우
    for start in range(0, len(tokens), chunk_token_size - chunk_overlap_token_size):
        chunk_content = tokenizer.decode(tokens[start : start + chunk_token_size])
```

- 문서 크기와 무관하게 항상 동일한 청크 크기
- 문장 경계를 고려하지 않음 — 토큰 위치에서 기계적으로 절단
- `split_by_character` 지정 시 해당 문자로 먼저 분리 후, 큰 조각만 토큰 재분할

#### EdgeQuake

**파일:** `edgequake-pipeline/src/chunker/mod.rs`, `types.rs`, `strategies/`

4가지 전략이 구현되어 있으나 **모두 규칙 기반**:

| 전략 | 분할 기준 | LLM/임베딩 사용 | 기본값 여부 |
|------|----------|----------------|------------|
| `TokenBasedChunking` | 토큰 수 고정 크기 | 없음 | **기본값** |
| `SentenceBoundaryChunking` | `. ! ?` 문장 부호 (약어 사전 포함) | 없음 | 대안 |
| `ParagraphBoundaryChunking` | `\n\n` 문단 구분자 | 없음 | 대안 |
| `CharacterBasedChunking` | 지정 문자 구분자 | 없음 | 대안 |

기본 생성자:
```rust
// mod.rs:64-68
pub fn new(config: ChunkerConfig) -> Self {
    Self {
        config,
        strategy: Arc::new(TokenBasedChunking),  // 기본값 = 토큰 기반
    }
}
```

기본 설정:
```rust
// types.rs:69-90
ChunkerConfig {
    chunk_size: 1200,       // 토큰
    chunk_overlap: 100,     // 토큰
    min_chunk_size: 100,    // 최소 크기 (이하 이전 청크에 병합)
    separators: ["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " "],
    preserve_sentences: true,
}
```

적응형 크기 조정 (`edgequake-core/src/orchestrator/ingestion.rs:42-63`):
```rust
fn calculate_adaptive_chunk_size(document_size_bytes: usize) -> usize {
    if document_size_bytes > 100_000 { 600 }   // >100KB: 작은 청크
    else if document_size_bytes > 50_000 { 800 } // 50-100KB: 중간
    else { 1200 }                                 // <50KB: 표준
}
// 오버랩도 비례 조정: chunk_size × 0.083
```

`ChunkingStrategy` trait으로 시맨틱 청킹 확장이 가능하지만, 현재 구현은 없음:
```rust
// types.rs:29
pub trait ChunkingStrategy: Send + Sync {
    async fn chunk(&self, content: &str, config: &ChunkerConfig) -> Result<Vec<ChunkResult>>;
    fn name(&self) -> &str;
}
```

#### "문장 경계 보존"과 "시맨틱 청킹"의 차이

EdgeQuake의 `SentenceBoundaryChunking`은 **시맨틱 청킹이 아니다:**

| 방식 | 원리 | 모델 사용 |
|------|------|----------|
| **시맨틱 청킹** | 임베딩 유사도 변화 감지 → 의미 전환점에서 분할 | 임베딩 모델 필요 |
| **문장 경계 보존** | `. ! ?` 다음에서 자르기 (약어 `Dr. Inc.` 제외) | 모델 없음 (정규식/사전) |

### 4-3. 청킹 전략 종합 비교

| 측면 | LightRAG / RAG-Anything | EdgeQuake |
|------|------------------------|-----------|
| **기본 전략** | 토큰 슬라이딩 윈도우 | 토큰 슬라이딩 윈도우 |
| **시맨틱 청킹** | 없음 | 없음 |
| **LLM/임베딩 기반 분할** | 없음 | 없음 |
| **청크 크기** | 1200 토큰 (고정) | 600-1200 토큰 (문서 크기 적응) |
| **오버랩** | 100 토큰 (고정) | 50-100 토큰 (비례 조정) |
| **문장 경계** | 무시 | 규칙 기반 보존 가능 (약어 사전) |
| **구분자 계층** | 단일 (선택적) | 8단계 (`\n\n` → `\n` → `. ` → ` `) |
| **최소 청크** | 없음 | 100 토큰 (병합) |
| **라인 번호 추적** | 없음 | start_line, end_line 저장 |
| **오프셋 추적** | 없음 | start_offset, end_offset 저장 |
| **확장성** | 함수 교체 | `ChunkingStrategy` trait |
| **대안 전략** | `split_by_character` 옵션 | Sentence, Paragraph, Character 전략 |

---

## 핵심 차이 요약표

| 단계 | LightRAG | RAG-Anything | EdgeQuake |
|-----|---------|-------------|----------|
| **문서 파싱** | 없음 (텍스트 직접 입력) | MinerU/Docling/PaddleOCR | edgequake-pdf2md (Vision LLM) |
| **청킹** | 1200t 고정, 오버랩 100t | LightRAG 위임 (동일) | 적응형 (1200/800/600t, 문서 크기 기반) |
| **엔티티 추출 프롬프트** | 튜플 기반 (11 타입) | LightRAG 동일 | 동일 프롬프트 포팅 (**9 타입**, 실용적) |
| **글리닝** | 1회 (기본) | LightRAG 동일 | 1회 (기본), 별도 모듈 |
| **엔티티 정규화** | 없음 (LLM 의존) | 없음 (LLM 의존) | **코드 레벨** UPPERCASE_UNDERSCORE |
| **멀티모달 노드** | 없음 | 별도 엔티티 노드 + belongs_to 관계 | 없음 (Markdown 변환) |
| **VLM 호출** | 없음 | 4종 프로세서별 (이미지/테이블/수식/일반) | PDF→이미지→Vision LLM만 |
| **머지** | LLM 요약 (8개 초과 시) | LightRAG 동일 | LLM 요약 (기본) + simple merge fallback |
| **커뮤니티** | 없음 (쿼리 시) | 없음 (쿼리 시) | Louvain (ingestion 시) |
| **프루닝** | source_ids_limit (FIFO/KEEP, 300) | LightRAG 동일 | max_sources=10, max_description_length=4096 |
| **비용 추적** | 없음 | 없음 | 토큰/비용/시간 상세 추적 |
| **재시도** | 캐시 기반 | LightRAG 동일 | 3회 재시도 + 지수 백오프 |
| **체크포인트** | 없음 | 파싱 캐시 (해시 기반) | FileCheckpointStore (PDF 변환 재개) |

---

## 5. 추가 과제 노트

### 5-1. RAG-Anything 인제스션 성능 병목: LLM 호출 폭발

RAG-Anything은 LightRAG 대비 **멀티모달 아이템 N개당 최소 2N회 추가 LLM 호출**이 발생한다. 병목은 I/O가 아닌 순전히 LLM 호출 횟수와 레이턴시이다.

| 단계 | LightRAG | RAG-Anything | 추가 LLM 호출 |
|------|----------|-------------|--------------|
| 파싱 | 텍스트만 | MinerU (OCR+레이아웃) | 0 (로컬) |
| Description 생성 | 없음 | 멀티모달 아이템마다 LLM | **+N** |
| Entity extraction | 텍스트 청크 C개 | 텍스트 C개 + 멀티모달 N개 | **+N** |
| gleaning 포함 | C×2 | (C+N)×2 | **+N×2** |

**예시**: 이미지 20 + 테이블 10 + 수식 5 = N=35, 텍스트 청크 C=10
- LightRAG: ~10회 LLM 호출
- RAG-Anything: ~10 + 35(desc) + 35(extract) = **~80회** (8배)
- gleaning 포함: ~10×2 + 35 + 35×2 = **~125회** (6배)

멀티모달 아이템이 많은 논문/문서일수록 **조합론적으로** 비용 증가. 단순히 문서 길이에 비례하는 LightRAG와는 근본적으로 다른 스케일링 특성.

### 5-2. 크로스-청크 엣지 누락 문제

**엣지 추출 단위**: 페이지가 아닌 청크 단위. 텍스트는 전체를 합친 후 `chunk_token_size` 기준 분할 (페이지 경계 소멸). 멀티모달은 개별 아이템 단위.

**현재 방식**: `merge_nodes_and_edges()` (operate.py:2398)에서 **이름 문자열 일치** 기반 병합만 수행. 별도의 크로스-청크 관계 추론 메커니즘 없음.

```python
# operate.py:2448-2460
all_nodes = defaultdict(list)
for maybe_nodes, maybe_edges in chunk_results:
    for entity_name, entities in maybe_nodes.items():
        all_nodes[entity_name].extend(entities)  # 같은 이름이면 합침
```

**놓치는 경우**: 엔티티 A가 청크1에만, 엔티티 B가 청크2에만 등장하고 어느 청크에서도 A-B 관계가 명시되지 않으면 관계 누락.

**해결 접근법**:
1. **오버래핑 청크**: `chunk_overlap_token_size`로 이미 지원. 먼 거리 한계.
2. **멀티스케일 청킹**: 여러 크기로 청킹 후 각각 추출. LLM 비용 배수 증가.
3. **글로벌 엔티티 해소**: 다른 이름의 같은 엔티티 통합. 새 관계 발견은 안 됨.
4. **2-패스 추출** (가장 효과적): 1차 추출 후 엔티티 목록을 컨텍스트로 2차 추출.
5. **그래프 후처리 (Link Prediction)**: 추출 완료 그래프에서 누락 엣지 추론. O(n^2) 문제.
6. **문서 요약 → 관계 추출**: 요약이 핵심 엔티티를 모아줌. GraphRAG의 community summary 역할.

| 상황 | 추천 |
|------|------|
| 빠르게 개선 | 오버랩 크기 늘리기 |
| 비용 감수 가능 | 2-패스 추출 |
| 장기 개선 | 엔티티 해소 + 그래프 후처리 조합 |
