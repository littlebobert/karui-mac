# karui-eval

Tries versions of Karui's Second Opinion prompt against a golden set you graded, and shows which does better. Each prompt goes to Private Cloud Compute through your own **Karui Second Opinion** Shortcut, the same way Karui for Mac asks it. Karui for Mac can't use Private Cloud Compute in the app, but the Shortcut's Use Model step can.

## Before you start

1. **A golden set.** In a developer build of Karui for Mac, Help → Grade History…, grade, then **Export Golden Set…**.
2. **The Shortcut.** Karui for Mac's Settings can add it.
3. **Your sorting settings.** Karui for Mac keeps the iPhone's settings in `~/Library/Application Support/Karui/SortingSettings.json` while the iPhone's Show History on your Mac is on. The prompt needs your names, terms, and important apps from them.

## Run

From this folder:

```bash
swift run karui-eval run --golden ~/Downloads/karui-golden-2026-10-21.jsonl
```

Every graded item goes through the shipping prompt and each variant in `variants/`, three times each. Items you graded Unclear are left out. The report is printed and written, with every answer, to a dated folder in `~/Library/Application Support/Karui/Grading/eval-reports/`.

- `--dry-run` says how many calls a run would make, and makes none.
- `--limit 20` tries a new variant on the first 20 items before spending a full run on it.
- `--variant variants/reason-first.txt` runs only the variants named.
- `--runs 1` is quicker but can't show which items flip between runs.

Apple limits how often Private Cloud Compute answers. Every answer is cached in `~/Library/Application Support/Karui/Grading/eval-cache.jsonl`, keyed by the exact prompt and run. Running again asks only about prompts that changed, and a run stopped by the limit picks up where it left off. A run goes one round at a time across every prompt, so if it stops partway, every prompt still has the same rounds to compare.

## The report

For each prompt, by each item's majority answer across runs:

- **Accuracy**: how often it matched your grade.
- **Important recall**: of what you graded Important, how much it called Important. Missing one is the costly mistake.
- **Important precision**, **Spam precision**, and **Spam recall**.
- **Important called Spam**: the worst mistake, counted on its own.
- **Unreadable answers**: answers the parser couldn't find a category in.
- **Items that flip between runs**: how unsure the prompt is.
- **Latency**: median and 95th percentile. In First mode an Important alert waits for this.
- **A confusion table**: rows are your grade, columns are the prompt's answer.

Then, for each variant, every item whose majority answer changed from the shipping prompt, split into **Fixed**, **Broke**, and **Changed, still not your grade**. Read those, not just the totals.

## Writing a variant

A variant is a text file in `variants/`, named for what it changes. It holds the prompt with placeholders for the shipping prompt's parts:

| Placeholder | What it is |
|---|---|
| `{{instructions}}` | The rules, examples, and interest scale, and the deadline instructions when deadline reminders are on |
| `{{policy}}` | "User policy:" and your settings |
| `{{notification}}` | "Notification:" and the notification, and the Dates line for deadlines |
| `{{answer}}` | "Answer with exactly … lines" and the lines it asks for |
| `{{answer.Category}}`, `{{answer.Reason}}`, `{{answer.Confidence}}`, `{{answer.Tags}}`, `{{answer.Task}}`, `{{answer.Due}}` | One answer line as shipped. A line holding only one of these is left out when there's nothing to show, as Task and Due are without deadline reminders. |
| `{{answer.count}}` | How many answer lines the variant asks for, as a word |

Lines at the top starting with `#` describe the variant. A line starting with `#-` leaves out every line of the prompt that starts with the text after it. A variant can drop part of the shipping instructions that way, and still follow them as they change. A `#-` line that no longer matches anything stops the run.

To start one:

```bash
swift run karui-eval template --golden golden.jsonl > variants/my-idea.txt
swift run karui-eval template --expanded --golden golden.jsonl > variants/my-idea.txt
```

The second writes the instructions out in full, to rewrite them. To check what an item would be sent:

```bash
swift run karui-eval prompt --golden golden.jsonl --item 3 --variant variants/my-idea.txt
```

## What it doesn't cover

- **Only Private Cloud Compute.** The on-device model takes the same instructions as a session, with structured output, not this prompt, so its variants aren't tried here.
- **The prompt's own answer.** Karui applies a few rules after Private Cloud Compute answers: saved contacts, quiet apps, and what it learned from your fixes. They're left out, so the scores are the prompt's alone.
- **What History doesn't keep.** It doesn't keep whether a notification was a direct message, so the prompt makes its usual guess. It doesn't keep the translation, or whether you've written to the sender, so those lines never appear.
- **The time.** The sort time stands in for the clock: it decides which apps were important at that hour, and the Received and Dates lines.

The golden set, cache, and reports are your notifications' text. They stay in Application Support, out of this repository.
