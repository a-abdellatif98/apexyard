# Classify /duty playbook proposals by effect, in a tested helper

> In the context of a shift loop that edits its own playbook, facing the risk that the loop removes its own constraints, I decided to classify each proposal by its effect in a deterministic helper, to achieve a rail that holds against proposals framed as corrections, accepting that some harmless corrections go to the operator.

## Context

The `/duty` skill (me2resh/apexyard#1360) runs a shift loop. A daily retro proposes playbook changes. A class A proposal corrects a false statement and applies immediately. A class B proposal waits for per-item operator approval.

A rail that blocks only literal edits to the hard-constraint list is not enough. The realistic failure is a proposal framed as a correction whose effect reduces supervision. Examples include a changed stale threshold, a narrowed escalation gate, or a check that the proposal calls redundant.

The model that drafts a proposal also labels it. A rule written only in prose relies on that same model to classify its own proposal honestly.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Prose rule in the playbook only | No code. Simple to read. | The author classifies its own proposal. No test can check it. |
| Classify by the proposal's declared fields | Simple helper. | The author sets the fields, so it has the same weakness as prose. |
| Classify by effect on the actual text, in `duty.sh` | Deterministic and testable. It ignores the declared framing. | Heuristic keyword and number checks send some harmless edits to class B. |
| A new PreToolUse hook that guards the playbook file | Mechanical enforcement. | Adds to the trust chain. A shell hook cannot tell a sanctioned approval from an unsanctioned edit. Heavy for a skill-scoped control. |

## Decision

Chosen: **classify by effect in `duty.sh`**, because it is the strongest control that stays inside the skill. The classifier ignores the declared class unless it is B. It returns class B when a proposal does any of these:

- edits or appends to a section that carries the `duty:protected` marker;
- removes or rewrites a line with normative words such as never, always, must, only, gate, or escalate;
- changes any number;
- adds text that widens unattended action or calls a check redundant;
- targets text or a section that the helper cannot find.

`duty.sh apply` refuses a class B proposal unless the call passes `--operator-approved`. The skill allows that flag only when the operator typed `approve <id>` in the current message.

## Consequences

- Some harmless corrections become class B, for example a corrected number in an evidence line. This error direction is the intended one.
- The rail is not a security boundary against an agent that edits `playbook.md` directly with a file tool. The helper and the tests make a violation visible and reviewable. They do not make it impossible.
- The protected-section marker is itself in the playbook. A proposal that removes a marker edits a protected section, so it is class B.
- The skill adds no hook and does not change `.claude/settings.json`.

## Artifacts

- me2resh/apexyard#1360
- `.claude/skills/duty/duty.sh`, `.claude/skills/duty/tests/test_duty_rail.sh`
