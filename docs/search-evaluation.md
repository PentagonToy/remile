# Local search evaluation

## Ranking

The native engine combines lexical ranking (B0) with optional query expansion (B-guided). B0 uses page and 160-token passage BM25, IDF-weighted coverage, bounded proximity and headings. Partial matches remain candidates. Quoted phrases are mandatory. Apple Intelligence can expand natural-language questions on this Mac. Keywords, Work offline, Manual mode and unavailable or failed model requests use B0.

Ranking data is prepared in memory on the first search and reused until the library changes, including changes from another SQLite connection. Existing indexed text is sufficient. Expansion requires neither reindexing nor a model download.

## Evidence

On a frozen corpus of 179 PDFs and 26,820 text pages, native Swift checks reproduced the reference B0 and guided raw top ten for twelve questions. This checks the mathematical port rather than relevance. Exploratory first-page support grades were 4/12 for B0 and 7/12 for guided retrieval. Guided retrieval was selected after initial rank review, so this is not an independent hold-out evaluation.

Pressure coupling, feature scaling and combustion-temperature questions expose weaknesses. The small domain sample does not establish general superiority. Matching query terms does not establish that a page answers the question.

## Resource measurements

Preparing native ranking data for that corpus took about 4.35 seconds on an M5 with 16 GB RAM. This single measurement excludes interface and model preparation. Complete-app memory also includes previews, ranking data and system model costs. Bundle size is not a memory measurement.

Matched whole-app latency and memory comparisons against other PDF applications have not been established. Historical measurements of earlier ranking implementations do not describe the current engine.
