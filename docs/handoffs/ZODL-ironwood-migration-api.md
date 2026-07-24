# Historical handoff — retired standalone Ironwood API

This handoff is retained only as a pointer for branches that referenced its old filename. Its
standalone-engine integration and public raw-PCZT, `submitNoteSplit`, restart, and batch-refresh
calls are retired and must not be implemented or restored.

Current app integration is documented in
[`ZEND-ironwood-consolidation.md`](ZEND-ironwood-consolidation.md). Source migrations from any
pre-release SDK draft must follow the claim-backed mappings in the repository-root `MIGRATING.md`.
Historical implementation detail remains available in the dated designs under
`docs/superpowers/specs/`; those files are records, not live API guidance.
