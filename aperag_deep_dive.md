# ApeRAG 심층 분석 리포트

**작성일:** 2026-03-23
**분석 대상:** https://github.com/apecloud/ApeRAG (v0.7.0-alpha.34, commit 2d119577)
**분석 범위:** 소스코드 레벨 — 그래프 저장소, 쿼리 파이프라인, 인덱스 구조, N+1 문제

---

## 목차

1. [ApeRAG 개요](#1-aperag-개요)
2. [전체 아키텍처](#2-전체-아키텍처)
3. [5종 인덱스 구조](#3-5종-인덱스-구조)
4. [그래프 저장소: PGOpsSyncGraphStorage 전체 분석](#4-그래프-저장소-pgopssyncstorage-전체-분석)
5. [N+1 문제 상세 분석](#5-n1-문제-상세-분석)
6. [쿼리 파이프라인](#6-쿼리-파이프라인)
7. [엔티티 머징 (ApeRAG 핵심 수정)](#7-엔티티-머징-aperag-핵심-수정)
8. [Celery 재조정 시스템](#8-celery-재조정-시스템)
9. [Apache AGE를 선택하지 않은 이유](#9-apache-age를-선택하지-않은-이유)
10. [관계형 테이블 그래프 vs 네이티브 그래프 DB](#10-관계형-테이블-그래프-vs-네이티브-그래프-db)
11. [성능 특성 요약](#11-성능-특성-요약)

---

## 1. ApeRAG 개요

ApeRAG는 APECloud가 개발한 프로덕션급 Python GraphRAG 플랫폼이다. 핵심은 HKUDS/LightRAG를 깊이 수정하여 엔터프라이즈 운영 환경에 맞게 확장한 것이다.

| 항목 | 내용 |
|------|------|
| 언어 | Python (FastAPI + Celery + React UI) |
| LightRAG 관계 | 수정된 LightRAG 포함 (`aperag/graph/lightrag/`) |
| 쿼리 모드 | Naive, Local, Global, Hybrid, Mix (LightRAG 동일 5가지) |
| 스토리지 스택 | PostgreSQL (pgvector + 관계형 테이블) + Qdrant + Elasticsearch + Redis |
| 인덱스 종류 | Vector, Fulltext, Graph, Summary, Vision (5종) |
| 프로덕션 기능 | 멀티테넌시, Celery 분산 태스크, 감사 로그, MCP 지원, K8s |
| LLM | OpenAI 기본, 환경변수로 교체 가능 |
| 문서 파싱 | MinerU (PDF, 표, 수식, 이미지) |

---

## 2. 전체 아키텍처

```
[사용자 / API]
      |
  FastAPI (aperag/api/)
      |
  DocumentIndexManager (aperag/index/manager.py)
      |-- 5종 인덱스 레코드 생성 (PENDING 상태)
      |
  Celery Reconciler (aperag/tasks/reconciler.py)
      |-- PENDING 상태 인덱스 폴링
      |
  DocumentIndexTask (aperag/tasks/document.py)
      |-- parse_document()     -> ParsedDocumentData
      |-- create_index(type)   -> IndexTaskResult
          |
          |-- VectorIndexer    -> Qdrant (청크 임베딩)
          |-- FulltextIndexer  -> Elasticsearch (BM25)
          |-- GraphIndexer     -> LightRAG 수정본
          |   |-- 엔티티 추출 -> 엔티티 머징 -> PGOpsSyncGraphStorage
          |   |-- 엔티티 임베딩 -> PGOpsSyncVectorStorage (pgvector)
          |-- SummaryIndexer   -> PostgreSQL (LLM 요약)
          |-- VisionIndexer    -> 이미지 분석 저장
```

### LightRAG 수정 범위

ApeRAG가 포함한 LightRAG는 원본 대비 핵심 변경 사항이 있다:

**파일:** `aperag/graph/lightrag/kg/__init__.py`

```python
STORAGES = {
    "Neo4JSyncStorage":          Neo4JSyncStorage,          # 원본 LightRAG 기본
    "PGOpsSyncGraphStorage":     PGOpsSyncGraphStorage,     # ApeRAG 추가
    "PGOpsSyncKVStorage":        PGOpsSyncKVStorage,        # ApeRAG 추가
    "PGOpsSyncVectorStorage":    PGOpsSyncVectorStorage,    # ApeRAG 추가
}
```

**파일:** `aperag/graph/lightrag/lightrag_manager.py`

```python
# ApeRAG 배포 기본값 (원본 LightRAG와 다름)
GRAPH_INDEX_GRAPH_STORAGE  = "PGOpsSyncGraphStorage"  # 원본: Neo4JSyncStorage
GRAPH_INDEX_KV_STORAGE     = "PGOpsSyncKVStorage"
GRAPH_INDEX_VECTOR_STORAGE = "PGOpsSyncVectorStorage"
ENTITY_EXTRACT_MAX_GLEANING = 0                        # 원본: 1 (비용 절감)
DEFAULT_LANGUAGE            = "zh-CN"                  # 원본: en
LLM_MODEL_MAX_ASYNC         = 20
```

주석의 설계 철학:
> "Removed global state management for true concurrent processing.
> Added stateless interfaces for Celery/Prefect integration.
> Unified connection pool and configuration management."

---

## 3. 5종 인덱스 구조

**파일:** `aperag/index/manager.py`, `aperag/db/models.py`

```python
# manager.py
all_index_types = [
    DocumentIndexType.VECTOR,     # Qdrant — 청크 임베딩
    DocumentIndexType.FULLTEXT,   # Elasticsearch — BM25
    DocumentIndexType.GRAPH,      # PostgreSQL 관계형 테이블 — 엔티티/관계
    DocumentIndexType.SUMMARY,    # PostgreSQL — LLM 요약 텍스트
    DocumentIndexType.VISION,     # 이미지 분석 결과
]
```

### 인덱스 상태 머신

```
PENDING -> RUNNING -> COMPLETE
                   -> FAILED
                   -> SKIPPED  (is_enabled() == False)
```

각 인덱스는 독립적으로 상태를 관리한다. 문서 업데이트 시 버전이 증가하고, 이전 버전의 인덱스는 무효화된다.

### 인덱스별 스토리지 매핑

| 인덱스 | 스토리지 | 필수 여부 | 비고 |
|--------|---------|-----------|------|
| VECTOR | Qdrant | 필수 | 청크 임베딩 벡터 |
| FULLTEXT | Elasticsearch | 필수 | BM25 자동 적용 |
| GRAPH | PostgreSQL (관계형 + pgvector) | 선택 | enable_knowledge_graph 설정 |
| SUMMARY | PostgreSQL | 선택 | enable_summary 설정 |
| VISION | 별도 저장소 | 선택 | 이미지 콘텐츠 |

---

## 4. 그래프 저장소: PGOpsSyncGraphStorage 전체 분석

**파일:** `aperag/graph/lightrag/kg/pg_ops_sync_graph_storage.py`
**파일:** `aperag/db/repositories/graph.py` — 실제 SQL

### 4.1 테이블 구조

그래프 데이터는 2개의 관계형 테이블에 저장된다:

```sql
-- lightrag_graph_nodes
(workspace TEXT, entity_id TEXT, entity_name TEXT, entity_type TEXT,
 description TEXT, source_id TEXT, file_path TEXT,
 createtime TIMESTAMP, updatetime TIMESTAMP)
UNIQUE(workspace, entity_id)

-- lightrag_graph_edges
(workspace TEXT, source_entity_id TEXT, target_entity_id TEXT,
 weight FLOAT, keywords TEXT, description TEXT, source_id TEXT, file_path TEXT,
 createtime TIMESTAMP, updatetime TIMESTAMP)
UNIQUE(workspace, source_entity_id, target_entity_id)
```

그래프 전용 확장(Apache AGE, Neo4j 등) 없이 순수 관계형 구조다.

### 4.2 asyncio.to_thread 래핑 패턴

`PGOpsSyncGraphStorage`의 모든 메서드는 동기 SQLAlchemy ORM을 `asyncio.to_thread`로 감싸서 LightRAG의 async 인터페이스에 맞춘다:

```python
# pg_ops_sync_graph_storage.py:61-70
async def upsert_node(self, node_id: str, node_data: dict) -> None:
    def _sync_upsert_node():
        from aperag.db.ops import db_ops
        db_ops.upsert_graph_node(self.workspace, node_id, node_data)
    await asyncio.to_thread(_sync_upsert_node)
```

이 패턴으로 Celery worker의 스레드 풀에서 동기 DB 연산을 실행하면서도 async LightRAG 인터페이스를 준수한다.

### 4.3 Upsert 구현

```python
# graph.py:42-68
stmt = insert(LightRAGGraphNode).values(
    workspace=workspace, entity_id=node_id, ...
)
stmt = stmt.on_conflict_do_update(
    index_elements=["workspace", "entity_id"],
    set_=dict(
        entity_name=stmt.excluded.entity_name,
        description=stmt.excluded.description,
        updatetime=func.now(),
    ),
)
session.execute(stmt)
```

PostgreSQL의 `INSERT ... ON CONFLICT DO UPDATE`로 원자적 upsert를 수행한다. 동시에 여러 Celery worker가 같은 엔티티를 upsert해도 race condition이 없다.

### 4.4 Batch 연산 (최적화된 경우)

**node degree (batch) — CTE + UNNEST:**
```sql
-- graph.py:386-410
WITH node_list AS (SELECT unnest(:node_ids) AS entity_id),
outgoing_counts AS (
    SELECT e.source_entity_id AS entity_id, COUNT(*) AS out_degree
    FROM lightrag_graph_edges e
    WHERE e.workspace = :workspace AND e.source_entity_id = ANY(:node_ids)
    GROUP BY e.source_entity_id
),
incoming_counts AS (
    SELECT e.target_entity_id AS entity_id, COUNT(*) AS in_degree
    FROM lightrag_graph_edges e
    WHERE e.workspace = :workspace AND e.target_entity_id = ANY(:node_ids)
    GROUP BY e.target_entity_id
)
SELECT nl.entity_id,
       COALESCE(oc.out_degree, 0) + COALESCE(ic.in_degree, 0) AS total_degree
FROM node_list nl
LEFT JOIN outgoing_counts oc ON nl.entity_id = oc.entity_id
LEFT JOIN incoming_counts ic ON nl.entity_id = ic.entity_id
```
N개 노드의 degree를 **1번** 쿼리에 처리한다.

**1-hop 엣지 (batch) — UNION ALL + ANY:**
```sql
-- graph.py:482-504
WITH node_list AS (SELECT unnest(:node_ids) AS entity_id),
outgoing_edges AS (SELECT e.source_entity_id AS node_id, ...
                   FROM lightrag_graph_edges e
                   WHERE e.workspace=:workspace AND e.source_entity_id=ANY(:node_ids)),
incoming_edges AS (SELECT e.target_entity_id AS node_id, ...
                   FROM lightrag_graph_edges e
                   WHERE e.workspace=:workspace AND e.target_entity_id=ANY(:node_ids))
SELECT node_id, source_entity_id, target_entity_id FROM outgoing_edges
UNION ALL
SELECT node_id, source_entity_id, target_entity_id FROM incoming_edges
ORDER BY node_id
```
N개 노드의 모든 인접 엣지를 **1번** 쿼리에 처리한다.

---

## 5. N+1 문제 상세 분석

### 5.1 N+1이란?

쿼리를 "1번" 실행해서 N개의 결과를 받고, 각 결과에 대해 "또 1번씩" 추가 쿼리를 실행하는 패턴이다:

```
BAD (N+1):
  쿼리 1: 엔티티 목록 N개 가져오기
  쿼리 2: 엔티티[0]의 degree 조회
  쿼리 3: 엔티티[1]의 degree 조회
  ...
  쿼리 N+1: 엔티티[N-1]의 degree 조회
  -> 총 N+1번

GOOD (batch):
  쿼리 1: 엔티티 목록 N개 가져오기
  쿼리 2: 엔티티 N개의 degree 한 번에 조회
  -> 총 2번
```

### 5.2 ApeRAG에서 N+1이 발생하는 지점

#### [WARN] get_graph_node_degree() — 단일 노드 버전

```python
# graph.py:212-228
def get_graph_node_degree(self, workspace: str, node_id: str) -> int:
    def _get_degree(session):
        outgoing_count = session.execute(
            select(func.count(LightRAGGraphEdge.id)).where(
                and_(workspace == workspace, source_entity_id == node_id)
            )
        ).scalar()                          # 쿼리 1
        incoming_count = session.execute(
            select(func.count(LightRAGGraphEdge.id)).where(
                and_(workspace == workspace, target_entity_id == node_id)
            )
        ).scalar()                          # 쿼리 2
        return outgoing_count + incoming_count
    return self._execute_query(_get_degree)
```

이 함수를 N개 노드에 반복 호출하면 **2N번** 쿼리가 발생한다.

**대안:** `get_graph_node_degrees_batch()` — CTE로 1번에 처리 (이미 구현됨)

#### [WARN] get_graph_edges_batch() — OR 폭발

```python
# graph.py:429-438
conditions = []
for source, target in edge_pairs:
    conditions.append(
        and_(LightRAGGraphEdge.source_entity_id == source,
             LightRAGGraphEdge.target_entity_id == target)
    )
stmt = select(LightRAGGraphEdge).where(and_(workspace == workspace, or_(*conditions)))
# 생성되는 SQL: WHERE workspace=? AND ((src=A AND tgt=B) OR (src=C AND tgt=D) OR ...)
```

edge pair 수가 100개면 100개의 OR 절이 생성된다. PostgreSQL 쿼리 플래너는 OR 절이 많아질수록 최적화가 어려워진다.

**더 나은 방법:**
```sql
-- VALUES 절 방식 (미구현)
SELECT e.* FROM lightrag_graph_edges e
JOIN (VALUES ('A','B'), ('C','D'), ...) AS pairs(src, tgt)
  ON e.source_entity_id = pairs.src AND e.target_entity_id = pairs.tgt
WHERE e.workspace = :workspace
```

### 5.3 N+1이 발생하지 않는 지점 (이미 최적화됨)

| 연산 | 최적화 방법 | 비고 |
|------|------------|------|
| node 데이터 (batch) | `.in_(node_ids)` | graph.py:348 |
| node degree (batch) | CTE + UNNEST | graph.py:386 |
| 1-hop 엣지 (batch) | UNION ALL + ANY | graph.py:482 |
| edge degree (batch) | node_degrees_batch 재활용 | pg_ops_sync_graph_storage.py:190-210 |

### 5.4 실제 영향 평가

LightRAG의 탐색 패턴은 기본적으로 batch API를 사용한다:

```
query -> 벡터 검색(상위 40개 엔티티)
      -> get_nodes_batch(40개)           # batch [OK]
      -> get_node_degrees_batch(40개)    # batch [OK]
      -> get_nodes_edges_batch(40개)     # batch [OK]
      -> 엣지 dedup -> get_edges_batch() # OR 폭발 가능 [WARN]
```

따라서 **일반적인 쿼리에서는 N+1이 발생하지 않는다.** 단, edge pairs 수가 많아지는 dense 그래프에서 `get_graph_edges_batch()`의 OR 폭발이 문제가 될 수 있다.

---

## 6. 쿼리 파이프라인

ApeRAG의 쿼리는 수정된 LightRAG를 통해 처리되며, 쿼리 모드는 원본과 동일하다.

```
사용자 쿼리
    |
[1] 키워드 추출 (LLM)
    |- high_level_keywords -> Global/Hybrid
    `- low_level_keywords  -> Local/Hybrid
    |
[2] 쿼리 모드 디스패치
    |- LOCAL:  엔티티 중심 (PGOpsSyncVectorStorage 벡터 검색 -> 1-hop)
    |- GLOBAL: 관계 중심 (PGOpsSyncVectorStorage -> 엔티티 역추출)
    |- HYBRID: Local + Global 병렬
    |- MIX:    KG + Qdrant 청크
    `- NAIVE:  Qdrant 순수 벡터
    |
[3] 그래프 탐색 (PGOpsSyncGraphStorage)
    |- get_nodes_batch()           -> PostgreSQL nodes 테이블
    |- get_node_degrees_batch()    -> CTE 집계
    `- get_nodes_edges_batch()     -> UNION ALL
    |
[4] 컨텍스트 조립
    |- 엔티티 + 관계 + 청크 결합
    `- 토큰 버짓 내 정렬/절삭
    |
[5] LLM 응답 생성
```

### 엔티티 임베딩 스토리지

벡터 검색에는 `PGOpsSyncVectorStorage`(pgvector)가 사용된다. Qdrant는 문서 청크 임베딩 전용이며, 엔티티/관계 임베딩은 PostgreSQL pgvector에 저장된다.

```
엔티티 벡터 검색: pgvector (PGOpsSyncVectorStorage)
청크 벡터 검색:   Qdrant (VectorIndexer)
풀텍스트 검색:    Elasticsearch (FulltextIndexer)
```

---

## 7. 엔티티 머징 (ApeRAG 핵심 수정)

ApeRAG가 LightRAG에 추가한 가장 중요한 기능이다. 동일한 의미를 가지는 다른 표현의 엔티티를 통합한다.

**예시:**
```
"삼성전자" + "Samsung Electronics" + "삼성" -> 단일 정규화 엔티티
```

원본 LightRAG는 이 3개를 별도 노드로 저장하여 그래프가 파편화된다. ApeRAG의 엔티티 머징은 임베딩 유사도 또는 LLM 판단으로 동의어 클러스터를 통합한다.

이 과정은 `PGOpsSyncGraphStorage` 레이어 위, LightRAG 수정 모듈에서 처리되므로 DB 스키마에는 영향이 없다. 최종 저장 시에는 이미 머징된 엔티티 ID로 upsert된다.

---

## 8. Celery 재조정 시스템

**파일:** `aperag/tasks/reconciler.py`

인덱싱은 HTTP 요청-응답 사이클이 아닌 비동기 작업 큐로 처리된다:

```
문서 업로드 API 응답 (즉시)
    -> DocumentIndexManager: 5종 인덱스 레코드 PENDING 생성
    -> HTTP 200 반환

별도 Celery Beat 스케줄러
    -> reconciler.py 주기적 실행
    -> PENDING 상태 인덱스 조회
    -> 각 인덱스에 맞는 Celery task 발송
    -> task 완료 시 상태 COMPLETE 업데이트
```

**장점:**
- 인덱싱 실패 시 PENDING 상태 유지 -> 자동 재시도
- 여러 Celery worker가 독립적으로 병렬 처리 가능
- 인덱스 타입별 독립 스케일링

**단점:**
- 인덱싱 완료 시점까지 지연 발생 (실시간 아님)
- 폴링 방식이므로 reconciler 주기에 따라 인덱싱 시작 지연

---

## 9. Apache AGE를 선택하지 않은 이유

### 9.1 기술적 배경

Apache AGE는 PostgreSQL 확장으로, Cypher 쿼리를 사용하는 그래프 DB 기능을 추가한다. 처음 보면 ApeRAG에 적합해 보이지만, 실제로는 선택하지 않았다.

### 9.2 선택하지 않은 이유 (소스코드 증거 기반)

**이유 1: 스택 통일성**

`kg/__init__.py` 주석:
> "Unified connection pool and configuration management"

Apache AGE는 별도 설치 (`CREATE EXTENSION age;`), Cypher 쿼리 파서, 세션마다 `SET search_path = ag_catalog` 실행이 필요하다. ApeRAG의 기존 SQLAlchemy ORM 스택과 연결 풀을 공유하기 어렵다.

**이유 2: Celery stateless 설계와 충돌**

AGE는 세션 상태(`search_path`)를 요구하지만, Celery worker는 매 태스크마다 독립적인 DB 연결을 사용한다. stateless 연결 풀에서 세션 상태를 관리하면 worker 간 충돌 가능성이 있다.

**이유 3: 원본 LightRAG가 Neo4j 기반**

`lightrag.py:99`:
```python
graph_storage: str = field(default="Neo4JSyncStorage")
```

ApeRAG의 목표는 "Neo4j 의존성 제거"였다. AGE로 교체하는 것은 "다른 그래프 전용 엔진으로 의존성 이전"에 불과했기 때문에, 이미 운영 중인 PostgreSQL에 관계형 테이블을 추가하는 방식을 선택했다.

**이유 4: 실제 쿼리 패턴이 단순**

LightRAG의 그래프 사용 패턴:
- 엔티티 upsert
- 1-hop 이웃 조회
- degree 계산

이 수준은 Cypher 없이 SQL로 충분히 구현 가능하다. AGE의 `MATCH (n)-[*1..3]-(m)` 같은 재귀 탐색이 필요한 시나리오가 현재 LightRAG 쿼리 알고리즘에 없다.

### 9.3 관계형 테이블 선택의 트레이드오프

| 항목 | PostgreSQL 관계형 테이블 | Apache AGE |
|------|------------------------|------------|
| 설치 복잡도 | 추가 없음 | Extension 설치 필요 |
| 연결 풀 | SQLAlchemy 통합 | 별도 설정 필요 |
| 1-hop 탐색 | UNION ALL (효율적) | Cypher (동등) |
| multi-hop 탐색 | 재귀 CTE 또는 Python 루프 | Cypher `[*1..n]` (우수) |
| 유지보수 | 기존 ORM 그대로 | Cypher 학습 비용 |
| 운영 환경 | 단일 PostgreSQL 인스턴스 | 동일 인스턴스 but 확장 |

---

## 10. 관계형 테이블 그래프 vs 네이티브 그래프 DB

LightRAG 계열 프레임워크들의 그래프 스토리지 선택을 비교하면:

| 프레임워크 | 그래프 스토리지 | 탐색 방식 |
|-----------|--------------|---------|
| LightRAG (원본) | Neo4j (기본) / NetworkX (인메모리) | Cypher / Python dict |
| RAG-Anything | LightRAG 위임 (동일) | 동일 |
| **ApeRAG** | **PostgreSQL 관계형 테이블** | **SQL + Python** |
| EdgeQuake | PostgreSQL tsvector + 관계형 | SQL + Rust |

### 실용적 관점

LightRAG의 탐색 알고리즘은 근본적으로 **"벡터로 시작 노드 찾기 → 1-hop 이웃 수집"** 패턴이다. 이 패턴에서는:

- 네이티브 그래프 DB의 장점(재귀 탐색, 그래프 알고리즘)이 발휘되지 않는다
- 관계형 테이블의 UNION ALL + INDEX SCAN이 충분히 효율적이다
- 운영 단순성(단일 DB 엔진)이 더 중요해진다

반면, **그래프 알고리즘이 복잡해질 경우**(PageRank, 커뮤니티 탐지, 다단계 추론) 네이티브 그래프 DB가 명확히 우세하다. EdgeQuake가 커뮤니티 알고리즘을 Rust로 직접 구현한 것도 이 한계를 인식했기 때문이다.

---

## 11. 성능 특성 요약

### 인덱싱 (Ingestion)

| 항목 | 평가 | 상세 |
|------|------|------|
| 병렬 인덱싱 | 우수 | Celery로 5종 인덱스 독립 병렬 실행 |
| 엔티티 머징 | 우수 | 동의어 통합으로 그래프 품질 향상 |
| upsert 안전성 | 우수 | ON CONFLICT DO UPDATE, race condition 없음 |
| 인덱싱 지연 | 보통 | Celery 폴링 방식 (즉시 아님) |
| 문서 파싱 | 우수 | MinerU (PDF, 표, 수식, 이미지 전처리) |

### 쿼리 (Query)

| 항목 | 평가 | 상세 |
|------|------|------|
| 1-hop 탐색 | 우수 | UNION ALL + ANY, 1번 쿼리 |
| batch degree 계산 | 우수 | CTE + UNNEST, 1번 쿼리 |
| edge pairs 조회 | 보통 | OR 폭발 가능 (pair 수 증가 시) |
| multi-hop 탐색 | 미구현 | max_depth 파라미터 무시됨 |
| 하이브리드 검색 | 우수 | Qdrant(벡터) + ES(BM25) 아키텍처 내장 |
| pruning | 미흡 | 알파벳 순 truncation (중요도 무관) |

### 운영 (Operations)

| 항목 | 평가 | 상세 |
|------|------|------|
| 멀티테넌시 | 우수 | workspace 기반 완전 격리 |
| 수평 확장 | 우수 | Celery worker 수평 확장, stateless 설계 |
| 스토리지 복잡도 | 높음 | PostgreSQL + Qdrant + Elasticsearch + Redis 4종 |
| 운영 단순성 | 보통 | 4가지 외부 서비스 관리 필요 |
| MCP 지원 | 있음 | AI 에이전트 통합 가능 |

---

*분석 기준 커밋: `2d119577` (v0.7.0-alpha.34)*
