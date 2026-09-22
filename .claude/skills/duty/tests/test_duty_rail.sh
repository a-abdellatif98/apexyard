#!/usr/bin/env bash
# The rail: a proposal whose effect reduces supervision is class B, however it is framed.
. "$(dirname "$0")/_helpers.sh"

playbook="$SANDBOX/playbook.md"
cp "$(dirname "$DUTY")/playbook.md" "$playbook"
original=$(cat "$playbook")

proposal() {
  jq -n --arg c "$1" --arg s "$2" --arg o "$3" --arg n "$4" \
    '{id: "P-1", class: $c, section: $s, old: $o, new: $n,
      evidence: "journal 10:00, the rule was wrong"}' > "$SANDBOX/p.json"
  printf '%s' "$SANDBOX/p.json"
}

verdict() { "$DUTY" classify "$1" "$playbook" | head -1; }
reasons() { "$DUTY" classify "$1" "$playbook" | tail -n +2; }

p=$(proposal A "## 9. Traps" "" "- **Quote globs.** An unquoted glob matched nothing and read as success.")
expect_eq "$(verdict "$p")" "A" "a plain trap-log addition is class A"

p=$(proposal A "## 9. Traps" \
  "- **zsh and \`\"\$var:c\"\`.** zsh reads \`:c\` after a variable as a history modifier and changes the" \
  "- **zsh and \`\"\$var:c\"\`.** zsh reads \`:c\` after a variable name as a history modifier and changes the")
expect_eq "$(verdict "$p")" "A" "a factual wording fix in an open section is class A"

p=$(proposal A "## 1. Hard constraints" "- Never force-push. Rebase locally, verify, and give the operator the exact push command." "")
expect_eq "$(verdict "$p")" "B" "deleting a hard constraint is class B"
expect_contains "$(reasons "$p")" "RAIL" "deleting a hard constraint is a rail case"

p=$(proposal A "## 2. Cadence and thresholds" \
  "| Watcher stamp is stale after | 45 minutes | \`duty.watcher_stale_minutes\` |" \
  "| Watcher stamp is stale after | 120 minutes | \`duty.watcher_stale_minutes\` |")
expect_eq "$(verdict "$p")" "B" "correcting a stale threshold is class B"
expect_contains "$(reasons "$p")" "changes a number" "threshold change is named"

p=$(proposal A "## 4. Reading the tracker" \
  "  and read again. Evidence: an unfiltered first page showed 19 of 28 items." \
  "  and read again. Evidence: an unfiltered first page showed 19 of 40 items.")
expect_eq "$(verdict "$p")" "B" "a number change in an open section is class B"
expect_contains "$(reasons "$p")" "changes a number" "open-section number change is named"

p=$(proposal A "## 7. Escalation" "- Repeated retries against failing infrastructure." \
  "- Repeated retries against failing infrastructure, after three attempts.")
expect_eq "$(verdict "$p")" "B" "fixing an over-broad gate is class B"
expect_contains "$(reasons "$p")" "protected section" "gate change names the protected section"

p=$(proposal A "## 3. The tick" \
  "1. **Watcher pass.** Always. Never conditional. Never skipped because review work looks urgent." \
  "1. **Watcher pass.** Run it when the review pass finishes early.")
expect_eq "$(verdict "$p")" "B" "removing a redundant check is class B"

p=$(proposal A "## 4. Reading the tracker" \
  "- **Read the merge-conflict field.** An item can be green with no open threads and still be" \
  "- **The merge-conflict field is redundant.** An item can be green with no open threads and still be")
expect_eq "$(verdict "$p")" "B" "calling a check redundant in an open section is class B"
expect_contains "$(reasons "$p")" "widens unattended action or removes a check" "redundant wording is caught"

p=$(proposal A "## 4. Reading the tracker" \
  "  failure. Check the return code. On failure, retry once, then report \`UNKNOWN\`. Never report zero." \
  "  failure. Check the return code. On failure, retry once, then report \`UNKNOWN\`.")
expect_eq "$(verdict "$p")" "B" "dropping a normative clause in an open section is class B"

p=$(proposal A "## 9. Traps" "" "- **Night pushes.** Open new pull requests unattended when the diff is small.")
expect_eq "$(verdict "$p")" "B" "an addition that widens unattended action is class B"

p=$(proposal A "## 10. The learning loop" "" "Class A proposals may also edit protected sections when the evidence is strong.")
expect_eq "$(verdict "$p")" "B" "an addition to the rail section itself is class B"

p=$(proposal A "## 6. Done" "## 6. Done

<!-- duty:protected -->" "## 6. Done")
expect_eq "$(verdict "$p")" "B" "removing a protection marker is class B"

p=$(proposal A "## 9. Traps" "text that is not in the playbook" "anything")
expect_eq "$(verdict "$p")" "B" "an unlocatable edit rounds up to class B"

p=$(proposal B "## 9. Traps" "" "- **A new idea.** Try it.")
expect_eq "$(verdict "$p")" "B" "declared class B stays class B"

p=$(proposal A "## 7. Escalation" "- A force-push." "")
out=$("$DUTY" apply "$p" "$playbook"); rc=$?
expect_eq "$rc" "1" "apply refuses a class B proposal"
expect_contains "$out" "needs operator approval" "refusal names the approval"
expect_eq "$(cat "$playbook")" "$original" "a refused proposal leaves the playbook unchanged"

out=$("$DUTY" apply "$p" "$playbook" --operator-approved)
expect_eq "$out" "APPLIED" "operator approval applies a class B proposal"
case "$(cat "$playbook")" in *"- A force-push."*) bad "approved change was not applied" ;; *) ok ;; esac

cp "$(dirname "$DUTY")/playbook.md" "$playbook"
p=$(proposal A "## 9. Traps" "" "- **Quote globs.** An unquoted glob matched nothing and read as success.")
expect_eq "$("$DUTY" apply "$p" "$playbook")" "APPLIED" "a class A addition applies"
section=$(awk '/^## 9\. Traps/{f=1} /^## 10\./{f=0} f' "$playbook")
expect_contains "$section" "Quote globs" "the addition lands inside its own section"

finish test_duty_rail
