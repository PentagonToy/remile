# Local search evaluation

The 20 October 2026 tuning keeps SQLite FTS5 BM25 and the existing proximity boost. It interprets explicit English questions as substantive keywords with limited word-ending matching. Ordinary keywords and quoted phrases retain their previous behaviour. Search settings can disable question interpretation or spelling suggestions. No model, index field or reindexing is added.

## Retrieval pilot

Ten PDFs with matching titles and page counts were compared against PDF Search PRO 16.0.2: 4,475 pages, including 454 pages without indexed text in remile. The underlying file bytes and extraction were not verified as identical. One assessor judged explanatory usefulness on a fixed eight-query set: two keyword searches, one typo, two quoted phrases, two English questions and one Korean question.

| Directly useful explanation | remile. before | remile. tuned | PDF Search PRO |
| --- | ---: | ---: | ---: |
| First result | 4 / 8 | 6 / 8 | 1 / 8 |
| Within first three | 4 / 8 | 6 / 8 | 6 / 8 |

The two English questions previously returned nothing. They now retrieve pressure–velocity coupling examples and upwind stabilisation explanations. The original five keyword, spelling and phrase result lists retain exactly the same first-five results, scores and excerpts. The Korean question still returns nothing, and the typo still needs the visible correction choice.

Five additional English questions were fixed before collecting their results. Directly useful first results increased from zero to three. The other two exposed remaining weaknesses: numerical diffusion retrieved a turbulence introduction, and Reynolds-number dependence retrieved adjacent modelling material. This remains lexical search; matching all the words does not establish that a page answers the question.

These small, domain-specific, non-blind judgements do not establish general superiority. A book-discovery task would value title pages differently. PDF Search was not tested on the additional five questions.

## Cost of the change

Optimised native workers ran the same isolated index through one warm-up and ten timed passes over 13 queries on an M1 Pro with 16 GB RAM. The final runs were serial, without concurrent agent builds or tests. Typical keyword medians stayed approximately 33–166 ms. The two recovered English questions took 27 ms and 9 ms; their previous sub-millisecond searches returned no results. Timings exclude the interface debounce, preview loading and spelling suggestions.

The repeated-search worker's peak physical footprint fell from about 492 MiB to 30 MiB after temporary Foundation text objects were released at the end of each search. This stress test keeps one task alive through 143 searches. It measures worker behaviour rather than normal complete-app memory savings. The index file remained byte-identical. No indexing-throughput comparison was needed because the indexing path did not change.

Complete-app process-family memory and latency were not compared under matched workloads. These results therefore do not prove that remile. is lighter than PDF Search PRO, PDF Expert or Acrobat.

## Ranking choices

BM25+ and BM25F were not implemented or compared in this round. Changing their formula alone would not resolve the previous requirement that every word of an English question occur on the page. Reliable title/body fields, metadata-page ranking and cross-language retrieval remain separate experiments.

PDF Search PRO's exact ranking formula is unconfirmed. Its [vendor manual](https://pdfsearchapp.com/docs/machelp.html) describes proximity, density, font emphasis and document date; this does not establish whether BM25 is used internally.
