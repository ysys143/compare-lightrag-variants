# LightRAG Query-Time Pipeline Research

**Research Date:** March 2025
**Source:** `/Users/jaesolshin/Documents/.venv/lib/python3.12/site-packages/lightrag/`
**Status:** Complete Analysis

---

## 1. Query Entry Point

### Main Query Methods (lightrag.py:2401-2454)

**Synchronous Query:**
```python
def query(
    self,
    query: str,
    param: QueryParam = QueryParam(),
    system_prompt: str | None = None,
) -> str | Iterator[str]:
    """Perform a sync query."""
    loop = always_get_an_event_loop()
    return loop.run_until_complete(self.aquery(query, param, system_prompt))
```
- **File:** lightrag.py:2401-2420
- **Returns:** Either a string (non-streaming) or Iterator[str] (streaming)

**Asynchronous Query (Backward Compatibility Wrapper):**
```python
async def aquery(
    self,
    query: str,
    param: QueryParam = QueryParam(),
    system_prompt: str | None = None,
) -> str | AsyncIterator[str]:
    """Wrapper around aquery_llm that maintains backward compatibility."""
    result = await self.aquery_llm(query, param, system_prompt)
    llm_response = result.get("llm_response", {})
    if llm_response.get("is_streaming"):
        return llm_response.get("response_iterator")
    else:
        return llm_response.get("content", "")
```
- **File:** lightrag.py:2422-2454

**Data Retrieval APIs:**
- `query_data()` / `aquery_data()`: Returns structured retrieval results WITHOUT LLM generation (lightrag.py:2456-2682)
- `query_llm()` / `aquery_llm()`: Returns complete results WITH LLM generation (lightrag.py:2684-2843)

---

## 2. Query Mode Dispatch

### Query Mode Dispatch Logic (lightrag.py:2711-2772)

The `aquery_llm()` function dispatches to different query modes:

```python
if param.mode in ["local", "global", "hybrid", "mix"]:
    query_result = await kg_query(...)
elif param.mode == "naive":
    query_result = await naive_query(...)
elif param.mode == "bypass":
    # Direct LLM call without knowledge retrieval
    response = await use_llm_func(...)
else:
    raise ValueError(f"Unknown mode {param.mode}")
```

**Supported Modes:**
1. **local** - Entity-focused, uses low-level keywords
2. **global** - Relationship-focused, uses high-level keywords
3. **hybrid** - Combines local and global with round-robin merging
4. **mix** - Knowledge graph + vector-retrieved document chunks
5. **naive** - Pure vector similarity search (no graph)
6. **bypass** - Direct LLM call, no retrieval

---

## 3. Keyword Extraction

### Keyword Extraction Pipeline (operate.py:3225-3364)

**Entry Point:** `get_keywords_from_query()` (operate.py:3225)

```python
async def get_keywords_from_query(
    query: str,
    query_param: QueryParam,
    global_config: dict[str, str],
    hashing_kv: BaseKVStorage | None = None,
) -> tuple[list[str], list[str]]:
    # Check if pre-defined keywords are already provided
    if query_param.hl_keywords or query_param.ll_keywords:
        return query_param.hl_keywords, query_param.ll_keywords

    # Extract keywords using extract_keywords_only
    hl_keywords, ll_keywords = await extract_keywords_only(
        query, query_param, global_config, hashing_kv
    )
    return hl_keywords, ll_keywords
```

### LLM-Based Keyword Extraction (operate.py:3257-3364)

**Function:** `extract_keywords_only()`

**Process:**
1. Build example keywords from `PROMPTS["keywords_extraction_examples"]`
2. Check LLM cache (if enabled) with hash of (mode, text, language)
3. Build keyword extraction prompt from `PROMPTS["keywords_extraction"]`
4. Call LLM with `keyword_extraction=True` flag
5. Parse JSON response for high_level_keywords and low_level_keywords
6. Cache results (if cache enabled)

**Keyword Extraction Prompt** (prompt.py:374-396):

```
---Role---
You are an expert keyword extractor, specializing in analyzing user queries for a RAG system.

---Goal---
Extract two distinct types of keywords:
1. **high_level_keywords**: for overarching concepts or themes, capturing user's core intent
2. **low_level_keywords**: for specific entities or details, identifying proper nouns, technical jargon, product names

---Instructions & Constraints---
1. **Output Format**: Your output MUST be a valid JSON object and nothing else.
2. **Source of Truth**: All keywords must be explicitly derived from the user query.
3. **Concise & Meaningful**: Keywords should be concise words or meaningful phrases.
4. **Handle Edge Cases**: For vague queries, return JSON with empty lists.
5. **Language**: All extracted keywords MUST be in {language}.

---Examples---
{examples}

---Real Data---
User Query: {query}

---Output---
Output:
```

**Example Keywords Extraction** (prompt.py:398-432):

```json
Query: "How does international trade influence global economic stability?"

Output:
{
  "high_level_keywords": ["International trade", "Global economic stability", "Economic impact"],
  "low_level_keywords": ["Trade agreements", "Tariffs", "Currency exchange", "Imports", "Exports"]
}
```

---

## 4. Graph Traversal - LOCAL Mode

### LOCAL Mode Flow (operate.py:3472-3478)

1. **Keyword Input:** Uses low-level keywords (`ll_keywords`)
2. **Function:** `_get_node_data()` (operate.py:4169-4224)

### Entity Retrieval (operate.py:4169-4224)

```python
async def _get_node_data(
    query: str,
    knowledge_graph_inst: BaseGraphStorage,
    entities_vdb: BaseVectorStorage,
    query_param: QueryParam,
):
    # Step 1: Vector search for similar entities
    results = await entities_vdb.query(query, top_k=query_param.top_k)
    # Default top_k: 40 (from constants.py)

    # Step 2: Extract entity IDs from results
    node_ids = [r["entity_name"] for r in results]

    # Step 3: Batch retrieve node data and degrees
    nodes_dict, degrees_dict = await asyncio.gather(
        knowledge_graph_inst.get_nodes_batch(node_ids),
        knowledge_graph_inst.node_degrees_batch(node_ids),
    )

    # Step 4: Find related edges from entities
    use_relations = await _find_most_related_edges_from_entities(
        node_datas,
        query_param,
        knowledge_graph_inst,
    )
```

**Entity Vector Search Parameters:**
- **Vector DB:** entities_vdb
- **Top K:** Default 40 (DEFAULT_TOP_K from constants.py)
- **Cosine Threshold:** 0.2 (DEFAULT_COSINE_THRESHOLD)
- **Similarity Metric:** Vector cosine similarity
- **Logged Info:** `Query nodes: {query} (top_k:40, cosine:0.2)`

### Edge/Relationship Traversal (operate.py:4227-4280)

**Function:** `_find_most_related_edges_from_entities()`

```python
async def _find_most_related_edges_from_entities(
    node_datas: list[dict],
    query_param: QueryParam,
    knowledge_graph_inst: BaseGraphStorage,
):
    # Step 1: Get all edges for each entity
    batch_edges_dict = await knowledge_graph_inst.get_nodes_edges_batch(node_names)

    # Step 2: Deduplicate edges (undirected graph)
    all_edges = []
    seen = set()
    for node_name in node_names:
        this_edges = batch_edges_dict.get(node_name, [])
        for e in this_edges:
            sorted_edge = tuple(sorted(e))  # Treat as undirected
            if sorted_edge not in seen:
                seen.add(sorted_edge)
                all_edges.append(sorted_edge)

    # Step 3: Get edge properties in batch
    edge_data_dict, edge_degrees_dict = await asyncio.gather(
        knowledge_graph_inst.get_edges_batch(edge_pairs_dicts),
        knowledge_graph_inst.edge_degrees_batch(edge_pairs_tuples),
    )

    # Step 4: Sort edges by (rank, weight) descending
    all_edges_data = sorted(
        all_edges_data, key=lambda x: (x["rank"], x["weight"]), reverse=True
    )
```

**Traversal Characteristics:**
- **Depth:** 1-hop (direct neighbors of found entities)
- **Ranking:** By edge_degree (rank) and relationship weight
- **Deduplication:** Undirected edges are treated as same regardless of direction

### Text Chunk Association (operate.py:4283-4348)

**Function:** `_find_related_text_unit_from_entities()`

Retrieves text chunks associated with entities using two strategies:

**Strategy 1: VECTOR** (Default, based on cosine similarity)
```
Chunk selection by vector embedding similarity to query
```

**Strategy 2: WEIGHT** (Linear gradient weighted polling)
```
Chunks with higher occurrence count = higher priority
```

**Configuration:**
- **Method:** `kg_chunk_pick_method` (DEFAULT: "VECTOR")
- **Max Chunks:** `related_chunk_number` (DEFAULT: 5)
- **Deduplication:** First occurrence of chunk kept, later ones skipped

---

## 5. Graph Traversal - GLOBAL Mode

### GLOBAL Mode Flow (operate.py:3480-3486)

1. **Keyword Input:** Uses high-level keywords (`hl_keywords`)
2. **Function:** `_get_edge_data()` (operate.py:4442-4495)

### Relationship Retrieval (operate.py:4442-4495)

```python
async def _get_edge_data(
    keywords,
    knowledge_graph_inst: BaseGraphStorage,
    relationships_vdb: BaseVectorStorage,
    query_param: QueryParam,
):
    # Step 1: Vector search for similar relationships
    results = await relationships_vdb.query(keywords, top_k=query_param.top_k)

    # Step 2: Get edge properties in batch
    edge_pairs_dicts = [{"src": r["src_id"], "tgt": r["tgt_id"]} for r in results]
    edge_data_dict = await knowledge_graph_inst.get_edges_batch(edge_pairs_dicts)

    # Step 3: Find entities connected to these relationships
    use_entities = await _find_most_related_entities_from_relationships(
        edge_datas,
        query_param,
        knowledge_graph_inst,
    )
```

**Relationship Vector Search:**
- **Vector DB:** relationships_vdb
- **Top K:** Default 40 (DEFAULT_TOP_K)
- **Similarity Metric:** Vector cosine similarity
- **Order:** Maintains vector search ranking (similarity)

### Entity Extraction from Relationships (operate.py:4498-4528)

**Function:** `_find_most_related_entities_from_relationships()`

```python
async def _find_most_related_entities_from_relationships(
    edge_datas: list[dict],
    query_param: QueryParam,
    knowledge_graph_inst: BaseGraphStorage,
):
    # Extract all unique entities from relationships (src and tgt)
    entity_names = []
    seen = set()
    for e in edge_datas:
        if e["src_id"] not in seen:
            entity_names.append(e["src_id"])
            seen.add(e["src_id"])
        if e["tgt_id"] not in seen:
            entity_names.append(e["tgt_id"])
            seen.add(e["tgt_id"])

    # Get node data for all entities
    nodes_dict = await knowledge_graph_inst.get_nodes_batch(entity_names)
```

**Characteristics:**
- Retrieves all entities referenced in top-k relationships
- No filtering or ranking applied (order preserved from relationship search)
- Bidirectional extraction (both src and tgt)

---

## 6. Graph Traversal - HYBRID Mode

### HYBRID Mode Combination (operate.py:3488-3502)

```python
else:  # hybrid or mix mode
    if len(ll_keywords) > 0:
        local_entities, local_relations = await _get_node_data(...)
    if len(hl_keywords) > 0:
        global_relations, global_entities = await _get_edge_data(...)
```

### Round-Robin Merging (operate.py:3524-3578)

**Entities Merging:**
```python
final_entities = []
seen_entities = set()
max_len = max(len(local_entities), len(global_entities))
for i in range(max_len):
    # First from local
    if i < len(local_entities):
        entity = local_entities[i]
        if entity_name not in seen_entities:
            final_entities.append(entity)
            seen_entities.add(entity_name)

    # Then from global
    if i < len(global_entities):
        entity = global_entities[i]
        if entity_name not in seen_entities:
            final_entities.append(entity)
            seen_entities.add(entity_name)
```

**Relationships Merging:** Same round-robin pattern with deduplication by (src, tgt) pairs

---

## 7. Graph Traversal - MIX Mode

### MIX Mode Characteristics (operate.py:3504-3522)

```python
if query_param.mode == "mix" and chunks_vdb:
    vector_chunks = await _get_vector_context(
        query,
        chunks_vdb,
        query_param,
        query_embedding,
    )
    # Track vector chunks with source metadata
    for i, chunk in enumerate(vector_chunks):
        chunk_tracking[chunk_id] = {
            "source": "C",
            "frequency": 1,
            "order": i + 1,
        }
```

**MIX Mode = Local/Global/Hybrid + Vector Chunks**
- Retrieves knowledge graph data (local/global/hybrid)
- PLUS vector similarity chunks
- Combined and merged in round-robin fashion

---

## 8. Pruning and Truncation Logic

### Stage 2: Token-Based Truncation (operate.py:3593-3761)

**Function:** `_apply_token_truncation()`

**Process:**
1. Convert entities and relations to context format (JSON-serializable dicts)
2. Apply token-based truncation separately for entities and relations
3. Create filtered lists based on truncation results

**Token Limits:**
```
max_entity_tokens: 6,000 (DEFAULT_MAX_ENTITY_TOKENS)
max_relation_tokens: 8,000 (DEFAULT_MAX_RELATION_TOKENS)
max_total_tokens: 30,000 (DEFAULT_MAX_TOTAL_TOKENS)
```

**Truncation Function:** `truncate_list_by_token_size()`
- Uses tokenizer to count tokens
- Removes items from end until under token limit
- Preserves JSON formatting

**Example Token Calculation:**
```python
entities_context_for_truncation = [
    {
        "entity": "Apple Inc.",
        "type": "Organization",
        "description": "Technology company...",
        "created_at": "2024-01-15"
    },
    ...
]

entities_context = truncate_list_by_token_size(
    entities_context_for_truncation,
    key=lambda x: json.dumps(x, ensure_ascii=False),
    max_token_size=6000,
    tokenizer=tokenizer,
)
```

### Stage 3: Chunk Merging (operate.py:3764-3850+)

**Function:** `_merge_all_chunks()`

Three chunk sources:
1. **Vector chunks** - From vector similarity search
2. **Entity chunks** - Text chunks associated with entities
3. **Relation chunks** - Text chunks associated with relationships

**Deduplication Strategy:**
- Track chunk IDs in `seen_chunk_ids` set
- Use round-robin merging (vector → entity → relation)
- First occurrence of chunk_id is kept, duplicates skipped

---

## 9. Context Assembly

### Stage 4: Context Building (operate.py:4119-4166)

**Function:** `_build_context_str()`

Returns: `tuple[str, dict]` = (context_string, raw_data)

**KG Query Context Template** (prompt.py:332-357):

```
Knowledge Graph Data (Entity):

```json
{entities_str}
```

Knowledge Graph Data (Relationship):

```json
{relations_str}
```

Document Chunks (Each entry has a reference_id refer to the `Reference Document List`):

```json
{text_chunks_str}
```

Reference Document List (Each entry starts with a [reference_id] that corresponds to entries in the Document Chunks):

```
{reference_list_str}
```

```

**Entity Format in Context:**
```json
{
  "entity": "Apple Inc.",
  "type": "Organization",
  "description": "Technology company founded in 1976",
  "created_at": "2024-01-15 10:30:45",
  "file_path": "document_1.pdf"
}
```

**Relationship Format in Context:**
```json
{
  "entity1": "Steve Jobs",
  "entity2": "Apple Inc.",
  "description": "Steve Jobs co-founded Apple Inc.",
  "keywords": "founder, creation, leadership",
  "weight": 0.95,
  "created_at": "2024-01-15 10:30:45",
  "file_path": "document_1.pdf"
}
```

**Chunk Format in Context:**
```json
{
  "reference_id": "[1]",
  "content": "Apple Inc. was founded on April 1, 1976, by Steve Jobs, Steve Wozniak, and Ronald Wayne..."
}
```

**Reference List Format:**
```
[1] document_1.pdf
[2] document_2.pdf
[3] document_3.pdf
```

---

## 10. Final LLM Prompt

### RAG Response System Prompt (prompt.py:224-276)

**System Prompt Template:**

```
---Role---

You are an expert AI assistant specializing in synthesizing information from a provided knowledge base. Your primary function is to answer user queries accurately by ONLY using the information within the provided **Context**.

---Goal---

Generate a comprehensive, well-structured answer to the user query.
The answer must integrate relevant facts from the Knowledge Graph and Document Chunks found in the **Context**.
Consider the conversation history if provided to maintain conversational flow and avoid repeating information.

---Instructions---

1. Step-by-Step Instruction:
  - Carefully determine the user's query intent in the context of the conversation history to fully understand the user's information need.
  - Scrutinize both `Knowledge Graph Data` and `Document Chunks` in the **Context**. Identify and extract all pieces of information that are directly relevant to answering the user query.
  - Weave the extracted facts into a coherent and logical response. Your own knowledge must ONLY be used to formulate fluent sentences and connect ideas, NOT to introduce any external information.
  - Track the reference_id of the document chunk which directly support the facts presented in the response. Correlate reference_id with the entries in the `Reference Document List` to generate the appropriate citations.
  - Generate a references section at the end of the response. Each reference document must directly support the facts presented in the response.
  - Do not generate anything after the reference section.

2. Content & Grounding:
  - Strictly adhere to the provided context from the **Context**; DO NOT invent, assume, or infer any information not explicitly stated.
  - If the answer cannot be found in the **Context**, state that you do not have enough information to answer. Do not attempt to guess.

3. Formatting & Language:
  - The response MUST be in the same language as the user query.
  - The response MUST utilize Markdown formatting for enhanced clarity and structure (e.g., headings, bold text, bullet points).
  - The response should be presented in {response_type}.

4. References Section Format:
  - The References section should be under heading: `### References`
  - Reference list entries should adhere to the format: `* [n] Document Title`. Do not include a caret (`^`) after opening square bracket (`[`).
  - The Document Title in the citation must retain its original language.
  - Output each citation on an individual line
  - Provide maximum of 5 most relevant citations.
  - Do not generate footnotes section or any comment, summary, or explanation after the references.

5. Reference Section Example:
```
### References

- [1] Document Title One
- [2] Document Title Two
- [3] Document Title Three
```

6. Additional Instructions: {user_prompt}


---Context---

{context_data}
```

**Full Prompt Assembly** (operate.py:3119-3135):

```python
sys_prompt_temp = system_prompt if system_prompt else PROMPTS["rag_response"]
sys_prompt = sys_prompt_temp.format(
    response_type=response_type,
    user_prompt=user_prompt,
    context_data=context_result.context,
)

user_query = query

# Call LLM
len_of_prompts = len(tokenizer.encode(query + sys_prompt))
response = await use_model_func(
    user_query,
    system_prompt=sys_prompt,
    history_messages=query_param.conversation_history,
    enable_cot=True,
    stream=query_param.stream,
)
```

**Response Type Options:**
- Default: "Multiple Paragraphs"
- Configurable via `query_param.response_type`

---

## 11. NAIVE Mode (Vector-Only)

### NAIVE Mode Entry Point (operate.py:4758-4802)

**Function:** `naive_query()`

**Process:**
1. Retrieve text chunks using vector similarity search
2. No entity/relationship extraction or ranking
3. Direct vector similarity on chunks_vdb

### Vector Chunk Retrieval (operate.py:3367-3421)

**Function:** `_get_vector_context()`

```python
async def _get_vector_context(
    query: str,
    chunks_vdb: BaseVectorStorage,
    query_param: QueryParam,
    query_embedding: list[float] = None,
) -> list[dict]:
    search_top_k = query_param.chunk_top_k or query_param.top_k
    cosine_threshold = chunks_vdb.cosine_better_than_threshold

    results = await chunks_vdb.query(
        query, top_k=search_top_k, query_embedding=query_embedding
    )

    # Convert to standard format
    valid_chunks = []
    for result in results:
        if "content" in result:
            chunk_with_metadata = {
                "content": result["content"],
                "created_at": result.get("created_at", None),
                "file_path": result.get("file_path", "unknown_source"),
                "source_type": "vector",
                "chunk_id": result.get("id"),
            }
            valid_chunks.append(chunk_with_metadata)
```

**Parameters:**
- **Top K:** Default 20 (DEFAULT_CHUNK_TOP_K)
- **Cosine Threshold:** 0.2 (DEFAULT_COSINE_THRESHOLD)
- **Query Embedding:** Can be pre-computed or computed on-the-fly

### NAIVE Response Prompt (prompt.py:278-330)

```
---Role---

You are an expert AI assistant specializing in synthesizing information from a provided knowledge base. Your primary function is to answer user queries accurately by ONLY using the information within the provided **Context**.

---Goal---

Generate a comprehensive, well-structured answer to the user query.
The answer must integrate relevant facts from the Document Chunks found in the **Context**.
Consider the conversation history if provided to maintain conversational flow and avoid repeating information.

---Instructions---

[Same as rag_response, but ONLY uses Document Chunks, no Knowledge Graph Data]
```

---

## 12. Query Parameter Configuration

### QueryParam Dataclass (base.py)

Key parameters controlling query behavior:

```python
@dataclass
class QueryParam:
    mode: str = "local"  # local, global, hybrid, mix, naive, bypass

    # Keyword parameters
    hl_keywords: List[str] = field(default_factory=list)  # Pre-defined high-level keywords
    ll_keywords: List[str] = field(default_factory=list)  # Pre-defined low-level keywords

    # Retrieval parameters
    top_k: int = 40  # Number of entities/relations to retrieve
    chunk_top_k: int = 20  # Number of chunks to retrieve

    # Token limits
    max_entity_tokens: int = 6000
    max_relation_tokens: int = 8000
    max_total_tokens: int = 30000

    # Response parameters
    response_type: str = "Multiple Paragraphs"
    stream: bool = False

    # LLM parameters
    model_func: Optional[Callable] = None  # Custom LLM function
    user_prompt: Optional[str] = None  # Additional user instructions
    conversation_history: List[Dict] = field(default_factory=list)

    # Control parameters
    only_need_context: bool = False  # Return only context, no LLM
    only_need_prompt: bool = False   # Return only prompt, no LLM
    enable_rerank: bool = False      # Enable reranking
```

---

## Summary Flow Diagram

```
User Query
    ↓
[1. Keyword Extraction]
    ├→ Check pre-defined keywords
    ├→ If missing: LLM extracts high-level & low-level keywords
    └→ Cache keywords if caching enabled
    ↓
[2. Mode Dispatch]
    ├→ LOCAL: Use ll_keywords + entity vector search
    ├→ GLOBAL: Use hl_keywords + relationship vector search
    ├→ HYBRID: Both local + global with round-robin merge
    ├→ MIX: Local/Global/Hybrid + vector chunks
    ├→ NAIVE: Pure vector chunk similarity search
    └→ BYPASS: Direct LLM call (no retrieval)
    ↓
[3. Graph Search (if not NAIVE/BYPASS)]
    ├→ Entity/Relation Vector Search (top_k=40)
    ├→ Edge/Node Traversal (1-hop from entities)
    └→ Text Chunk Association (5 chunks per entity/relation)
    ↓
[4. Token Truncation]
    ├→ Truncate entities to 6,000 tokens
    ├→ Truncate relations to 8,000 tokens
    └→ Filter results based on truncation
    ↓
[5. Chunk Merging]
    ├→ Collect entity chunks
    ├→ Collect relation chunks
    ├→ Deduplicate across sources
    └→ Round-robin merge
    ↓
[6. Context Assembly]
    ├→ Format entities as JSON
    ├→ Format relations as JSON
    ├→ Format chunks with reference IDs
    ├→ Build reference document list
    └→ Assemble context string
    ↓
[7. Final LLM Generation]
    ├→ Build system prompt (RAG template)
    ├→ Insert context data
    ├→ Check LLM cache
    ├→ Call LLM with conversation history
    ├→ Cache LLM response
    └→ Return response ± streaming
```

---

## Key Files Reference

- **Main Query Logic:** `lightrag.py:2401-2843`
- **Query Operation Functions:** `operate.py:3015-5003`
- **Prompts:** `prompt.py:224-432`
- **Constants:** `constants.py:45-100`
- **Query Parameters:** `base.py` (QueryParam dataclass)

---

## Important Constants

From `constants.py`:
```python
DEFAULT_TOP_K = 40                      # Entities/relations per query
DEFAULT_CHUNK_TOP_K = 20                # Document chunks per query
DEFAULT_MAX_ENTITY_TOKENS = 6000        # Token budget for entities
DEFAULT_MAX_RELATION_TOKENS = 8000      # Token budget for relations
DEFAULT_MAX_TOTAL_TOKENS = 30000        # Total context token budget
DEFAULT_COSINE_THRESHOLD = 0.2          # Vector similarity threshold
DEFAULT_RELATED_CHUNK_NUMBER = 5        # Chunks per entity/relation
DEFAULT_KG_CHUNK_PICK_METHOD = "VECTOR" # Chunk selection: VECTOR or WEIGHT
```

---

## Caching Strategy

**Three Cache Types:**
1. **Keywords Cache** - Caches extracted high/low level keywords
2. **Query Cache** - Caches final LLM responses
3. **LLM Response Cache** - Optional caching per query mode

**Cache Key Components:**
```python
args_hash = compute_args_hash(
    query_param.mode,
    query,
    query_param.response_type,
    query_param.top_k,
    query_param.chunk_top_k,
    query_param.max_entity_tokens,
    query_param.max_relation_tokens,
    query_param.max_total_tokens,
    hl_keywords_str,
    ll_keywords_str,
    query_param.user_prompt or "",
    query_param.enable_rerank,
)
```

---

## Error Handling

**Failure Responses:**
- Empty keywords: Returns `PROMPTS["fail_response"]`
- No KG results: Returns None (handled by aquery_llm)
- No vector results: Returns None (handled by naive_query)
- JSON parsing errors in keyword extraction: Returns empty lists

**Logging:**
- All major steps logged with DEBUG/INFO level
- Token counts logged for debugging
- Cache hits logged for monitoring
