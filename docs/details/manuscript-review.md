# Manuscript review

Open **Review** in a LaTeX or Overleaf project to ask for source-linked questions an attentive reviewer might raise. Files and Outline remain available in the same sidebar. Choose the AI provider inside Review, then select **Review file**. Review does not edit the manuscript.

The criteria cover numerical consistency, the scope of claims, fair comparisons, methodological rationale, repeated explanations and the basis for literature claims. They are prompts for scrutiny, not a representation of academic consensus. The bundled scenarios are independently constructed examples from other domains. They retain no reviewer identities, manuscript identifiers, original measurements or quoted review text.

## Scope and evidence

Each request includes the selected buffer and available `.tex` and `.bib` context, including unsaved edits. ChatGPT requests include up to 12 files within a 48 KB source budget. On-device requests use a 2.4 KB source budget and three criteria: consistency, scope and clarity. Large files are shortened and the request identifies omitted files and truncated context. Review does not search the web, inspect figure pixels or verify the content of cited papers.

The model returns at most five questions with an explanation and exact source excerpts. A consistency or repetition question needs two distinct excerpts. remile. rejects malformed responses, unknown criteria and excerpts it cannot locate uniquely in the supplied context. These checks establish source links, not the correctness of a scientific interpretation. An empty response is recorded for its scope and is not an assurance that the manuscript has no issues.

## Saved questions

Questions remain across navigation and app restarts. A new source version appends a review and keeps earlier questions. Changed source versions are marked in the panel. Source links follow an unchanged passage when possible and report when the passage is missing or ambiguous. Repeating an unchanged request reuses its saved result. Changes to the criteria or prompt invalidate that reuse.

Use **Export** for Markdown or JSON and **Clear** to remove the project's saved reviews. Clear stops a pending request before removing results, so a late response cannot restore them. Removing an Overleaf project from the library, or removing its containing Search library folder, also removes its saved reviews. Removing a recent-document entry does not clear reviews. Local project renames retain the archive.

Archives live in `~/Library/Application Support/local.remile.app/Reviews`, outside the manuscript and its Git history. Each archive records the project directory, review date, provider, criteria version, source hashes and questions. Exports contain this provenance and the quoted manuscript passages. Clear and library removal move existing archives to the macOS Trash.

## CLI

```sh
remile review --criteria
remile review --run --file main.tex
remile review
remile review --format markdown --output /absolute/new-questions.md
remile review --stop
remile review --clear
remile review /absolute/project --format json --output /absolute/new-questions.json
```

Criteria and saved results for an explicit project directory can be read without an open application. Starting, stopping and clearing use the running app. A new review requires that project to be open. `--run` returns immediately with its running state. Read `review` again for completion, saved questions or an error. CLI exports require a new `.md` or `.json` destination and do not overwrite existing files.

The versioned catalogue and question instructions are in `others/templates/review`. They are bundled with the app and exposed by `review --criteria`. Provider availability and the app's existing online-service settings apply. An unavailable provider or a rejected response leaves saved questions intact.
