---
name: pr-description
description: Write a short, natural pull request description that reads like a person wrote it. Use when the user asks for a PR description, PR summary, PR body, or "something to paste into the PR", in any repo. Writes the text only; to push and open the PR as well, use git-create-pr.
---

# PR description

Write the description the author would have written: short, plain, specific. Reviewers should know in 30 seconds what changed, why, and how far it's been checked.

## Gather the facts first

Don't write from memory of the conversation alone. Check what's actually in the branch:

```sh
git branch --show-current
git log --oneline <base>..HEAD          # base is usually main
git diff --stat <base>...HEAD
git status --short                      # uncommitted work isn't in the PR
```

Read the diff for anything you didn't make yourself. If the branch contains uncommitted or unpushed changes that the description would mention, say so to the user.

## Format

```markdown
## <Short title: what the PR does, imperative or noun phrase>

<One or two sentences of context: what and, if not obvious, why.>

**<area or module>**: <what it does / what changed, 1–3 sentences>
**<area or module>**: ...

<Any cross-cutting point: defaults, breaking changes, required versions, migration steps.>

<Testing: what actually ran and what didn't.>
```

- Typical length is **5–12 lines**. Small PRs can be two sentences. Don't pad.
- One short paragraph per area or module, with the name in bold. Use bullets only when listing several parallel items.
- Lead with what a reviewer needs: behavior changes, surprising defaults, anything breaking, anything they must do.
- Mention a design decision only when a reviewer would otherwise ask "why?" (e.g. "ignores AMI changes so new releases don't replace the instance").

## Voice

- Plain and direct, like a teammate writing quickly: "Adds…", "Fixes…", "Also…".
- Don't open with "This PR…". Don't write a "Summary" heading over a three-line description.
- No marketing words: comprehensive, robust, seamless, enhance, leverage, powerful, streamline.
- No emojis, no "🚀", no closing pleasantries, no "Let me know if…".
- No exhaustive file lists or restating the diff line by line. The diff is right there.
- Use backticks for code identifiers, names, and commands.
- Leave out private context (internal repo or ticket names, where code was copied from, people) unless the user includes it.

## Be honest about testing

State exactly what ran: "`fmt`/`validate` pass", "unit tests pass", "deployed to staging". If something wasn't tested, say so in one line ("Not applied against a real account yet."). Never imply more testing than happened.

## Hand-off

- Start your message with one line naming the audience, e.g. "Written for: reviewers on the `feat/x` PR."
- Put the description in a single fenced `markdown` block so it's easy to copy.
- Only create or edit the PR on GitHub (`gh pr create` / `gh pr edit`) if the user asks. Otherwise just hand over the text.
- If the repo has a PR template (`.github/pull_request_template.md` or `.github/PULL_REQUEST_TEMPLATE/`), fill in its sections instead of using the format above.
