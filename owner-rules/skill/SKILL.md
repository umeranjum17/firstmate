---
name: owner-rules
description: >-
  Use before writing a lane brief or merging a lane, and when a brief or merge is refused with an "owner-rules:" line.
  States the two owner rules (every lane serves an owner ask; no-mistakes only for listed risks) and the one-step fix for each refusal.
user-invocable: false
---

# Owner rules

Two owner rules are enforced by the fleet, not by prose. A refusal prints one `owner-rules:` line; fix it as below.

## Rule 00: every lane names the owner ask it serves

The backlog item for the lane id (`data/backlog.md`) must have a title starting `[captain-ask]`, or its title or body must name a `MainNNN` order. Ship and scout lanes both need one; secondmate charters do not.

Refusal at brief time (`$id` is the task id):

```
owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for $id)
```

Fix: retitle the item `[captain-ask] ...` or add the `MainNNN` order to its body, then brief again.

## Rule 13: direct-PR plus a done-done check is the default route

`--mode no-mistakes` is only for an npm/store release, sign-in/keys/payment/security code, a data migration, a large change (new subsystem or about 400+ changed lines), or shared protocol/crypto. Everything else ships direct-PR, and the real user journey is checked (the done-done check) with its evidence on the sign-off Evidence tab.

Refusal at brief time for `--mode no-mistakes`:

```
owner-rules: mode no-mistakes needs one listed risk reason (release, security, migration, large-change, shared-protocol) in the backlog item for $id; use direct-PR plus a done-done check
```

Fix: if the lane truly is one of those, add exactly one body line `risk: <reason>` to the item (reason is one of the five listed). Otherwise brief with `--mode direct-PR`.

Refusal at merge time (`$what` is the PR URL, or `local merge <head>` with no PR):

```
owner-rules: no passed-proof receipt for $what; run the done-done check and post the evidence to the sign-off Evidence tab first
```

Fix: run the done-done check on the real journey at the merge head and post its evidence, then merge again. A merge whose Checks block says `screen: none` is exempt.

## Install

No add-on installs skills, so link this folder into the home's skills by hand:

```
ln -s <firstmate-addons>/owner-rules/skill <fm-home>/.agents/skills/owner-rules
```

`owner-rules/install.sh <fm-home>` turns the refusals on; the skill is only the reading for the leads.
