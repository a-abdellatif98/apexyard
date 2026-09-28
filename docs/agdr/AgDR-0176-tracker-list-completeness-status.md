# Report tracker_list completeness through a status variable

> In the context of skills that list issues from a tracker, facing short and failed reads that look like complete reads, I decided to report a completeness status from `tracker_list` and pass an explicit default limit, to achieve callers that can tell a complete read from a partial one, accepting a new caller contract and a changed default limit on adapters.

## Context

`tracker_list` returns a JSON array. It prints `[]` and returns non-zero when the call fails. A caller that ignores the return code reads a failure as an empty set and reports zero items.

Two more short-read paths exist. When a caller passes no `limit`, each CLI applies its own default of 30. The GitLab adapter maps `limit` to `--per-page`, and GitLab caps a page at 100.

`/inbox` and `/tasks` both call `tracker_list` with a fixed limit and no completeness check.

This is the reusable half of the `/duty` proposal in #1360. The premise check on #1361 recommended extracting it.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Document the return code, change no code | No new contract | The failure path stays easy to ignore, and neither short-read path is addressed |
| Return a wrapper object `{items, status}` | One value carries both facts | Breaking change for every existing caller |
| Set a status variable beside the array | No change to the returned JSON. Callers opt in | A shell variable is a weaker contract than a return value, and a subshell does not propagate it |
| Paginate inside `tracker_list` | Callers need no completeness logic | Each adapter pages differently, and an unbounded internal loop hides cost from the caller |

## Decision

Chosen: **set `TRACKER_LIST_STATUS` beside the returned array**, because it adds the missing fact without changing the JSON that current callers parse.

- `tracker_fetch_status <rc> <count> <limit> [repo]` returns `COMPLETE`, `TRUNCATED`, or `UNKNOWN`. It is pure, so a caller can also use it on its own reads.
- `tracker_page_cap <repo>` reports the adapter's maximum page size. GitLab is 100, and every other adapter is 0, which means no cap.
- `tracker_list` sets `TRACKER_LIST_STATUS` on every exit path, and sets `UNKNOWN` before any work so an early return cannot leave a stale value.
- `tracker_list` passes an explicit limit, from `tracker.list_default_limit` (default 30), when the caller gives none.
- The status reads the count the server returned, before the client-side `since` filter, so a filtered-down array does not read as `COMPLETE`.

The default-limit lookup runs after the tracker kind is resolved. Loading the config library before that step warmed the resolution cache from a different context and changed adapter dispatch, which two existing stderr tests caught.

## Consequences

- A caller that reads `TRACKER_LIST_STATUS` inside a command substitution does not see it, because a subshell does not export back. Callers must run `tracker_list` in the current shell.
- Adapters now always receive a limit. The value matches each CLI's previous default, so the returned set does not change.
- A `glab` read that returns 100 items stays `TRUNCATED` at any requested limit. This was inferred from the adapter code and was not run against GitLab.
- `/inbox` and `/tasks` still need their own retry loop. This change gives them the signal, not the loop.

## Artifacts

- me2resh/apexyard#1441
- `.claude/hooks/_lib-tracker.sh`, `.claude/hooks/tests/test_tracker_fetch_status.sh`
