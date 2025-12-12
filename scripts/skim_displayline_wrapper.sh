#!/bin/bash
# Wrapper for Skim's displayline: call displayline then clear selection in Skim
# Usage: skim_displayline_wrapper.sh [options] line pdffile texfile

DISPLAYLINE="/Applications/Skim.app/Contents/SharedSupport/displayline"

if [ ! -x "$DISPLAYLINE" ]; then
  echo "Error: displayline not found at $DISPLAYLINE" >&2
  #!/bin/bash
  # Wrapper for Skim's displayline: call displayline then clear selection in Skim
  # Usage: skim_displayline_wrapper.sh [options] line pdffile texfile

  DISPLAYLINE="/Applications/Skim.app/Contents/SharedSupport/displayline"

  if [ ! -x "$DISPLAYLINE" ]; then
    echo "Error: displayline not found at $DISPLAYLINE" >&2
    exit 1
  fi

  "$DISPLAYLINE" "$@"


  # Increased delay for Skim to update
  sleep 0.3

  # Clear selection in Skim documents and current page (run AppleScript silently)
  osascript <<'OSA' >/dev/null 2>&1
  try
    tell application "Skim"
      repeat with d in documents
        try
          set selection of d to {}
          set selection of (current page of d) to {}
        end try
      end repeat
    end tell
  end try
  OSA

  exit 0
