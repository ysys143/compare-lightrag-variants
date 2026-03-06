# BM25 하이브리드 서치 도입 설계서

**작성일:** 2026-03-07 (초판 03-06, Bayesian BM25 옵션 추가 03-07)
**범위:** LightRAG, RAG-Anything, EdgeQuake 세 프레임워크의 BM25 기반 하이브리드 검색 도입 전략

---

## 1. 현재 상태 분석

### 1.1 검색 레벨별 BM25 활용 현황

| 검색 레벨 | LightRAG | RAG-Anything | EdgeQuake |
|-----------|----------|-------------|-----------|
| **엔티티 검색** | 벡터 only | 벡터 only (LightRAG 위임) | 벡터 only |
| **관계 검색** | 벡터 only | 벡터 only (LightRAG 위임) | 벡터 only |
| **청크 검색 (NAIVE/MIX)** | 벡터 only | 벡터 only (LightRAG 위임) | 벡터 only |
| **청크 리랭킹 (post-retrieval)** | 없음 | 없음 | **BM25 리랭킹** |
| **엔티티 정렬** | degree x weight | degree x weight | **degree DESC** |

**핵심 발견:** EdgeQuake조차 BM25를 **리랭킹**(post-retrieval)에만 사용하고, **검색 자체**(retrieval)에는 벡터만 사용한다. 진정한 하이브리드 서치(BM25 검색 + 벡터 검색 결과 병합)는 세 프레임워크 모두 부재하다.

### 1.2 EdgeQuake의 현재 BM25 리랭킹 구조

**파일:** `edgequake-query/src/sota_engine/reranking.rs`

`reranking.rs`는 3가지 독립적인 함수를 포함한다:

| 함수 | 역할 | BM25 관련 |
|------|------|-----------|
| `rerank_chunks()` | 청크 BM25 리랭킹 (post-retrieval) | 직접 사용 |
| `sort_entities_by_degree()` | 엔티티를 degree 내림차순 정렬 | 무관 |
| `validate_keywords()` | 키워드가 그래프에 존재하는지 확인 | 무관 |

**BM25Reranker 위치:** 외부 크레이트 `edgequake-llm` (v0.3.0)
- `edgequake_llm::reranker::BM25Reranker`
- `Reranker` trait: `rerank(query, documents, top_k) -> Vec<RerankResult>`
- 생성자: `new()`, `new_enhanced()`, `for_rag()`, `for_semantic()`

**현재 파이프라인에서의 호출 위치** (`query_basic.rs`):

```
Step 1:  키워드 추출
Step 1.5: 키워드 검증 (validate_keywords)
Step 2:  모드 선택
Step 3:  임베딩 계산
Step 4:  모드별 검색 (벡터 only)           ← 여기가 하이브리드 서치 도입 지점
Step 4.5: 청크 리랭킹 (rerank_chunks)      ← 현재 BM25 위치 (post-retrieval)
Step 4.6: 엔티티 정렬 (sort_entities_by_degree)
Step 5:  토큰 절삭 (balance_context)
Step 6:  LLM 응답 생성
```

### 1.3 벡터 only 검색의 한계

세 프레임워크 모두 동일한 구조적 약점을 가진다:

**1) 정확한 키워드 매칭 실패**

임베딩은 의미적 유사도를 측정하므로, 정확한 텍스트 매칭이 중요한 경우 놓칠 수 있다.

```
쿼리: "Peugeot 2008 ENVY 사양"
청크 A: "Peugeot 2008 ENVY는 프리미엄 SUV로..."  ← 벡터 유사도 0.82
청크 B: "Peugeot 3008 GT는 크로스오버로..."       ← 벡터 유사도 0.85 (!)
→ "3008 GT"가 "2008 ENVY"보다 임베딩 공간에서 가까울 수 있음
→ BM25는 "2008"과 "ENVY" 정확 매칭으로 청크 A를 확실히 1위로 올림
```

**2) 전문 용어 / 고유명사 / 약어**

```
쿼리: "PostgreSQL의 MVCC 구현"
→ 임베딩이 "데이터베이스 동시성 제어"와 더 가까울 수 있음
→ BM25는 "PostgreSQL"과 "MVCC" 리터럴 매칭으로 정확한 청크 발견
```

**3) 희귀 용어의 IDF 효과 부재**

벡터 검색은 빈도 정보를 활용하지 않는다. BM25의 IDF 항이 희귀 용어를 포함한 문서를 자연스럽게 부스팅한다.

```
"ENVY" (1개 문서에만 등장) vs "Peugeot" (전체 문서에 등장)
→ BM25 IDF: "ENVY" 포함 청크에 높은 점수
→ 벡터: 두 용어를 동등하게 취급
```

---

## 2. 도입 레벨 3단계

효과와 구현 난이도를 기준으로 3단계로 나눈다.

### Level 1: 청크 검색 하이브리드 (가장 효과 높음)

NAIVE/MIX 모드에서 `chunks_vdb` 검색 시, 벡터 검색과 BM25 검색을 병렬 실행 후 RRF로 병합.

```
현재:  query → 벡터 검색 → top_k 청크

개선:  query ─┬─ 벡터 검색 → top_k 후보
             └─ BM25 검색  → top_k 후보
                    ↓
              RRF (Reciprocal Rank Fusion) 병합
                    ↓
              최종 top_k 청크
```

**영향 범위:**
- LightRAG: `operate.py`의 `naive_query()`, `_get_vector_context()`
- RAG-Anything: LightRAG 수정 시 자동 상속
- EdgeQuake: `query_modes.rs`의 `query_naive()`, `query_mix()` + `vector_queries.rs` 변형들

### Level 2: 엔티티 검색 하이브리드

LOCAL 모드에서 `entities_vdb` 검색 시, 엔티티 이름/설명에 대해 BM25 병행.

```
현재:  ll_keywords → 벡터 검색 (entities_vdb) → top_k 엔티티

개선:  ll_keywords ─┬─ 벡터 검색 (임베딩 유사도)
                   └─ BM25 검색 (엔티티 이름 + 설명 텍스트)
                          ↓
                    RRF 병합 → top_k 엔티티
```

**영향 범위:**
- LightRAG: `operate.py`의 `_get_node_data()`
- EdgeQuake: `query_modes.rs`의 `query_local()` Step 1

### Level 3: 관계 검색 하이브리드 (선택적)

GLOBAL 모드에서 `relationships_vdb` 검색에 BM25 추가. 효과는 Level 1, 2보다 낮다.

---

## 3. 점수 병합 방식: 두 가지 옵션

벡터 검색(cosine 0~1)과 BM25 검색(0~∞)의 결과를 병합하는 방식으로 두 가지 옵션을 검토한다.

### Option A: RRF (Reciprocal Rank Fusion) — 순위 기반

```
score(doc) = Σ weight_i / (k + rank_i(doc))

- k = 60 (표준값, Cormack et al. 2009)
- rank_i = i번째 검색 결과에서의 순위 (0-based)
- weight_i = 각 검색 소스의 가중치
```

**장점:**
- 점수 정규화 불필요 (스케일이 다른 점수를 순위로 통일)
- 구현이 간단하고 성능이 입증됨
- 파라미터가 k 하나뿐 (튜닝 부담 낮음)

**단점:**
- 점수 크기 정보를 버림 ("1위 0.99"와 "1위 0.51"을 동일하게 취급)
- 의미 있는 임계값 필터링 불가 (순위에 절대 기준 없음)
- 3개 이상 소스 병합 시 k 튜닝이 어려움

**가중치 튜닝 가이드:**

| 도메인 특성 | vector_weight | bm25_weight | 이유 |
|------------|--------------|-------------|------|
| 기본값 | 1.0 | 1.0 | 균등 |
| 고유명사/전문 용어 많음 | 1.0 | 1.2~1.5 | 정확 매칭 중요 |
| 자연어 질문 위주 | 1.2 | 0.8 | 의미적 유사도 중요 |
| 다국어 혼합 | 1.0 | 0.7 | BM25 토크나이저 한계 |

### Option B: Bayesian Probability Fusion — 확률 기반 (권장)

**출처:** [cognica-io/bayesian-bm25](https://github.com/cognica-io/bayesian-bm25), [Bayesian BM25와 하이브리드 검색](https://www.cognica.io/ko/blog/posts/2026-02-01-bayesian-bm25-hybrid-search), [왜 Sigmoid인가](https://www.cognica.io/ko/blog/posts/2026-02-23-why-sigmoid)

RRF와 근본적으로 다른 접근: 두 검색 점수를 **확률 공간으로 변환**한 뒤, **베이즈 정리**로 결합한다.

```
RRF 방식:
  벡터 점수 (0~1) ─┐
                    ├─ 순위 기반 병합 (점수 크기 정보 버림)
  BM25 점수 (0~∞)  ─┘

Bayesian 방식:
  벡터 cosine (0~1) → sigmoid 변환 → 확률 P_vec (0~1) ─┐
                                                         ├─ log-odds 결합 (확률 이론)
  BM25 점수 (0~∞)   → sigmoid 변환 → 확률 P_bm25 (0~1) ─┘
```

#### 3.B.1 이론적 배경

**왜 Sigmoid인가 — 수학적 필연성:**

관련성(Relevance)은 이진 확률 변수(R=1 또는 R=0)이며, 베르누이 분포에 속한다. 베르누이는 지수족(Exponential Family)이고, 지수족의 정준 연결 함수(Canonical Link Function)의 역함수는 **유일하게 sigmoid**이다. 즉 sigmoid는 공학적 선택이 아니라 이론적 귀결이다.

이 변환은 BM25, TF-IDF, SPLADE 등 점수 생성 메커니즘에 무관하게 동작한다. 단지 "점수와 관련성 사이의 단조 관계"만 요구한다.

기존 BM25의 문제: 점수 12.34가 "관련성 90%"인지 "50%"인지 알 수 없다. 점수의 절댓값이 쿼리 길이, 코퍼스 통계, 문서 길이에 따라 달라지기 때문이다. Bayesian BM25는 이 문제를 해결하여 보정된 확률(calibrated probability)을 출력한다.

#### 3.B.2 핵심 수식

**1단계: BM25 점수 → 관련성 확률**

```
우도(Likelihood):  L(s) = σ(α·(s − β)) = 1 / (1 + e^(-α(s-β)))
사후확률(Posterior): P(R|s) = (L·π) / (L·π + (1−L)·(1−π))

- α: 기울기 (점수 변화에 대한 확률 민감도, 기본값 1.5)
- β: 중심점 (50% 관련성에 해당하는 BM25 점수, 기본값 1.0)
- π: 사전확률/기저율 (코퍼스 내 관련 문서 비율, 기본값 0.01)
```

**2단계: Cosine 유사도 → 관련성 확률**

```
P_vec(s) = σ(α·(s − β))

- α: 기본값 4.0 (cosine은 0~1 범위라 더 급한 기울기 필요)
- β: 기본값 0.5 (cosine 0.5를 50% 관련성으로 매핑)
```

**3단계: 확률 공간에서 결합**

논리합 (OR/SHOULD — 어느 한 소스라도 관련성 지지):
```
P(A ∨ B) = 1 − (1−P_A)·(1−P_B)
```

논리곱 (AND/MUST — 모든 소스가 관련성 지지):
```
P(A ∧ B) = P_A · P_B
```

하이브리드 서치에서는 **OR 결합**이 적합하다 (벡터든 BM25든 하나만 높아도 관련성 있음).

**실제 예시:**

```
벡터 cosine 0.85 → P_vec = σ(4·(0.85−0.5)) = σ(1.4) ≈ 0.80
BM25 score 3.2   → P_bm25 = posterior(σ(1.5·(3.2−1.0)), 0.01) ≈ 0.72

OR 결합: P = 1 − (1−0.80)·(1−0.72) = 1 − 0.056 = 0.944
→ 두 신호 모두 관련성 지지 → 높은 최종 확률

벡터 cosine 0.85 → P_vec ≈ 0.80
BM25 score 0.0   → P_bm25 ≈ 0.01 (BM25 매칭 없음)

OR 결합: P = 1 − (1−0.80)·(1−0.01) = 1 − 0.198 = 0.802
→ 벡터만 지지해도 합리적인 확률 유지
```

#### 3.B.3 구현 코드 (외부 의존성 없이 직접 구현)

핵심 수식이 간단하므로 라이브러리 없이 직접 구현한다.

**Python (LightRAG / RAG-Anything용) — 30줄:**

```python
import math

def sigmoid(x: float) -> float:
    x = max(-500.0, min(500.0, x))
    return 1.0 / (1.0 + math.exp(-x))

def bm25_to_probability(
    score: float, alpha: float = 1.5, beta: float = 1.0, prior: float = 0.01
) -> float:
    """BM25 점수 → 보정된 관련성 확률 [0,1]."""
    likelihood = sigmoid(alpha * (score - beta))
    joint = likelihood * prior
    complement = (1.0 - likelihood) * (1.0 - prior)
    return joint / (joint + complement)

def cosine_to_probability(
    cosine: float, alpha: float = 4.0, beta: float = 0.5
) -> float:
    """Cosine 유사도 → 관련성 확률 [0,1]."""
    return sigmoid(alpha * (cosine - beta))

def fuse_or(probs: list[float]) -> float:
    """OR 결합: 어느 하나라도 관련성을 지지하면 높은 확률."""
    return 1.0 - math.exp(
        sum(math.log(max(1.0 - p, 1e-10)) for p in probs)
    )

def fuse_and(probs: list[float]) -> float:
    """AND 결합: 모든 신호가 관련성을 지지할 때."""
    return math.exp(
        sum(math.log(max(p, 1e-10)) for p in probs)
    )
```

**Rust (EdgeQuake용) — 20줄:**

```rust
fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x.clamp(-500.0, 500.0)).exp())
}

fn bm25_to_probability(score: f32, alpha: f32, beta: f32, prior: f32) -> f32 {
    let likelihood = sigmoid(alpha * (score - beta));
    let joint = likelihood * prior;
    let complement = (1.0 - likelihood) * (1.0 - prior);
    joint / (joint + complement)
}

fn cosine_to_probability(cosine: f32, alpha: f32, beta: f32) -> f32 {
    sigmoid(alpha * (cosine - beta))
}

fn fuse_or(probs: &[f32]) -> f32 {
    1.0 - probs.iter()
        .map(|p| (1.0 - p.clamp(1e-10, 1.0 - 1e-10)).ln())
        .sum::<f32>()
        .exp()
}
```

#### 3.B.4 장점 (RRF 대비)

| 측면 | RRF | Bayesian |
|------|-----|----------|
| **점수 크기 활용** | 버림 (순위만) | 보존 (확률 변환) |
| **이론적 근거** | 경험적 휴리스틱 | 베이즈 정리 + 지수족 이론 |
| **임계값 필터링** | 불가 | 가능 (P > 0.5 = 관련) |
| **가중치 의미** | 임의적 | 사전확률로 해석 가능 |
| **3+ 소스 병합** | k 튜닝 어려움 | OR/AND 자연스러움 |
| **보정(calibration)** | 없음 | ECE 68-77% 감소 (벤치마크) |
| **구현 복잡도** | 낮음 (~15줄) | 낮음 (~30줄) |

#### 3.B.5 세 프레임워크에 특히 유용한 점

**1) 프루닝 개선 (`query_pipeline_comparison.md` 5.5절 문제 해결)**

현재 토큰 버짓 초과 시 "뒤에서부터 자르기"만 수행. 확률 기반이면:

```
P(관련|ENVY 청크) = 0.92  ← 확실히 관련
P(관련|Peugeot 일반 청크) = 0.45  ← 불확실
→ P < 0.5 청크를 우선 제거 (의미 있는 임계값)
```

**2) 엔티티 IDF 문제 완화 (`query_pipeline_comparison.md` 5.7절)**

BM25 확률이 자연스럽게 IDF를 반영하므로, degree 편향 없이 희귀 엔티티를 부스팅:

```
"AI" (degree=500, BM25_prob=0.3)  ← 너무 흔해서 낮은 확률
"MVCC" (degree=2, BM25_prob=0.9)  ← 희귀해서 높은 확률
→ OR 결합 시 MVCC가 자연스럽게 상위
```

**3) MIX 모드의 3소스 병합 개선**

현재 라운드로빈(vector[0], entity[0], relation[0], ...) 대신:

```python
P = fuse_or([P_vector, P_entity_chunk, P_relation_chunk])
# 어느 한 소스에서라도 높은 확률이면 상위로
```

#### 3.B.6 파라미터 가이드

| 파라미터 | 기본값 | 의미 | 조정 시 |
|---------|--------|------|---------|
| BM25 α | 1.5 | 기울기 (점수 민감도) | 높이면 고점수/저점수 구분 날카로움 |
| BM25 β | 1.0 | 중심점 (50% 관련성 점수) | 코퍼스 평균 BM25 점수에 맞춤 |
| BM25 π (prior) | 0.01 | 기저율 (관련 문서 비율) | 큰 코퍼스 → 낮게, 작은 코퍼스 → 높게 |
| Cosine α | 4.0 | 기울기 | 임베딩 모델 품질에 따라 조정 |
| Cosine β | 0.5 | 중심점 | 0.5가 50% 관련성 |

α, β 자동 튜닝: 코퍼스 인제스천 후 점수 분포의 중간값을 β로, 표준편차의 역수를 α로 설정하면 합리적인 초기값을 얻을 수 있다.

### 3.C Option A vs B 비교 요약

| 기준 | Option A (RRF) | Option B (Bayesian) |
|------|---------------|-------------------|
| **구현 난이도** | 매우 낮음 (15줄) | 낮음 (30줄) |
| **외부 의존성** | 없음 | 없음 (직접 구현) |
| **이론적 근거** | 경험적 | 베이즈 정리 |
| **점수 정보 보존** | 아니오 (순위만) | 예 (확률 변환) |
| **임계값 필터링** | 불가 | 가능 (P > 0.5) |
| **파라미터 수** | 1개 (k) | 5개 (α, β, π × 2종) |
| **튜닝 부담** | 거의 없음 | 중간 (기본값으로 시작 가능) |
| **3+ 소스 병합** | 약함 | 강함 (OR/AND 자연스러움) |
| **기존 문제 해결** | 하이브리드 검색만 | + 프루닝 개선 + IDF 편향 완화 |
| **디버깅 용이성** | 높음 (순위 직관적) | 중간 (확률 해석 필요) |

**권장:** Option B (Bayesian). 구현 비용 차이가 15줄 vs 30줄로 미미한 반면, 점수 보존 + 임계값 필터링 + 이론적 근거에서 확실한 이점. 특히 MIX 모드의 3소스 병합과 토큰 버짓 프루닝에서 실질적 차이가 발생한다.

**Option A가 적합한 경우:** 빠른 프로토타이핑, 파라미터 튜닝 부담을 최소화하고 싶을 때, 또는 벤치마크로 기본 효과를 먼저 확인하고 싶을 때.

---

## 4. 역인덱스 저장소 설계

BM25 검색을 위해서는 **역인덱스**(inverted index)가 필요하다. 역인덱스를 어디에 두는지는 프레임워크의 스토리지 백엔드에 따라 결정된다.

### 4.1 EdgeQuake — PostgreSQL tsvector + GIN

EdgeQuake는 이미 PostgreSQL을 사용하며, `documents.title`, `messages.content`, `conversations.title`에 `tsvector + GIN` 인덱스가 존재한다 (`init.sql:542-665`). **청크/엔티티/관계 테이블에는 아직 없다.**

또한 `GraphStorage.search_labels()` (`postgres/graph/mod.rs:847`)가 이미 `to_tsvector() @@ plainto_tsquery()` + `ts_rank()` 패턴을 사용 중이므로, 동일 패턴을 확장하면 된다.

**추가 필요한 인덱스 (init.sql 또는 마이그레이션):**

```sql
-- Level 1: 청크 BM25 검색용
ALTER TABLE chunks ADD COLUMN IF NOT EXISTS tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED;
CREATE INDEX IF NOT EXISTS idx_chunks_content_fts
    ON chunks USING GIN (tsv);

-- Level 2: 엔티티 BM25 검색용 (name + description)
ALTER TABLE entities ADD COLUMN IF NOT EXISTS tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', name || ' ' || COALESCE(description, ''))) STORED;
CREATE INDEX IF NOT EXISTS idx_entities_fts
    ON entities USING GIN (tsv);

-- Level 3 (선택): 관계 BM25 검색용
ALTER TABLE relationships ADD COLUMN IF NOT EXISTS tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', COALESCE(description, ''))) STORED;
CREATE INDEX IF NOT EXISTS idx_relationships_fts
    ON relationships USING GIN (tsv);
```

**왜 `GENERATED ALWAYS AS ... STORED`인가:**
- `content` 컬럼 변경 시 `tsv`가 자동 갱신 — 증분 업데이트 문제 없음
- 별도 트리거나 애플리케이션 로직 불필요
- 디스크 비용은 있지만, 쿼리 시 매번 `to_tsvector()` 계산하는 것보다 빠름

**쿼리 레이어 — `TextSearchStorage` trait 신설:**

| 방법 | 설명 | 판단 |
|------|------|------|
| A. `VectorStorage` trait에 `text_search()` 추가 | 기존 trait 확장 | 부적합 — MemoryVectorStorage에 BM25 구현을 끼워넣는 것이 어색 |
| **B. `TextSearchStorage` trait 신설** | 분리된 관심사 | **권장** — `SOTAQueryEngine`에 `text_search: Option<Arc<dyn TextSearchStorage>>` 추가 |

`GraphStorage.search_labels()`가 tsvector FTS를 직접 호출하는 기존 패턴이 있으므로, 동일 패턴을 `TextSearchStorage` trait으로 일반화한다.

```
edgequake-storage/src/
├── traits/
│   ├── mod.rs           ← + pub use text_search::TextSearchStorage;
│   ├── vector.rs        ← 변경 없음
│   ├── graph.rs         ← 변경 없음
│   ├── kv.rs            ← 변경 없음
│   └── text_search.rs   ← [NEW] TextSearchStorage trait
├── adapters/
│   ├── postgres/
│   │   └── text_search.rs  ← [NEW] tsvector + GIN 구현
│   └── memory/
│       └── text_search.rs  ← [NEW] 인메모리 BM25 (테스트용)
```

### 4.2 LightRAG / RAG-Anything — 스토리지 백엔드별 분기

LightRAG은 다양한 스토리지 백엔드를 지원하므로, 역인덱스 위치가 백엔드에 따라 달라진다.

| 스토리지 백엔드 | 역인덱스 위치 | 방법 | 증분 업데이트 |
|---------------|-------------|------|-------------|
| **NanoVectorDB** (기본) | Python 인메모리 | `rank-bm25` 또는 `bm25s` 라이브러리 | 전체 리빌드 필요 |
| **PostgreSQL** | DB tsvector + GIN | EdgeQuake과 동일한 SQL 방식 | 자동 |
| **Milvus** | Milvus 2.4+ sparse vector | 내장 BM25 지원 | 자동 |
| **Qdrant** | payload index | 내장 FTS 지원 | 자동 |

**NanoVectorDB (기본 백엔드) 인메모리 구현:**

```python
# lightrag/bm25_index.py (신규)
from rank_bm25 import BM25Okapi

class BM25Index:
    def __init__(self):
        self.corpus_ids: list[str] = []
        self.bm25: BM25Okapi | None = None

    def build(self, documents: dict[str, str]):
        """문서 dict {id: content}로 역인덱스 구축."""
        self.corpus_ids = list(documents.keys())
        tokenized = [doc.lower().split() for doc in documents.values()]
        self.bm25 = BM25Okapi(tokenized)

    def add(self, doc_id: str, content: str):
        """단건 추가 — IDF 재계산이 필요하므로 리빌드 트리거."""
        # rank-bm25는 증분 미지원, 전체 리빌드 필요
        # 대안: bm25s는 증분 업데이트 지원
        pass

    def search(self, query: str, top_k: int) -> list[tuple[str, float]]:
        if self.bm25 is None:
            return []
        scores = self.bm25.get_scores(query.lower().split())
        top_indices = scores.argsort()[-top_k:][::-1]
        return [(self.corpus_ids[i], float(scores[i])) for i in top_indices if scores[i] > 0]
```

**인제스천 시 인덱스 구축 위치:** `lightrag.py` 초기화에서 `chunks_vdb` 옆에 `chunks_bm25` 구축.

### 4.3 인메모리 BM25 역인덱스 — 대응 가능 범위

NanoVectorDB 백엔드 사용 시 인메모리 BM25의 스케일 한계.

**메모리 사용량 추정 (청크 512 토큰, 고유 토큰 ~200개 기준):**

| 청크 수 | 원문 크기 | BM25 인덱스 메모리 | 벡터(1536d) 메모리 | BM25/벡터 비율 |
|--------|----------|------------------|------------------|-------------|
| 1,000 | ~2MB | ~5MB | ~6MB | 0.8× |
| 10,000 | ~20MB | ~40MB | ~60MB | 0.7× |
| 100,000 | ~200MB | ~350MB | ~600MB | 0.6× |
| 500,000 | ~1GB | ~1.5GB | ~3GB | 0.5× |

**BM25 인덱스는 벡터 스토리지보다 항상 작다.** 벡터가 메모리에 올라가 있으면 BM25도 올라갈 수 있다.

**빌드 시간:**

| 청크 수 | `rank-bm25` (순수 Python) | `bm25s` (NumPy 기반) | Rust 자체 구현 |
|--------|--------------------------|---------------------|--------------|
| 1,000 | ~50ms | ~5ms | ~5ms |
| 10,000 | ~500ms | ~50ms | ~50ms |
| 100,000 | ~5초 | ~500ms | ~500ms |

**실질적 한계선:**

| 규모 | 인메모리 BM25 | 판단 |
|------|-------------|------|
| ~10만 청크 이하 | **안전** | NanoVectorDB 실사용 범위와 동일 |
| 10만~50만 | 가능하지만 주의 | 빌드 2~5초, 메모리 1~2GB |
| 50만 이상 | **DB 전환 권장** | NanoVectorDB 자체도 한계 |

**핵심:** NanoVectorDB가 인메모리이므로, **두 인덱스의 스케일 한계가 동일**하다. NanoVectorDB를 쓰는 규모면 인메모리 BM25도 충분하고, NanoVectorDB가 한계인 규모면 어차피 PostgreSQL로 전환해야 하므로 BM25도 tsvector + GIN으로 자연스럽게 넘어간다.

**증분 업데이트 비교:**

| | 인메모리 (rank-bm25) | PostgreSQL tsvector |
|---|---------------------|-------------------|
| 문서 추가 | IDF 재계산 필요 (전체 리빌드 or 근사) | 인덱스 자동 업데이트 |
| 문서 삭제 | 리빌드 필요 | 자동 |
| 서버 재시작 | 디스크에서 재로딩/리빌드 | 영속적 |

인메모리의 약점은 메모리보다 **증분 업데이트**다. 문서가 자주 추가/삭제되는 환경이면 규모와 무관하게 DB(tsvector)가 유리하다.

### 4.4 프레임워크별 요약

| 프레임워크 | 역인덱스 저장소 | 새 인프라 필요? | 구현 난이도 |
|-----------|---------------|---------------|-----------|
| **EdgeQuake** | PostgreSQL tsvector + GIN (GENERATED STORED 컬럼) | **없음** (기존 PG 활용) | 낮음 |
| **LightRAG (NanoVDB)** | Python 인메모리 (`rank-bm25` / `bm25s`) | pip 패키지 1개 | 낮음 |
| **LightRAG (PG)** | PostgreSQL tsvector + GIN | 없음 | 낮음 |
| **RAG-Anything** | LightRAG 상속 | 없음 | 없음 |

---

## 5. 프레임워크별 구현 방안

### 5.1 LightRAG (+ RAG-Anything 자동 상속)

LightRAG의 `operate.py`를 수정하면 RAG-Anything도 자동으로 혜택을 받는다.

**수정 대상 파일:** `lightrag/operate.py`

**Level 1 — 청크 검색:**

```python
# operate.py - _get_vector_context() / naive_query()
# 현재:
results = await chunks_vdb.query(query, top_k=20)

# 개선 (Option A — RRF):
vector_results = await chunks_vdb.query(query, top_k=top_k * 2)
bm25_results = bm25_chunk_index.search(query, top_k=top_k * 2)
merged = reciprocal_rank_fusion(vector_results, bm25_results, k=60)
results = merged[:top_k]

# 개선 (Option B — Bayesian, 권장):
vector_results = await chunks_vdb.query(query, top_k=top_k * 2)
bm25_results = bm25_chunk_index.search(query, top_k=top_k * 2)
# 모든 후보를 합집합으로 모은 뒤, 각 문서의 확률을 계산하여 정렬
all_doc_ids = set(r.id for r in vector_results) | set(r.id for r in bm25_results)
scored = []
for doc_id in all_doc_ids:
    vec_score = next((r.score for r in vector_results if r.id == doc_id), 0.0)
    bm25_score = next((r.score for r in bm25_results if r.id == doc_id), 0.0)
    p_vec = cosine_to_probability(vec_score)
    p_bm25 = bm25_to_probability(bm25_score)
    p_fused = fuse_or([p_vec, p_bm25])
    scored.append((doc_id, p_fused))
results = sorted(scored, key=lambda x: x[1], reverse=True)[:top_k]
```

**Level 2 — 엔티티 검색:**

```python
# operate.py - _get_node_data()
# 현재:
results = await entities_vdb.query(keywords_str, top_k=40)

# 개선 (Option A — RRF):
vector_results = await entities_vdb.query(keywords_str, top_k=60)
bm25_results = bm25_entity_index.search(keywords_str, top_k=60)
merged = reciprocal_rank_fusion(vector_results, bm25_results, k=60)
results = merged[:40]

# 개선 (Option B — Bayesian, 권장):
# 청크 검색과 동일한 패턴 (cosine_to_probability + bm25_to_probability + fuse_or)
```

**BM25 인덱스 구축 (인제스천 시):**

```python
# 청크 저장 시
await text_chunks_db.upsert(chunk)
await chunks_vdb.upsert(chunk)
bm25_chunk_index.add(chunk_id, chunk_text)        # 새로 추가

# 엔티티 저장 시
await knowledge_graph.upsert_node(entity_name, node_data)
await entities_vdb.upsert(entity_embedding)
bm25_entity_index.add(entity_name, f"{entity_name} {description}")  # 새로 추가
```

**Python BM25 라이브러리 옵션:**

| 라이브러리 | 특징 | 적합성 |
|-----------|------|--------|
| `rank_bm25` | 순수 Python, 가볍고 간단 | 프로토타이핑 |
| `bm25s` | C 바인딩, 빠름, Scipy sparse matrix | 프로덕션 |
| PostgreSQL `tsvector` | DB 내장, 인덱스 자동 관리 | PostgreSQL 백엔드 사용 시 최적 |

**저장:** pickle 직렬화 또는 PostgreSQL `tsvector` + GIN 인덱스 활용.

### 5.2 RAG-Anything

LightRAG를 수정하면 자동 상속. 추가 작업 없음.

단, 멀티모달 쿼리(`aquery_with_multimodal`)에서 enhanced query를 LightRAG에 넘길 때, BM25 검색 대상 쿼리도 enhanced query가 사용되는지 확인만 필요. 현재 `query.py:257`에서 `aquery(enhanced_query)`를 호출하므로 자연스럽게 전파된다.

### 5.3 EdgeQuake

#### 5.3.1 파일 구조 변경

```
edgequake-query/src/sota_engine/
├── mod.rs              ← + `mod bm25_search;` 추가
│                          + SOTAQueryEngine에 text_search 필드 추가
│                          + SOTAQueryConfig에 하이브리드 설정 추가
├── bm25_search.rs      ← [NEW] BM25 검색 + RRF 병합
├── reranking.rs        ← 기존 유지 (post-retrieval reranking, 변경 없음)
├── query_modes.rs      ← bm25_search 호출하도록 수정
├── vector_queries.rs   ← bm25_search 호출하도록 수정 (workspace 변형)
├── query_entry/
│   └── query_basic.rs  ← 변경 없음 (Step 4.5 reranking 그대로 유지)
└── prompt.rs           ← 변경 없음
```

**왜 `reranking.rs`를 리네임하지 않는가:**
- `reranking.rs`의 3개 함수(`rerank_chunks`, `sort_entities_by_degree`, `validate_keywords`)는 모두 **post-retrieval** 로직으로 여전히 유효
- 하이브리드 서치는 **retrieval-level** 로직으로 개념이 다름
- `bm25_search.rs`로 분리하면 책임이 명확: retrieval vs post-processing

**이중 BM25 구조 (retrieval + reranking):**

```
Query
  ↓
[Retrieval] hybrid_chunk_search()     ← bm25_search.rs (recall 향상)
  ↓
[Post-retrieval] rerank_chunks()      ← reranking.rs (precision 향상)
  ↓
[Truncation] balance_context()
  ↓
LLM
```

retrieval-level BM25가 recall을 넓히고, post-retrieval BM25 리랭킹이 precision을 좁힌다. 두 단계의 BM25가 중복이 아니라 상호 보완적인 이유는:
- retrieval: **벡터가 놓친 문서를 발견** (recall)
- reranking: **이미 발견된 문서 중 가장 관련 높은 것을 상위로** (precision)

#### 5.3.2 `bm25_search.rs` 설계

```rust
// bm25_search.rs — BM25-based hybrid search (retrieval-level)
//
// WHY: Vector search misses exact keyword matches (e.g., "ENVY", "PostgreSQL").
// BM25 lexical search complements vector semantic search by catching these cases.
//
// Supports two fusion strategies:
// - Option A: RRF (Reciprocal Rank Fusion) — rank-based, simple
// - Option B: Bayesian probability fusion — score-preserving, principled (recommended)

impl SOTAQueryEngine {
    /// Hybrid chunk search: vector + BM25, merged with configurable fusion.
    pub(super) async fn hybrid_chunk_search(
        &self,
        query: &str,
        embedding: &[f32],
        top_k: usize,
        filter_ids: Option<&[String]>,
        tenant_id: Option<&str>,
        workspace_id: Option<&str>,
    ) -> Result<Vec<RetrievedChunk>>

    /// Hybrid entity search: vector + BM25 on entity name+description.
    pub(super) async fn hybrid_entity_search(
        &self,
        query: &str,
        embedding: &[f32],
        top_k: usize,
        tenant_id: Option<&str>,
        workspace_id: Option<&str>,
    ) -> Result<Vec<RetrievedEntity>>
}

// --- Option A: RRF ---

pub(super) fn reciprocal_rank_fusion(
    result_lists: &[(&[RankedResult], f32)],  // (results, weight)
    k: usize,      // default 60
    top_k: usize,
) -> Vec<(String, f32)>

// --- Option B: Bayesian probability fusion (recommended) ---

fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x.clamp(-500.0, 500.0)).exp())
}

fn bm25_to_probability(score: f32, alpha: f32, beta: f32, prior: f32) -> f32 {
    let likelihood = sigmoid(alpha * (score - beta));
    let joint = likelihood * prior;
    let complement = (1.0 - likelihood) * (1.0 - prior);
    joint / (joint + complement)
}

fn cosine_to_probability(cosine: f32, alpha: f32, beta: f32) -> f32 {
    sigmoid(alpha * (cosine - beta))
}

fn fuse_or(probs: &[f32]) -> f32 {
    1.0 - probs.iter()
        .map(|p| (1.0 - p.clamp(1e-10, 1.0 - 1e-10)).ln())
        .sum::<f32>()
        .exp()
}
```

#### 5.3.3 `SOTAQueryConfig` 추가 필드

```rust
/// Enable BM25 hybrid search at retrieval level.
/// When false, falls back to vector-only search (current behavior).
pub enable_hybrid_search: bool,       // default: true

/// Fusion strategy: "rrf" (Option A) or "bayesian" (Option B, recommended).
pub fusion_strategy: String,          // default: "bayesian"

// --- Option A (RRF) parameters ---

/// BM25 weight in RRF fusion (relative to vector weight=1.0).
pub rrf_bm25_weight: f32,             // default: 1.0

/// RRF k parameter.
pub rrf_k: usize,                     // default: 60

// --- Option B (Bayesian) parameters ---

/// BM25 sigmoid slope (score sensitivity).
pub bayesian_bm25_alpha: f32,         // default: 1.5

/// BM25 sigmoid midpoint (score where P=50%).
pub bayesian_bm25_beta: f32,          // default: 1.0

/// BM25 base rate prior (fraction of relevant docs in corpus).
pub bayesian_bm25_prior: f32,         // default: 0.01

/// Cosine sigmoid slope.
pub bayesian_cosine_alpha: f32,       // default: 4.0

/// Cosine sigmoid midpoint.
pub bayesian_cosine_beta: f32,        // default: 0.5

/// Minimum probability threshold for filtering (P < threshold → discard).
/// Only applicable with Bayesian fusion.
pub bayesian_min_probability: f32,    // default: 0.1
```

#### 5.3.4 `SOTAQueryEngine` 추가 필드

```rust
pub struct SOTAQueryEngine {
    // ... existing fields ...
    /// Optional text search storage for BM25 hybrid search.
    text_search: Option<Arc<dyn TextSearchStorage>>,
}
```

#### 5.3.5 `TextSearchStorage` trait (edgequake-storage)

```rust
// edgequake-storage/src/traits.rs

pub struct TextSearchResult {
    pub id: String,
    pub score: f32,
    pub content: String,
    pub metadata: HashMap<String, serde_json::Value>,
}

#[async_trait]
pub trait TextSearchStorage: Send + Sync {
    /// BM25 full-text search on chunks.
    async fn search_chunks_bm25(
        &self, query: &str, top_k: usize,
        tenant_id: Option<&str>, workspace_id: Option<&str>,
    ) -> Result<Vec<TextSearchResult>>;

    /// BM25 full-text search on entity names+descriptions.
    async fn search_entities_bm25(
        &self, query: &str, top_k: usize,
        tenant_id: Option<&str>, workspace_id: Option<&str>,
    ) -> Result<Vec<TextSearchResult>>;
}
```

#### 5.3.6 PostgreSQL 구현 (tsvector + GIN)

EdgeQuake는 이미 PostgreSQL을 사용하므로 추가 인프라 없이 구현 가능.

**마이그레이션 SQL:**

```sql
-- 청크 테이블에 tsvector 컬럼 추가
ALTER TABLE text_chunks ADD COLUMN tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED;
CREATE INDEX idx_chunks_tsv ON text_chunks USING GIN(tsv);

-- 엔티티 테이블에도
ALTER TABLE entities ADD COLUMN tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('simple', name || ' ' || COALESCE(description, ''))) STORED;
CREATE INDEX idx_entities_tsv ON entities USING GIN(tsv);
```

**BM25 검색 쿼리:**

```sql
-- 청크 BM25 검색
SELECT id, content, ts_rank_cd(tsv, query) AS score
FROM text_chunks, plainto_tsquery('simple', $1) query
WHERE tsv @@ query
  AND ($2::text IS NULL OR tenant_id = $2)
  AND ($3::text IS NULL OR workspace_id = $3)
ORDER BY score DESC
LIMIT $4;

-- 엔티티 BM25 검색
SELECT id, name, description, ts_rank_cd(tsv, query) AS score
FROM entities, plainto_tsquery('simple', $1) query
WHERE tsv @@ query
  AND ($2::text IS NULL OR tenant_id = $2)
  AND ($3::text IS NULL OR workspace_id = $3)
ORDER BY score DESC
LIMIT $4;
```

**왜 `'simple'` 설정인가:**
- `'english'` 등 언어별 설정은 스테밍/불용어 처리를 하지만, 기술 용어와 고유명사가 변형될 위험
- `'simple'`은 공백 기준 토크나이징만 수행하여 정확 매칭에 유리
- 다국어 문서 지원에도 안전 (한국어, 프랑스어 등)

#### 5.3.7 `query_modes.rs` 변경 예시

**query_naive (Level 1):**

```rust
// 현재:
let results = self.vector_storage
    .query(&embeddings.query, self.config.max_chunks * 2, None)
    .await?;
let chunk_results = filter_by_type(results, VectorType::Chunk);

// 변경:
let chunks = if self.config.enable_hybrid_search && self.text_search.is_some() {
    self.hybrid_chunk_search(
        query, &embeddings.query,
        self.config.max_chunks, None,
        tenant_id.as_deref(), workspace_id.as_deref(),
    ).await?
} else {
    // 폴백: 기존 벡터 only 경로
    let results = self.vector_storage
        .query(&embeddings.query, self.config.max_chunks * 2, None)
        .await?;
    // ... existing filter logic ...
};
```

**query_local Step 1 (Level 2):**

```rust
// 현재:
let vector_results = self.vector_storage
    .query(&embeddings.low_level, self.config.max_entities * 3, None)
    .await?;
let entity_vectors = filter_by_type(vector_results, VectorType::Entity);

// 변경:
let entities = if self.config.enable_hybrid_search && self.text_search.is_some() {
    self.hybrid_entity_search(
        &keywords.low_level.join(" "), &embeddings.low_level,
        self.config.max_entities,
        tenant_id.as_deref(), workspace_id.as_deref(),
    ).await?
} else {
    // 폴백: 기존 벡터 only 경로
    // ... existing logic ...
};
```

---

## 6. 변경 영향 범위 요약

### 6.1 LightRAG

| 파일 | 변경 내용 |
|------|----------|
| `operate.py` | `_get_vector_context()`, `naive_query()` — 하이브리드 검색 추가 |
| `operate.py` | `_get_node_data()` — 엔티티 하이브리드 검색 추가 |
| `lightrag.py` | BM25 인덱스 초기화 로직 추가 |
| (인제스천) | 청크/엔티티 저장 시 BM25 인덱스 동시 빌드 |

### 6.2 RAG-Anything

| 파일 | 변경 내용 |
|------|----------|
| 없음 | LightRAG 수정 시 자동 상속 |

### 6.3 EdgeQuake

| 파일 | 변경 내용 |
|------|----------|
| `sota_engine/bm25_search.rs` | **[NEW]** `hybrid_chunk_search()`, `hybrid_entity_search()`, `reciprocal_rank_fusion()` |
| `sota_engine/mod.rs` | `mod bm25_search;` 추가, `text_search` 필드, config 필드 추가 |
| `sota_engine/query_modes.rs` | 벡터 검색을 `hybrid_*_search()` 호출로 교체 (폴백 포함) |
| `sota_engine/vector_queries.rs` | workspace 변형도 동일하게 교체 |
| `sota_engine/reranking.rs` | **변경 없음** |
| `sota_engine/query_entry/query_basic.rs` | **변경 없음** (Step 4.5 리랭킹 그대로) |
| `edgequake-storage/src/traits.rs` | `TextSearchStorage` trait 추가 |
| `edgequake-storage` (postgres impl) | PostgreSQL `tsvector` + GIN 인덱스 구현 |
| DB 마이그레이션 | `text_chunks`, `entities` 테이블에 `tsv` 컬럼 + GIN 인덱스 추가 |

---

## 7. 구현 우선순위

| 순서 | 작업 | 프레임워크 | 효과 | 난이도 | 비고 |
|------|------|-----------|------|--------|------|
| **1** | 청크 하이브리드 검색 | LightRAG | 높음 | 중간 | RAG-Anything 자동 상속 |
| **2** | 엔티티 하이브리드 검색 | LightRAG | 높음 | 중간 | RAG-Anything 자동 상속 |
| **3** | 청크 하이브리드 검색 | EdgeQuake | 높음 | 낮음 | BM25 인프라 이미 존재 |
| **4** | 엔티티 하이브리드 검색 | EdgeQuake | 중간 | 낮음 | PostgreSQL tsvector 활용 |
| **5** | 관계 하이브리드 검색 | 전체 | 낮음 | 중간 | 선택적 |

**1번부터 시작하면** RAG-Anything도 자동으로 혜택을 받으므로, 실질적으로 두 프레임워크를 동시에 개선하는 효과.

**3번이 난이도가 낮은 이유:**
- EdgeQuake는 이미 `BM25Reranker`를 사용 중 (edgequake-llm 크레이트)
- PostgreSQL tsvector + GIN 인덱스는 DB 마이그레이션만으로 준비 완료
- `bm25_search.rs` 신규 생성으로 기존 코드 수정 최소화

---

## 8. 기대 효과

### 8.1 개선되는 케이스

| 케이스 | 현재 (벡터 only) | 개선 후 (하이브리드) |
|--------|-----------------|-------------------|
| 정확한 고유명사 검색 | 임베딩 거리에 의존 (불안정) | BM25 정확 매칭으로 보장 |
| 희귀 전문 용어 | 임베딩에 학습 안 된 경우 놓침 | BM25 IDF가 희귀 용어 부스팅 |
| 약어/코드명 검색 | "MVCC", "ENVY" 등 놓칠 수 있음 | 리터럴 매칭으로 확실히 발견 |
| 숫자/버전 구분 | "2008" vs "3008" 임베딩 유사 | BM25가 정확히 구분 |

### 8.2 Option B (Bayesian) 선택 시 추가 개선 효과

RRF에는 없고 Bayesian에서만 얻을 수 있는 효과:

| 케이스 | RRF | Bayesian |
|--------|-----|----------|
| 확률 기반 프루닝 (P < 0.5 제거) | 불가 | **가능** — 토큰 예산 효율 향상 |
| 3소스 MIX 병합 (vector + entity + relation 청크) | k 튜닝 어려움 | **OR 결합 자연스러움** |
| 엔티티 IDF 편향 완화 | 개선 없음 | **BM25 확률이 IDF 반영** |
| 점수 크기 정보 ("0.99 vs 0.51" 구분) | 동일 취급 | **차별화** |
| post-retrieval reranking 점수도 확률 변환 | 불가 | **가능** — reranking.rs 결과도 sigmoid 변환하여 일관된 확률 체계 |
| 결과 품질 디버깅 | 순위만 관찰 가능 | **확률값으로 관련성 정량 평가** |

**비용 차이:** 구현 코드 15줄(RRF) vs 30줄(Bayesian). 파라미터는 5개 추가되지만 모두 합리적 기본값 제공.

### 8.3 개선되지 않는 케이스

| 케이스 | 이유 |
|--------|------|
| 의미적 동의어 검색 | BM25는 리터럴 매칭만 (벡터가 담당) |
| 다국어 크로스링구얼 | BM25 토크나이저 한계 |
| 엔티티 degree 편향 (5.7절) | 그래프 구조적 문제, 검색 레벨과 무관 (단, Bayesian 옵션은 부분 완화) |
| 2-hop 이상 연결 발견 | 그래프 탐색 깊이 문제 |

### 8.4 리스크

| 리스크 | 완화 방안 |
|--------|----------|
| 레이턴시 증가 (2개 검색 병렬) | tokio::join! / asyncio.gather 병렬 실행 |
| BM25 인덱스 메모리/디스크 | PostgreSQL tsvector는 DB 내장, 별도 관리 불필요 |
| 설정 복잡도 증가 | `enable_hybrid_search` 플래그로 on/off, 기본값 true |
| BM25 토크나이저 한계 (CJK 등) | `'simple'` 설정 + 향후 형태소 분석기 추가 가능 |
