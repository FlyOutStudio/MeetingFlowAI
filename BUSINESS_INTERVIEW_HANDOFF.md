# Business interview MVP handoff

## Scope and baseline

Implemented on `codex/business-interview-mvp`, based on
`4b8c359807414efda4e8b82cc4321ea4738b8ae6`. A read-only fetch confirmed that
`origin/main` had the same commit on 2026-10-01. The initial worktree was clean.
No AGENTS.md was found in the repository or its workspace ancestors.
No push, PR, merge, release, real analysis API call, credential access, or recording
upload was performed. Xcode was not installed or attempted on Linux.

## Behavior

The new 業務ヒアリング tab groups records into 現状の業務, 課題, 要件, 確認事項.
Current processes expose actor, action, input, tools, output and exceptions.
Missing values are displayed as 未確認. The AI prompt explicitly prohibits
invented permissions, causes, responsibilities and agreements. Exact quotation
validation proves that an excerpt exists; it cannot prove that every generated
interpretation follows from it. Human review remains necessary.

Origin (`agreed`, `proposed`, `aiSuggestion`) and human review
(`unreviewed`, `confirmed`) are independent. The AI DTO/schema has no review,
identifier, offset, or snapshot fields. Extra review fields in a model response
are ignored, and the ViewModel resets review flags at the provider boundary.
Only the explicit human confirmation action marks an item confirmed. Changing
content, origin or evidence resets confirmation; saving identical values does not.

Each record requires at least one exact, nonempty quotation. A quote must match
one location, including repeated/overlapping occurrences; ambiguous quotes need
more surrounding context. Duplicate references are rejected. The app computes
UTF-16 offsets and assigns item UUIDs. The original transcript is stored as an
immutable snapshot alongside the records. References are revalidated on decode
and before confirmation. Opening a reference shows the saved transcript and
highlights the actual range. No speaker labels or timestamps are invented.

Reanalysis preserves the entire current interview if any item was edited or
confirmed by a human. It stores the new interview as a separate, unreviewed
candidate. Users may inspect, discard, or explicitly replace with that candidate.
Replacement has a confirmation dialog and backs up the latest human edits first.
Further reanalysis may replace an unadopted AI candidate; this MVP does not keep
multiple revisions. The existing single backup is shared with whole-analysis
restoration. Restoration replaces the entire analysis and its review states. When the current
interview contains human work, a confirmation dialog explicitly warns that
changes since the backup will be lost and suggests exporting JSON first.

Existing minutes, ToDo, flow, Mermaid and draw.io behavior is retained. No new
diagram generation, task generation or cross-meeting versioning was added.

## Persistence and export

`MeetingAnalysis` adds optional `businessInterview` and `interviewCandidate`.
Existing `analysisJSON` and `PreviousAnalysisStore` already encode the complete
analysis, so no SwiftData schema migration or new storage field is required.
Legacy JSON without these keys remains valid. New AI responses require the
interview payload, even when its items array is empty.

JSON preserves all new data, UUIDs, snapshots, references and review states.
Markdown includes all four sections, status/origin, process fields, linked source
excerpts, UTF-16 positions, source snapshots and any unadopted candidate. Quoted
content uses fences longer than any backtick run in the source.

Corrupt stored analysis produces a per-record load error instead of silently
becoming an editable nil analysis. Other history entries remain available, and
the affected record's transcript remains readable. Title saving, regeneration
and backup restoration are disabled for that record. The store also rejects
non-UI attempts to overwrite its original analysisJSON bytes. Repair of corrupt
records is outside this MVP. Failed SwiftData saves roll back
pending context changes. Failed interview edits revert the published analysis;
the edit sheet remains open with its draft. Backup failure blocks regeneration
or candidate replacement. Operation-ID checks retain their existing protection
against cancelled/stale generation callbacks.

## Validation performed in Linux

- `git diff --check`: passed.
- Offline tree-sitter grammar check of all 43 Swift source/test files: no new
  syntax-error files. Two unchanged baseline parser limitations remain in
  `MeetingFlowAIApp.swift` and `SpeechAnalyzerService.swift`, compared directly
  with the immutable baseline. This is not Swift compiler validation.
- Reviewed model/DTO/schema mapping, optional legacy decoding, preservation in
  minutes normalization, persistence and export paths, and existing cancellation
  guards against the implementation.

Reproduce the grammar check without accessing any meeting data:

```bash
python3 -m pip install --target /tmp/meetingflow-static-parser \
  tree-sitter==0.26.0 tree-sitter-swift==0.7.3
PYTHONPATH=/tmp/meetingflow-static-parser python3 Scripts/check-swift-syntax.py
```

## Tests added, but NOT executed here

25 new XCTest methods cover:

- Legacy JSON and JSON/Markdown round trips, including pending candidates.
- Edit/confirm/re-edit, no-op saves, origin/evidence edits, failed edits.
- Empty, invented, duplicate, ambiguous and malformed evidence; Unicode offsets
  and bounds; composed/decomposed text, combining marks, ZWJ sequences and partial
  grapheme rejection; corrupted persisted references.
- AI review-state injection and independent preservation of all origin values.
- Mocked service response validation and schema fields with URLProtocol stubs.
- Human-work preservation during reanalysis, candidate adoption/discard,
  history reselection/reinitialization, and backup restoration.
- Failed/cancelled generation, late callbacks, edit-save and backup failures.
- SwiftData round trip across contexts, per-record corrupt-history isolation,
  original JSON overwrite prevention, read-only ViewModel behavior, and real
  temporary-file backup round trip.

The existing service fixtures now include an empty interview payload. Existing
schema assertions were updated. All API tests intercept requests using the
existing URLProtocol stub and use synthetic text and a test key.

## Additional independent review

Two independent read-only reviews covered SwiftUI/actor/type consistency and
model/evidence/persistence/export behavior. Four issues were addressed:

- Quote editor rows now use stable UUIDs and guarded lookup Bindings, so delayed
  updates from deleted fields cannot index outside the draft array.
- Duplicate quotation search advances by one UTF-16 unit. Evidence ranges must
  start/end at grapheme boundaries, preserving whole displayed characters.
- A corrupt history entry is isolated, visibly read-only and protected against
  raw JSON overwrite, while other records remain accessible.
- Restoring a backup over human work requires an explicit UI confirmation.

Both reviewers examined the revised code and found no further concrete issues.
This was code review only; neither reviewer ran a compiler or XCTest. Existing
record initializers remain source-compatible through the optional error argument.

## Required Mac verification

Use macOS 15+ and Xcode 26+. Swift/Xcode are absent from this Linux environment;
no Swift type checking, XCTest, application build, UI run or SwiftData runtime
validation was possible. These remain release blockers.

From the repository root on a Mac:

```bash
xcodebuild -version
xcrun swift test --parallel
xcodebuild -project MeetingFlowAI.xcodeproj -scheme MeetingFlowAI \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/MeetingFlowAI-Interview-DerivedData \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MeetingFlowAI.xcodeproj -scheme MeetingFlowAI \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/MeetingFlowAI-Interview-DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Run the tests before any live API use. They require neither a real key nor audio.
Use synthetic fixture data for subsequent UI checks: four sections and all six
process fields; source popover scroll/highlight for Japanese text and emoji;
editing and reconfirming; deleting the last focused quotation field and adding
it again; candidate replacement cancellation and adoption; restore warning
cancellation and acceptance;
closing/reopening and backup restoration; JSON/Markdown export; existing
minutes/ToDo/flow/Mermaid/draw.io controls. UI layout, accessibility and real
Claude structured-output compatibility remain unverified.

## Transfer

A standalone patch is provided at `/workspace/MeetingFlowAI-business-interview.patch`.
Apply to a clean checkout of the baseline on a dedicated Mac work branch:

```bash
git switch -c codex/business-interview-mvp 4b8c359807414efda4e8b82cc4321ea4738b8ae6
git apply --check /path/to/MeetingFlowAI-business-interview.patch
git apply /path/to/MeetingFlowAI-business-interview.patch
```

The patch contains the complete baseline-to-final diff, including follow-up
review fixes. `git apply --check` was rerun against a fresh baseline worktree.
The final commit ID, file size/hash and Library identifiers are reported in the
handoff response. A `/workspace` path belongs only to this execution environment;
use the Library file identifier to transfer to a different environment.

The local working branch also contains the implementation. No remote branch was
created. If main has advanced, apply on a separate branch and resolve the diff
before running the Mac validation above.

## Library transfer status

The current Library save workflow was attempted after validation. Its connection
failed before upload preparation, including a retry with expanded network access.
No successful Library write or library_file_id was returned. The patch and this
document therefore remain local to this selected cloud environment. Do not assume
these absolute paths exist in another environment. The response and the local
`/workspace/MeetingFlowAI-deliverables.json` manifest include exact byte sizes and
SHA-256 hashes for transfer verification.
