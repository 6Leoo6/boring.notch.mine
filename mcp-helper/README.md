# boringnotch-mcp

stdio MCP server that gives agents access to the boring.notch shelf and clipboard history.

It talks to the running app over a loopback bridge the app opens when **Settings → Agents →
Allow local agents** is on. The helper finds it through `~/.config/boringnotch/agent-bridge.json`,
so there is nothing to configure.

```sh
./install.sh   # builds, installs to ~/.local/bin, runs `claude mcp add --scope user boringnotch`
```

| Tool | What it does |
|---|---|
| `shelf_list` | Every shelf item: id, kind (file/text/link), name, size, original path for dropped files |
| `shelf_pull` | Writes a file item to a path (folders arrive zipped); returns text/link items inline |
| `shelf_put` | Copies a file or folder (≤ 64 MB) onto the shelf, or adds text or a link |
| `clipboard_list` | History filtered by `type`, `since`/`until`, `pinned_only`, `protected`; paged |
| `clipboard_get` | One entry in full, including `is_pinned`; images inline or saved to a path |
| `clipboard_add` | Adds text, an image file, or file paths to the history, optionally pinned |

Protected entries (marked by the user, copied from a password manager, or that look like a key
or token, unless auto-detection is off) are listed with metadata only.
