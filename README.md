# LightRAG 계열 GraphRAG 프레임워크 종합 비교

> **LightRAG** (원본) vs **RAG-Anything** vs **ApeRAG** vs **EdgeQuake**
>
> 네 프레임워크 모두 [HKUDS/LightRAG](https://github.com/HKUDS/LightRAG) 기반의 Graph RAG 프레임워크입니다. 소스코드 레벨 분석을 바탕으로 언어·구현 차이를 포함한 모든 핵심 차이점을 다룹니다.

---

## 목차

1. [LightRAG와의 관계](#0-lightrag와의-관계)
2. [멀티모달 범위](#1-멀티모달-범위)
3. [아키텍처 철학](#2-아키텍처-철학)
4. [프로덕션 기능](#3-프로덕션-기능)
5. [스토리지 백엔드](#4-스토리지-백엔드)
6. [그래프 탐색 성능](#5-그래프-탐색-성능)
7. [쿼리 모드](#6-쿼리-모드)
8. [엔티티 추출 및 그래프](#7-엔티티-추출-및-그래프)
9. [LLM 제공자 지원](#8-llm-제공자-지원)
10. [성능](#9-성능)
11. [문서 파싱](#10-문서-파싱)
12. [MCP 통합](#11-mcp-통합)
13. [요약: 언제 무엇을 쓸까](#요약-언제-무엇을-쓸까)
14. [관련 심층 분석 리포트](#관련-심층-분석-리포트)

---

## 0. LightRAG와의 관계

```
LightRAG (원본, Python)
  └── 엔티티 추출 + 그래프 구축 + 벡터 인덱싱 + 6가지 쿼리 모드
  └── 순수 라이브러리. 프로덕션 기능 없음. 텍스트 전용.

RAG-Anything  ── LightRAG를 그대로 import + 멀티모달 레이어 추가
  └── GraphRAG 코어: LightRAG 변경 없음
  └── 추가: 모달리티별 프로세서 + 멀티모달 노드 + VLM 강화 쿼리

ApeRAG  ── LightRAG를 깊이 수정 + 프로덕션 플랫폼으로 확장 (Python)
  └── GraphRAG 코어: 수정된 LightRAG (엔티티 머징 추가)
  └── 추가: 5종 병렬 인덱스, Celery 분산 태스크, 멀티테넌시, MCP, K8s

EdgeQuake  ── LightRAG 알고리즘을 Rust로 완전 재구현 + 프로덕션
  └── GraphRAG 코어: 자체 재구현 (추출 품질 강화, 커뮤니티 알고리즘 재작성)
  └── 추가: PDF Vision 파이프라인, 멀티테넌시, 인증, MCP
```

| | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--|---------|-------------|--------|-----------|
| **언어** | Python | Python | Python | Rust |
| **LightRAG 관계** | 원본 | 위에 추가 | 깊이 수정 | 개념 차용 후 재구현 |
| **목적** | 연구용 라이브러리 | 멀티모달 확장 | 프로덕션 플랫폼 | 프로덕션 플랫폼 |

---

## 1. 멀티모달 범위

| 항목 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--------|---------|-------------|--------|-----------|
| **텍스트** | 지원 | 지원 | 지원 | 지원 |
| **이미지** | 미지원 | 지원 (Vision LLM, base64) | 지원 (Vision 인덱스) | 독립 처리 없음 |
| **테이블** | 미지원 | 지원 (구조화 추출, JSON/CSV) | 지원 (MinerU 파싱) | PDF vision 모드 경유만 |
| **수식** | 미지원 | 지원 (수식 인식) | 지원 (MinerU LaTeX) | 미지원 |
| **범용 모달리티** | 미지원 | 지원 (폴백 프로세서) | 지원 (5종 인덱스) | 미지원 |
| **PDF** | 미지원 (텍스트 직접 입력) | MinerU 2.0, Docling, PaddleOCR | MinerU 기반 | Embedded pdfium + Vision LLM |

**결론**: LightRAG는 텍스트 직접 입력만 지원합니다. RAG-Anything은 5개 모달리티 프로세서로 그래프 노드를 직접 생성합니다. ApeRAG는 5종 인덱스 타입으로 멀티모달을 처리합니다. EdgeQuake는 PDF는 Vision LLM으로 처리하지만 이미지·수식은 독립 모달리티로 다루지 않습니다.

### 1-1. Multi-Modal 처리 방식 상세

**RAG-Anything: 모달리티별 전문 프로세서**

```
문서 파싱 → 모달리티 분류
  ├── ImageModalProcessor  → Vision LLM → 별도 chunk + 엔티티 노드로 그래프 저장
  ├── TableModalProcessor  → LLM 분석  → 별도 chunk + 엔티티 노드로 그래프 저장
  ├── EquationModalProcessor → LLM 분석 → 별도 chunk + 엔티티 노드로 그래프 저장
  └── GenericModalProcessor → 폴백 처리
```

**EdgeQuake: PDF Vision 파이프라인**

```
PDF 업로드 → edgequake-pdf2md (bundled pdfium)로 페이지별 이미지 렌더링
  → Vision LLM → 마크다운 변환 → 표준 텍스트 파이프라인
```

- 적응형 동시성: <50p: 10 / 50-200p: 8 / 200-500p: 5 / 500+p: 3
- 적응형 DPI: <500p: 150 / 500-1000p: 120 / 1000+p: 100
- 체크포인팅: 중단 재시작 시 이어서 처리 (`FileCheckpointStore`)

| | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--|---------|-------------|--------|-----------|
| **멀티모달 노드** | 없음 | 이미지/테이블/수식이 별도 엔티티 노드 | Vision 인덱스에 별도 저장 | 없음 (마크다운으로 통합) |
| **쿼리 시 이미지** | 없음 | VLM에 base64 포함 가능 | Vision 인덱스 검색 후 포함 | 텍스트만 |
| **멀티모달 쿼리** | 없음 | 이미지/테이블/수식 첨부 가능 | 텍스트 쿼리 | 불가 |

---

## 2. 아키텍처 철학

| 항목 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--------|---------|-------------|--------|-----------|
| **설계** | Python 라이브러리 | Python 라이브러리/SDK | 풀스택 플랫폼 (FastAPI + Celery + React) | 풀스택 앱 (API + WebUI) |
| **구조** | 단일 패키지 | 믹스인 패턴 단일 패키지 | FastAPI + Celery 워커 + React | 11개 Rust crate |
| **인터페이스** | Python async API | Python async API | REST API + WebUI + MCP | REST API + SSE + Swagger |
| **프론트엔드** | 없음 | 없음 | React WebUI (문서 관리, 그래프 시각화, 에이전트 워크플로우) | Sigma.js 그래프 시각화 WebUI |
| **배포** | `pip install` | `pip install` | Docker Compose / K8s | Docker / 독립 서버 |

---

## 3. 프로덕션 기능

| 기능 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|---------|---------|-------------|--------|-----------|
| **멀티테넌시** | 미지원 | 미지원 | 지원 (Collection 격리) | 지원 (워크스페이스, ADMIN/EDITOR/VIEWER) |
| **인증** | 미지원 | 미지원 | 지원 (API 키) | JWT + Argon2 |
| **요청 제한** | 미지원 | 미지원 | 미지원 | 지원 (사용자/워크스페이스별) |
| **감사 로깅** | 미지원 | 미지원 | 지원 (trace 모듈) | 지원 (PostgreSQL 기반) |
| **대화 이력** | 미지원 | 미지원 | 지원 (chat 모듈) | 지원 (workspace별 영속) |
| **비용 추적** | 미지원 | 미지원 | 미지원 | 지원 (작업별) |
| **백그라운드 작업** | 없음 | 기본 async | Celery 분산 태스크 큐 | 체크포인팅 + 복구 전체 태스크 시스템 |
| **헬스 체크** | 없음 | 없음 | FastAPI 기본 | `/health`, `/ready`, `/live` |
| **에이전트 워크플로우** | 없음 | 없음 | 지원 (flow 모듈, AI 에이전트 편집기) | 없음 |
| **MCP 서버** | 없음 | 없음 | 지원 | 지원 |
| **SDK** | Python | Python | REST API (언어 무관) | Python, TS, Rust, Java, Go, C#, Ruby, Swift, PHP |

**결론**: LightRAG와 RAG-Anything은 프로덕션 기능이 없습니다. ApeRAG는 에이전트 워크플로우·Celery 분산 처리가 강점, EdgeQuake는 비용 추적·요청 제한·멀티 SDK가 강점입니다.

---

## 4. 스토리지 백엔드

| 항목 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--------|---------|-------------|--------|-----------|
| **그래프** | Neo4j (기본) / NetworkX (인메모리) | LightRAG 경유 | PostgreSQL 관계형 테이블 (SQLAlchemy ORM, AGE 없음) | PostgreSQL + Apache AGE |
| **그래프용 벡터** | 플러그형 (Chroma, pgvector 등) | LightRAG 경유 | PostgreSQL pgvector (`PGOpsSyncVectorStorage`) | pgvector + HNSW |
| **청크 벡터** | 플러그형 | LightRAG 경유 | Qdrant | pgvector |
| **풀텍스트** | 없음 | 없음 | Elasticsearch | PostgreSQL tsvector + GIN |
| **KV / 캐시** | 플러그형 | LightRAG 경유 | PostgreSQL KV + Redis | PostgreSQL |
| **인메모리** | 지원 (기본값) | LightRAG 경유 | 미지원 (외부 서비스 필수) | 지원 (개발용) |
| **외부 서비스 수** | 0–1개 | 0–1개 (LightRAG 설정에 따라) | 4개 (PG + Qdrant + ES + Redis) | 1개 (PostgreSQL 전체) |

**결론**: LightRAG/RAG-Anything은 인메모리도 가능한 최소 의존성입니다. ApeRAG는 4종 외부 서비스를 역할별로 분리합니다. EdgeQuake는 PostgreSQL 하나로 통합 운영합니다. ApeRAG의 그래프는 Apache AGE 없이 **순수 관계형 테이블**입니다.

---

## 5. 그래프 탐색 성능

LightRAG 계열 핵심 탐색 패턴: **"벡터 검색 → 시작 엔티티 → 1-hop 이웃 수집 → 컨텍스트 조립"**

| 항목 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--------|---------|-------------|--------|-----------|
| **1-hop 탐색** | NetworkX/Neo4j (인메모리 또는 Cypher) | LightRAG 위임 | PostgreSQL UNION ALL + ANY (1번 쿼리) | Apache AGE Cypher + tokio::join! |
| **multi-hop 탐색** | NetworkX 재귀 / Cypher `[*1..n]` | LightRAG 위임 | **미구현** (max_depth 파라미터 무시됨) | Cypher `[*1..n]` |
| **N+1 위험** | 인메모리 없음 / Neo4j 위임 | LightRAG 위임 | 단일 degree 조회 시 발생 (batch 버전은 CTE로 안전) | 없음 (Rust batch) |
| **OR 폭발** | 없음 | 없음 | edge pairs 조회 시 OR 조건 반복 | 없음 |
| **Pruning** | 토큰 기반 절삭 | LightRAG 기본 | max_nodes 알파벳 순 truncation | degree/weight 정렬 + BM25 리랭킹 |
| **배치 최적화** | 기본 | 기본 | CTE + UNNEST / UNION ALL | tokio::join! 병렬 |

### 5-1. ApeRAG 그래프 탐색 구조적 한계

소스코드 주석 (`pg_ops_sync_graph_storage.py:289`) 명시:

```
"For now, it only supports getting nodes by label pattern and their immediate connections.
Full graph traversal with max_depth would require additional Repository methods."
```

**실용적 영향**: 현재 LightRAG 탐색 알고리즘이 1-hop 패턴이므로 일반 사용에는 문제 없습니다. 다단계 추론이 필요한 경우 제약이 됩니다.

### 5-2. 그래프 스토리지 선택 비교

| 관점 | LightRAG | ApeRAG | EdgeQuake |
|------|---------|--------|-----------|
| 1-hop | NetworkX dict / Neo4j Cypher | UNION ALL (SQL) | AGE Cypher |
| multi-hop | NetworkX 재귀 / Cypher | Python 반복 필요 | Cypher 한 줄 |
| 운영 복잡도 | Neo4j 또는 인메모리 | PostgreSQL 단일 | PostgreSQL + AGE 확장 |
| 인메모리 | 가능 | 불가 | 개발용만 |

---

## 6. 쿼리 모드

| 모드 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|------|---------|-------------|--------|-----------|
| **Naive** (벡터 전용) | 지원 | 지원 | 지원 | 지원 |
| **Local** (엔티티 중심) | 지원 | 지원 | 지원 | 지원 |
| **Global** (커뮤니티 기반) | 지원 | 지원 | 지원 | 지원 |
| **Hybrid** (local+global) | 지원 | 지원 | 지원 | 지원 (기본값) |
| **Mix** (가중 혼합) | 지원 | 지원 | 지원 | 지원 (조정 가능) |
| **Bypass** (직접 LLM) | 지원 | 지원 | 지원 | 지원 |
| **멀티모달 쿼리** | 없음 | 지원 (이미지·테이블·수식 포함) | 없음 (Vision 인덱스 병렬 검색) | 없음 |
| **자동 모드 선택** | 없음 | 없음 | 없음 | 지원 (query intent 기반) |

**결론**: 6가지 쿼리 모드는 네 프레임워크 모두 동일합니다. RAG-Anything은 멀티모달 쿼리를, EdgeQuake는 intent 기반 자동 모드 선택을 추가합니다. ApeRAG는 Graph 외 4종 인덱스를 병렬 검색합니다.

---

## 7. 엔티티 추출 및 그래프

| 항목 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--------|---------|-------------|--------|-----------|
| **추출 포맷** | JSON 기반 | JSON 기반 (동일) | 튜플 기반 (수정된 LightRAG) | 튜플 기반 (더 견고한 파싱) |
| **엔티티 타입** | 동적 (LLM 자유 결정) | 동적 (동일) | 동적 (수정 가능) | 7개 고정 (PERSON, ORG, LOCATION, CONCEPT, EVENT, TECH, PRODUCT) |
| **정규화** | 없음 | 없음 | 엔티티 머징 (동의어 통합) | UPPERCASE_UNDERSCORE (중복 36-40% 감소) |
| **글리닝** | 없음 | 없음 | 1회 (LightRAG 기본) | 지원 (멀티패스, 재현율 15-25% 향상) |
| **커뮤니티 감지** | 내장 (쿼리 시) | LightRAG 위임 | LightRAG 위임 | Louvain 자체 구현 (**인제스션 시** 사전 계산) |
| **그래프 시각화** | 없음 | 없음 | 지원 (WebUI 내장) | 지원 (Sigma.js 인터랙티브) |

### 7-1. GraphRAG 코어 로직 전체 비교

| | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--|---------|-------------|--------|-----------|
| **파싱 포맷** | JSON | JSON (동일) | 튜플 (수정) | 튜플 (`entity<\|#\|>name<\|#\|>type<\|#\|>desc`) |
| **이름 정규화** | 없음 | 없음 | 엔티티 머징 | `UPPERCASE_UNDERSCORE` 강제 |
| **커뮤니티 알고리즘** | 내장 | 위임 | 위임 | Louvain + Label Propagation + Connected Components |
| **커뮤니티 실행** | 쿼리 시 | 쿼리 시 | 쿼리 시 | **인제스션 시** |
| **쿼리 엔진** | 원본 | `aquery` 그대로 | 수정된 `aquery` | `sota_engine` 재구현 |
| **쿼리 캐싱** | LLM 응답 캐시 | 멀티모달 전용 추가 | Redis 기반 | 자체 구현 (24h TTL) |
| **대화 히스토리** | 없음 | 없음 | 지원 | 지원 |
| **자동 모드 선택** | 없음 | 없음 | 없음 | 지원 |

---

## 8. LLM 제공자 지원

| 제공자 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|----------|---------|-------------|--------|-----------|
| **OpenAI** | 지원 | 지원 | 지원 | 지원 |
| **Ollama** | 지원 | 지원 | 지원 | 지원 |
| **LM Studio** | 지원 | 지원 | 미지원 | 지원 |
| **vLLM** | 지원 | 지원 | 지원 (OpenAI 호환) | 미지원 |
| **LOLLMS** | 지원 | 지원 | 미지원 | 미지원 |
| **Azure OpenAI** | 지원 | 지원 | 지원 | 미지원 |
| **Anthropic** | 미지원 | 미지원 | 지원 | 지원 (vision 전용) |
| **Google Gemini** | 미지원 | 미지원 | 지원 | 지원 (vision 전용) |
| **Vision 모델** | 없음 | OpenAI 호환 | 지원 (Vision 인덱스용) | 4개 제공자 (OpenAI, Anthropic, Gemini, Ollama) |

---

## 9. 성능

| 지표 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--------|---------|-------------|--------|-----------|
| **언어** | Python (GIL) | Python (GIL) | Python (GIL, Celery로 보완) | Rust (제로 비용 추상화) |
| **쿼리 지연** | 벤치마크 없음 | 벤치마크 없음 | 벤치마크 없음 | hybrid <200ms |
| **동시 사용자** | 낮음 | 낮음 | Celery 수평 확장 (이론상 무제한) | 1000+ |
| **문서당 메모리** | 낮음 (인메모리 가능) | 낮음 | 높음 (4종 외부 서비스) | ~2MB |
| **확장 방식** | 단일 프로세스 | 단일 프로세스 | K8s + Celery 수평 확장 | 수직/수평 (Rust 효율) |
| **그래프 탐색 (1-hop)** | NetworkX dict / Cypher | 위임 | CTE + UNION ALL (1번) | Cypher + tokio::join! |
| **그래프 탐색 (multi-hop)** | NetworkX 재귀 / Cypher | 위임 | **미구현** | Cypher |
| **빌드 최적화** | 없음 | 없음 | 없음 | LTO, opt-level 3, 단일 codegen |

---

## 10. 문서 파싱

| 항목 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--------|---------|-------------|--------|-----------|
| **PDF** | 없음 (텍스트 직접 입력) | MinerU 2.0, Docling, PaddleOCR | MinerU 기반 | edgequake-pdf2md (pdfium + Vision LLM) |
| **오피스 문서** | 없음 | 지원 (LibreOffice 경유) | 지원 (docparser) | 없음 |
| **이미지 파일** | 없음 | 지원 (PNG, JPG, BMP 등) | 지원 (Vision 인덱스) | 없음 |
| **마크다운** | 지원 (직접 입력) | 지원 | 지원 | 지원 (네이티브) |
| **파싱 캐싱** | 없음 | 해시 기반 | 없음 (Celery 재실행) | 체크포인팅 |

---

## 11. MCP 통합

| 항목 | LightRAG | RAG-Anything | ApeRAG | EdgeQuake |
|--------|---------|-------------|--------|-----------|
| **MCP 지원** | 없음 | 없음 | 지원 (mcp 모듈) | 지원 |

---

## 요약: 언제 무엇을 쓸까

| 사용 사례 | 추천 |
|----------|------|
| 연구 / 프로토타이핑 / 최소 의존성 | **LightRAG** |
| 기존 Python 앱에 임베드 | **LightRAG** 또는 **RAG-Anything** |
| 멀티모달 문서 (이미지·테이블·수식, 그래프 노드 포함) | **RAG-Anything** |
| 멀티모달 + 엔터프라이즈 | **ApeRAG** |
| 인증/멀티테넌시 포함 프로덕션 배포 | **ApeRAG** 또는 **EdgeQuake** |
| 대규모 병렬 인제스션 / K8s 수평 확장 | **ApeRAG** |
| 에이전트 워크플로우 편집기 | **ApeRAG** |
| 단일 인스턴스 고성능 / 낮은 지연 | **EdgeQuake** |
| 단일 PostgreSQL 스택 통합 운영 | **EdgeQuake** |
| multi-hop 그래프 탐색 / 복잡한 지식 그래프 | **EdgeQuake** |
| 엔터프라이즈 기능 (비용 추적, 요청 제한) | **EdgeQuake** |
| 유연한 LLM 백엔드 (로컬 모델 다수) | **LightRAG** 또는 **RAG-Anything** |
| WebUI 포함 독립 서비스 | **ApeRAG** 또는 **EdgeQuake** |
| 에이전트/MCP 통합 | **ApeRAG** 또는 **EdgeQuake** |

---

## 관련 심층 분석 리포트

| 리포트 | 내용 |
|--------|------|
| [query_pipeline_comparison.md](./query_pipeline_comparison.md) | 쿼리 파이프라인 소스코드 레벨 비교 — 키워드 추출, 그래프 탐색, ApeRAG N+1 분석(§4.6), 프루닝, LLM 응답 생성 |
| [ingestion_pipeline_comparison.md](./ingestion_pipeline_comparison.md) | 인덱싱 파이프라인 비교 — 청킹, 엔티티 추출, ApeRAG 그래프 저장소 성능 분석(§4-9) |
| [hybrid_search_design.md](./hybrid_search_design.md) | BM25 하이브리드 검색 도입 설계 — 현황 분석 및 프레임워크별 구현 전략 |
| [aperag_deep_dive.md](./aperag_deep_dive.md) | ApeRAG 전용 심층 분석 — PGOpsSyncGraphStorage, N+1 문제, Celery 재조정 시스템, Apache AGE 미선택 이유 |
