# EdgeQuake Agentic RAG Architecture Note

**Date:** 2026-03-07
**Context:** EdgeQuake에 DeepTutor 스타일 multihop agentic-RAG 도입 검토

---

## 1. 현재 EdgeQuake의 한계

- LightRAG 기반 단일 패스 파이프라인 (5-stage)
- LLM 호출 2회 고정 (키워드 추출 + 답변 생성)
- 그래프 탐색은 1~2 hop 이웃 batch fetch일 뿐, 추론 기반 multihop이 아님
- 쿼리 분해, 반복 검색, 충분성 판단, 자기 검증 모두 부재

---

## 2. 3-Tier 쿼리 라우팅 아키텍처

복잡도에 따라 3단계로 분기:

```
쿼리 입력
  |
  |-- 단순 (factual/단일 엔티티)
  |     --> 기존 5-stage 파이프라인
  |         LLM 2회, 200ms~1s
  |
  |-- 복잡 (multihop/관계 추론)
  |     --> Solve Agent (2중 루프)
  |         LLM 10~20회, 10~30s
  |
  |-- 광범위 (탐색/리포트)
        --> Research Agent (토픽 큐 + 병렬)
            LLM 30~100회+, 1~5min
```

라우팅 판단: 기존 키워드 추출 단계의 `query_intent`에 복잡도 분류 확장.

---

## 3. Tier 1 — 기존 파이프라인 (변경 없음)

```
키워드 추출 --> 모드 선택 --> 임베딩 --> 검색 --> LLM 답변
```

- 6 Query Modes: Naive, Local, Global, Hybrid, Mix, Bypass
- 단일 패스, 고정 토큰 버짓 (30K)
- 단순 질문에 최적 (비용 최소, 지연 최소)

---

## 4. Tier 2 — Solve Agent (DeepTutor solve 참조)

### 4.1 Analysis Loop (지식 수집)

```
while knowledge != sufficient:
    InvestigateAgent (LLM)
      --> 지식 갭 분석
      --> 다중 쿼리 생성 + 도구 선택
    도구 실행
      --> rag_naive (chunk only)
      --> rag_hybrid (graph 탐색)
      --> web_search
      --> paper_search
      --> code_exec
    NoteAgent (LLM)
      --> 결과 압축 + 인용 생성
      --> knowledge_chain에 누적
    종료: [TOOL]none 출력 시 자동 중단
```

핵심: 에이전트가 **매 iteration마다** chunk only vs graph hybrid를 판단.
기존 SOTAQueryEngine의 6-mode가 그대로 도구 목록이 됨.

### 4.2 Solve Loop (문제 풀이)

```
PlanAgent --> 문제를 블록으로 분해
ManagerAgent --> 블록을 구체적 스텝(3~5개)으로 변환
for each step:
    SolveAgent --> 스텝 실행 (도구 호출 포함)
    CheckAgent --> 검증 (pass / needs_revision)
      --> 실패 시 SolveAgent 재시도 (max 3회)
ResponseAgent --> 최종 답변 종합
```

핵심: CheckAgent의 매 스텝 검증 (논리 완결성, 인용 정확성, 계산 정확성).

---

## 5. Tier 3 — Research Agent (DeepTutor research 참조)

### 5.1 3-Phase Pipeline

```
Phase 1: Planning
    RephraseAgent --> 질문 리프레이즈
    DecomposeAgent --> 서브토픽 분해
    --> plan.json 생성

Phase 2: Researching (토픽별 병렬 가능)
    TopicQueue에서 토픽 꺼냄
    for each topic (semaphore 병렬):
        Analysis Loop (Tier 2와 동일 구조)
        --> topic_N_overview.md (지식 노트)
        --> topic_N_traces.json (도구 호출 이력)
    동적 토픽 추가: 검색 중 새 서브토픽 발견 시 큐에 추가

Phase 3: Reporting
    ReportingAgent --> 모든 노트를 종합하여 report.md 생성
    CitationManager --> citations.json
```

### 5.2 산출물 구조

```
research_output/
    plan.json                  <-- 토픽 분해 결과
    topics/
        topic_01_overview.md   <-- 토픽별 지식 노트
        topic_01_traces.json   <-- 도구 호출 이력 + 인용
        topic_02_overview.md
        topic_02_traces.json
    report.md                  <-- 최종 종합 리포트
    citations.json             <-- 전체 인용 레지스트리
```

### 5.3 Research가 Solve와 다른 점

| | Solve | Research |
|---|---|---|
| 중간 산출물 | 메모리만 | 파일 (md/json) |
| 병렬화 | 순차 (스텝 의존) | 토픽별 병렬 |
| 컨텍스트 제약 | LLM 윈도우 한계 | 노트 기반으로 무제한 |
| 재개 가능 | 불가 | 체크포인트 가능 |
| 용도 | 추론/답변 | 조사/리포트 |

---

## 6. 도구 레이어 — 기존 엔진 래핑

모든 Tier에서 공유하는 도구 세트:

| 도구 | 구현 | 설명 |
|---|---|---|
| `rag_naive` | SOTAQueryEngine (Naive mode) | chunk only 벡터 검색 |
| `rag_local` | SOTAQueryEngine (Local mode) | 엔티티 중심 + 1-hop |
| `rag_global` | SOTAQueryEngine (Global mode) | 관계/커뮤니티 중심 |
| `rag_hybrid` | SOTAQueryEngine (Hybrid mode) | Local + Global 결합 |
| `web_search` | 외부 API (신규) | 그래프에 없는 정보 |
| `paper_search` | 외부 API (신규) | 학술 논문 검색 |
| `code_exec` | 샌드박스 (신규) | 계산/데이터 처리 |

기존 SOTAQueryEngine::query()는 변경 없이 context_only=true로 호출하면
LLM 답변 생성 없이 검색 컨텍스트만 반환 가능.

---

## 7. 오케스트레이션 패턴 — Tool-Calling Orchestrator

### 7.1 핵심 아이디어

별도 그래프 엔진(LangGraph 등) 없이, **오케스트레이터 LLM이 플랜을 세우고 tool calling으로 실행**.
모든 분기/반복/병렬이 오케스트레이터의 tool call 시퀀스로 표현된다.
Claude Code의 Agent/Task 패턴(deepagents)과 동일한 구조.

### 7.2 도구 체계

```
Orchestrator (메인 LLM 컨텍스트)
  |
  |-- 검색 도구 (동기, 직접 호출)
  |     rag_hybrid(query)
  |     rag_naive(query)
  |     rag_local(query)
  |     rag_global(query)
  |     web_search(query)
  |     paper_search(query)
  |     code_exec(code)
  |
  |-- 에이전트 도구 (비동기, 병렬 가능)
  |     subagent(task, tools)           <-- 단일 서브에이전트
  |     agent_team([task1, task2, ...]) <-- N개 병렬 실행, 결과 수집
  |
  |-- 계획 도구
  |     plan(question)                    <-- 질문 분해 + 실행 플랜 생성
  |     decompose(question, depth)        <-- 서브토픽 분해 (Research용)
  |
  |-- 판단 도구
  |     check_sufficiency(knowledge, question)
  |     validate_answer(answer, criteria)
  |
  |-- 산출물 도구
  |     write_note(topic, content)
  |     write_plan(plan_json)
  |     write_report(sections)
```

### 7.3 Tier별 오케스트레이터 동작

**Tier 1 — 단순 질문**: 오케스트레이터 불필요. 기존 파이프라인 직행.

**Tier 2 — Solve**: 오케스트레이터가 직접 루프.
```
Orchestrator:
  1. tool: rag_hybrid("서브질문 1") --> 결과
  2. tool: check_sufficiency(결과, 질문) --> 불충분
  3. tool: rag_naive("보완 질문") --> 추가 결과
  4. tool: check_sufficiency(누적 결과, 질문) --> 충분
  5. tool: validate_answer(답변, 기준) --> pass
  --> 최종 답변
```

**Tier 3 — Research**: 오케스트레이터가 서브에이전트 팀 생성.
```
Orchestrator:
  1. 플랜 수립 (토픽 분해)
  2. tool: write_plan(plan.json)
  3. tool: agent_team([
       {task: "토픽1 조사", tools: [rag_hybrid, web_search]},
       {task: "토픽2 조사", tools: [rag_naive, paper_search]},
       {task: "토픽3 조사", tools: [rag_hybrid, web_search]},
     ])
     --> 각 서브에이전트가 독립적으로 Analysis Loop 실행
     --> 각자 write_note()로 지식 노트 생성
  4. 서브에이전트 결과 수집
  5. tool: write_report(종합)
```

### 7.4 이 패턴의 장점

| | LangGraph 방식 | Tool-Calling Orchestrator |
|---|---|---|
| 워크플로우 정의 | 코드로 그래프 하드코딩 | LLM이 동적으로 결정 |
| 분기/반복 | 조건부 엣지로 정적 정의 | tool call 시퀀스로 유연하게 |
| 새 도구 추가 | 그래프 재구성 필요 | 도구 목록에 추가만 하면 됨 |
| 병렬 실행 | Send() API | agent_team() tool call |
| 에러 복구 | 그래프 내 fallback 노드 | 오케스트레이터가 판단 후 재시도 |
| 프레임워크 의존 | LangGraph 필수 | 없음 (LLM + tool calling만) |

### 7.5 구현 시 코드 구조

```
edgequake-query/src/
    (기존 코드 유지)
    sota_engine/          <-- 기존 5-stage 파이프라인
    strategies/           <-- 기존 6-mode 전략
    ...

    agentic/              <-- 신규 모듈
        mod.rs            <-- Tier 라우터 (복잡도 판단 -> 분기)
        orchestrator.rs   <-- 오케스트레이터 LLM 루프
        tools/
            rag.rs        <-- SOTAQueryEngine 래핑 (6-mode)
            web.rs        <-- web_search, paper_search
            code.rs       <-- code_exec 샌드박스
            judge.rs      <-- check_sufficiency, validate_answer
            artifact.rs   <-- write_note, write_plan, write_report
            agent.rs      <-- subagent(), agent_team() 비동기 실행
        memory.rs         <-- knowledge_chain / solve_memory
        research/
            topic_queue.rs
            artifacts.rs  <-- 파일 기반 노트/플랜 관리

    prompts/
        agentic/
            orchestrator_solve.txt
            orchestrator_research.txt
            subagent.txt
```

---

## 8. 비용/지연 비교

| | Tier 1 (기존) | Tier 2 (Solve) | Tier 3 (Research) |
|---|---|---|---|
| LLM 호출 | 2회 | 10~20회 | 30~100회+ |
| 지연 | 200ms~1s | 10~30s | 1~5min |
| 비용 배수 | 1x | 5~10x | 15~50x |
| 검색 도구 | 1회 고정 모드 | 매 iteration 선택 | 토픽별 병렬 + 매 iteration 선택 |
| 검증 | 없음 | CheckAgent 매 스텝 | 토픽별 충분성 판단 |
| 산출물 | 답변 텍스트 | 답변 + 인용 | 플랜 + 노트 + 리포트 + 인용 |

---

## 9. 추가 패턴 — agentic-rag-for-dummies 참조

### 9.1 Parent-Child 계층 청킹

현재 EdgeQuake는 고정 사이즈 청킹 (1200 토큰). 이 프로젝트의 2단계 전략:

```
Parent Chunk (2000~4000자, 헤더 기반 분할)
  |-- Child Chunk (500자, 검색용)
  |-- Child Chunk
  |-- Child Chunk
```

- child chunk로 벡터 검색 (빠르고 정밀) → parent chunk로 컨텍스트 확장 (풍부)
- EdgeQuake의 graph 탐색과 직교적으로 결합 가능:
  graph에서 엔티티 → source chunk → parent chunk로 확장

### 9.2 쿼리 명확화 + Human-in-the-loop

```
QueryAnalysis (structured output):
  is_clear: bool
  questions: List[str]       # 최대 3개로 분리
  clarification_needed: str

  --> is_clear == false --> 사용자에게 되물음 (interrupt)
  --> is_clear == true  --> 분해된 질문별 병렬 검색
```

EdgeQuake의 MCP/대화형 인터페이스에 적용 가능.
Tier 라우팅 전에 명확화 단계를 두면 잘못된 Tier 진입 방지.

### 9.3 Map-Reduce 병렬 검색 + 자기 수정

```
분해된 질문 N개 --> LangGraph Send() --> N개 agent 병렬 실행
  각 agent:
    orchestrator --> search --> 불충분? --> self-correction (재검색)
                                         --> 컨텍스트 초과? --> compress_context
                                         --> max_iterations? --> fallback
  --> aggregate_answers (종합)
```

DeepTutor의 Analysis Loop와 유사하나 더 경량:
- 파일 영속화 없이 메모리 내 압축 (compress_context)
- Tier 2 (Solve)의 경량 대안으로 참고 가능

### 9.4 EdgeQuake 차별화 포인트

위 프로젝트들은 모두 **chunk only** 검색. EdgeQuake만의 강점:
- **parent-child chunk + knowledge graph traversal** 결합
- 에이전트가 매 iteration마다 chunk only vs graph hybrid를 선택
- 이 조합이 기존 agentic-RAG 프로젝트에 없는 차별점

---

---

# Part 2: 기존 Agentic RAG 프로젝트 구조 정리

---

## A. DeepTutor Solve Agent

**Repo:** https://github.com/HKUDS/DeepTutor/tree/main/src/agents/solve
**목적:** 구체적 문제 풀이 (multihop 추론, 계산, 단계적 답변)

### A.1 디렉토리 구조

```
src/agents/solve/
    analysis_loop/
        investigate_agent.py   <-- 지식 갭 분석 + 다중 쿼리 생성 + 도구 호출
        note_agent.py          <-- 검색 결과 압축 + 인용(cite_id) 생성
    solve_loop/
        plan_agent.py          <-- 문제를 개념적 블록으로 분해
        manager_agent.py       <-- 블록을 구체적 스텝(3~5개)으로 변환
        solve_agent.py         <-- 스텝 실행 (도구 호출 포함)
        tool_agent.py          <-- 통합 도구 접근 (RAG, 웹, 코드, 아이템 쿼리)
        check_agent.py         <-- 스텝별 품질 검증 (pass/needs_revision)
        response_agent.py      <-- 최종 답변 종합
        precision_answer_agent.py
        citation_manager.py    <-- 인용 관리
    memory/
        investigate_memory.py  <-- Analysis Loop 상태 (knowledge_chain)
        solve_memory.py        <-- Solve Loop 상태 (블록/스텝 계층)
    utils/
    prompts/
        analysis_loop/
        solve_loop/
    main_solver.py             <-- 진입점
    session_manager.py
```

### A.2 2중 루프 흐름

```
[Analysis Loop — 지식 수집]

while true:
    InvestigateAgent:
      - 현재 knowledge_chain 평가
      - 다중 쿼리 동시 생성 + 도구 호출
      - cite_id -> raw_result 매핑 생성
    NoteAgent:
      - 각 raw_result를 순차적으로 LLM 압축
      - 요약 + 인용 추출
      - knowledge_chain에 누적
    종료 조건: InvestigateAgent가 [TOOL]none 출력
              (고정 iteration이 아닌 동적 판단)

    --> knowledge_chain + citations 전달

[Solve Loop — 문제 풀이]

PlanAgent:
  - 문제를 개념적 블록으로 분해
  - 블록별 목표 정의

ManagerAgent:
  - 각 블록을 구체적 실행 스텝(3~5개)으로 변환

for each step:
    SolveAgent:
      - 스텝 실행 (ToolAgent를 통해 도구 호출)
      - 사용 가능 도구: rag_hybrid, rag_naive, web_search, run_code, query_item
    CheckAgent:
      - 4가지 기준 검증: 논리 완결성, 인용 명확성, 계산 정확성, 포맷 준수
      - 판정: pass -> 다음 스텝 / needs_revision -> SolveAgent 재시도
      - 최대 3회 재시도 후 강제 진행

ResponseAgent:
  - 모든 스텝 결과를 종합하여 최종 답변 생성
```

### A.3 도구 선택 전략 (iteration 위치 기반)

| 구간 | 추천 도구 | 이유 |
|---|---|---|
| 초기 (1~1/3) | RAG (knowledge base) | 내부 지식 우선 활용 |
| 중기 (1/3~2/3) | 논문 검색, 웹 검색 | 내부 지식 보완 |
| 후기 (2/3~) | 코드 실행, 외부 소스 | 갭 메우기 |

### A.4 메모리 구조

**InvestigateMemory** (knowledge_chain, JSON):
- 각 도구 호출에 고유 cite_id 부여
- raw_result + summary + metadata 영속화
- iteration 수, 지식 항목 수, 신뢰도 메트릭 추적

**SolveMemory** (블록/스텝 계층, JSON):
- 블록별, 스텝별 상태 플래그 (pending/in_progress/completed/failed)
- 생성된 콘텐츠 + 인용 + 도구 실행 로그
- 체크포인트 재개 가능

---

## B. DeepTutor Research Agent

**Repo:** https://github.com/HKUDS/DeepTutor/tree/main/src/agents/research
**목적:** 광범위 조사 + 구조화된 리포트 생성

### B.1 디렉토리 구조

```
src/agents/research/
    main.py                    <-- CLI 진입점
    research_pipeline.py       <-- 3-Phase 오케스트레이션
    data_structures.py         <-- TopicBlock, ToolTrace, DynamicTopicQueue
    agents/
        rephrase_agent.py      <-- 질문 리프레이즈 (반복 정제 가능)
        decompose_agent.py     <-- 서브토픽 분해 (RAG 컨텍스트 활용)
        manager_agent.py       <-- 큐 스케줄링 + 상태 관리
        research_agent.py      <-- 충분성 평가 + 쿼리 계획 + 도구 실행
        note_agent.py          <-- 결과 압축 + 인용
        reporting_agent.py     <-- 최종 리포트 종합
    prompts/                   <-- 다국어 프롬프트 템플릿
    utils/
```

### B.2 3-Phase 흐름

```
[Phase 1: Planning]

RephraseAgent:
  - 사용자 입력 최적화
  - 반복 정제 가능 (interactive iteration)
DecomposeAgent:
  - RAG 컨텍스트를 활용하여 서브토픽 분해
  - TopicQueue 초기화 (서브토픽 = TopicBlock으로 시드)
  --> plan.json 저장

[Phase 2: Researching]

실행 모드: series 또는 parallel (설정 기반)

Series:
  ManagerAgent.get_next_task() --> pending TopicBlock 순차 처리

Parallel:
  모든 pending blocks 수집
  asyncio.Semaphore로 동시성 제한 (max_parallel_topics)
  AsyncManagerAgentWrapper로 thread-safe 운영
  active_tasks 딕셔너리 + lock 보호

각 TopicBlock에 대해:
  ResearchAgent.process(topic_block):
    while iteration < max_iterations:
      1. check_sufficiency (LLM)
         - "fixed" 모드: 보수적 (중간에 잘 안 멈춤)
         - "flexible" 모드: 자율적 (한계 효용 판단)
      2. generate_query_plan (LLM)
         - 자연어 쿼리 생성
         - 도구 선택 (rag_hybrid/rag_naive/web_search/paper_search/run_code)
         - 선택 근거 제시
         - 새 서브토픽 발견 시 ManagerAgent에 동적 추가
      3. 도구 실행
      4. NoteAgent (LLM) --> 결과 압축 + 인용
      5. current_knowledge += summary

  --> topic_N_overview.md + topic_N_traces.json 저장

[Phase 3: Reporting]

ReportingAgent:
  - 모든 토픽 노트를 종합
  - 마크다운 리포트 생성 (단어 수, 섹션 구조, 인용 메트릭)
CitationManager:
  - 전체 인용 레지스트리 생성
  --> report.md + citations.json 저장
```

### B.3 핵심 자료구조

**TopicBlock** (최소 스케줄링 단위):
- sub_topic, overview, status (pending/researching/completed/failed)
- tool_traces: List[ToolTrace]
- iteration 수, 타임스탬프
- to_dict/from_dict 직렬화 (세션 간 영속화)

**ToolTrace** (도구 호출 기록):
- tool_id, cite_id, query, raw_answer (50KB 자동 절삭), summary
- JSON 구조 보존하면서 절삭

**DynamicTopicQueue** (스케줄링 센터):
- 블록 순차 관리, 중복 체크 (case-insensitive)
- 상태 전이, JSON 영속화 (자동 저장)

### B.4 Solve와의 핵심 차이

| 측면 | Solve | Research |
|---|---|---|
| 종료 조건 | `[TOOL]none` (동적) | iteration 제한 또는 충분성 (모드 선택) |
| 토픽 관리 | 없음 (단일 문제) | DynamicTopicQueue (다중 토픽 + 동적 추가) |
| 병렬화 | 순차 (스텝 간 의존) | 토픽별 병렬 (semaphore 제어) |
| 산출물 | 메모리 내 knowledge_chain | 파일 (md/json) per topic + 종합 리포트 |
| 재개 | 불가 | 체크포인트 가능 (JSON 직렬화) |

---

## C. Agentic RAG for Dummies

**Repo:** https://github.com/GiovanniPasq/agentic-rag-for-dummies
**목적:** LangGraph 기반 경량 agentic RAG (학습용 + 확장 가능)

### C.1 디렉토리 구조

```
project/
    core/
        rag_system.py          <-- RAG 오케스트레이션
        document_manager.py    <-- 문서 수집
        chat_interface.py      <-- 대화 처리
    db/
        vector_db_manager.py   <-- Qdrant 벡터 DB
        parent_store_manager.py <-- Parent chunk JSON 저장
    rag_agent/
        graph.py               <-- LangGraph 워크플로우 정의
        graph_state.py         <-- 상태 관리
        nodes.py               <-- 노드 구현
        edges.py               <-- 조건부 라우팅
        tools.py               <-- 검색 도구
        prompts.py
        schemas.py             <-- 구조화 출력 스키마
    ui/
        gradio_app.py
    config.py
    document_chunker.py        <-- Parent-Child 청킹
```

### C.2 4-Stage 워크플로우

```
[Stage 1: Conversation Understanding]
- 최근 대화 이력 분석, 컨텍스트 연속성 유지

[Stage 2: Query Clarification]
- QueryAnalysis (structured output):
    is_clear: bool
    questions: List[str]  (최대 3개로 분리)
    clarification_needed: str
- 불명확 시 -> human-in-the-loop (interrupt -> 사용자 응답 -> 재개)
- 도메인 용어 보존

[Stage 3: Multi-Agent Map-Reduce Retrieval]
- 분해된 질문별 병렬 agent 생성: LangGraph Send() API
- 각 agent 루프:
    1. orchestrator -> 강제로 search_child_chunks 먼저 호출
    2. child chunk 검색 (Qdrant hybrid: dense + sparse)
    3. parent chunk 확장 (JSON store에서 parent_id로 조회)
    4. 결과 불충분? -> self-correction (재검색)
    5. 컨텍스트 초과? -> compress_context (LLM 메모리 내 압축)
       - 이미 실행한 쿼리/parent_id 로그 -> 중복 검색 방지
    6. max_iterations 또는 max_tool_calls 도달? -> fallback_response
    7. 충분하면 -> collect_answer

[Stage 4: Aggregate Answers]
- 모든 서브 질문 답변을 index 순서로 정렬
- 단일 종합 답변 생성
```

### C.3 Parent-Child 계층 청킹

```
원본 마크다운
  | 헤더 기반 분할 (#, ##, ###)
Parent Chunks (2000~4000자)
  | 작은 chunk 병합 (<2000자), 큰 chunk 재분할 (>4000자)
  | 각 parent에서 고정 사이즈로 분할
Child Chunks (500자, 검색용)
  - metadata에 parent_id 포함
  - Qdrant에 hybrid 인덱싱 (dense + sparse embedding)

검색 시:
  child chunk로 빠른 유사도 검색 -> parent_id로 원본 컨텍스트 확장
```

### C.4 기술 스택

| 구성 | 선택 |
|---|---|
| 오케스트레이션 | LangGraph (정적 그래프) |
| 벡터 DB | Qdrant (dense + sparse hybrid) |
| LLM | Ollama/OpenAI/Anthropic/Google (1줄 교체) |
| 임베딩 | HuggingFace |
| PDF | PyMuPDF4LLM |

---

## D. A-RAG (Agentic RAG)

**Repo:** https://github.com/Ayanami0730/arag
**목적:** LLM이 검색 전략을 자율적으로 선택하는 최소 agentic RAG

### D.1 핵심 아이디어 — 검색 도구에 granularity 부여

다른 프로젝트들이 하나의 search tool을 제공하는 반면,
A-RAG는 **granularity가 다른 3개 도구**를 에이전트에게 주고 자율 선택시킴:

```
도구 3개 (granularity 순서):
  keyword_search(keywords, top_k)  <-- 정밀: 정확한 용어 매칭
  semantic_search(query, top_k)    <-- 탐색: 의미 유사도 검색
  read_chunk(chunk_ids)            <-- 확장: 전체 내용 읽기
```

에이전트가 ReAct 루프 안에서 상황에 따라 골라 씀:
- "정확한 엔티티명 알고 있다" -> keyword_search
- "개념은 아는데 정확한 용어 모른다" -> semantic_search
- "검색 결과의 snippet이 유망하다" -> read_chunk로 전체 확인

### D.2 2단계 검색 패턴: Search -> Read

```
Agent:
  1. keyword_search("STLA Medium") -> 약식 snippet + chunk_id 반환
  2. "이 chunk가 유망하다"
  3. read_chunk(["chunk_42"]) -> 전체 텍스트 + 인접 chunk(+-1) 반환
  4. "충분하다" -> 최종 답변
```

search 도구는 **약식 snippet만 반환** (full text 아님).
에이전트가 snippet을 보고 read_chunk를 호출해야 전체 내용을 읽을 수 있음.
-> 토큰 낭비 방지 + 에이전트에게 "깊이 읽을지 말지" 판단을 위임.

### D.3 에이전트 루프 (ReAct)

```
run(query):
  messages = [system_prompt, user_query]
  for i in 0..max_loops(10):
      if token_budget_exceeded: force_final_answer()
      response = llm(messages, tools=[keyword_search, semantic_search, read_chunk])
      if no tool_calls: break  (자연 종료 - 답변 완성)
      for tool_call in response.tool_calls:
          result = registry.execute(tool_call)
          messages.append(tool_result)
      trajectory.log(loop, tool, args, result, tokens)
  return final_answer
```

종료 조건 3가지:
- 자연 종료: LLM이 tool_call 없이 답변
- 토큰 초과: 128K 한도 -> 강제 종합
- 루프 한도: max 10회

### D.4 컨텍스트 추적

| 기능 | 구현 |
|---|---|
| 중복 읽기 방지 | `context.mark_chunk_as_read()` -- 이미 읽은 chunk 표시 |
| 토큰 예산 관리 | 매 루프마다 현재 토큰 수 계산 |
| 궤적 기록 | trajectory에 모든 도구 호출 + 결과 + 토큰 수 기록 |

### D.5 EdgeQuake 적용 시 시사점

A-RAG의 granularity 개념을 EdgeQuake의 6-mode에 적용:

```
현재: 에이전트가 mode를 선택 (naive/local/global/hybrid)
확장: mode + granularity 조합

검색 도구 (granularity 순서):
  keyword_search(keywords)           <-- 정밀, 저비용
  entity_lookup(entity_name)         <-- graph 노드 직접 조회 (신규)
  rag_naive(query, top_k)            <-- chunk 벡터 검색
  rag_local(query, top_k)            <-- 엔티티 중심 + 1-hop
  rag_hybrid(query, top_k)           <-- 전체 graph + chunk
  rag_global(query, top_k)           <-- 커뮤니티/테마 중심

읽기 도구:
  read_chunk(chunk_ids)              <-- 전체 텍스트 확인
  read_entity(entity_id)             <-- 엔티티 상세 + 관계 (신규)
  read_community(community_id)       <-- 커뮤니티 요약 (신규)
```

핵심: search는 snippet 반환, read는 full context 반환.
에이전트가 "얕게 넓게 -> 깊게 좁게"로 탐색 가능.

---

## E. 5개 프로젝트 종합 비교 (우리 설계 포함)

| 측면 | DeepTutor Solve | DeepTutor Research | rag-for-dummies | A-RAG | **New Plan** |
|---|---|---|---|---|---|
| 프레임워크 | 자체 구현 | 자체 구현 | LangGraph | 자체 구현 (ReAct) | **Tool-Calling Orchestrator** |
| 에이전트 수 | 6+ (전문화) | 6+ (전문화) | 1 타입 (범용) | 1 (범용) | **1 orchestrator + N subagent** |
| 쿼리 분해 | PlanAgent (블록+스텝) | DecomposeAgent (토픽) | QueryAnalysis (max 3) | 없음 (단일 쿼리) | **plan() 도구 (동적 판단)** |
| 검색 전략 | 다중 도구 선택 | 다중 도구 선택 | child->parent chunk only | granularity별 3도구 | **6-mode graph + granularity** |
| 도구 granularity | 없음 (도구=모드) | 없음 (도구=모드) | 없음 (child->parent) | 핵심 (keyword/semantic/read) | **search(snippet) + read(full) + graph** |
| 자기 수정 | CheckAgent (4기준, 3회) | 충분성 평가 (fixed/flexible) | 조건부 재검색 | 자연 종료 (LLM 판단) | **validate_answer() + check_sufficiency()** |
| 병렬화 | 순차 | 토픽별 병렬 (semaphore) | 질문별 병렬 (Send) | 없음 (순차 루프) | **agent_team() 비동기 병렬** |
| 컨텍스트 관리 | 메모리 (knowledge_chain) | 파일 (md/json per topic) | 메모리 내 압축 | context tracker (중복 방지) | **Tier2 메모리 / Tier3 파일 영속** |
| human-in-the-loop | 없음 | 없음 | 쿼리 명확화 시 | 없음 | **명확화 도구 (추가 가능)** |
| graph 탐색 | 없음 | 없음 | 없음 | 없음 | **knowledge graph 6-mode** |
| 산출물 | 답변 + 인용 | 플랜 + 노트 + 리포트 + 인용 | 답변 | 답변 + trajectory | **Tier별: 답변 / 인용 / 플랜+노트+리포트** |
| 재개 가능 | SolveMemory로 가능 | 체크포인트 가능 | 불가 | 불가 | **Tier3 체크포인트 가능** |
| 적합 용도 | multihop 추론, 계산 | 광범위 조사, 리포트 | 경량 QA, 학습 | 문서 내 정밀 탐색 | **단순~리포트 전 범위 (3-Tier)** |
| 핵심 차별점 | 2중 루프 + 검증 | 토픽 병렬 + 파일 영속 | parent-child + HITL | search/read 분리 | **graph RAG + granularity + 3-Tier 라우팅** |

---

## 10. 참조

- DeepTutor Solve: https://github.com/HKUDS/DeepTutor/tree/main/src/agents/solve
- DeepTutor Research: https://github.com/HKUDS/DeepTutor/tree/main/src/agents/research
- agentic-rag-for-dummies: https://github.com/GiovanniPasq/agentic-rag-for-dummies
- A-RAG: https://github.com/Ayanami0730/arag
- EdgeQuake Query Pipeline: EDGEQUAKE_QUERY_PIPELINE.md
- LightRAG Paper: arXiv:2410.05779
