# Contributing

Keep remile a local-first reading and writing workspace. Prefer small changes that preserve documents, annotations, citation identity and recovery data. Discuss new integrations or large scope changes in an issue first.

## Changes and checks

Use an Apple Silicon Mac with full Xcode and the deployment target in Package.swift. Build with `swift build -c release --product Remile` and run `swift test`. Put build scratch directories and generated fixtures outside the checkout. Run the matching `tools/check_*.sh` for behaviour not covered by standard tests. [Tests/README.md](Tests/README.md) maps the current safety checks. Do not use real accounts or private documents in automated tests.

Describe the behaviour changed, why it matters and the checks performed. Include before/after captures for UI changes. Preserve shared symbol slots, accessible labels and Reduce Motion. Format touched code for readability without mixing unrelated repository-wide formatting into a functional change.

## Rights and privacy

Contributions are offered under the project's MIT licence. Identify copied or adapted code, artwork and data, retain their notices and discuss incompatible licences before submitting. A reference repository is not permission to copy its implementation. Do not commit credentials, account sessions, private papers or generated account exports. See [third-party notices](THIRD_PARTY_NOTICES.md) and [security reporting](SECURITY.md).
