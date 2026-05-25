# SelfLearningTests

Smoke tests for FreeFlow's self-learning correction pipeline.

## What is covered

- `CommonWordGuard`: rejects common words, short tokens, and accepts valid vocabulary pairs
- `PostInsertionMonitor.extractSingleWordSubstitutions`: LCS-based word diff extracts clean substitution pairs
- `CorrectionLearningService`: confidence threshold, app-scoping, guard integration, and JSON persistence round-trip
- `PostProcessingService.formatLearnedCorrectionsPrompt`: sorted output and empty-dict handling

18 cases total. All cases must pass on the `feat/v2.2-foundations` base branch.

## How to run

```
make test
```

The `test` target compiles a standalone executable from the relevant `Sources/` files
and the test source, then runs it. Exit code is non-zero if any case fails.
