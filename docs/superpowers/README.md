# Development archive (Japanese)

The files under this directory are a dated record of how Island was built. They
are written in Japanese and are **not** kept in sync with the code.

- `specs/` — design documents written before implementation
- `plans/` — task breakdowns and the reasoning behind each step
- `notes/` — investigation logs (what was measured against a real herdr)

They are kept because the reasoning is often more useful than the conclusion:
several decisions in the code only make sense once you know which alternative
was tried and why it failed. But they capture what was believed on a particular
date, so where they disagree with the code, the code wins.

Translating them would defeat their purpose. A translation inevitably smuggles
in hindsight, and these are worth keeping precisely as a record of what was
known at the time.

## Where to look instead

Everything you need to use or modify Island is in English:

| You want | Read |
| --- | --- |
| What Island does, how to install it | [`README.md`](../../README.md) |
| Why the code is shaped the way it is | the comments in `bin/`, `hooks/`, `lib/` |
| What behaviour is guaranteed | `tests/` — each assertion states its contract |

The source comments are not a summary of these documents. Where a design
decision still constrains the code, the reasoning was moved into the comment
next to the code it constrains, so nothing here is required reading.
