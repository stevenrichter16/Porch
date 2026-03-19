# Analysis: LLM File Editing via the GitHub Connector

## Summary

The `github_create_branch_and_commit_changes` tool **already supports editing
existing files** via `operation: "update"`. The backend correctly validates the
file exists, fetches current content, generates a diff preview, and commits the
change. The issue is that LLMs don't reliably *use* the update operation—they
default to creating new files instead.

## Root Causes

### 1. The schema example only demonstrates `"create"`

`GitHubConnector.swift:1364-1384` — The `examples` array shipped with the tool
schema contains a single example using `"operation": "create"`. LLMs anchor
heavily on schema examples when deciding how to call a function.

### 2. The tool name primes for creation

The name `github_create_branch_and_commit_changes` leads with "create." Models
interpret tool names semantically before reading descriptions, so they approach
this tool with a creation mindset.

### 3. The description doesn't teach the read→edit→commit workflow

The description at `GitHubConnector.swift:1727-1728` mentions "create, update,
or delete" in passing. There's no explicit guidance that an update requires:

1. Reading the current file content with `github_get_file_content`
2. Providing the **complete modified content** (not a diff/patch)
3. Using `"operation": "update"`

### 4. Full-content replacement is non-obvious

For `operation: "update"`, the `content` field must contain the entire new file.
This is a full replacement—not a patch or diff. Many LLMs won't attempt this
unprompted because it requires reading the file first, mentally merging changes,
then emitting potentially hundreds of lines.

## Recommended Changes (by effort/impact)

### Quick wins (high impact, low effort)

**A. Add an update example to the schema**

In `gitHubWriteArgumentsExampleSchema`, add a second example showing an update:

```swift
"changes": .array([
    .object([
        "path": .string("Sources/Config.swift"),
        "operation": .string("update"),
        "content": .string("// updated file content here\n")
    ]),
    .object([
        "path": .string("Tests/ConfigTests.swift"),
        "operation": .string("create"),
        "content": .string("import XCTest\n")
    ])
])
```

**B. Improve the tool description**

Change the description from:

> "…containing text file create, update, or delete changes."

To something like:

> "Commit file changes to a new branch. Supports three operations: 'create'
> (new file), 'update' (replace existing file—read it first with
> github_get_file_content and provide the complete modified content), and
> 'delete' (remove file). Each item in changes[] is one file."

**C. Expand the `operation` field description in the change schema**

At `GitHubConnector.swift:1299-1302`, change:

> "One of: create, update, delete."

To:

> "create — new file (must not exist); update — replace an existing file (must
> exist, provide full new content); delete — remove a file (must exist, omit
> content)."

### Medium effort

**D. Rename the tool**

Consider `github_commit_file_changes` or `github_branch_and_commit`. Removing
"create" from the name eliminates the creation bias.

**E. Inject a system-prompt snippet when GitHub context is active**

When a `GitHubChatContext` is attached to a chat, prepend a system message like:

> "You have access to a GitHub repository. To edit an existing file: first read
> it with `github_get_file_content`, then call
> `github_create_branch_and_commit_changes` with `operation: "update"` and the
> complete new file content. To create a new file, use `operation: "create"`. To
> delete, use `operation: "delete"` with no content."

### Higher effort (significant UX improvement)

**F. Support diff/patch-based updates**

Add an optional `patch` field to the change schema that accepts a unified diff.
The connector would apply the patch server-side (fetch current content, apply
diff, commit result). This dramatically reduces the token cost of edits and
makes the operation more natural for LLMs, which are good at generating diffs.

## How the Current Update Flow Works (for reference)

1. LLM calls `github_create_branch_and_commit_changes` with
   `operation: "update"`, a `path`, and full `content`
2. `normalizeChanges()` validates path and content size
3. `prepareWriteRequest()` fetches the repo tree, confirms the file exists as a
   blob, fetches current content, and generates a diff preview
4. Approval sheet shows the diff to the user for review
5. On approval, `executeApprovedWrite()` creates a blob, tree, commit, and
   branch ref via the GitHub Git Data API

The entire pipeline works correctly. The gap is exclusively in how the LLM is
prompted to use it.
