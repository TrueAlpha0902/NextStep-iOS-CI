# NextStep Implementation Status

Status date: 2026-07-19. This file reports implementation evidence; the numbered handoff remains the normative target.

## Implemented in the current candidate

- The normal app root is Today, with distinct compact iPhone tab/stack navigation and regular iPad split navigation.
- A user can create one protected goal and deadline, import a PDF/image source, preserve a SHA-256-addressed local copy, review an anchored deadline candidate, and explicitly confirm or reject it without allowing AI to overwrite protected facts.
- The deterministic Guided Task includes source-grounded reading, a three-question quiz, completion evidence, progress update and replanning. Completion remains gated until the quiz passes and the required draft evidence is present.
- The Beta path does not call a generative model or invent paper/news claims. Its summary is explicitly extractive and opens the original user file.
- Local Beta state now uses the app-owned SQLite v2 projection as its sole write authority. The bridge enforces generation-and-digest CAS, atomically commits canonical payload plus outbox intent, reconciles memory from SQLite after every sync success/failure, and bounds retained canonical payloads after mirror publication.
- Existing `nextstep-beta-v1.json` data is migrated backup-first with a byte-identical create-once backup and a replay-checked migration ledger. The JSON path is now only a repairable, non-authoritative compatibility mirror; a corrupt/incompatible SQLite database never falls back to it.
- Imported source blobs remain separate from structured state and are immutable per source path. A stale sync cannot replace bytes referenced by a newer canonical archive, even when its archive CAS is rejected.
- Quiz-backed Guided Action completion is now represented by a canonical immutable operation carrying the exact responses, deterministic quiz evidence, user attestation and completion-contract digest. Local projection, applied ledger and outbox commit atomically; remote replay repairs an older uncompleted snapshot without LWW regression, while competing evidence for the same Action stops for review.
- The operation freezes the v1 planning-engine contract and binds the stable progress/decision/replan identities plus causal metadata. Progress fractions and plan contents are context-local projections recalculated against the receiving archive; each application therefore stores a separate receipt binding its exact pre-apply planning context and full derived-record digest, so legitimate device differences converge while later projection tampering fails closed.
- SQLite v2 keeps transactional inbox/applied-operation ledgers. Published completion operations remain content-addressed in the applied ledger, are paged with a stable millisecond/UUID cursor, can be applied in bounded atomic chunks, and can be republished when the user selects a different sync destination.
- A user may select the same iCloud Drive folder on each Apple device. The current transport restores bookmarks per device, verifies source hashes, queues offline work and stops on protected-deadline or immutable-source conflicts.
- The retained Notes/PencilKit/PDF/OCR/search/audio/replay/export features are reachable as a source library from NextStep and have compact-width navigation adaptations.
- A local-only Windows contract twin exercises Today -> Guided -> completion -> replan -> Sources/Goals/Workspace and is permanently labeled as non-native.
- Native UI fixtures exercise the real Beta flow on iPhone and iPad. Screenshot export remains disabled during active development and is reserved for final acceptance.

## Not yet sufficient to declare Phase 1 complete

- Completion is the first fine-grained immutable operation slice. Equivalent operation contracts for non-quiz completion, deadline/source mutations, acknowledgements, tombstone lifecycle and the broader field-level merge model remain in Phase 1C-B.
- The SQLite v2 migration, completion-operation replay and the app-owned compact keyboard-dismiss control still require their exact macOS 26 / Xcode 26 CI run to pass before this candidate is accepted as native build evidence.
- A physical two-device iCloud Drive convergence test remains a release gate.
- Paper discovery, advanced ink-to-action, thesis, project, career and current-affairs verticals belong to later roadmap phases and are not complete.

No screenshot, browser preview or historical workflow run may be used to claim a missing release gate passed. Update this file only when the corresponding repository implementation and reproducible evidence exist.
