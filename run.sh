#!/bin/bash
# Automatically resolve the script's directory and change to it
cd "$(dirname "$0")"

# Load environment variables
if [ -f env.sh ]; then
  . env.sh
fi

# 1. Detect and activate mise (if installed)
if [ -f "$HOME/.local/bin/mise" ]; then
  eval "$("$HOME/.local/bin/mise" env -s bash)"
elif [ -d "$HOME/.local/share/mise" ] && [ -f "$HOME/.local/share/mise/bin/mise" ]; then
  eval "$("$HOME/.local/share/mise/bin/mise" env -s bash)"
elif command -v mise &> /dev/null; then
  eval "$(mise env -s bash)"
fi

# 2. Detect and activate asdf (if installed)
if [ -f "$HOME/.asdf/asdf.sh" ]; then
  . "$HOME/.asdf/asdf.sh"
fi

# 3. Explicit fallback to prepend user shims and bins to PATH
if [ -d "$HOME/.asdf/shims" ]; then
  export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"
fi
if [ -d "$HOME/.local/share/mise/shims" ]; then
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
fi

# Execute the Elixir bot using exec to replace the shell process
exec elixir muscle_bot.exs
