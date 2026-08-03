# Prompt shapes for browser Oracle

Use these shapes when the default “review this” prompt would produce generic advice.

## Root-cause debugging

```
BRIEFING
<project, language, runtime, what this subsystem does>

SYMPTOM
<exact failure, logs, reproduction, what changed>

CONSTRAINTS
<can't break API, must preserve data, performance bound, security constraints>

PRIOR ATTEMPTS
<what was tried, observed result>

FILES
<explain attached path groups and why they matter>

ASK
Rank the likely root causes. For each, give:
1. why it fits the evidence,
2. the fastest falsification test,
3. the smallest safe fix if true.
End with the single next command or edit you would do first.
```

## Architecture decision

```
BRIEFING
<product/system context and current architecture>

DECISION
We need to choose between <A>, <B>, and <C>.

PRESSURE
<operator pain, user pain, complexity, migration, reversibility, team constraints>

EVIDENCE
<attached files/docs, incidents, measurements>

ASK
Compare the options. Optimize for reducing future user and operator pain; weight backward compatibility only where it prevents real pain. Recommend one path, name the assumptions that would flip the recommendation, and give a reversible first implementation slice.
```

## UX/user-pain review

```
BRIEFING
<what the user is trying to do>

CURRENT FLOW
<steps, screenshots/files if attached, where friction appears>

PAINS WE EXPERIENCE
<agent/operator pains: babysitting, copy/paste, stale status, hidden failure>

PAINS USERS EXPERIENCE
<confusion, waiting, duplicate work, bad defaults, unclear recovery>

ASK
Find the highest-leverage design changes. Separate:
- remove this pain now,
- instrument this pain,
- automate this pain away,
- accept this pain with honest messaging.
Return concrete copy/UI/API changes and the first patch to make.
```

## Code review with actionability

```
BRIEFING
<repo, stack, changed feature>

CHANGE SUMMARY
<what changed and why>

RISK AREAS
<data loss, auth, concurrency, billing, privacy, migration, user-visible behavior>

FILES
<changed files and supporting context>

ASK
Do a ruthless review. Output only issues that are real enough to act on. For each issue include severity, evidence path/line if possible, exploit/failure mode, and suggested fix. Also list non-issues you checked so we do not chase ghosts.
```

## Skill/workflow design

```
BRIEFING
We are designing a reusable agent skill/workflow for <task>.

CURRENT PAIN
<what repeatedly hurts agents and users>

EXISTING TOOLS
<commands, browser surfaces, APIs, known constraints>

ASK
Design the workflow to minimize repeated pain. Include trigger conditions, decision tree, guardrails, fallback paths, verification steps, and what should be scripted versus left to agent judgement.
```
