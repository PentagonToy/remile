# Local search and model choices

Keep ordinary PDF reading and exact-text search independent of machine-learning runtimes. Recreate the useful PDF Search workflows—folder indexing, ranked passages, page context and direct navigation—with our own implementation. Existing reference inspection establishes product behaviour, not permission or a technical route to transplant proprietary engine code.

## Current direction

Search currently uses a persistent PDF/Markdown lexical index, vocabulary-based spelling suggestions and explicit on-device Foundation Models query expansion through Explore. Reusable Ask uses the same local system model for cited passage answers. No separate model is needed for these features, and no cloud path is present. The embedding proposal below is deferred evaluation material rather than the current setup workflow.

## Deferred embedding proposal

The intended Search settings show ordinary text search as always available, with an optional local semantic-search engine. Users choose a model, see its download size and licence, and explicitly start a download. Show progress, cancellation, verification, repair, model removal and indexed-folder controls. Download from pinned Hugging Face revisions and verify a manifest of sizes and SHA-256 hashes before activation; do not execute remote repository code. Keep the previous usable model until its replacement verifies successfully. Authentication and licence acceptance, where required, remain explicit user actions.

Load one model only when semantic search or indexing needs it; release it after inactivity. Provide pause/resume for indexing and cancel stale queries. A switch back to text search should stop model work and release the worker. Reading a PDF must not automatically start a server or keep an embedding model resident. Offline inference follows a completed download; no PDF text is sent to Hugging Face.

Use page-aware passages with stable document/page/geometry references. Combine exact lexical matches with dense retrieval, preserving exact symbols, quoted phrases, author names and formula tokens. Record model revision, tokenizer, pooling, dimensions, query instruction and chunking version in each index; changing these requires rebuilding affected embeddings. Benchmark Korean/English scientific queries, equations and scanned documents separately. OCR and embeddings are distinct stages; embeddings do not recover text from an unrecognised scanned page.

## Verified candidates, 18 October 2026

| Candidate | Evidence and role | Open checks |
| --- | --- | --- |
| [Qwen3-Embedding-0.6B MLX 4-bit](https://huggingface.co/majentik/Qwen3-Embedding-0.6B-MLX-4bit) | First evaluation candidate. Community conversion lists roughly 333 MB of weights (Hub total about 335 MB), a 32K context and 1024-dimensional vectors. The [upstream model](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) documents query instructions and multilingual retrieval. | Verify conversion parity, licence notices, last-token pooling, normalisation and query instructions. Weight size is not peak process/unified memory; measure on this M1 Pro with bounded passage lengths and batches. |
| [EmbeddingGemma 2 MLX 4-bit](https://huggingface.co/mlx-community/embeddinggemma-2-4bit) | Alternative requiring further evaluation. [Google's model](https://huggingface.co/google/embeddinggemma-2) has 740M total parameters, including a 270M text model and modular vision/audio encoders. This particular conversion stores 1.098 GB; vision/audio towers remain BF16. | Do not label this download as a 270M/378 MB complete model. Determine whether a supported text-only package provides a worthwhile smaller runtime, and inspect Gemma terms and runtime support. |
| [BGE-M3 MLX FP16](https://huggingface.co/mlx-community/bge-m3-mlx-fp16) | About 1.1 GB of weights; potentially useful for multilingual retrieval. The conversion's sample uses pooled dense embeddings. | Upstream dense/sparse/ColBERT capabilities do not establish that this MLX conversion exposes trained sparse/multi-vector heads. Verify outputs and parity before presenting those modes. |
| [nomic-embed-text](https://ollama.com/library/nomic-embed-text) | Additional text-search baseline rather than an assumed default. | Verify the exact variant, weight format, licence, Korean retrieval quality and measured memory before comparison. |

The [Qwen MLX server](https://github.com/jakedahn/qwen3-embeddings-mlx) claims 44K tokens/s for batched inputs on an M2 Max with 32 GB, and lists about 900 MB for its small model configuration. These figures are not measurements of our 4-bit candidate on the M1 Pro. A persistent HTTP server is unnecessary for the intended on-demand desktop worker; the local reference checkout can inform a bounded embedding adapter.

## Current status

Only in-document exact-text search is implemented. The model catalogue above, download workflow, folder index, hybrid ranking and embedding runtime are design decisions and evaluation work; none is advertised as a working setting. No model or package has been installed or downloaded during this task. Before enabling model downloads, package a tested runtime and verify one pinned model end to end, including cancellation, corrupt downloads, offline reopen, index migration and measured memory.
