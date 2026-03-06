# RAG-Anything vs EdgeQuake: Comprehensive Comparison

Both are multi-modal Graph RAG frameworks based on [HKUDS/LightRAG](https://github.com/HKUDS/LightRAG). This document covers all key differences beyond the obvious Python vs Rust distinction.

---

## 0. LightRAG와의 관계

세 프레임워크의 계층 구조를 먼저 이해해야 합니다.

```
LightRAG (원본)
  └── 엔티티 추출 + 그래프 구축 + 벡터 인덱싱 + 6가지 쿼리 모드 (기본 프레임워크)

RAG-Anything = LightRAG 위에 멀티모달 레이어 추가
  └── GraphRAG 코어: LightRAG 그대로 사용 (엔티티 추출, 그래프, 쿼리 엔진 변경 없음)
  └── 추가: 모달리티별 전용 프로세서 + 멀티모달 노드 생성 + VLM 강화 쿼리

EdgeQuake = LightRAG 개념을 Rust로 재구현 + 프로덕션 기능
  └── GraphRAG 코어: 자체 재구현 (엔티티 추출 품질 강화, 커뮤니티 알고리즘 자체 구현, 쿼리 엔진 재작성)
  └── 추가: PDF Vision 파이프라인, 멀티테넌시, 인증, MCP 등
```

**핵심 차이**: RAG-Anything은 LightRAG를 라이브러리로 import하여 그대로 호출합니다. EdgeQuake는 LightRAG의 아이디어를 차용했지만 코어 로직을 Rust로 완전히 재구현했습니다.

---

## 1. Multi-Modal Scope

| Aspect | RAG-Anything | EdgeQuake |
|--------|-------------|-----------|
| **Text** | Yes | Yes |
| **Images** | Yes (vision model analysis, base64) | No native image processing |
| **Tables** | Yes (structured extraction, JSON/CSV) | Via vision PDF only |
| **Equations** | Yes (formula recognition) | No |
| **Generic modality** | Yes (fallback processor) | No |
| **PDF** | MinerU 2.0, Docling, PaddleOCR | Embedded pdfium + optional vision mode |

**Verdict**: RAG-Anything is truly multi-modal with 5 modality processors. EdgeQuake handles PDFs well but doesn't process images, tables, or equations as standalone modalities.

### 1-1. Multi-Modal 처리 방식 상세

두 프레임워크 모두 LightRAG 원본에는 없는 멀티모달 처리를 자체적으로 추가했지만, 접근 방식이 근본적으로 다릅니다.

**RAG-Anything: 모달리티별 전문 프로세서**

```
문서 파싱 → 모달리티 분류
  ├── ImageModalProcessor  → Vision LLM 설명 생성 → 별도 chunk + 엔티티 노드로 그래프에 저장
  ├── TableModalProcessor  → LLM 분석 → 별도 chunk + 엔티티 노드로 그래프에 저장
  ├── EquationModalProcessor → LLM 분석 → 별도 chunk + 엔티티 노드로 그래프에 저장
  └── GenericModalProcessor → 폴백 처리
```

- 인제스천: 각 모달리티가 **별도 청크 + 별도 엔티티 노드**로 저장됨. 관계 추출까지 수행하여 텍스트 엔티티와 연결
- 쿼리: 검색된 컨텍스트에 이미지 경로가 있으면 base64로 변환하여 VLM에 전송 (`aquery_vlm_enhanced`). 멀티모달 컨텍스트를 포함한 질의도 가능 (`aquery_with_multimodal`)

**EdgeQuake: PDF Vision 파이프라인**

```
PDF 업로드 → edgequake-pdf2md (bundled pdfium)로 페이지별 이미지 렌더링
  → Vision LLM에 전송 → 마크다운 반환
  → 마크다운을 텍스트로 저장 → 표준 텍스트 파이프라인 (엔티티 추출 → 그래프 구축)
```

- 인제스천: PDF 페이지 전체를 Vision LLM이 마크다운으로 변환 (테이블은 `| |` 구문, 수식은 `$$LaTeX$$`, 이미지는 `[Image: ...]`으로 기술). 이후 일반 텍스트로 처리
- 쿼리: 텍스트 기반만 지원. 멀티모달 쿼리 없음
- **텍스트 전용 PDF 추출은 deprecated** — 현재 모든 PDF 처리는 vision 모드 필수 (`enable_vision=true`). 과거 `edgequake-pdf` crate는 `legacy/`로 이동되고 `edgequake-pdf2md`로 대체됨
- 프로덕션 기능:
  - **적응형 동시성**: 페이지 수에 따라 자동 조절 (<50p: 10, 50-200p: 8, 200-500p: 5, 500+p: 3)
  - **적응형 DPI**: 대용량 문서에서 메모리 절약 (<500p: 150 DPI, 500-1000p: 120 DPI, 1000+p: 100 DPI)
  - **적응형 타임아웃**: 60초 + 페이지당 5초 (1000페이지 → ~84분)
  - **체크포인팅**: 중단 시 이미 변환된 페이지를 디스크에 저장, 재시작 시 이어서 처리 (`FileCheckpointStore`)
  - **워크스페이스별 vision provider 선택**: 워크스페이스마다 다른 LLM provider 사용 가능

| | RAG-Anything | EdgeQuake |
|--|-------------|-----------|
| **멀티모달 노드** | 이미지/테이블/수식이 별도 엔티티 노드로 그래프에 존재 | 없음 (마크다운 텍스트로 통합) |
| **쿼리 시 이미지 전송** | VLM에 base64 이미지 포함 가능 | 텍스트만 전송 |
| **멀티모달 쿼리** | 질문에 이미지/테이블/수식 첨부 가능 | 불가 |

---

## 2. Architecture Philosophy

| Aspect | RAG-Anything | EdgeQuake |
|--------|-------------|-----------|
| **Design** | Python library/SDK (import & use) | Full-stack application (API server + WebUI) |
| **Structure** | Single package with mixins | 11 Rust crates in workspace |
| **Interface** | Python async API | REST API + SSE streaming + Swagger UI |
| **Frontend** | None (library only) | Built-in WebUI with Sigma.js graph visualization |
| **Deployment** | `pip install` into your app | Docker / standalone server |

**Verdict**: RAG-Anything is a library you embed into existing applications. EdgeQuake is a deployable service with its own frontend.

---

## 3. Production Features

| Feature | RAG-Anything | EdgeQuake |
|---------|-------------|-----------|
| **Multi-tenancy** | No | Yes (workspace isolation, roles: ADMIN/EDITOR/VIEWER) |
| **Authentication** | No | JWT + Argon2 password hashing |
| **Rate limiting** | No | Yes (per-user/workspace) |
| **Audit logging** | No | Yes (PostgreSQL-backed compliance trail) |
| **Conversation history** | No | Yes (persistent per workspace) |
| **Cost tracking** | No | Yes (per-operation monitoring) |
| **Background jobs** | Basic async | Full task system with checkpointing & recovery |
| **Health checks** | No | `/health`, `/ready`, `/live` endpoints |
| **SDKs** | Python only | Python, TypeScript, Rust, Java, Go, C#, Ruby, Swift, PHP |

**Verdict**: EdgeQuake is production-hardened with enterprise features. RAG-Anything is research/prototyping focused.

---

## 4. Storage Backends

| Aspect | RAG-Anything | EdgeQuake |
|--------|-------------|-----------|
| **Graph** | Via LightRAG (Neo4j, Apache AGE, in-memory) | Apache AGE on PostgreSQL |
| **Vector** | Via LightRAG (Chroma, pgvector, etc.) | pgvector with HNSW indexing |
| **KV** | Via LightRAG abstractions | PostgreSQL |
| **In-memory** | Yes (default) | Yes (development fallback) |
| **Unified DB** | Yes (PostgreSQL via LightRAG env vars) | Yes (all on PostgreSQL) |

**Verdict**: Both can run fully on PostgreSQL (AGE + pgvector). EdgeQuake enforces this by default; RAG-Anything supports it via LightRAG environment variables alongside other backend options.

---

## 5. Query Modes

| Mode | RAG-Anything | EdgeQuake |
|------|-------------|-----------|
| **Naive** (vector only) | Yes | Yes |
| **Local** (entity-centric) | Yes | Yes |
| **Global** (community-based) | Yes | Yes |
| **Hybrid** (local+global) | Yes | Yes (default) |
| **Mix** (weighted blend) | Yes | Yes (tunable) |
| **Bypass** (direct LLM) | Yes | Yes |
| **Multimodal query** | Yes (images, tables, equations in query) | No |

**Verdict**: Same 6 query modes. RAG-Anything additionally supports multimodal queries (e.g., asking about an image).

---

## 6. Entity Extraction & Graph

| Aspect | RAG-Anything | EdgeQuake |
|--------|-------------|-----------|
| **Extraction format** | JSON-based (LightRAG default) | Tuple-based (more robust parsing) |
| **Entity types** | Dynamic (LLM decides) | 7 fixed types (PERSON, ORG, LOCATION, CONCEPT, EVENT, TECH, PRODUCT) |
| **Normalization** | LightRAG default | UPPERCASE_UNDERSCORE (36-40% fewer duplicates) |
| **Gleaning** | No | Yes (multi-pass extraction, 15-25% better recall) |
| **Community detection** | Via LightRAG | Louvain modularity optimization |
| **Graph visualization** | No | Yes (interactive Sigma.js) |

**Verdict**: EdgeQuake has stronger entity extraction (gleaning, normalization, fixed types reduce noise). RAG-Anything is more flexible but less precise.

### 6-1. GraphRAG 코어 로직 비교 (LightRAG vs RAG-Anything vs EdgeQuake)

Ingestion 외에 GraphRAG 파이프라인 자체의 로직 차이입니다.

#### 엔티티 추출

| | LightRAG (원본) | RAG-Anything | EdgeQuake |
|--|----------------|-------------|-----------|
| **파싱 포맷** | JSON 기반 | JSON 기반 (동일) | 튜플 기반 (`entity<\|#\|>name<\|#\|>type<\|#\|>desc`) |
| **엔티티 타입** | 동적 (LLM 자유 결정) | 동적 (동일) | 7개 고정 (PERSON, ORGANIZATION, LOCATION, EVENT, CONCEPT, TECHNOLOGY, PRODUCT) |
| **이름 정규화** | 기본 | 기본 (동일) | `UPPERCASE_UNDERSCORE` 강제 (`"John Doe"` → `JOHN_DOE`, 관사/소유격 제거) |
| **글리닝** | 없음 | 없음 (동일) | 있음 (multi-pass 추출, 15-25% 리콜 향상) |

#### 커뮤니티 감지

| | LightRAG (원본) | RAG-Anything | EdgeQuake |
|--|----------------|-------------|-----------|
| **알고리즘** | 내장 구현 | LightRAG 그대로 사용 | 3개 알고리즘 자체 구현 (Louvain, Label Propagation, Connected Components) |
| **모듈러리티 계산** | LightRAG 위임 | LightRAG 위임 | 직접 계산 (`calculate_modularity`) |
| **설정 파라미터** | 기본값 | 기본값 | `min_community_size`, `resolution` 튜닝 가능 |

#### 쿼리 엔진

| | LightRAG (원본) | RAG-Anything | EdgeQuake |
|--|----------------|-------------|-----------|
| **6가지 모드** | 원본 구현 | LightRAG의 `aquery` 그대로 호출 | `sota_engine`으로 재구현 |
| **멀티모달 쿼리** | 없음 | `aquery_with_multimodal` 추가 | 없음 |
| **VLM 강화 쿼리** | 없음 | `aquery_vlm_enhanced` 추가 | 없음 |
| **쿼리 캐싱** | LLM 응답 캐시 | 멀티모달 쿼리 전용 캐시 추가 | 자체 구현 |
| **대화 히스토리** | 없음 | 없음 | 있음 (workspace별 영속) |

**요약**: RAG-Anything은 LightRAG의 GraphRAG 로직을 그대로 사용하고 멀티모달 쿼리만 추가했습니다. EdgeQuake는 엔티티 추출 품질 강화(정규화, 글리닝, 고정 타입), 커뮤니티 알고리즘 자체 구현, 쿼리 엔진 재작성 등 GraphRAG 코어 자체를 개선했습니다.

---

## 7. LLM Provider Support

| Provider | RAG-Anything | EdgeQuake |
|----------|-------------|-----------|
| **OpenAI** | Yes | Yes |
| **Ollama** | Yes | Yes |
| **LM Studio** | Yes | Yes |
| **vLLM** | Yes | No |
| **LOLLMS** | Yes | No |
| **Azure OpenAI** | Yes | No |
| **Anthropic** | No (text LLM) | Yes (vision only) |
| **Google Gemini** | No | Yes (vision only) |
| **Vision models** | Optional (any OpenAI-compatible) | 4 providers (OpenAI, Anthropic, Gemini, Ollama) |

EdgeQuake vision 지원 모델 상세:
- **OpenAI**: gpt-4o, gpt-4.1-nano, gpt-4.1-mini 등
- **Ollama**: gemma3 (4B/12B/27B), gemma3n (2B/8B), llama3.2-vision, glm-4v-flash
- **Anthropic**: Claude 계열 (vision only)
- **Google Gemini**: gemini-2.5-flash, gemini-2.0-flash, gemini-2.5-pro 등

**Verdict**: RAG-Anything has more text LLM options. EdgeQuake has broader vision provider support.

---

## 8. Performance

| Metric | RAG-Anything | EdgeQuake |
|--------|-------------|-----------|
| **Language overhead** | Python (GIL, asyncio) | Rust (zero-cost abstractions, true concurrency) |
| **Query latency** | Not benchmarked | <200ms hybrid mode |
| **Concurrent users** | Limited by Python async | 1000+ |
| **Memory per doc** | Higher (Python objects) | ~2MB |
| **Build optimization** | N/A | LTO, opt-level 3, single codegen unit |

**Verdict**: EdgeQuake is significantly faster and more resource-efficient due to Rust.

---

## 9. Document Parsing

| Aspect | RAG-Anything | EdgeQuake |
|--------|-------------|-----------|
| **PDF parser** | MinerU 2.0 (OCR 전용 경량 VLM 기반) | edgequake-pdf2md (bundled pdfium + Vision LLM) |
| **Alternative parsers** | Docling, PaddleOCR | legacy edgequake-pdf (deprecated) |
| **Office docs** | Yes (via LibreOffice) | No |
| **Image files** | Yes (PNG, JPG, BMP, TIFF, GIF, WebP) | No |
| **Markdown** | Yes (with PDF conversion) | Yes (native) |
| **Parse caching** | Yes (hash-based) | Checkpointing |

**Verdict**: RAG-Anything handles far more document formats. EdgeQuake focuses on PDF/TXT/MD.

---

## 10. MCP Integration

| Aspect | RAG-Anything | EdgeQuake |
|--------|-------------|-----------|
| **MCP support** | No | Yes (Model Context Protocol for agent integration) |

**Verdict**: EdgeQuake supports MCP for AI agent tool-use scenarios. RAG-Anything does not.

---

## Summary: When to Use Which

| Use Case | Better Choice |
|----------|--------------|
| Multi-modal documents (images, tables, equations) | **RAG-Anything** |
| Production deployment with auth/multi-tenancy | **EdgeQuake** |
| Research / prototyping | **RAG-Anything** |
| High-performance / high-concurrency | **EdgeQuake** |
| Diverse document formats (Office, images) | **RAG-Anything** |
| Enterprise features (audit, rate limiting) | **EdgeQuake** |
| Embedding in existing Python app | **RAG-Anything** |
| Standalone service with WebUI | **EdgeQuake** |
| Agent/MCP integration | **EdgeQuake** |
| Flexible LLM backends | **RAG-Anything** |
