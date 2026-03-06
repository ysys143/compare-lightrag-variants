# EdgeQuake Query-Time Pipeline - Complete Analysis

**Last Updated:** March 6, 2026
**Research Status:** Complete READ-ONLY analysis
**Source:** EdgeQuake Rust codebase - /crates/edgequake-query/

---

## Executive Summary

EdgeQuake implements the **LightRAG algorithm** with a sophisticated 5-stage query pipeline that supports 6 different retrieval modes. The system prioritizes **graph context over naive chunks** and uses **LLM-based keyword extraction** to route queries to mode-specific retrieval strategies.

### Key Stats
- **Default Mode:** Hybrid (combines local + global)
- **Max Context Tokens:** 30,000 (matching LightRAG spec)
- **Max Entities:** 60 (preserves LightRAG parity)
- **Max Chunks:** 20
- **Token Budget Split:** Entities 33% / Relationships 33% / Chunks 33%
- **Keyword Cache TTL:** 24 hours
- **Reranking:** Enabled by default (BM25-based)

---

## 1. Query Entry Point

**File:** `/crates/edgequake-query/src/sota_engine/query_entry/query_basic.rs`
**Entry Method:** `SOTAQueryEngine::query(request: QueryRequest)`
**Implements:** FEAT0109 (SOTA Query Engine)

### Query Request Structure
```rust
pub struct QueryRequest {
    pub query: String,
    pub mode: Option<QueryMode>,                    // Override default mode
    pub max_results: Option<usize>,
    pub context_only: bool,                         // Skip LLM generation
    pub prompt_only: bool,                          // Return formatted prompt only
    pub params: HashMap<String, serde_json::Value>,
    pub conversation_history: Vec<ConversationMessage>,  // Multi-turn context
    pub enable_rerank: Option<bool>,                // Override reranking
    pub rerank_top_k: Option<usize>,
    pub llm_provider: Option<String>,               // User-selected LLM override
    pub llm_model: Option<String>,                  // User-selected model override
}
```

### Query Response
```rust
pub struct QueryResponse {
    pub answer: String,
    pub context: QueryContext,
    pub sources: Vec<Source>,
    pub stats: QueryStats,
}
```

---

## 2. 5-Stage Query Pipeline

### Stage 1: Keyword Extraction (FEAT0107)

**File:** `/crates/edgequake-query/src/keywords/llm_extractor.rs`
**Class:** `LLMKeywordExtractor`

#### Extraction Prompt
Located at: `LLMKeywordExtractor::build_prompt()` lines 80-141

```
Extract high-level and low-level keywords from the following query, and classify the query intent.

## Definitions

**High-level keywords**: Abstract concepts, themes, or topics that represent the broader context or domain of the query. These are used to find relevant relationships and global patterns in a knowledge graph.
Examples: "artificial intelligence", "climate change", "software architecture", "healthcare outcomes"

**Low-level keywords**: Specific entities, technical terms, proper nouns, or concrete concepts. These are used to find specific entities in a knowledge graph.
Examples: "GPT-4", "Sarah Chen", "PostgreSQL", "neural network", "Microsoft"

**Query Intent**:
- factual: Questions asking for facts about a specific thing ("What is X?", "Who is Y?")
- relational: Questions about connections between things ("How does X relate to Y?")
- exploratory: Broad questions seeking overview or understanding ("Tell me about X")
- comparative: Questions comparing multiple things ("Compare X and Y")
- procedural: Questions about processes or steps ("How to do X?")

[Query provided here]

## Output Format
Respond ONLY with valid JSON:
{
  "high_level_keywords": ["concept1", "concept2", ...],
  "low_level_keywords": ["entity1", "term1", ...],
  "query_intent": "factual|relational|exploratory|comparative|procedural"
}
```

**Why LLM Extraction:**
- Low-level keywords match entity embeddings
- High-level keywords match relationship embeddings
- Different keywords retrieve different context types optimally
- Caching (24h TTL) reuses extraction results for identical queries

**Output Type:** `ExtractedKeywords`
```rust
pub struct ExtractedKeywords {
    pub high_level: Vec<String>,
    pub low_level: Vec<String>,
    pub query_intent: QueryIntent,
    pub cache_key: String,
}
```

#### Provider Override Support
Method: `extract_with_provider(query, llm_override)`
**Why:** If user selected GPT-4 in UI, keyword extraction MUST use GPT-4 too, not the server's default Ollama. Without this, keyword extraction would be inconsistent with final LLM generation.

---

### Stage 1.5: Keyword Validation

**File:** `/crates/edgequake-query/src/sota_engine/query_entry/query_basic.rs` line 72

**Method:** `SOTAQueryEngine::validate_keywords()`

**Purpose:** Drop keywords with no graph matches to prevent embedding dilution

**Process:**
1. Check if each extracted keyword exists in the knowledge graph
2. Filter keywords where graph lookup returns empty results
3. Only pass validated keywords to embedding computation

**Example:**
- Query: "What about STLA Medium and Tesla?"
- Raw extraction: `["STLA Medium", "Tesla", "vehicle", ...]`
- After validation: `["Tesla", "vehicle", ...]` (STLA Medium dropped)

---

### Stage 2: Mode Selection

**File:** `/crates/edgequake-query/src/modes.rs`

#### Query Modes (6 Total)

| Mode | FEAT | Use Case | Key Strategy |
|------|------|----------|--------------|
| **Naive** | FEAT0101 | Simple keyword search | Vector search on chunks only |
| **Local** | FEAT0102 | Entity-specific questions | Entity-centric + 1-hop neighbors |
| **Global** | FEAT0103 | Broad/thematic questions | Relationship-centric + communities |
| **Hybrid** | FEAT0104 | Complex questions (DEFAULT) | Local + Global combined |
| **Mix** | FEAT0105 | Adaptive blending | Weighted naive + graph |
| **Bypass** | FEAT0106 | Testing/debugging | Direct LLM, no RAG |

#### Mode Selection Logic

**File:** `/crates/edgequake-query/src/sota_engine/query_entry/query_basic.rs` lines 75-81

```rust
let mode = if let Some(m) = request.mode {
    m  // User override
} else if self.config.use_adaptive_mode {
    keywords.query_intent.recommended_mode()  // Intent-based selection
} else {
    self.config.default_mode  // Hybrid
};
```

**Intent -> Mode Mapping:**
- `Factual` -> Local (specific entity facts)
- `Relational` -> Hybrid (entity + relationships)
- `Exploratory` -> Global (broad themes)
- `Comparative` -> Hybrid (compare entities + context)
- `Procedural` -> Local (step-by-step entities)

**Default:** Hybrid (lines 70, 139 of modes.rs)

---

### Stage 3: Embedding Computation

**File:** `/crates/edgequake-query/src/sota_engine/mod.rs` lines 177-192
**Struct:** `QueryEmbeddings`

#### Three Embeddings Generated (In Parallel)

```rust
pub struct QueryEmbeddings {
    pub query: Vec<f32>,           // Original query embedding (Naive mode)
    pub high_level: Vec<f32>,      // High-level keywords embedding (Global mode)
    pub low_level: Vec<f32>,       // Low-level keywords embedding (Local mode)
}
```

**Computation Method:** `QueryEmbeddings::compute()`

```
Query: "How does machine learning improve healthcare outcomes?"
    |
Keyword extraction:
  - high_level: ["machine learning", "healthcare", "improvement"]
  - low_level: ["ML algorithms", "clinical diagnosis", "patient data"]
    |
Three parallel embeddings:
  1. Query embedding <- entire query text
  2. High-level embedding <- concat(high_level keywords)
  3. Low-level embedding <- concat(low_level keywords)
```

**Why Three Embeddings:**
- **query embedding:** Direct chunk similarity (Naive mode)
- **low_level embedding:** Entity vector search (Local mode)
- **high_level embedding:** Relationship vector search (Global mode)

---

### Stage 4: Mode-Specific Retrieval

**File:** `/crates/edgequake-query/src/sota_engine/query_modes.rs`

#### 4.1 LOCAL MODE (Entity-Centric)

**Method:** `SOTAQueryEngine::query_local()` lines 31-190

**Strategy:** Answer specific factual questions like "Who is the CEO of Apple?"

**Steps:**

1. **Vector Search** (lines 40-47)
   - Use `embeddings.low_level`
   - Fetch top `max_entities * 3` (180 candidates)
   - Search vector storage for entity vectors

2. **Filter to Entities Only** (line 48)
   - Ignore relationship and chunk vectors
   - Keep only entity vectors (type filter)

3. **Build Entity Scores Map** (lines 50-64)
   - Preserve similarity scores from vector search
   - Maps entity names -> relevance scores
   - **Why:** Fixes score=0.0 bug in downstream processing

4. **Extract Top Entities** (lines 66-80)
   - Take top `max_entities` (60) entities
   - Filter by min_score threshold (0.1)
   - Filter by tenant_id/workspace_id if provided
   - Maintain **deterministic order** (Vec, not HashMap)

5. **Batch Fetch Graph Data** (lines 87-94)
   ```rust
   tokio::join!(
       graph_storage.get_nodes_batch(&entity_ids),      // Node properties
       graph_storage.node_degrees_batch(&entity_ids),   // Degree scores
   )
   ```

6. **Build Entity Context** (lines 115-123)
   - Iterate in vector search score order (not HashMap order)
   - Add degree metadata (number of connections)
   - Preserve original similarity scores

7. **Fetch Direct Relationships** (lines 125-138)
   - Get all edges connected to the entities
   - Take top `max_relationships` (60)
   - Build relationship context with descriptions

8. **Retrieve Source Chunks** (lines 140-187)
   - Collect chunk IDs from entity `source_chunk_ids`
   - Collect chunk IDs from relationship `source_chunk_id`
   - Query vector storage with chunk ID filter
   - Rerank by cosine similarity to `embeddings.low_level`
   - Take top chunks to fit token budget

**Why This Order:**
1. Entities are the primary context (most specific)
2. Relationships provide connections
3. Chunks provide evidence/proof

---

#### 4.2 GLOBAL MODE (Relationship-Centric)

**Method:** `SOTAQueryEngine::query_global()` lines 211-410

**Strategy:** Answer thematic/analytical questions like "How do tech companies compete?"

**Steps:**

1. **Vector Search for Relationships** (lines 222-231)
   - Use `embeddings.high_level`
   - Fetch top `max_relationships * 3` (180 candidates)
   - Search for relationship vectors

2. **Filter to Relationships Only** (line 234)
   - Keep only relationship vectors
   - Ignore entity and chunk vectors

3. **Extract Relationships** (lines 237-306)
   - For each result:
     - Get src_id (source entity)
     - Get tgt_id (target entity)
     - Get rel_type (relationship type)
     - Get description (relationship description)
   - Deduplicate by key: `"{src}->{tgt}:{type}"`
   - Track source provenance (chunk IDs, doc IDs, file paths)

4. **Entity Hydration - Two Paths:**

   **Path A - Normal Path** (lines 340-359):
   - Collect all entity IDs from relationship endpoints
   - Batch fetch entity nodes and degrees
   - Add entities to context
   - **Deterministic order:** Preserve entity_ids Vec order

   **Path B - Fallback Path** (lines 308-339):
   - IF no relationships found, fallback to **popular entities**
   - Query: `get_popular_nodes_with_degree(max_entities, min_degree=2)`
   - Add relationships between popular entities

5. **Add Chunks** (lines 362-371)
   - Direct chunk vectors from the vector search results
   - Filter by min_score and tenant/workspace
   - Take top `max_chunks` (20)

6. **Add Source Chunks** (lines 373-411)
   - Collect chunk IDs tracked by entities/relationships
   - Fill remaining chunk slots
   - Query vector storage with chunk ID filter
   - Rerank by similarity to `embeddings.high_level`

---

#### 4.3 HYBRID MODE (Local + Global Combined)

**File:** `/crates/edgequake-query/src/strategies/hybrid.rs`

**Method:** Implemented in strategy pattern

**Strategy:**

```rust
// Run both with reduced limits
local_config.max_chunks /= 2;           // 10 chunks
local_config.max_entities /= 2;         // 30 entities

global_config.max_entities /= 2;        // 30 entities

local_context = local_strategy.execute(...);
global_context = global_strategy.execute(...);

// Merge: Local entities first (more relevant), then global
```

**Merging Logic:**
1. Add all local chunks first (more specific)
2. Add entities: dedup by name, local + global
3. Add relationships: dedup by key, local + global

---

#### 4.4 NAIVE MODE (Vector-Only Search)

**Method:** `query_naive_with_vector_storage()` lines 17-44

**Strategy:** Simple vector similarity on chunks

**Steps:**
1. Fetch top `max_chunks * 2` (40 candidates) - oversampling to account for non-chunk results
2. Filter to chunk vectors only
3. Take top 20 chunks
4. No graph traversal

---

#### 4.5 MIX MODE (Adaptive Blending)

**File:** `/crates/edgequake-query/src/strategies/mix.rs`

**Strategy:** Weighted combination of naive + graph results

**Configuration:**
```rust
pub struct MixStrategyConfig {
    pub vector_weight: f32,  // Weight for naive vector results
    pub graph_weight: f32,   // Weight for graph results
}
```

---

### Stage 4.5: Reranking (Optional)

**File:** `/crates/edgequake-query/src/sota_engine/reranking.rs`

**Method:** `rerank_chunks()` lines 6-100

**Type:** BM25-based reranking (OODA-231 fix)

**Process:**
1. Check if reranking enabled (`config.enable_rerank = true` by default)
2. Call `reranker.rerank(query, documents, top_k)`
3. Filter results by `min_rerank_score` (default 0.1)
4. **Fallback:** If ALL chunks filtered by rerank score, return top_k original chunks
   - **Why:** BM25 scores 0.0 for terms not in chunks, but chunks may be relevant via graph
   - **Example:** Graph found chunk, but query terms don't match chunk text literally

**Configuration:**
```rust
pub enable_rerank: bool = true,
pub min_rerank_score: f32 = 0.1,
pub rerank_top_k: usize = 20,
```

---

### Stage 5: Token Budgeting & Truncation

**File:** `/crates/edgequake-query/src/truncation.rs`

#### Token Budget Allocation

**Default Configuration:**
```rust
pub struct TruncationConfig {
    pub max_entity_tokens: usize = 10_000,        // 33%
    pub max_relation_tokens: usize = 10_000,      // 33%
    pub max_total_tokens: usize = 30_000,         // Grand total
}
```

**Why 30,000 tokens:**
- LightRAG standard
- GPT-4o-mini has 128K context
- 30K uses only 23% of context window (safe margin)
- Previous 4K budget wasted 87% of usable context

#### Truncation Strategy (BR0102 - Graph Priority)

**Order of Priority:**
1. **Entities** - Truncate first (remove lowest-score entities)
2. **Relationships** - Truncate second (remove lowest-score relationships)
3. **Chunks** - Truncate last (remove lowest-relevance chunks)

**Rationale:**
- Graph context is pre-summarized and denser
- Chunks contain raw evidence but are more verbose
- Prioritizing graph maximizes information density

#### Truncation Process

**File:** `/crates/edgequake-query/src/truncation.rs` lines 77-132

```rust
pub fn truncate_entities(
    entities: Vec<RetrievedEntity>,
    max_tokens: usize,
    tokenizer: &dyn Tokenizer,
) -> Vec<RetrievedEntity> {
    let mut result = Vec::new();
    let mut total_tokens = 0;

    for entity in entities {
        let formatted = format!(
            "Entity: {} ({})\n{}\n",
            entity.name, entity.entity_type, entity.description
        );
        let entity_tokens = tokenizer.count_tokens(&formatted);

        if total_tokens + entity_tokens <= max_tokens {
            result.push(entity);
            total_tokens += entity_tokens;
        } else {
            break;  // Stop when exceeding limit
        }
    }

    result
}
```

**Token Counting:**
- Entities formatted as: `"Entity: NAME (TYPE)\nDESCRIPTION\n"`
- Relationships formatted as: `"Relationship: SRC -> TGT (TYPE)\n"`
- Chunks counted as-is

#### Deterministic Ordering

**Critical for Reproducibility:**
- Items already sorted by relevance before truncation
- Truncation preserves most relevant items
- Same query -> same truncated results

---

## 5. Context Assembly

**File:** `/crates/edgequake-query/src/context.rs`

### QueryContext Structure

```rust
pub struct QueryContext {
    pub chunks: Vec<RetrievedChunk>,
    pub entities: Vec<RetrievedEntity>,
    pub relationships: Vec<RetrievedRelationship>,
    pub token_count: usize,
    pub is_truncated: bool,
    pub metadata: HashMap<String, serde_json::Value>,
}
```

### Context Serialization to LLM

**Method:** `QueryContext::to_context_string()` lines 68-117

**Format:**

```markdown
### Knowledge Graph Data (Entities)

- **Entity Name** (ENTITY_TYPE) [connections: N]: Description text

### Knowledge Graph Data (Relationships)

- Source --[RELATION_TYPE]--> Target: Description text

### Document Chunks

[1] (score: 0.95)
Chunk content text here...

[2] (score: 0.87)
Another chunk...
```

**Why This Format:**
- Clear section breaks for LLM parsing
- Entity metadata (type, degree) provides context
- Relationship descriptions explain connections
- Chunk indexing enables citation in final answer

---

## 6. Final LLM Prompt Generation

**File:** `/crates/edgequake-query/src/sota_engine/prompt.rs`

### Prompt Template

**Method:** `SOTAQueryEngine::build_prompt()` lines 75-115

**Full Prompt:**

```
---Role---

You are an expert AI assistant specializing in synthesizing information from a provided knowledge base. Your primary function is to answer user queries accurately by ONLY using the information within the provided **Context**.

---Goal---

Generate a comprehensive, well-structured answer to the user query.
The answer must integrate relevant facts from the Knowledge Graph and Document Chunks found in the **Context**.

---Instructions---

1. Step-by-Step Reasoning:
  - Carefully determine the user's query intent to fully understand the information need.
  - Scrutinize both Knowledge Graph Data (Entities and Relationships) and Document Chunks in the **Context**. Identify and extract all pieces of information that are directly relevant to answering the user query.
  - Weave the extracted facts into a coherent and logical response. Your own knowledge must ONLY be used to formulate fluent sentences and connect ideas, NOT to introduce any external information.

2. Content & Grounding:
  - Strictly adhere to the provided context; DO NOT invent, assume, or infer any information not explicitly stated.
  - If the answer cannot be fully determined from the **Context**, state what information IS available and note what is missing. A partial answer with specific data is better than a generic "insufficient information" response.

3. Formatting & Language:
  - The response MUST be in the same language as the user query.
  - Use Markdown formatting for clarity (headings, bold text, bullet points).

---Context---

[CONTEXT_TEXT_HERE]

---User Query---

[QUERY_HERE]
```

### Provider Override Support

**Method:** `generate_answer_with_provider()` lines 121-144

```rust
pub(super) async fn generate_answer_with_provider(
    &self,
    query: &str,
    context: &QueryContext,
    llm_override: Option<&Arc<dyn LLMProvider>>,
) -> Result<(String, usize)> {
    let prompt = self.build_prompt(query, context);

    // SPEC-032: Use override provider if provided, else default
    let response = if let Some(provider) = llm_override {
        provider.complete(&prompt).await?
    } else {
        self.llm_provider.complete(&prompt).await?
    };

    Ok((response.content, response.completion_tokens))
}
```

**Why Provider Override:**
- User selects "OpenAI GPT-4" in UI
- Query pipeline MUST use GPT-4 end-to-end:
  - [O] Keyword extraction: GPT-4
  - [O] Final LLM generation: GPT-4
  - [X] Not: Ollama -> GPT-4 (inconsistent)

---

## 7. Vector Search Operations

**File:** `/crates/edgequake-query/src/sota_engine/vector_queries.rs`

### Vector Storage Interface

**Trait:** `VectorStorage` (from edgequake-storage)

```rust
pub async fn query(
    embedding: &[f32],
    top_k: usize,
    candidate_ids: Option<&[String]>  // Optionally filter to these IDs
) -> Result<Vec<VectorSearchResult>>;
```

### VectorSearchResult Metadata

```rust
pub struct VectorSearchResult {
    pub id: String,
    pub score: f32,  // Cosine similarity (0.0-1.0)
    pub metadata: HashMap<String, serde_json::Value>,
}
```

### Metadata Fields by Vector Type

**Entity Vectors:**
```json
{
    "entity_name": "Apple Inc.",
    "entity_type": "COMPANY",
    "description": "...",
    "source_chunk_ids": ["doc-uuid-chunk-0", ...],
    "source_document_id": "doc-uuid",
    "source_file_path": "/path/to/doc.txt"
}
```

**Relationship Vectors:**
```json
{
    "src_id": "Apple Inc.",
    "tgt_id": "Microsoft Corp.",
    "relation_type": "PARTNERS_WITH",
    "description": "Partnership in cloud services",
    "source_chunk_id": "doc-uuid-chunk-5",
    "source_document_id": "doc-uuid",
    "source_file_path": "/path/to/doc.txt"
}
```

**Chunk Vectors:**
```json
{
    "document_id": "doc-uuid",
    "chunk_index": 0,
    "start_line": 0,
    "end_line": 50,
    "file_path": "/path/to/doc.txt"
}
```

### Vector Filtering

**File:** `/crates/edgequake-query/src/vector_filter.rs`

**Type Classification:**
```rust
pub enum VectorType {
    Entity,
    Relationship,
    Chunk,
}

pub fn filter_by_type(
    results: Vec<VectorSearchResult>,
    vector_type: VectorType,
) -> Vec<VectorSearchResult> {
    // Detect type from metadata structure
    // Entity: has "entity_name" field
    // Relationship: has "src_id" + "tgt_id" fields
    // Chunk: has "document_id" field (or neither)
}
```

---

## 8. Graph Storage Operations

**File:** `/crates/edgequake-storage/src/traits/graph.rs`

### Key Graph Queries Used

#### Get Node
```rust
pub async fn get_node(&self, id: &str) -> Result<Option<Node>>;

pub struct Node {
    pub id: String,
    pub properties: HashMap<String, Value>,
}
```

#### Batch Get Nodes
```rust
pub async fn get_nodes_batch(&self, ids: &[String])
    -> Result<HashMap<String, Node>>;
```

#### Node Degree
```rust
pub async fn node_degree(&self, id: &str) -> Result<usize>;
pub async fn node_degrees_batch(&self, ids: &[String])
    -> Result<Vec<(String, usize)>>;
```

**Why Batch Operations:**
- Reduces round-trips to database
- 60 entities -> 1 batch query, not 60 individual queries
- Lines 87-94, 138-145 of query_modes.rs show `tokio::join!()` parallelism

#### Get Node Edges
```rust
pub async fn get_node_edges(&self, id: &str)
    -> Result<Vec<Edge>>;

pub async fn get_edges_for_nodes_batch(&self, ids: &[String])
    -> Result<Vec<Edge>>;

pub struct Edge {
    pub source: String,
    pub target: String,
    pub properties: HashMap<String, Value>,
}
```

#### Get Popular Nodes
```rust
pub async fn get_popular_nodes_with_degree(
    &self,
    limit: usize,
    min_degree: Option<usize>,
    max_degree: Option<usize>,
    tenant_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Result<Vec<(Node, usize)>>;
```

**Used for Fallback:**
- Global mode fallback (line 310-318 of query_modes.rs)
- Local mode fallback with workspace-specific storage (line 105-122 of vector_queries.rs)

---

## 9. Cost Tracking & Metrics

**File:** `/crates/edgequake-query/src/engine.rs` (QueryResponse)

### Query Statistics

```rust
pub struct QueryStats {
    pub embedding_time_ms: u64,
    pub retrieval_time_ms: u64,
    pub context_tokens: usize,
    pub completion_tokens: usize,
    pub total_time_ms: u64,
}
```

**Tracked Metrics:**
1. **Embedding Time:** Keyword extraction + query embedding computation
2. **Retrieval Time:** Vector search + graph queries
3. **Context Tokens:** Total tokens in assembled context
4. **Completion Tokens:** LLM response token count
5. **Total Time:** End-to-end query latency

---

## 10. Tenant & Workspace Isolation

### Multi-Tenancy Support

**Filtering Applied at:**
1. **Vector Search Results** (lines 54, 70 in query_modes.rs)
   ```rust
   .filter(|r| self.matches_tenant_filter(&r.metadata, &tenant_id, &workspace_id))
   ```

2. **Graph Queries** (lines 132 in query_modes.rs)
   ```rust
   .filter(|r| self.matches_tenant_filter_props(&edge.properties, &tenant_id, &workspace_id))
   ```

3. **Popular Entities Fallback** (lines 315-317 in query_modes.rs)
   ```rust
   get_popular_nodes_with_degree(
       max_entities,
       Some(2),
       None,
       tenant_id.as_deref(),      // tenant filter
       workspace_id.as_deref(),   // workspace filter
   )
   ```

### Metadata Fields
```json
{
    "tenant_id": "org-123",
    "workspace_id": "ws-456",
    ...other fields...
}
```

---

## 11. Configuration & Defaults

**File:** `/crates/edgequake-query/src/sota_engine/mod.rs` lines 90-175

### SOTAQueryConfig Defaults

```rust
pub struct SOTAQueryConfig {
    pub default_mode: QueryMode = Hybrid,
    pub max_entities: usize = 60,              // LightRAG parity
    pub max_relationships: usize = 60,
    pub max_chunks: usize = 20,
    pub max_context_tokens: usize = 30_000,    // LightRAG parity
    pub graph_depth: usize = 2,                // 2-hop traversal
    pub min_score: f32 = 0.1,                  // Similarity threshold
    pub use_keyword_extraction: bool = true,
    pub use_adaptive_mode: bool = true,        // Intent-based selection
    pub truncation: TruncationConfig = {
        max_entity_tokens: 10_000,
        max_relation_tokens: 10_000,
        max_total_tokens: 30_000,
    },
    pub keyword_cache_ttl_secs: u64 = 86_400,  // 24 hours
    pub enable_rerank: bool = true,            // BM25 enabled
    pub min_rerank_score: f32 = 0.1,
    pub rerank_top_k: usize = 20,
}
```

---

## 12. Key Architectural Decisions

### Decision 1: Three Separate Embeddings (Not One)

**Why:**
- Low-level keywords match entity descriptions -> entity embeddings needed
- High-level keywords match relationship descriptions -> relationship embeddings needed
- Query text doesn't match either well -> need direct chunk embedding
- Result: Different modes can search different vector spaces optimally

**Cost:** Extra embedding API calls (3x instead of 1x)
**Benefit:** 30% quality improvement from targeted retrieval

### Decision 2: Deterministic Entity Ordering (Vec, Not HashMap)

**Why:**
- Same query must return same results (reproducibility)
- HashMap iteration order is non-deterministic in Rust
- Vector preserves vector search score order

**Code:** Lines 98-113, 350-352 in query_modes.rs

### Decision 3: Graph Context Priority in Token Budget

**Why:**
- Entities/relationships are pre-summarized (denser than raw text)
- Same token budget in graph = 2-3x more unique information
- Chunks provide raw evidence but are verbose

**Example:**
```
Same 10K tokens budget:
- Graph: 100 high-quality facts about relationships
- Chunks: 20 paragraphs of raw text (same semantic content, 5x verbose)
```

### Decision 4: BM25 Reranking with Fallback

**Why:**
- BM25 scores literal term matches (high precision)
- Some chunks found via graph don't contain query terms literally
- Fallback to top_k original chunks preserves context

**Code:** Lines 71-84 in reranking.rs

---

## 13. Performance Optimizations

### 1. Batch Graph Operations
```rust
tokio::join!(
    graph_storage.get_nodes_batch(...),
    graph_storage.node_degrees_batch(...),
)
```
**Impact:** Reduces DB round-trips from 120+ to 2-3

### 2. Vector Result Oversampling
```rust
vector_storage.query(..., max_chunks * 2, ...)  // Fetch 2x, filter to 1x
```
**Reason:** Mixed result types (entities, relationships, chunks) in vector storage

### 3. Keyword Caching (24h TTL)
**Impact:** Same query across 1000 users -> 1 LLM keyword extraction

### 4. Parallel Embedding Computation
**Code:** `QueryEmbeddings::compute()` (lines 196-200 of mod.rs)
**Impact:** 3 embeddings computed in parallel, not sequentially

---

## 14. File Structure Summary

```
/crates/edgequake-query/src/
|-- lib.rs                          <- Main exports
|-- modes.rs                         <- Query mode enum (6 modes)
|-- engine.rs                        <- QueryEngine, QueryRequest, config
|-- context.rs                       <- QueryContext, RetrievedEntity, etc
|-- chunk_retrieval.rs               <- Chunk selection (weight/vector)
|-- truncation.rs                    <- Token budgeting
|-- tokenizer.rs                     <- Token counting
|-- vector_filter.rs                 <- Classify vector result types
|-- keywords/
|   |-- mod.rs                       <- KeywordExtractor trait
|   |-- llm_extractor.rs             <- LLM-based extraction (FEAT0107)
|   |-- cache.rs                     <- Keyword caching (24h TTL)
|   |-- extractor.rs                 <- Base types
|   |-- intent.rs                    <- Query intent classification
|   |-- mock_extractor.rs            <- Testing mock
|-- strategies/
|   |-- mod.rs                       <- Strategy factory
|   |-- config.rs                    <- Strategy config
|   |-- naive.rs                     <- Naive mode strategy
|   |-- local.rs                     <- Local mode strategy
|   |-- global.rs                    <- Global mode strategy
|   |-- hybrid.rs                    <- Hybrid mode strategy
|   |-- mix.rs                       <- Mix mode strategy
|-- sota_engine/
|   |-- mod.rs                       <- SOTAQueryEngine, config defaults
|   |-- prompt.rs                    <- Build LLM prompt (FEAT0108)
|   |-- query_modes.rs               <- query_local, query_global, etc
|   |-- vector_queries.rs            <- Vector search wrappers
|   |-- reranking.rs                 <- BM25 reranking with fallback
|   |-- query_entry/
|       |-- mod.rs                   <- Sub-module exports
|       |-- query_basic.rs           <- Main query() entry point
|       |-- query_workspace.rs       <- Workspace-specific queries
|       |-- query_stream.rs          <- Streaming variants
|-- error.rs                         <- Error types
|-- helpers.rs                       <- Helper functions (FEAT0117)
```

---

## Summary: Key Takeaways

1. **LightRAG Implementation:** EdgeQuake faithfully implements the LightRAG algorithm with 6 query modes
2. **LLM-Driven Routing:** Query intents -> modes via keyword extraction, not hardcoded rules
3. **Graph Priority:** Entity/relationship context prioritized over raw chunks in token budget
4. **Batch Operations:** All graph operations batched to minimize DB round-trips
5. **Provider Flexibility:** Full support for user-selected LLM provider override (SPEC-032)
6. **Deterministic Results:** Careful Vec-based ordering ensures reproducibility
7. **Robust Fallbacks:** Popular entities fallback, reranking graceful degradation
8. **Token Budgeting:** 30K tokens split equally (entity/rel/chunk), matching LightRAG
9. **24h Keyword Cache:** Same query across users reuses keyword extraction
10. **Configurable Reranking:** Optional BM25 reranking with intelligent fallback

---

**END OF RESEARCH DOCUMENT**
