#!/bin/zsh
# Builds boringnotch-mcp, installs it to ~/.local/bin, and registers it with Claude Code.
set -euo pipefail

here=${0:A:h}
dest="$HOME/.local/bin"

swift build --package-path "$here" -c release
mkdir -p "$dest"
install -m 0755 "$here/.build/release/boringnotch-mcp" "$dest/boringnotch-mcp"
echo "Installed $dest/boringnotch-mcp"

if command -v claude >/dev/null; then
    if claude mcp get boringnotch >/dev/null 2>&1; then
        echo "Claude Code already has a 'boringnotch' MCP server; left as is."
    else
        claude mcp add --scope user boringnotch -- "$dest/boringnotch-mcp"
    fi
else
    echo "Claude Code not found. Register manually:"
    echo "  claude mcp add --scope user boringnotch -- $dest/boringnotch-mcp"
fi
