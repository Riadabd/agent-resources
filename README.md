# agents-gen

`agents-gen` builds Codex CLI instruction files from small Markdown snippets in
`snippets/`. The snippets are the source of truth. The generator discovers the
tree, lets you list or select entries, renders the selected Markdown into a
single AGENTS-style file, and writes a date-stamped output file without touching
an existing `AGENTS.md`.

## Quick Start

List the snippets the generator can see:

```bash
zig build run -- list
```

Generate a full file from every snippet:

```bash
zig build run -- generate --output-dir . --snippets snippets
```

Pick sections and snippets interactively:

```bash
zig build run
```

Generate a smaller file by passing explicit section flags and snippet paths:

```bash
zig build run -- generate \
  --output-dir . \
  --quick-summary quick-summary/operating-contract.md quick-summary/quick-obligations.md \
  --tooling tooling/git-read-only.md tooling/ci-workflows.md \
  --testing testing/philosophy.md testing/targeted-tests.md \
  --language languages/rust.md languages/zig/style.md \
  --communication communication/tone.md \
  --environment environment/nix.md
```

The output is named `AGENTS-YY-MM-DD.md` in the chosen output directory. If that
name already exists, the generator appends a numeric suffix such as
`AGENTS-26-04-26-01.md`. If `AGENTS.md` already exists in the output directory,
the generator warns and leaves it alone.

## Commands

### `zig build run`

Runs the interactive picker against `snippets/` and writes to the current
directory.

Use the picker like this:

- `Up` / `Down`: move the cursor.
- `Space`: toggle the highlighted section or file. On a directory row, toggles
  every snippet under that directory.
- `Enter`: from the section list, start snippet selection for the first selected
  section, or the highlighted section if none are selected. From snippet
  selection, continue to the next selected section or move to review. From the
  review screen, generate the file.
- `Right`: open the highlighted section from the section list, or expand a
  directory in snippet selection.
- `Left`: collapse an expanded directory, or return to the section list from a
  top-level snippet row.
- `Esc` / `Backspace`: go back one stage. From the section list, this cancels.
- `q` / `Ctrl-C`: cancel.

The picker has three stages:

1. Select sections.
1. Select snippets inside each chosen section.
1. Review the output filename and selected files, then press `Enter` to write.

If you press `Enter` during snippet selection without selecting any snippet
first, the highlighted snippet or directory is selected for that section. A
directory selection includes every snippet under it. This keeps the
single-snippet path quick without hiding what will be generated.

### `zig build run -- list`

Prints the discovered catalog. File paths in this output are the paths to pass to
the explicit `generate` flags. Directory rows are shown for orientation and are
not accepted by explicit generation.

```bash
zig build run -- list
```

Limit the listing to one section:

```bash
zig build run -- list --section language
zig build run -- list --section handoff
```

Known section aliases work for listing. For example, `language` matches the
`snippets/languages/` folder.

### `zig build run -- generate`

Writes a generated Markdown file without opening the picker. You must choose one
selection mode: pass `--snippets` for the whole tree, or pass at least one
explicit section flag with one or more file paths.

Wholesale generation uses a snippets root and includes every `.md` file under it:

```bash
zig build run -- generate --output-dir . --snippets snippets
```

Explicit generation uses section flags. Each path after a flag must be a file
path that belongs to that section:

```bash
zig build run -- generate \
  --output-dir . \
  --mindset mindset/architecture-first.md mindset/code-hygiene.md \
  --tooling tooling/dependency-selection.md \
  --language languages/python.md languages/typescript.md
```

Supported explicit section flags:

- `--quick-summary`
- `--mindset`
- `--tooling`
- `--testing`
- `--language`
- `--communication`
- `--environment`

`--snippets` and explicit section flags are mutually exclusive. Use `--snippets`
when you want the whole tree, including custom top-level sections. Use explicit
flags when you want a curated subset of the known profile sections. A bare
`zig build run -- generate --output-dir .` fails because it does not select any
snippets.

## Snippet Layout

The default snippet root is `snippets/`. Every Markdown file under that tree is a
selectable snippet.

```text
snippets/
  quick-summary/
    operating-contract.md
  tooling/
    git-read-only.md
  languages/
    zig/
      style.md
```

Top-level folders become top-level sections in the rendered file. Known folders
get stable titles and ordering:

- `quick-summary` -> `Quick Summary`
- `mindset` -> `Mindset`
- `tooling` -> `Tooling`
- `testing` -> `Testing`
- `languages` -> `Languages`
- `communication` -> `Communication Preferences`
- `environment` -> `Environment And Setup`

Unknown top-level folders are still discovered, listed, and included by
wholesale generation. Their titles are inferred from the folder name.

Nested folders become nested headings. Files become selectable leaves. If a file
starts with a `# Title` heading, that heading becomes the snippet title and is
not duplicated in the body. Other Markdown headings are shifted so the final
document keeps a coherent hierarchy. Headings inside fenced code blocks are left
unchanged.

## Development

Use Zig 0.15.2 for this repo. The package declares 0.15.2 as the minimum, and
the code targets the 0.15.2 standard library APIs. Newer Zig versions can still
break the build.

If Zig 0.15.2 is installed natively:

```bash
zig version
```

If you use Nix, enter the checked-in flake dev shell instead:

```bash
nix develop
zig version
```

Both paths should report `0.15.2` before you build or test.

Build and run the tool:

```bash
zig build run -- list
```

Run the test suite:

```bash
zig build test
```
