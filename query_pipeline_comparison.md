# Query-Time Pipeline 비교: LightRAG vs RAG-Anything vs ApeRAG vs EdgeQuake

**작성일:** 2026-03-06 (ApeRAG 추가: 2026-03-23)
**분석 범위:** 소스코드 레벨 query-time logic 전체 추적

---

## 목차

1. [전체 흐름 요약](#1-전체-흐름-요약)
2. [Stage 1: 키워드 추출](#2-stage-1-키워드-추출)
3. [Stage 2: 쿼리 모드 디스패치](#3-stage-2-쿼리-모드-디스패치)
4. [Stage 3: 그래프 탐색](#4-stage-3-그래프-탐색)
    - 4.6 [ApeRAG 그래프 탐색 — PGOpsSyncGraphStorage 성능 분석](#46-aperag-그래프-탐색--pgopssyncstorage-성능-분석)
5. [Stage 4: 프루닝 & 토큰 버짓](#5-stage-4-프루닝--토큰-버짓)
6. [Stage 5: 컨텍스트 조립](#6-stage-5-컨텍스트-조립)
7. [Stage 6: 최종 LLM 프롬프트 & 응답 생성](#7-stage-6-최종-llm-프롬프트--응답-생성)
8. [멀티모달 쿼리 (RAG-Anything 전용)](#8-멀티모달-쿼리-rag-anything-전용)
9. [EdgeQuake 고유 기능](#9-edgequake-고유-기능)
10. [종합 비교표](#10-종합-비교표)
    - 5.6 [그래프 저장 구조: 청크 vs 엔티티](#56-그래프-저장-구조-청크-vs-엔티티)
    - 5.7 [IDF Penalty 부재와 High-Degree 엔티티 편향](#57-idf-penalty-부재와-high-degree-엔티티-편향)
    - 5.8 [벡터 검색 투입 텍스트: 키워드 vs 원본 쿼리](#58-벡터-검색-투입-텍스트-키워드-vs-원본-쿼리)

---

## 1. 전체 흐름 요약

### 공통 파이프라인 (LightRAG 알고리즘 기반)

```
User Query
    |
[1] 키워드 추출 (LLM)
    ├─ high_level_keywords  → Global/Relationship 검색용
    └─ low_level_keywords   → Local/Entity 검색용
    |
[2] 쿼리 모드 디스패치
    ├─ LOCAL:  엔티티 중심 탐색
    ├─ GLOBAL: 관계 중심 탐색
    ├─ HYBRID: Local + Global 병합
    ├─ MIX:   KG + 벡터 청크 결합
    ├─ NAIVE:  순수 벡터 유사도 검색
    └─ BYPASS: 직접 LLM 호출 (검색 없음)
    |
[3] 그래프 탐색
    ├─ 벡터 검색으로 시작 엔티티/관계 탐색
    ├─ 1-hop 이웃 엣지 탐색
    └─ 연관 텍스트 청크 수집
    |
[4] 프루닝 & 토큰 버짓
    ├─ 엔티티 토큰 제한
    ├─ 관계 토큰 제한
    └─ 총 컨텍스트 토큰 제한
    |
[5] 컨텍스트 조립
    ├─ 엔티티 JSON/Markdown
    ├─ 관계 JSON/Markdown
    ├─ 문서 청크 + 참조 목록
    |
[6] 최종 LLM 호출
    ├─ 시스템 프롬프트 + 컨텍스트 + 쿼리
    └─ 응답 생성 (스트리밍 지원)
```

### 프레임워크별 주요 차이

| 단계 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|------|----------|-------------|--------|-----------|
| 키워드 추출 | LLM (JSON 응답) | LightRAG 그대로 | LightRAG 그대로 (수정 버전) | LLM + **query intent 분류** |
| 모드 선택 | 수동 (파라미터) | LightRAG 그대로 | LightRAG 그대로 (수동) | **자동 (intent 기반)** |
| 그래프 탐색 | 벡터 → 1-hop | LightRAG 그대로 | LightRAG 그대로 (수정 버전) | 벡터 → 1-hop + **배치 최적화** |
| 프루닝 | 토큰 기반 절삭 | LightRAG 그대로 | LightRAG 그대로 | 토큰 기반 + **BM25 리랭킹** |
| 컨텍스트 포맷 | JSON 블록 | LightRAG 그대로 | LightRAG 그대로 (JSON) | **Markdown 블록** |
| 멀티모달 | 없음 | **텍스트 변환 + VLM 호출** | Vision 인덱스 병렬 검색 | 없음 |
| 캐싱 | 키워드 + 응답 | 키워드 + 응답 + **멀티모달** | **Redis** 기반 (키워드 + 응답) | 키워드 (**24h TTL**) |
| 풀텍스트 검색 | 없음 | 없음 | **Elasticsearch** 병렬 검색 | BM25 리랭킹 (post-retrieval) |

---

## 2. Stage 1: 키워드 추출

사용자 쿼리를 그래프 검색 가능한 키워드로 변환하는 첫 단계.

### 2.1 LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:3225-3364`, `lightrag/prompt.py:374-432`

**프롬프트 전문:**

```
---Role---
You are an expert keyword extractor, specializing in analyzing user queries
for a Retrieval-Augmented Generation (RAG) system.

---Goal---
Given a user query, your task is to extract two distinct types of keywords:
1. **high_level_keywords**: for overarching concepts or themes,
   capturing user's core intent
2. **low_level_keywords**: for specific entities or details,
   identifying proper nouns, technical jargon, product names

---Instructions & Constraints---
1. **Output Format**: Valid JSON object only. No markdown fences.
2. **Source of Truth**: All keywords explicitly derived from user query.
3. **Concise & Meaningful**: Multi-word phrases preferred over single words.
4. **Handle Edge Cases**: Vague queries → empty lists.
5. **Language**: All keywords in {language}.

---Examples---
Query: "How does international trade influence global economic stability?"
Output:
{
  "high_level_keywords": ["International trade", "Global economic stability",
                          "Economic impact"],
  "low_level_keywords": ["Trade agreements", "Tariffs", "Currency exchange",
                         "Imports", "Exports"]
}
[... 2 more examples ...]

---Real Data---
User Query: {query}
```

**출력:** `{"high_level_keywords": [...], "low_level_keywords": [...]}`

**캐싱:** `compute_args_hash(mode, query, language)` → LLM 응답 캐시 저장

### 2.2 EdgeQuake

**파일:** `edgequake-query/src/keywords/llm_extractor.rs:80-141`

**프롬프트 전문:**

```
Extract high-level and low-level keywords from the following query,
and classify the query intent.

## Definitions

**High-level keywords**: Abstract concepts, themes, or topics that represent
the broader context or domain of the query. Used to find relevant relationships
and global patterns in a knowledge graph.
Examples: "artificial intelligence", "climate change", "software architecture"

**Low-level keywords**: Specific entities, technical terms, proper nouns, or
concrete concepts. Used to find specific entities in a knowledge graph.
Examples: "GPT-4", "Sarah Chen", "PostgreSQL", "neural network", "Microsoft"

**Query Intent**:
- factual: "What is X?", "Who is Y?"
- relational: "How does X relate to Y?"
- exploratory: "Tell me about X"
- comparative: "Compare X and Y"
- procedural: "How to do X?"

## Query
"{query}"

## Output Format
Respond ONLY with valid JSON:
{
  "high_level_keywords": ["concept1", "concept2", ...],
  "low_level_keywords": ["entity1", "term1", ...],
  "query_intent": "factual|relational|exploratory|comparative|procedural"
}
[... 4 examples ...]
```

**출력:** `{"high_level_keywords": [...], "low_level_keywords": [...], "query_intent": "..."}`

**핵심 차이: `query_intent` 필드 추가** — 쿼리 의도를 5가지로 분류하여 자동 모드 선택에 사용.

**캐싱:** `CachedKeywordExtractor` — 24시간 TTL, 쿼리 해시 기반
- 캐시 키는 쿼리만 기준 (LLM 프로바이더 무관)
- 동일 쿼리는 1000명의 사용자가 써도 1회만 LLM 호출

**키워드 검증 (EdgeQuake 전용):**
```rust
// query_basic.rs:72
SOTAQueryEngine::validate_keywords()
// 그래프에 존재하지 않는 키워드를 사전 필터링
// → 임베딩 희석 방지
```

### 2.3 ApeRAG

ApeRAG는 수정된 LightRAG를 사용하므로 키워드 추출 방식이 LightRAG / RAG-Anything과 거의 동일하다. 주요 차이점은 Redis 캐싱 레이어가 추가된 것이다.

**파일:** `aperag/index/graph_index.py` (LightRAG 래퍼를 통해 호출)

- 동일한 `high_level_keywords` + `low_level_keywords` 2개 필드 출력
- Redis 캐시를 통해 동일 쿼리의 LLM 호출 중복 방지
- query intent 분류 없음 → 모드 선택은 수동

### 2.4 키워드 추출 비교

| 측면 | LightRAG / RAG-Anything | ApeRAG | EdgeQuake |
|------|------------------------|--------|-----------|
| 출력 필드 | 2개 (hl, ll) | 2개 (hl, ll) — LightRAG 동일 | **3개 (hl, ll, intent)** |
| 예시 수 | 3개 | 3개 (LightRAG 동일) | 4개 |
| 의도 분류 | 없음 | 없음 | **5가지 (factual/relational/exploratory/comparative/procedural)** |
| 캐시 TTL | 무기한 (수동 삭제) | **Redis** (설정 가능) | **24시간** |
| 키워드 검증 | 없음 | 없음 | **그래프 존재 여부 확인** |
| LLM 프로바이더 오버라이드 | 없음 | 없음 | **사용자 선택 LLM 전파** |
| JSON 오류 복구 | 기본 파싱 | 기본 파싱 | **정규식 기반 자동 수정** (따옴표 변환, trailing comma 제거) |

---

## 3. Stage 2: 쿼리 모드 디스패치

### 3.1 LightRAG / RAG-Anything

**파일:** `lightrag/lightrag.py:2711-2772`

```python
if param.mode in ["local", "global", "hybrid", "mix"]:
    query_result = await kg_query(...)
elif param.mode == "naive":
    query_result = await naive_query(...)
elif param.mode == "bypass":
    response = await use_llm_func(...)
```

**모드 선택:** 사용자가 `QueryParam(mode="hybrid")`로 **수동 지정**

### 3.2 EdgeQuake

**파일:** `edgequake-query/src/sota_engine/query_entry/query_basic.rs:75-81`

```rust
let mode = if let Some(m) = request.mode {
    m  // 사용자 오버라이드
} else if self.config.use_adaptive_mode {
    keywords.query_intent.recommended_mode()  // 의도 기반 자동 선택
} else {
    self.config.default_mode  // Hybrid (기본값)
};
```

**자동 모드 매핑:**

| Query Intent | 자동 선택 모드 | 이유 |
|-------------|--------------|------|
| Factual | **Local** | 특정 엔티티에 대한 사실 → 엔티티 중심 |
| Relational | **Hybrid** | 관계 파악 → 엔티티 + 관계 모두 필요 |
| Exploratory | **Global** | 넓은 탐색 → 관계/커뮤니티 중심 |
| Comparative | **Hybrid** | 비교 → 여러 엔티티 + 관계 |
| Procedural | **Local** | 절차적 → 구체적 엔티티 단계 |

---

## 4. Stage 3: 그래프 탐색

### 4.1 LOCAL 모드 — 엔티티 중심 탐색

#### LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:4169-4280`

```
ll_keywords → 벡터 검색 (entities_vdb, top_k=40)
    → 엔티티 ID 추출
    → 배치 노드 데이터 + degree 조회
    → 1-hop 이웃 엣지 탐색 (get_nodes_edges_batch)
    → 엣지 중복 제거 (무방향 그래프: sorted tuple)
    → 엣지 정렬 (rank × weight 내림차순)
    → 연관 텍스트 청크 수집
```

**엣지 탐색 상세** (`_find_most_related_edges_from_entities`, operate.py:4227):
- 각 엔티티의 모든 직접 연결 엣지를 가져옴
- `sorted_edge = tuple(sorted(e))` — 무방향 그래프 처리
- `sorted(key=lambda x: (x["rank"], x["weight"]), reverse=True)` — 중요도 정렬

**청크 연결 전략** (`_find_related_text_unit_from_entities`, operate.py:4283):

| 전략 | 설명 | 기본값 |
|------|------|--------|
| `VECTOR` | 벡터 유사도로 청크 선택 | **기본값** |
| `WEIGHT` | 출현 빈도 가중치 폴링 | 대안 |

- 엔티티당 최대 5개 청크 (`DEFAULT_RELATED_CHUNK_NUMBER`)

#### EdgeQuake

**파일:** `edgequake-query/src/sota_engine/query_modes.rs:31-190`

```
ll_keywords → 임베딩 계산 (embeddings.low_level)
    → 벡터 검색 (max_entities × 3 = 180 후보)
    → 엔티티 타입 필터링
    → 유사도 점수 맵 구축
    → 상위 60개 엔티티 (min_score=0.1)
    → 배치 그래프 조회 (tokio::join!)
        ├─ get_nodes_batch (노드 속성)
        └─ node_degrees_batch (연결 수)
    → 직접 관계 탐색 (get_edges_for_nodes_batch)
    → 소스 청크 수집 (source_chunk_ids)
    → BM25 리랭킹 → 토큰 버짓 내 상위 청크
```

**핵심 차이:**
- 벡터 검색 시 **3배 오버샘플링** (180 → 60) — 타입 필터링 후에도 충분한 결과 보장
- **배치 그래프 연산** (`tokio::join!`) — DB 라운드트립 120+ → 2-3회로 감소
- **결정론적 순서** (Vec, HashMap 아님) — 동일 쿼리 → 동일 결과 보장
- **테넌트/워크스페이스 필터링** — 모든 결과에 격리 필터 적용

### 4.2 GLOBAL 모드 — 관계 중심 탐색

#### LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:4442-4528`

```
hl_keywords → 벡터 검색 (relationships_vdb, top_k=40)
    → 엣지 데이터 추출 (src_id, tgt_id)
    → 연결된 엔티티 역추출 (_find_most_related_entities_from_relationships)
    → 양방향 엔티티 수집 (src + tgt 모두)
    → 연관 텍스트 청크 수집
```

#### EdgeQuake

**파일:** `edgequake-query/src/sota_engine/query_modes.rs:211-410`

```
hl_keywords → 임베딩 계산 (embeddings.high_level)
    → 벡터 검색 (max_relationships × 3 = 180 후보)
    → 관계 타입 필터링
    → 중복 제거 (key: "{src}->{tgt}:{type}")
    → 소스 추적 (chunk_ids, doc_ids, file_paths)
    → 엔티티 수화 (2가지 경로):
        Path A (정상): 관계 양 끝 엔티티 배치 조회
        Path B (폴백): 검색 결과 없을 시 → 인기 엔티티 폴백
            get_popular_nodes_with_degree(max_entities, min_degree=2)
    → 청크 수집 + BM25 리랭킹
```

**핵심 차이: 인기 엔티티 폴백** — 벡터 검색이 빈 결과를 반환할 때, `min_degree=2` 이상인 인기 노드를 반환하여 빈 응답 방지.

### 4.3 HYBRID 모드 — Local + Global 병합

#### LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:3488-3578`

```python
# 병렬 실행
local_entities, local_relations = await _get_node_data(ll_keywords, ...)
global_relations, global_entities = await _get_edge_data(hl_keywords, ...)

# 라운드로빈 병합
final_entities = []
seen = set()
max_len = max(len(local_entities), len(global_entities))
for i in range(max_len):
    if i < len(local_entities) and local_entities[i] not in seen:
        final_entities.append(local_entities[i])
    if i < len(global_entities) and global_entities[i] not in seen:
        final_entities.append(global_entities[i])
```

**병합 방식:** Local[0], Global[0], Local[1], Global[1], ... (교대 삽입, 중복 제거)

#### EdgeQuake

**파일:** `edgequake-query/src/strategies/hybrid.rs`

```rust
// 리소스 분할: 각 모드에 절반씩
local_config.max_chunks /= 2;     // 10개
local_config.max_entities /= 2;   // 30개
global_config.max_entities /= 2;  // 30개

// 병렬 실행
local_context = local_strategy.execute(...);
global_context = global_strategy.execute(...);

// 병합: Local 우선 (더 구체적)
merged_entities = local_entities + global_entities (dedup by name)
merged_relationships = local_rels + global_rels (dedup by key)
```

**핵심 차이:**
- LightRAG: 라운드로빈 (공평 교대)
- EdgeQuake: **Local 우선** (Local이 더 구체적이므로 먼저 배치) + 리소스 사전 분할

### 4.4 MIX 모드 — KG + 벡터 청크

#### LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:3504-3522`

```python
# KG 데이터 (Local/Global/Hybrid 중 하나)
kg_entities, kg_relations = await kg_query(...)

# + 벡터 청크 추가
vector_chunks = await _get_vector_context(query, chunks_vdb, ...)

# 라운드로빈 병합: vector → entity → relation 청크
```

#### EdgeQuake

**파일:** `edgequake-query/src/strategies/mix.rs`

```rust
pub struct MixStrategyConfig {
    pub vector_weight: f32,  // 벡터 결과 가중치
    pub graph_weight: f32,   // 그래프 결과 가중치
}
// 가중 결합: naive 벡터 결과 + 그래프 결과
```

### 4.5 NAIVE 모드 — 순수 벡터 검색

#### LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:4758-4802`, `operate.py:3367-3421`

```python
results = await chunks_vdb.query(query, top_k=20)
# 그래프 탐색 없음, 순수 벡터 유사도
```

- `DEFAULT_CHUNK_TOP_K = 20`
- `DEFAULT_COSINE_THRESHOLD = 0.2`

#### EdgeQuake

**파일:** `edgequake-query/src/strategies/naive.rs`

```rust
// 2배 오버샘플링 후 필터링
vector_storage.query(embeddings.query, max_chunks * 2)
    → filter to chunk vectors only
    → take top 20
```

---

### 4.6 ApeRAG 그래프 탐색 — PGOpsSyncGraphStorage 성능 분석

ApeRAG는 수정된 LightRAG를 사용하므로 **탐색 알고리즘**(벡터 검색 → 1-hop 이웃 수집)은 LightRAG와 동일하다. 그러나 스토리지 백엔드가 Neo4j/NetworkX가 아닌 **PostgreSQL 관계형 테이블**이기 때문에, 실제 그래프 연산이 어떻게 구현되는지 별도로 분석한다.

**관련 파일:**
- `aperag/aperag/graph/lightrag/kg/pg_ops_sync_graph_storage.py` — async 래퍼
- `aperag/aperag/db/repositories/graph.py` — 실제 SQL 구현

#### 4.6.1 1-hop 탐색 — 효율적

탐색의 핵심 연산인 `get_nodes_edges_batch()`는 UNION ALL + `ANY(:node_ids)`로 **1번의 쿼리**에 N개 노드의 모든 인접 엣지를 가져온다:

```sql
-- graph.py:482-504
WITH node_list AS (SELECT unnest(:node_ids) AS entity_id),
outgoing_edges AS (
    SELECT e.source_entity_id AS node_id, e.source_entity_id, e.target_entity_id
    FROM lightrag_graph_edges e
    WHERE e.workspace = :workspace AND e.source_entity_id = ANY(:node_ids)
),
incoming_edges AS (
    SELECT e.target_entity_id AS node_id, e.source_entity_id, e.target_entity_id
    FROM lightrag_graph_edges e
    WHERE e.workspace = :workspace AND e.target_entity_id = ANY(:node_ids)
)
SELECT node_id, source_entity_id, target_entity_id
FROM outgoing_edges
UNION ALL
SELECT node_id, source_entity_id, target_entity_id FROM incoming_edges
ORDER BY node_id
```

LightRAG가 실제로 필요한 탐색 깊이가 1-hop이므로, 이 구현은 **실용적으로 충분**하다.

#### 4.6.2 Multi-hop 순회 — 구현 없음

`get_knowledge_graph()`는 `max_depth` 파라미터를 받지만 실제 재귀 순회를 구현하지 않는다. 코드 주석이 이를 명시한다 (`pg_ops_sync_graph_storage.py:289-291`):

```
"For now, it only supports getting nodes by label pattern and their immediate connections.
Full graph traversal with max_depth would require additional Repository methods."
```

Apache AGE나 Neo4j였다면 Cypher 한 줄로 해결된다:

```cypher
MATCH (n)-[*1..3]-(m) WHERE n.entity_id = $start RETURN m
```

관계형 테이블에서 동등한 연산을 수행하려면 재귀 CTE(`WITH RECURSIVE`) 또는 Python에서 BFS/DFS 루프가 필요하다. 현재 ApeRAG에는 그 구현이 없다.

#### 4.6.3 N+1 문제 — 단일 연산 호출 시

`get_graph_node_degree()` (단일 노드 버전)는 쿼리 2번을 분리 실행한다:

```python
# graph.py:217-228 — 단일 노드, 2번 쿼리
outgoing_count = session.execute(COUNT where source == node_id).scalar()
incoming_count = session.execute(COUNT where target == node_id).scalar()
```

이 함수를 N개 노드에 반복 호출하면 **2N번 쿼리**가 발생한다. 단, 실제 쿼리 파이프라인은 대부분 batch 버전을 사용하므로 실제 발생 빈도는 낮다:

```sql
-- graph.py:386-410 — batch 버전: CTE로 1번 쿼리
WITH node_list AS (SELECT unnest(:node_ids) AS entity_id),
outgoing_counts AS (SELECT source_entity_id, COUNT(*) AS out_degree ...),
incoming_counts AS (SELECT target_entity_id, COUNT(*) AS in_degree ...)
SELECT nl.entity_id,
       COALESCE(oc.out_degree, 0) + COALESCE(ic.in_degree, 0) AS total_degree
FROM node_list nl
LEFT JOIN outgoing_counts oc ON nl.entity_id = oc.entity_id
LEFT JOIN incoming_counts ic ON nl.entity_id = ic.entity_id
```

#### 4.6.4 OR 폭발 — edge pairs 배치 조회

`get_graph_edges_batch()`는 조회할 (src, tgt) 쌍 수만큼 OR 절을 생성한다:

```python
# graph.py:430-438
conditions = []
for source, target in edge_pairs:
    conditions.append(and_(source == source, target == target))
stmt = select(...).where(and_(workspace == ws, or_(*conditions)))
# 결과: WHERE workspace=? AND ((src=A AND tgt=B) OR (src=C AND tgt=D) OR ...)
```

edge pair가 수백 개 이상이면 쿼리 플래너 최적화가 어려워진다. 개선 방법은 VALUES 절 또는 임시 테이블 조인이다.

#### 4.6.5 Pruning — 단순 Truncation

`get_knowledge_graph()`의 pruning은 단순히 앞에서 자른다:

```python
# pg_ops_sync_graph_storage.py:307-311
matching_labels = all_labels[:MAX_GRAPH_NODES]
```

weight 내림차순이나 degree 내림차순 정렬 없이, `entity_id` 알파벳 순서대로 상위 N개를 반환한다. 의미 있는 중요도 기반 pruning은 이 레이어에 없다. 실제 token-budget pruning은 Python `query.py` 레이어에서 처리된다.

#### 4.6.6 종합 평가

| 연산 | SQL 구현 | 쿼리 횟수 | 평가 |
|------|----------|-----------|------|
| 1-hop 엣지 조회 (batch) | UNION ALL + ANY | 1번 | [OK] |
| node degree (batch) | CTE + UNNEST | 1번 | [OK] |
| node 데이터 (batch) | IN 조건 | 1번 | [OK] |
| node degree (단일) | 2번 COUNT 분리 | 2번/노드 | [WARN] 반복 호출 시 N+1 |
| edge pairs 조회 | OR 조건 반복 | 1번이나 OR 폭발 | [WARN] 대규모 시 느림 |
| multi-hop 순회 | 미구현 | N/A | [ERR] max_depth 무시됨 |
| pruning | 알파벳 순 truncation | N/A | [WARN] 중요도 무관 |

**결론:** ApeRAG의 관계형 테이블 그래프는 LightRAG가 실제로 사용하는 1-hop 탐색 패턴에 대해서는 잘 최적화되어 있다. Multi-hop이 필요해지는 시나리오(복잡한 지식 그래프 탐색)에서는 추가 구현이 필요하다.

---

## 5. Stage 4: 프루닝 & 토큰 버짓

### 5.1 LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:3593-3850`

**토큰 예산:**

| 항목 | 기본값 | 상수명 |
|------|--------|--------|
| 엔티티 | 6,000 토큰 | `DEFAULT_MAX_ENTITY_TOKENS` |
| 관계 | 8,000 토큰 | `DEFAULT_MAX_RELATION_TOKENS` |
| 전체 | 30,000 토큰 | `DEFAULT_MAX_TOTAL_TOKENS` |

**절삭 방식:** `truncate_list_by_token_size()`
- 각 항목을 JSON으로 직렬화 → 토큰 수 계산
- 예산 초과 시 마지막 항목부터 제거
- 순서: 이미 rank/weight로 정렬되어 있으므로, **덜 중요한 항목이 먼저 제거**

**청크 병합:** 라운드로빈 (vector → entity → relation 청크 교대 삽입, 중복 제거)

### 5.2 EdgeQuake

**파일:** `edgequake-query/src/truncation.rs:77-132`

**토큰 예산:**

| 항목 | 기본값 | 비율 |
|------|--------|------|
| 엔티티 | **10,000 토큰** | 33% |
| 관계 | **10,000 토큰** | 33% |
| 전체 | 30,000 토큰 | 100% |

**절삭 방식:**
```rust
fn truncate_entities(entities: Vec<RetrievedEntity>, max_tokens: usize) {
    for entity in entities {
        let formatted = format!("Entity: {} ({})\n{}\n",
            entity.name, entity.entity_type, entity.description);
        let entity_tokens = tokenizer.count_tokens(&formatted);
        if total_tokens + entity_tokens <= max_tokens {
            result.push(entity);
        } else {
            break;  // 예산 초과 시 즉시 중단
        }
    }
}
```

**우선순위:** 엔티티 → 관계 → 청크 (그래프 데이터가 더 밀도 높으므로 우선)

**BM25 리랭킹 (EdgeQuake 전용):**

**파일:** `edgequake-query/src/sota_engine/reranking.rs:6-100`

```rust
// 1. BM25 점수 계산
reranker.rerank(query, documents, top_k)

// 2. 최소 점수 필터링 (min_rerank_score = 0.1)
results.filter(|r| r.score >= 0.1)

// 3. 폴백: 모든 청크가 필터링되면 원래 top_k 반환
if all_filtered {
    return original_top_k;  // BM25가 0점이라도 그래프가 찾은 청크는 유효
}
```

### 5.3 프루닝 비교

| 측면 | LightRAG / RAG-Anything | EdgeQuake |
|------|------------------------|-----------|
| 엔티티 버짓 | 6,000 토큰 | **10,000 토큰** |
| 관계 버짓 | 8,000 토큰 | **10,000 토큰** |
| 전체 버짓 | 30,000 토큰 | 30,000 토큰 |
| 배분 비율 | 20:27:53 (엔:관:청크) | **33:33:33 (균등)** |
| 리랭킹 | 없음 | **BM25 (폴백 포함)** |
| 절삭 순서 | 끝에서 제거 | 끝에서 제거 (break) |
| 컨텍스트 우선순위 | 청크 > 관계 > 엔티티 | **엔티티 > 관계 > 청크** (그래프 우선) |

---

## 5.5 고립된 정보 손실 문제와 완화 전략

### 문제: 연결이 적은 중요 정보가 프루닝에서 밀려남

Graph RAG의 구조적 한계로, 다음 3가지 경로에서 고립된 중요 정보가 손실될 수 있다.

#### 손실 경로 1: 벡터 검색 자체에서 놓치는 경우

엔티티 description의 표현과 쿼리 표현이 의미적으로 가까운데 임베딩 공간에서 거리가 먼 경우.

```
[중요 엔티티 X]
  - description: "특수 촉매 반응의 활성화 에너지 임계값"
  - 쿼리: "화학 반응 속도에 영향을 미치는 요인"
  - 임베딩 유사도: 0.18 (threshold 0.2 미만) → 놓침
```

이것은 벡터 검색의 근본적 한계이며, 세 프레임워크 모두 동일하게 영향받는다.

#### 손실 경로 2: 엣지 정렬에서 밀려나는 경우 (가장 실질적)

1-hop 탐색 후 엣지를 `rank(=degree) × weight`로 정렬하는데, 연결이 적고 한 번만 언급된 관계는 뒤로 밀림.

```
[엔티티 A] ──희귀하지만_중요한_관계── [엔티티 B]
  degree: 1          weight: 0.5         degree: 1

vs.

[허브 C] ──흔한_관계── [허브 D]
  degree: 50         weight: 3.2         degree: 45

→ 토큰 버짓 프루닝 시 희귀 관계가 먼저 잘림
```

#### 손실 경로 3: 엔티티는 찾았으나 엣지가 없는 경우

이 경우는 실제로 **문제가 아님**. 벡터 검색 결과는 엣지 유무와 무관하게 반환되며, 엔티티 description 자체가 컨텍스트에 포함된다. 1-hop 탐색은 추가 보강일 뿐.

### 각 프레임워크의 완화 전략

#### LightRAG / RAG-Anything: MIX 모드 (핵심 안전망)

```python
# operate.py:3504 - MIX 모드의 3가지 청크 소스
vector_chunks   ← 쿼리 ↔ 청크 직접 유사도 (그래프 무관, 최후의 안전망)
entity_chunks   ← 엔티티에서 역추적한 원본 청크
relation_chunks ← 관계에서 역추적한 원본 청크

→ 라운드로빈 병합: [vector[0], entity[0], relation[0], vector[1], ...]
```

그래프에서 못 찾아도 원본 청크 텍스트 자체가 쿼리와 유사하면 `vector_chunks`에서 직접 발견 가능. 이것이 LightRAG와 RAG-Anything의 기본 모드가 `mix`인 이유.

#### EdgeQuake: 3중 폴백 체인

| 완화 장치 | 코드 위치 | 설명 |
|-----------|----------|------|
| **인기 엔티티 폴백** | `query_modes.rs:308-339` | GLOBAL 검색이 빈 결과 → degree≥2인 인기 노드로 대체 |
| **BM25 리랭킹 폴백** | `reranking.rs:71-84` | 모든 청크가 BM25로 필터링되면 원래 top_k를 그대로 반환 |
| **부분 답변 정책** | `prompt.rs:101` | "정보 부족" 대신 가용 정보로 부분 답변 + 누락 정보 명시 |

#### RAG-Anything 추가: 멀티모달 쿼리 강화

멀티모달 컨텐츠를 텍스트로 변환해 enhanced query에 포함하여 쿼리 자체를 풍부하게 만듦 → 벡터 검색 적중률 향상.

### 구조적 한계가 남는 지점

세 프레임워크 모두 완벽하게 해결하지 못하는 케이스:

```
시나리오: 문서에 딱 한 번 등장하는 핵심 사실

"프로젝트 X의 실패 원인은 공급업체 Z의 납품 지연이었다."

- 엔티티 "공급업체 Z": degree=1, weight=0.5
- 관계 "공급업체Z → 프로젝트X": weight=0.5
- 쿼리: "프로젝트 X가 왜 실패했나?"
```

| 검색 경로 | 결과 |
|-----------|------|
| LOCAL (ll="프로젝트 X") | 프로젝트 X는 찾지만, 공급업체 Z 관계가 rank 낮아서 잘릴 수 있음 |
| GLOBAL (hl="프로젝트 실패 원인") | 관계 벡터 DB에서 유사도 충분하면 찾음, 아니면 놓침 |
| MIX (vector chunks) | 원본 청크가 쿼리와 유사하면 직접 발견 가능 ← **최후의 안전망** |

**핵심 통찰:** MIX 모드의 벡터 청크 검색에 의존하는 순간, 그것은 사실상 "Graph RAG"가 아니라 일반 RAG로 폴백하는 것이다. Graph RAG의 구조적 이점(관계 추론, 다중 홉 연결)은 그 케이스에서 활용되지 못한다.

**설계적 이유 — 왜 2-hop 이상 탐색하지 않는가:**

1. **토큰 폭발**: 1-hop만 해도 엔티티 40개 × 평균 5개 엣지 = 200개 엣지. 2-hop이면 수천 개로 폭발
2. **노이즈 증가**: 2-hop 관계는 원래 쿼리와 관련성이 급격히 떨어짐
3. **역할 분담**: 벡터 검색 = 의미적 장거리 점프, 1-hop = 구조적 근거리 보강

---

## 5.6 그래프 저장 구조: 청크 vs 엔티티

### 핵심 발견: 청크는 그래프 노드가 아니다

세 프레임워크 모두 **문서 청크를 그래프 노드로 저장하지 않는다.** 그래프에는 오직 엔티티(Entity)만 노드로, 관계(Relationship)만 엣지로 저장된다.

```
┌─────────────────────────────────────────────────────────┐
│                    5개 독립 저장소                         │
│                                                         │
│  ① text_chunks_db (KV)     ← 원본 청크 텍스트 저장        │
│  ② chunks_vdb (Vector)     ← 청크 임베딩 (MIX/NAIVE용)    │
│  ③ entities_vdb (Vector)   ← 엔티티 임베딩 (검색 진입점)    │
│  ④ relationships_vdb (Vec) ← 관계 임베딩 (GLOBAL용)        │
│  ⑤ knowledge_graph (Graph) ← 엔티티=노드, 관계=엣지만      │
│                                                         │
│  청크는 ①②에만 존재. ⑤ 그래프에는 없음.                     │
└─────────────────────────────────────────────────────────┘
```

### 청크 ↔ 엔티티 연결: `source_id` 메타데이터

청크는 그래프 노드가 아니지만, 엔티티 노드의 메타데이터 속성으로 역참조된다.

**LightRAG** (`operate.py:1835-1847`):
```python
node_data = dict(
    entity_id=entity_name,
    entity_type=entity_type,
    description=description,
    source_id=source_id,      # "chunk_key1<SEP>chunk_key2<SEP>..."
    file_path=file_path,
)
await knowledge_graph_inst.upsert_node(entity_name, node_data=node_data)
```

**EdgeQuake** (`context.rs:206-214`):
```rust
pub struct RetrievedEntity {
    pub name: String,
    pub entity_type: String,
    pub description: String,
    pub score: f32,
    pub degree: usize,
    pub source_chunk_ids: Vec<String>,      // 역참조
    pub source_document_id: Option<String>, // 역참조
}
```

### 쿼리 시 청크 역추적 경로

```
벡터검색 → 엔티티 노드 선택
  → 엔티티 노드의 source_id / source_chunk_ids 속성 읽기
  → text_chunks_db (KV) 에서 원본 청크 텍스트 조회
  → context에 포함 (MIX 모드)
```

그래프 엣지를 통한 탐색이 아니라, **노드의 메타데이터 속성을 통한 직접 조회**다. 청크가 그래프 구조의 일부가 아니므로 centrality 계산에 청크는 영향을 주지 않는다.

### source_id 상한

| 프레임워크 | 제한 | 전략 |
|-----------|------|------|
| **LightRAG** | `max_source_ids_per_entity` (설정 가능) | KEEP (오래된 것 유지) 또는 FIFO (최신 유지) |
| **EdgeQuake** | 300개 (`core/types/entity.rs:50`) | FIFO |

### 프레임워크별 그래프 저장 구조 비교

| 항목 | LightRAG / RAG-Anything | EdgeQuake |
|------|------------------------|-----------|
| **그래프 노드** | 엔티티만 | 엔티티만 |
| **그래프 엣지** | 관계만 | 관계만 |
| **청크 저장** | KV + Vector (별도) | KV + Vector (별도) |
| **청크→엔티티 연결** | `source_id` (구분자 연결 문자열) | `source_chunk_ids` (Vec) |
| **엔티티→문서 연결** | `file_path` 속성 | `source_document_id` 속성 |
| **그래프 백엔드** | NetworkX / Neo4j / PostgreSQL | Apache AGE (PostgreSQL) |
| **노드 속성** | entity_id, entity_type, description, source_id, file_path, created_at | entity_type, description, importance, source_chunk_ids, source_document_id, tenant_id, workspace_id |

---

## 5.7 IDF Penalty 부재와 High-Degree 엔티티 편향

### 문제: 범용 엔티티의 degree 편향

세 프레임워크 모두 **엔티티 수준의 IDF(Inverse Document Frequency) penalty를 구현하지 않는다.** "AI", "technology" 같은 범용 엔티티는 많은 문서에서 추출되어 높은 degree를 갖지만, 정보 밀도는 낮다.

```
"AI의 윤리적 문제" 쿼리 시:

1. 벡터 검색 → "AI" 엔티티 발견 (degree=500)
2. 1-hop 탐색 → "AI"의 500개 엣지 중 상위 선택
3. degree 기반 정렬 → "AI-TECHNOLOGY", "AI-COMPANY" 등 범용 관계가 상위
4. "AI-ETHICS" 같은 구체적 관계는 degree 낮아서 하위로 밀림
5. 토큰 예산 초과 → 프루닝 → 구체적 정보 손실
```

### 각 레벨별 IDF 적용 현황

| 레벨 | LightRAG | EdgeQuake |
|------|----------|-----------|
| **엔티티 선택** | 벡터 유사도 (IDF 없음) | 벡터 유사도 (IDF 없음) |
| **엔티티 랭킹** | degree × weight (**high-degree 우대**) | degree DESC (**high-degree 우대**) |
| **엣지 랭킹** | degree × weight (**high-degree 우대**) | 벡터 유사도 기반 |
| **청크 랭킹** | 출현 빈도 가중 (WEIGHT) 또는 벡터 (VECTOR) | **BM25 IDF 적용** ← 유일한 IDF |
| **키워드 필터** | 없음 | 그래프 존재 여부 validation |

**RAG-Anything**: LightRAG를 그대로 사용하므로 LightRAG와 동일.

### EdgeQuake BM25: 청크 레벨에서만 IDF 적용

EdgeQuake의 BM25 reranker가 **청크 단위에서** IDF를 적용한다 (`e2e_sota_engine.rs:924-943`):

```
"ENVY"(희귀 용어, 1개 문서) vs "Peugeot"(보편 용어, 전체 문서)
→ BM25 IDF가 "ENVY" 포함 청크를 상위로 → 희귀 정보 우선
```

하지만 **엔티티 랭킹에는 IDF가 적용되지 않고, 오히려 반대로 동작**한다 (`reranking.rs:105-113`):

```rust
/// Sort entities by degree (descending) for importance-based ranking.
/// High-degree entities are more connected in the knowledge graph
/// and typically represent more important/central concepts.
pub(super) fn sort_entities_by_degree(&self, entities: &mut [RetrievedEntity]) {
    entities.sort_by(|a, b| b.degree.cmp(&a.degree));
}
```

degree가 높을수록 상위 — IDF와 정반대 방향이다.

### EdgeQuake의 부분적 완화: 키워드 검증

EdgeQuake의 keyword validation (`reranking.rs:121-196`)이 간접적으로 도움된다:
- 쿼리 키워드가 그래프에 존재하는지 확인
- 존재하지 않는 키워드는 drop → 임베딩 dilution 방지
- 하지만 이는 "없는 키워드 제거"이지, "너무 흔한 엔티티 패널티"가 아님

### 구조적 한계 요약

| 문제 | 원인 | 영향 |
|------|------|------|
| 범용 엔티티 편향 | degree 기반 랭킹이 IDF 없이 동작 | 일반적 정보가 context 상위 차지 |
| 구체적 정보 밀려남 | high-degree 엣지가 토큰 예산 선점 | 쿼리와 관련된 세부 정보 프루닝 |
| 청크 레벨에서만 보정 | EdgeQuake BM25만 IDF 적용 | 그래프 탐색 결과에는 무효 |
| 벡터 유사도 의존 | 시드 선택은 유사도 기반 | 시드는 적절하나 1-hop 확장 시 편향 발생 |

**개선 방향 (미구현):** 엔티티 degree에 log(N/df) 같은 IDF 패널티를 적용하면, degree가 높지만 정보 밀도가 낮은 범용 엔티티의 영향을 줄일 수 있다. 혹은 엣지 랭킹에서 `weight / log(1 + degree)` 같은 degree-normalized scoring을 사용할 수 있다.

---

## 5.8 벡터 검색 투입 텍스트: 키워드 vs 원본 쿼리

### 현황: 엔티티/관계 검색에는 키워드만, 청크 검색에만 원본 쿼리

세 프레임워크 모두 벡터 검색 시 **추출된 키워드만** 엔티티/관계 벡터 DB에 투입하며, 원본 쿼리 문장은 청크 검색에만 사용한다.

### LightRAG / RAG-Anything

**파일:** `lightrag/operate.py:3471-3510`

```python
# LOCAL: ll_keywords → entities_vdb
local_entities, local_relations = await _get_node_data(
    ll_keywords,            # ← 키워드만 투입
    knowledge_graph_inst, entities_vdb, query_param,
)

# GLOBAL: hl_keywords → relationships_vdb
global_relations, global_entities = await _get_edge_data(
    hl_keywords,            # ← 키워드만 투입
    knowledge_graph_inst, relationships_vdb, query_param,
)

# MIX/NAIVE: query → chunks_vdb
vector_chunks = await _get_vector_context(
    query,                  # ← 원본 쿼리 투입
    chunks_vdb, query_param,
)
```

| 벡터 DB | 투입 텍스트 | 소스 |
|---------|-----------|------|
| `entities_vdb` (LOCAL) | `ll_keywords` (low-level 키워드) | `operate.py:3473-3474` |
| `relationships_vdb` (GLOBAL) | `hl_keywords` (high-level 키워드) | `operate.py:3481-3482` |
| `chunks_vdb` (MIX/NAIVE) | `query` (원본 쿼리) | `operate.py:3506-3507` |

### EdgeQuake — 3중 임베딩 사전 계산

**파일:** `edgequake-query/src/sota_engine/mod.rs:183-227`

EdgeQuake는 3개 임베딩을 **병렬로 동시 계산**한다:

```rust
pub struct QueryEmbeddings {
    pub query: Vec<f32>,       // 원본 쿼리 임베딩
    pub high_level: Vec<f32>,  // high-level 키워드 임베딩
    pub low_level: Vec<f32>,   // low-level 키워드 임베딩
}
```

| 벡터 DB | 투입 임베딩 | 실제 텍스트 |
|---------|-----------|------------|
| Entity vectors (LOCAL) | `embeddings.low_level` | `keywords.low_level.join(", ")` |
| Relationship vectors (GLOBAL) | `embeddings.high_level` | `keywords.high_level.join(", ")` |
| Chunk vectors (NAIVE/MIX) | `embeddings.query` | **원본 쿼리 그대로** |

**폴백:** 키워드가 비어있으면 원본 쿼리를 대신 사용한다 (`mod.rs:201-211`):

```rust
let low_level_text = if keywords.low_level.is_empty() {
    query.to_string()  // 폴백: 원본 쿼리
} else {
    keywords.low_level.join(", ")
};
```

### 왜 키워드만 투입하는가?

1. **임베딩 공간 일치**: `entities_vdb`에 저장된 벡터는 `"엔티티명\n설명"` 형태로 임베딩됨 (`operate.py:1851`). 키워드 (`"AI"`, `"윤리"`)가 이 공간과 더 유사함
2. **노이즈 제거**: 원본 쿼리 `"AI의 윤리적 문제는 무엇인가?"` 전체를 임베딩하면 `"무엇인가?"` 같은 비핵심 토큰이 노이즈로 작용
3. **의도 추출**: LLM이 쿼리에서 핵심 개체명/관계명만 추출하여 검색 정밀도 향상

### 키워드만 사용할 때의 한계

1. **키워드 추출 실패**: LLM이 핵심 키워드를 놓치면 해당 엔티티를 아예 검색하지 못함
2. **맥락 소실**: `"삼성과 애플의 특허 분쟁에서 누가 이겼나?"` → 키워드 `["삼성", "애플"]`만 추출되면 `"특허 분쟁"`, `"승패"` 맥락 소실
3. **의미적 장거리 매칭 약화**: 원본 쿼리의 미묘한 의미(어감, 맥락)가 키워드로 압축되면서 손실

### 프레임워크별 비교

| 항목 | LightRAG / RAG-Anything | EdgeQuake |
|------|------------------------|-----------|
| 엔티티 검색 투입 | ll_keywords (문자열) | ll_keywords 임베딩 (사전 계산) |
| 관계 검색 투입 | hl_keywords (문자열) | hl_keywords 임베딩 (사전 계산) |
| 청크 검색 투입 | 원본 쿼리 (문자열) | 원본 쿼리 임베딩 (사전 계산) |
| 키워드 비었을 때 | 해당 모드 스킵 | **원본 쿼리로 폴백** |
| 임베딩 계산 시점 | 각 검색 시 개별 계산 | **3개 동시 배치 계산** |

### 개선 가능한 방향 (미구현)

| 전략 | 설명 |
|------|------|
| **하이브리드 임베딩** | `α × embed(keywords) + (1-α) × embed(query)`의 가중 평균으로 검색 |
| **듀얼 쿼리** | 키워드 임베딩 + 원본 쿼리 임베딩 각각 top-k → 합집합 후 재정렬 |
| **쿼리 확장** | 키워드에 원본 쿼리의 핵심 구문 포함하여 검색 범위 확대 |

---

## 6. Stage 5: 컨텍스트 조립

### 6.1 LightRAG / RAG-Anything

**파일:** `lightrag/prompt.py:332-357`

**컨텍스트 형식 (JSON 블록):**

```
Knowledge Graph Data (Entity):

```json
[
  {
    "entity": "Apple Inc.",
    "type": "Organization",
    "description": "Technology company founded in 1976",
    "created_at": "2024-01-15 10:30:45",
    "file_path": "document_1.pdf"
  }
]
```

Knowledge Graph Data (Relationship):

```json
[
  {
    "entity1": "Steve Jobs",
    "entity2": "Apple Inc.",
    "description": "Steve Jobs co-founded Apple Inc.",
    "keywords": "founder, creation, leadership",
    "weight": 0.95,
    "created_at": "2024-01-15",
    "file_path": "document_1.pdf"
  }
]
```

Document Chunks (Each entry has a reference_id):

```json
[
  {
    "reference_id": "[1]",
    "content": "Apple Inc. was founded on April 1, 1976..."
  }
]
```

Reference Document List:

[1] document_1.pdf
[2] document_2.pdf
```

### 6.2 EdgeQuake

**파일:** `edgequake-query/src/context.rs:68-117`

**컨텍스트 형식 (Markdown 블록):**

```markdown
### Knowledge Graph Data (Entities)

- **Apple Inc.** (ORGANIZATION) [connections: 15]: Technology company
  founded in 1976 by Steve Jobs, Steve Wozniak, and Ronald Wayne.

### Knowledge Graph Data (Relationships)

- Steve Jobs --[FOUNDED]--> Apple Inc.: Steve Jobs co-founded Apple Inc.
- Apple Inc. --[HEADQUARTERED_IN]--> Cupertino: Apple's headquarters

### Document Chunks

[1] (score: 0.950)
Apple Inc. was founded on April 1, 1976...

[2] (score: 0.870)
Under Steve Jobs' leadership...
```

### 6.3 컨텍스트 포맷 비교

| 측면 | LightRAG / RAG-Anything | EdgeQuake |
|------|------------------------|-----------|
| 포맷 | **JSON 블록** | **Markdown 블록** |
| 엔티티 정보 | entity, type, description, created_at, file_path | **name (TYPE) [connections: N]: description** |
| 관계 정보 | entity1, entity2, description, keywords, weight | **source --[TYPE]--> target: description** |
| 청크 정보 | reference_id, content | **[N] (score: X.XXX), content** |
| 참조 목록 | 별도 섹션 ([N] filename) | 점수 인라인 표시 |
| degree 메타데이터 | 없음 | **[connections: N]** 포함 |
| 유사도 점수 | 없음 | **score 표시** |

---

## 7. Stage 6: 최종 LLM 프롬프트 & 응답 생성

### 7.1 LightRAG / RAG-Anything — RAG 응답 프롬프트

**파일:** `lightrag/prompt.py:224-276`

```
---Role---

You are an expert AI assistant specializing in synthesizing information
from a provided knowledge base. Your primary function is to answer user
queries accurately by ONLY using the information within the provided
**Context**.

---Goal---

Generate a comprehensive, well-structured answer to the user query.
The answer must integrate relevant facts from the Knowledge Graph and
Document Chunks found in the **Context**.
Consider the conversation history if provided.

---Instructions---

1. Step-by-Step Instruction:
  - Determine user's query intent
  - Scrutinize both Knowledge Graph Data and Document Chunks
  - Weave extracted facts into coherent response
  - Track reference_id for citations
  - Generate references section

2. Content & Grounding:
  - Strictly adhere to provided context; DO NOT invent information
  - If answer cannot be found, state you don't have enough information

3. Formatting & Language:
  - Response in same language as user query
  - Markdown formatting required
  - Response type: {response_type} (default: "Multiple Paragraphs")

4. References Section Format:
  - Under heading: ### References
  - Format: * [n] Document Title
  - Maximum 5 most relevant citations
  - No content after references

6. Additional Instructions: {user_prompt}

---Context---

{context_data}
```

**프롬프트 조립 코드:** (`operate.py:3119-3135`)
```python
sys_prompt = PROMPTS["rag_response"].format(
    response_type=response_type,
    user_prompt=user_prompt,
    context_data=context_result.context,
)
response = await use_model_func(
    user_query,
    system_prompt=sys_prompt,
    history_messages=query_param.conversation_history,
)
```

### 7.2 LightRAG / RAG-Anything — NAIVE 응답 프롬프트

**파일:** `lightrag/prompt.py:278-330`

RAG 응답과 거의 동일하지만:
- "Knowledge Graph and Document Chunks" → **"Document Chunks"만**
- KG 데이터 참조 제거

### 7.3 EdgeQuake — 응답 프롬프트

**파일:** `edgequake-query/src/sota_engine/prompt.rs:75-115`

```
---Role---

You are an expert AI assistant specializing in synthesizing information
from a provided knowledge base. Your primary function is to answer user
queries accurately by ONLY using the information within the provided
**Context**.

---Goal---

Generate a comprehensive, well-structured answer to the user query.
The answer must integrate relevant facts from the Knowledge Graph and
Document Chunks found in the **Context**.

---Instructions---

1. Step-by-Step Reasoning:
  - Carefully determine user's query intent
  - Scrutinize both Knowledge Graph Data and Document Chunks
  - Weave extracted facts into coherent response
  - Own knowledge ONLY for fluent sentences, NOT external information

2. Content & Grounding:
  - Strictly adhere to provided context; DO NOT invent information
  - If answer cannot be fully determined, state what IS available
    and note what is missing. A partial answer with specific data
    is better than "insufficient information".

3. Formatting & Language:
  - Same language as user query
  - Markdown formatting for clarity

---Context---

{context_text}

---User Query---

{query}
```

### 7.4 최종 프롬프트 비교

| 측면 | LightRAG / RAG-Anything | EdgeQuake |
|------|------------------------|-----------|
| 역할 정의 | 동일 | 동일 |
| 지시사항 | 6개 항목 (참조 형식 상세) | **3개 항목 (간결)** |
| 참조 요구 | **### References 필수, 최대 5개** | 참조 형식 미지정 |
| 불충분 정보 처리 | "답변 불가 명시" | **"가용 정보로 부분 답변 + 누락 정보 명시"** |
| response_type 파라미터 | 있음 (기본: "Multiple Paragraphs") | 없음 |
| user_prompt 확장 | 있음 ("Additional Instructions") | 없음 |
| 대화 이력 | 있음 (conversation_history) | **QueryRequest.conversation_history** |
| 빈 컨텍스트 처리 | `PROMPTS["fail_response"]` | **하드코딩 사과 메시지** (prompt.rs:77) |
| LLM 프로바이더 | 서버 기본값 | **사용자 선택 프로바이더 오버라이드** |

---

## 8. 멀티모달 쿼리 (RAG-Anything 전용)

RAG-Anything은 LightRAG의 query 파이프라인을 **변경하지 않고**, 멀티모달 컨텐츠를 **텍스트 설명으로 변환하여 enhanced query를 생성**하는 전처리 계층을 추가.

### 8.1 3가지 쿼리 경로

**파일:** `RAG-Anything/raganything/query.py`

| 메서드 | 용도 | 파이프라인 |
|--------|------|-----------|
| `aquery()` (line 100) | 순수 텍스트 쿼리 | LightRAG.aquery() 직접 호출 |
| `aquery_with_multimodal()` (line 163) | 멀티모달 쿼리 | 컨텐츠 → 텍스트 변환 → LightRAG |
| `aquery_vlm_enhanced()` (line 303) | VLM 강화 쿼리 | LightRAG 결과에서 이미지 추출 → VLM 호출 |

### 8.2 멀티모달 쿼리 흐름

```
사용자 쿼리 + 멀티모달 컨텐츠 [{type: "image", img_path: ...}, ...]
    |
[1] 캐시 확인 (MD5 해시 기반)
    |
[2] 각 멀티모달 아이템 텍스트 변환
    ├─ 이미지: VLM으로 시각적 설명 생성 (QUERY_IMAGE_DESCRIPTION)
    ├─ 테이블: LLM으로 구조/패턴 분석 (QUERY_TABLE_ANALYSIS)
    ├─ 수식:  LLM으로 수학적 의미 설명 (QUERY_EQUATION_ANALYSIS)
    └─ 기타:  LLM으로 컨텐츠 분석 (QUERY_GENERIC_ANALYSIS)
    |
[3] Enhanced Query 조립
    "User query: {원본 쿼리}
     Related image content: {이미지 설명}
     Related table content: {테이블 분석}
     Please provide a comprehensive answer..."
    |
[4] Enhanced Query → LightRAG.aquery() (표준 파이프라인)
    |
[5] 결과 캐싱
```

### 8.3 VLM Enhanced 쿼리 흐름

```
사용자 쿼리
    |
[1] LightRAG에 only_need_prompt=True로 호출 → raw 프롬프트 획득
    |
[2] 프롬프트에서 "Image Path: *.jpg" 패턴 정규식 추출
    |
[3] 각 이미지 파일 검증
    ├─ 파일 존재 확인
    ├─ 확장자 확인 (.jpg, .png, .gif, .bmp, .webp, .tiff)
    ├─ 파일 크기 확인 (<50MB)
    └─ 보안 검증 (CWD, working_dir, parser_output_dir만 허용)
    |
[4] base64 인코딩 + [VLM_IMAGE_N] 마커 삽입
    |
[5] VLM 메시지 구축 (텍스트 + image_url 교차 배치)
    [
      {"role": "system", "content": "You are a helpful assistant..."},
      {"role": "user", "content": [
        {"type": "text", "text": "Context: ..."},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}},
        {"type": "text", "text": "\nUser Question: ..."}
      ]}
    ]
    |
[6] VLM 호출 → 최종 응답
```

### 8.4 쿼리 시 사용되는 프롬프트

**이미지 쿼리 프롬프트** (`prompt.py:303-309`):
```
시스템: "You are a professional image analyst who can accurately describe
         image content."
사용자: "Please briefly describe the main content, key elements, and
         important information in this image."
```

**테이블 쿼리 프롬프트** (`prompt.py:311-324`):
```
시스템: "You are a professional data analyst who can accurately analyze
         table data."
사용자: "Please analyze the main content, structure, and key information
         of the following table data:
         Table data: {table_data}
         Table caption: {table_caption}
         Please briefly summarize the main content, data characteristics,
         and important findings of the table."
```

**수식 쿼리 프롬프트** (`prompt.py:326-337`):
```
시스템: "You are a mathematics expert who can clearly explain mathematical
         formulas."
사용자: "Please explain the meaning and purpose of the following
         mathematical formula:
         LaTeX formula: {latex}
         Formula caption: {equation_caption}
         Please briefly explain the mathematical meaning, application
         scenarios, and importance of this formula."
```

### 8.5 핵심 설계 결정

**멀티모달 → 텍스트 변환 접근법:**
- 이미지/테이블/수식을 **base64나 원본 데이터로 그래프에 전달하지 않음**
- 대신 **LLM/VLM이 생성한 텍스트 설명**으로 변환하여 표준 텍스트 파이프라인 활용
- 장점: LightRAG의 그래프 탐색 로직 수정 불필요
- 단점: 멀티모달 정보가 텍스트로 축약되면서 정보 손실 가능

**LightRAG 파이프라인 무수정:**
- 그래프 탐색 로직 변경 없음
- 키워드 추출 변경 없음
- 프루닝/랭킹 변경 없음
- 최종 LLM 프롬프트 변경 없음

---

## 9. EdgeQuake 고유 기능

### 9.1 Query Intent 기반 자동 모드 선택

**파일:** `edgequake-query/src/keywords/intent.rs`

```rust
pub enum QueryIntent {
    Factual,      // → Local
    Relational,   // → Hybrid
    Exploratory,  // → Global
    Comparative,  // → Hybrid
    Procedural,   // → Local
}
```

- LLM이 키워드 추출 시 동시에 intent 분류
- `use_adaptive_mode = true` (기본값) 시 자동 적용
- 사용자가 mode를 명시하면 오버라이드

### 9.2 키워드 검증 (Keyword Validation)

**파일:** `edgequake-query/src/sota_engine/query_entry/query_basic.rs:72`

```
추출된 키워드 → 그래프에 존재하는지 확인 → 없으면 필터링
```

- 그래프에 없는 키워드로 임베딩 계산 시 **임베딩 희석** 발생
- 예: "STLA Medium"이 그래프에 없으면 임베딩에 노이즈로 작용

### 9.3 3중 병렬 임베딩

**파일:** `edgequake-query/src/sota_engine/mod.rs:177-200`

```rust
pub struct QueryEmbeddings {
    pub query: Vec<f32>,        // Naive 모드용
    pub high_level: Vec<f32>,   // Global 모드용 (hl_keywords)
    pub low_level: Vec<f32>,    // Local 모드용 (ll_keywords)
}
// 3개 임베딩을 tokio::join!으로 병렬 계산
```

- LightRAG: 각 검색 시점에 순차적으로 임베딩 계산
- EdgeQuake: **파이프라인 초기에 3개 동시 계산** → 레이턴시 감소

### 9.4 BM25 리랭킹 + 지능적 폴백

**파일:** `edgequake-query/src/sota_engine/reranking.rs`

- 기본 활성화 (`enable_rerank = true`)
- BM25로 쿼리 용어와 청크 텍스트 간 리터럴 매칭 점수 계산
- `min_rerank_score = 0.1` 이하 필터링
- **폴백:** 모든 청크가 필터링되면 원래 top_k 반환
  - 이유: 그래프가 찾은 청크는 BM25 점수가 0이어도 의미적으로 유효할 수 있음

### 9.5 LLM 프로바이더 오버라이드

**파일:** `edgequake-query/src/sota_engine/prompt.rs:121-144`

```rust
// 사용자가 UI에서 "OpenAI GPT-4" 선택 시:
// 키워드 추출 → GPT-4
// 최종 응답 생성 → GPT-4
// (서버 기본값 Ollama가 아닌, 사용자 선택 일관 적용)
```

### 9.6 인기 엔티티 폴백

**파일:** `edgequake-query/src/sota_engine/query_modes.rs:308-339`

GLOBAL 모드에서 벡터 검색이 빈 결과를 반환할 때:
```rust
graph_storage.get_popular_nodes_with_degree(
    max_entities,
    Some(2),   // min_degree: 연결 2개 이상인 노드만
    None,
    tenant_id,
    workspace_id,
)
```

### 9.7 비용 추적

```rust
pub struct QueryStats {
    pub embedding_time_ms: u64,
    pub retrieval_time_ms: u64,
    pub context_tokens: usize,
    pub completion_tokens: usize,
    pub total_time_ms: u64,
}
```

### 9.8 멀티테넌시 격리

모든 벡터 검색 결과와 그래프 쿼리에 `tenant_id`/`workspace_id` 필터 적용:
```rust
.filter(|r| self.matches_tenant_filter(&r.metadata, &tenant_id, &workspace_id))
```

---

## 10. 종합 비교표

### 10.1 파이프라인 단계별 비교

| 단계 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|------|----------|-------------|--------|-----------|
| **키워드 추출** | LLM (hl + ll) | LightRAG 그대로 | LightRAG 그대로 (수정 버전) | LLM (hl + ll + **intent**) |
| **모드 선택** | 수동 파라미터 | 수동 파라미터 | 수동 파라미터 | **자동 (intent 기반)** + 수동 오버라이드 |
| **키워드 검증** | 없음 | 없음 | 없음 | **그래프 존재 확인** |
| **임베딩 계산** | 필요 시 순차 | LightRAG 그대로 | LightRAG 그대로 | **3중 병렬 사전 계산** |
| **Local 탐색** | top_k=40 → 1-hop | LightRAG 그대로 | LightRAG 그대로 | top_k=60 (3x 오버샘플) → 1-hop |
| **Global 탐색** | top_k=40 → 역추출 | LightRAG 그대로 | LightRAG 그대로 | top_k=60 (3x 오버샘플) + **인기 엔티티 폴백** |
| **Hybrid 병합** | 라운드로빈 교대 | LightRAG 그대로 | LightRAG 그대로 | **Local 우선 + 리소스 분할** |
| **풀텍스트 검색** | 없음 | 없음 | **Elasticsearch BM25 병렬** | BM25 리랭킹 (post-retrieval) |
| **리랭킹** | 없음 | 없음 | ES 스코어 기반 | **BM25 (폴백 포함)** |
| **엔티티 토큰** | 6,000 | 6,000 | 6,000 (LightRAG 기본) | **10,000** |
| **관계 토큰** | 8,000 | 8,000 | 8,000 (LightRAG 기본) | **10,000** |
| **전체 토큰** | 30,000 | 30,000 | 30,000 | 30,000 |
| **컨텍스트 포맷** | JSON 블록 | JSON 블록 | JSON 블록 (LightRAG 기본) | **Markdown 블록** |
| **불충분 정보** | "답변 불가" | "답변 불가" | "답변 불가" | **"가용 정보로 부분 답변"** |
| **멀티모달 쿼리** | 없음 | **텍스트 변환 + VLM** | Vision 인덱스 병렬 검색 | 없음 |
| **VLM 이미지 처리** | 없음 | **base64 인라인 + VLM** | Vision 인덱스 저장 후 검색 | 없음 |
| **프로바이더 오버라이드** | 없음 | 없음 | 없음 | **사용자 선택 LLM 전파** |
| **캐싱** | 키워드 + 응답 | 키워드 + 응답 + 멀티모달 | **Redis** (키워드 + 응답) | 키워드 (24h TTL) |
| **비용 추적** | 없음 | 없음 | 없음 | **embedding/retrieval/tokens 추적** |
| **멀티테넌시** | 없음 | 없음 | **Collection 격리** | **tenant/workspace 격리** |
| **결정론적 결과** | HashMap (비결정적) | HashMap (비결정적) | HashMap (비결정적) | **Vec (결정론적)** |
| **청크 IDF penalty** | 없음 | 없음 | **ES IDF 적용** | **BM25 IDF 적용** |

### 10.2 핵심 설계 철학 차이

| 관점 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|------|----------|-------------|--------|-----------|
| **접근법** | 기본 Graph RAG 알고리즘 | LightRAG + 멀티모달 전처리 | LightRAG 수정 + **분산 인프라** | LightRAG 알고리즘 + **프로덕션 최적화** |
| **그래프 탐색 수정** | 원본 | **무수정** (완전 위임) | 수정된 LightRAG 위임 | **배치 최적화 + 폴백 전략** |
| **지능 계층** | LLM 키워드 추출 | LLM/VLM 컨텐츠 변환 | LightRAG 기반 + **5종 병렬 인덱스** | **LLM intent 분류 + 자동 라우팅** |
| **에러 처리** | 빈 결과 → 실패 응답 | LightRAG 위임 | LightRAG 위임 | **폴백 체인** (인기 엔티티, BM25 폴백, 부분 답변) |
| **토큰 효율** | 청크 중심 (53%) | LightRAG 그대로 | LightRAG 그대로 | **그래프 중심 (66%)** — 요약된 그래프 데이터가 더 밀도 높음 |
| **확장성** | 단일 프로세스 | 단일 프로세스 | **Celery + K8s 수평 확장** | Rust 멀티코어 활용 |

### 10.3 파일 위치 참조

**LightRAG:**
- 쿼리 진입점: `lightrag/lightrag.py:2401-2843`
- 쿼리 연산: `lightrag/operate.py:3015-5003`
- 프롬프트: `lightrag/prompt.py:224-432`
- 상수: `lightrag/constants.py:45-100`

**ApeRAG:**
- 인덱스 타입 정의: `aperag/index/base.py`
- 그래프 인덱서 (LightRAG 래퍼): `aperag/index/graph_index.py`
- 벡터 인덱서 (Qdrant): `aperag/index/vector_index.py`
- 풀텍스트 인덱서 (Elasticsearch): `aperag/index/fulltext_index.py`
- 요약 인덱서: `aperag/index/summary_index.py`
- Vision 인덱서: `aperag/index/vision_index.py`
- 인덱스 관리자: `aperag/index/manager.py`
- 쿼리 모델: `aperag/query/query.py`
- 태스크 오케스트레이터: `aperag/tasks/document.py`

**RAG-Anything:**
- 쿼리 메서드: `raganything/query.py:1-819`
- 프롬프트: `raganything/prompt.py:1-354`

**EdgeQuake:**
- 쿼리 엔진: `edgequake-query/src/sota_engine/query_entry/query_basic.rs`
- 모드별 탐색: `edgequake-query/src/sota_engine/query_modes.rs`
- 키워드 추출: `edgequake-query/src/keywords/llm_extractor.rs`
- 프롬프트: `edgequake-query/src/sota_engine/prompt.rs`
- 컨텍스트: `edgequake-query/src/context.rs`
- 절삭: `edgequake-query/src/truncation.rs`
- 리랭킹: `edgequake-query/src/sota_engine/reranking.rs`

---

## 11. 추가 과제 노트

### 11-1. 컨텍스트 자연어 재구성 부재

세 프레임워크 모두 그래프 탐색 결과를 **구조화된 포맷 그대로** 프롬프트에 삽입한다. 중간에 자연어 내러티브로 재구성하는 단계가 없음.

| 프레임워크 | 컨텍스트 포맷 | 자연어 재구성 |
|-----------|-------------|-------------|
| LightRAG / RAG-Anything | JSON 배열 그대로 | 없음 |
| EdgeQuake | Markdown 나열 | 없음 |

**관련 연구 및 접근법:**
- **Microsoft GraphRAG**: community summary로 엔티티/관계 클러스터를 자연어 요약 → 프롬프트에 삽입. 구조화 데이터보다 LLM이 더 잘 이해.
- **RAPTOR**: 트리 기반 재귀 요약. 리프 청크를 클러스터링 → 요약 → 상위 노드로 반복.
- **관련 논문**: 구조화 데이터(JSON/테이블)를 자연어로 변환 후 LLM에 제공하면 추론 정확도가 향상된다는 연구 다수 존재 (e.g., "Structured Data → Natural Language verbalization").

**현재 방식의 한계:**
1. LLM이 JSON/Markdown 구조를 파싱하는 데 토큰을 소모 (형식 오버헤드)
2. 엔티티 간 관계의 맥락이 나열식으로 분리되어 추론 연결이 어려움
3. 동일 토큰 버짓 내에서 자연어 내러티브가 더 높은 정보 밀도를 전달할 수 있음

**가능한 개선:**
- 프루닝 후 최종 컨텍스트를 LLM에 한 번 더 보내 자연어 요약 생성 → 최종 프롬프트에 삽입
- 트레이드오프: LLM 호출 1회 추가 vs 응답 품질 향상
- GraphRAG처럼 인제스션 시 사전 요약하면 쿼리 타임 비용은 없지만, 쿼리 독립적인 요약이라 쿼리 특화 맥락 제공 불가

### 11-2. Document Registry & 이질적 검색 전략

현재 세 프레임워크 모두 **모든 문서를 동일한 파이프라인으로 인제스션하고 동일한 방식으로 검색**한다. 하지만 실제 사용 환경에서는 문서마다 최적의 처리 수준이 다르다.

**핵심 아이디어: 문서별 처리 티어(tier) 관리**

| 티어 | 인제스션 | 검색 방식 | 적합한 문서 |
|------|---------|----------|-----------|
| **T0: Raw** | 처리 없음 | grep / 전문 검색 / QMD | 로그, 설정 파일, 코드, 자주 안 쓰는 참고자료 |
| **T1: Naive RAG** | 청킹 + 임베딩만 | 벡터 유사도 검색 | FAQ, 단순 문서, 짧은 메모 |
| **T2: Full GraphRAG** | 청킹 + 엔티티 추출 + 그래프 구축 | KG 탐색 + 벡터 + BM25 | 논문, 기술 문서, 복잡한 관계가 있는 문서 |

**승격/강등 메커니즘:**
- 자주 질의되는 T0 문서 → T1으로 승격 (임베딩 생성)
- T1에서 관계 기반 질의가 반복되면 → T2로 승격 (그래프 구축)
- 오래된/미사용 T2 문서 → 그래프 노드 프루닝, T1로 강등
- 사용 패턴 기반 자동 승격 또는 수동 지정

**쿼리 타임 라우팅 — 이질적 검색 오케스트레이션:**

단일 쿼리에 대해 여러 티어의 문서를 동시에 탐색해야 한다. 이는 단순 RAG가 아닌 **에이전트/툴콜링 패턴**이 필요함을 의미한다.

```
사용자 쿼리
    |
[1] 쿼리 의도 분류 + 관련 문서 티어 판별
    |
[2] 티어별 검색 도구 호출 (병렬)
    ├─ T0 문서 → grep/FTS 도구
    ├─ T1 문서 → 벡터 검색 도구
    └─ T2 문서 → GraphRAG 탐색 도구
    |
[3] 결과 통합 + 재랭킹
    |
[4] 통합 컨텍스트로 최종 응답 생성
```

**필요한 구성 요소:**
1. **Document Registry**: 문서별 메타데이터 (티어, 마지막 접근일, 질의 빈도, 인제스션 상태)
2. **Tier Router**: 쿼리 → 어떤 티어의 문서를 탐색할지 결정 (LLM 또는 규칙 기반)
3. **Tool Interface**: 각 티어에 대한 검색 도구를 MCP/function calling으로 노출
4. **Result Merger**: 이질적 검색 결과(텍스트 스니펫, 벡터 청크, 그래프 컨텍스트)를 통합 랭킹
5. **Promotion Engine**: 사용 패턴 기반 자동 승격/강등 로직

**현재 프레임워크와의 갭:**
- LightRAG/RAG-Anything: 문서 레지스트리 개념 자체가 없음. `doc_status`는 처리 상태 추적일 뿐.
- EdgeQuake: `workspace` 단위 격리는 있지만 문서별 티어 구분은 없음. 모든 문서가 동일 파이프라인.

**트레이드오프:**
- 구현 복잡도 증가 (레지스트리, 라우터, 머저 모두 새로 필요)
- 하지만 대규모 문서 컬렉션에서 인제스션 비용과 검색 품질을 동시에 최적화할 수 있는 유일한 방법
- 모든 문서를 Full GraphRAG로 처리하는 건 비현실적 (RAG-Anything의 LLM 호출 폭발 문제 참조: `ingestion_pipeline_comparison.md` 섹션 5-1)

### 11-3. 관심 기법 — 통합 검토 대상

현재 세 프레임워크에 미적용이지만 통합 시 가치가 있을 수 있는 기법들. 각각 통합 난이도와 트레이드오프가 다르다.

#### HyDE (Hypothetical Document Embeddings)

- **원리**: 쿼리에 대해 LLM이 "가상의 정답 문서"를 생성 → 그 문서의 임베딩으로 벡터 검색
- **장점**: 쿼리-문서 간 임베딩 공간 불일치 해소. 특히 짧은 쿼리 → 긴 문서 매칭에 효과적
- **통합 난이도**: 낮음. 벡터 검색 전에 LLM 호출 1회 추가만 하면 됨
- **트레이드오프**: 쿼리 레이턴시 +1 LLM 호출. 가상 문서가 hallucinate하면 검색 방향이 틀어짐
- **GraphRAG에서의 위치**: 키워드 추출 대신 또는 병행. entities_vdb/relationships_vdb 검색에 HyDE 임베딩 투입 가능

#### Neural Sparse Search (SPLADE 등)

- **원리**: 학습된 sparse 벡터로 검색. BM25의 정확한 토큰 매칭 + dense retrieval의 의미 확장을 결합
- **장점**: BM25보다 recall 높고, dense보다 해석 가능. 희귀 용어에 강함
- **통합 난이도**: 중간. 별도 인코더 모델 필요 (SPLADE, Elastic Learned Sparse 등). 인덱싱 파이프라인 변경
- **트레이드오프**: 추가 모델 의존성. 인덱싱 시 sparse 벡터 생성 비용. 멀티테넌시 환경에서 인덱스 관리 복잡도 증가
- **GraphRAG에서의 위치**: EdgeQuake의 BM25 리랭킹을 대체하거나, 엔티티/관계 검색의 1차 필터로 사용 가능

#### VisRAG / ColPali / Multi-Vector Retrieval

- **원리**: 문서 페이지를 이미지로 렌더링 → Vision 모델로 멀티벡터 임베딩 생성 → 페이지 단위 검색. 텍스트 추출/OCR 불필요
- **장점**: 레이아웃, 표, 차트, 수식 등을 시각적으로 이해. OCR 오류 회피. 파싱 파이프라인 자체를 건너뜀
- **통합 난이도**: 높음. 기존 텍스트 기반 파이프라인과 근본적으로 다른 패러다임. 그래프 구축 자체가 텍스트 전제
- **트레이드오프**:
  - GraphRAG와 결합하기 가장 어려움 — 엔티티 추출이 텍스트에 의존하므로 VisRAG의 "텍스트 없는" 철학과 충돌
  - 검색은 VisRAG, 그래프 구축은 기존 파이프라인으로 이원화할 수 있으나 복잡도 급증
  - RAG-Anything의 MinerU 파싱을 VisRAG로 대체하면 멀티모달 처리가 단순해질 수 있지만, 그래프에 넣을 텍스트가 없어짐
- **현실적 접근**: Document Registry (11-2)의 T0/T1 티어에서 VisRAG를 사용하고, T2(GraphRAG)는 기존 텍스트 파이프라인 유지하는 하이브리드

#### 통합 난이도 요약

| 기법 | 통합 난이도 | 추가 비용 | GraphRAG 궁합 |
|------|-----------|----------|--------------|
| HyDE | 낮음 (벡터 검색 전 LLM 1회) | 쿼리당 +1 LLM | 좋음 — 키워드 추출과 병행 가능 |
| Neural Sparse | 중간 (인코더 모델 + 인덱스 변경) | 인덱싱 시 인코더 비용 | 좋음 — BM25 대체/보완 |
| VisRAG/Multi-Vector | 높음 (패러다임 전환) | Vision 모델 + 멀티벡터 인덱스 | 충돌 — 텍스트 없는 검색 vs 텍스트 기반 그래프 |
