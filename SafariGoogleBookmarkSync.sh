#!/usr/bin/env zsh
# ============================================================
#  safari_to_chrome_bookmarks.sh
#  Converts Safari bookmarks → Chrome Bookmarks JSON format
#  and replaces ALL Chrome profiles' bookmarks with them.
#
#  Usage:  ./safari_to_chrome_bookmarks.sh
#  Requires: Python 3 (pre-installed on macOS)
# ============================================================

set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Paths ───────────────────────────────────────────────────
SAFARI_PLIST="$HOME/Library/Safari/Bookmarks.plist"
CHROME_DIR="$HOME/Library/Application Support/Google/Chrome"
BACKUP_DIR="$HOME/Desktop/ChromeBookmarkBackups_$(date +%Y%m%d_%H%M%S)"
TMP_JSON="/tmp/safari_bookmarks_$$.json"
EXCLUSIONS_FILE="$HOME/.safari_chrome_sync_excluded"

# ── Exclusion helpers ────────────────────────────────────────
is_excluded() {
    [[ -f "$EXCLUSIONS_FILE" ]] && grep -qxF "$1" "$EXCLUSIONS_FILE"
}

exclude_profile() {
    is_excluded "$1" || echo "$1" >> "$EXCLUSIONS_FILE"
}

unexclude_profile() {
    [[ -f "$EXCLUSIONS_FILE" ]] && grep -vxF "$1" "$EXCLUSIONS_FILE" > "${EXCLUSIONS_FILE}.tmp" && mv "${EXCLUSIONS_FILE}.tmp" "$EXCLUSIONS_FILE"
}

manage_exclusions() {
    while true; do
        echo ""
        echo -e "${BOLD}  Manage permanent exclusions:${RESET}"
        local midx=1
        for pname in "${ALL_PROFILES[@]}"; do
            local prefs="$CHROME_DIR/$pname/Preferences"
            local dname=""
            [[ -f "$prefs" ]] && dname=$(python3 - "$prefs" <<'PYNAME'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('profile', {}).get('name', ''))
except:
    print('')
PYNAME
)
            local marker=""
            is_excluded "$pname" && marker=" ${RED}[excluded]${RESET}"
            if [[ -n "$dname" ]]; then
                echo -e "    ${BOLD}[$midx]${RESET} $pname — $dname${marker}"
            else
                echo -e "    ${BOLD}[$midx]${RESET} $pname${marker}"
            fi
            (( midx++ ))
        done
        echo -e "    ${BOLD}[D]${RESET} Done"
        echo ""
        echo -n "  Toggle exclusion for a profile number, or D when done: "
        read -r MCHOICE
        echo ""
        if [[ "$(echo "$MCHOICE" | tr '[:lower:]' '[:upper:]')" == "D" ]]; then
            break
        elif [[ "$MCHOICE" =~ ^[0-9]+$ ]] && (( MCHOICE >= 1 && MCHOICE <= ${#ALL_PROFILES[@]} )); then
            local target="${ALL_PROFILES[$MCHOICE]}"
            if is_excluded "$target"; then
                unexclude_profile "$target"
                success "  '$target' removed from permanent exclusions."
            else
                exclude_profile "$target"
                success "  '$target' permanently excluded from future syncs."
            fi
        else
            warn "  Invalid choice: '$MCHOICE'"
        fi
    done
}

# ── Python conversion script (written inline) ───────────────
PYTHON_SCRIPT=$(cat <<'PYEOF'
import sys, json, plistlib, time, hashlib

def uid(s):
    """Generate a stable numeric-ish ID from a string."""
    return int(hashlib.md5(s.encode()).hexdigest()[:12], 16)

def epoch_to_webkit(epoch_secs):
    """Convert Unix timestamp to WebKit/Chrome microseconds."""
    # Chrome epoch: Jan 1 1601  Unix epoch: Jan 1 1970
    DELTA = 11644473600  # seconds between the two epochs
    return str(int((epoch_secs + DELTA) * 1_000_000))

def now_webkit():
    return epoch_to_webkit(time.time())

def convert_node(node):
    """Recursively convert a Safari bookmark node to Chrome format."""
    kind = node.get("WebBookmarkType", "")

    # ── Folder ──────────────────────────────────────────────
    if kind == "WebBookmarkTypeList":
        title = node.get("Title", "Imported from Safari")
        children_raw = node.get("Children", [])
        children = [c for c in (convert_node(n) for n in children_raw) if c]
        ts = now_webkit()
        return {
            "children": children,
            "date_added": ts,
            "date_last_used": "0",
            "date_modified": ts,
            "guid": hashlib.md5((title + ts).encode()).hexdigest(),
            "id": str(uid(title + ts)),
            "name": title,
            "type": "folder"
        }

    # ── Leaf / URL ───────────────────────────────────────────
    if kind == "WebBookmarkTypeLeaf":
        url = node.get("URLString", "")
        if not url:
            return None
        uri_dict = node.get("URIDictionary", {})
        title = uri_dict.get("title", url)
        ts = now_webkit()
        return {
            "date_added": ts,
            "date_last_used": "0",
            "guid": hashlib.md5((url + ts).encode()).hexdigest(),
            "id": str(uid(url + ts)),
            "name": title,
            "type": "url",
            "url": url
        }

    return None  # skip unknown types

def main(plist_path, out_path):
    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)

    root_children = plist.get("Children", [])

    # Safari's top-level folders: BookmarksBar, BookmarksMenu, etc.
    bar_children  = []
    other_children = []

    for node in root_children:
        title = node.get("Title", "")
        if title == "BookmarksBar":
            bar_children = [c for c in
                            (convert_node(n) for n in node.get("Children", []))
                            if c]
        elif title in ("BookmarksMenu", "com.apple.ReadingList"):
            pass  # skip Reading List
        else:
            converted = convert_node(node)
            if converted:
                other_children.append(converted)

    ts = now_webkit()

    chrome_bookmarks = {
        "checksum": "",
        "roots": {
            "bookmark_bar": {
                "children": bar_children,
                "date_added": ts,
                "date_last_used": "0",
                "date_modified": ts,
                "guid": "0bc5d13f-2cba-5d74-951f-3f233fe6c908",
                "id": "1",
                "name": "Bookmarks bar",
                "type": "folder"
            },
            "other": {
                "children": other_children,
                "date_added": ts,
                "date_last_used": "0",
                "date_modified": ts,
                "guid": "82b081ec-3dd3-529c-8475-ab6c344590bf",
                "id": "2",
                "name": "Other bookmarks",
                "type": "folder"
            },
            "synced": {
                "children": [],
                "date_added": ts,
                "date_last_used": "0",
                "date_modified": ts,
                "guid": "4cf2e351-0e85-532b-bb37-df045d8f8d0f",
                "id": "3",
                "name": "Mobile bookmarks",
                "type": "folder"
            }
        },
        "version": 1
    }

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(chrome_bookmarks, f, ensure_ascii=False, indent=2)

    print(f"Converted bookmarks written to: {out_path}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
PYEOF
)

# ── Step 1: Sanity checks ────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo -e "${BOLD}   Safari → Chrome Bookmark Sync          ${RESET}"
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo ""

if [[ ! -f "$SAFARI_PLIST" ]]; then
    error "Safari bookmarks not found at: $SAFARI_PLIST"
    error "Make sure Safari has been opened at least once."
    exit 1
fi
success "Found Safari bookmarks: $SAFARI_PLIST"

if [[ ! -d "$CHROME_DIR" ]]; then
    error "Chrome user data directory not found at: $CHROME_DIR"
    error "Make sure Google Chrome is installed."
    exit 1
fi
success "Found Chrome directory: $CHROME_DIR"

# ── Step 2: Quit Chrome if running ──────────────────────────
if pgrep -x "Google Chrome" &>/dev/null; then
    warn "Chrome is running — quitting it now…"
    osascript -e 'quit app "Google Chrome"'
    sleep 2
    # Force-kill if it didn't quit cleanly
    if pgrep -x "Google Chrome" &>/dev/null; then
        warn "Force-killing Chrome…"
        pkill -x "Google Chrome" || true
        sleep 1
    fi
    success "Chrome has been quit."
else
    info "Chrome is not running — no need to quit."
fi

# ── Step 3: Convert Safari plist → JSON ─────────────────────
info "Converting Safari bookmarks to Chrome JSON format…"
echo "$PYTHON_SCRIPT" | python3 - "$SAFARI_PLIST" "$TMP_JSON"
success "Conversion complete."

# ── Step 4: Discover Chrome profiles ────────────────────────
info "Scanning for Chrome profiles…"
ALL_PROFILES=()

# Default profile
if [[ -d "$CHROME_DIR/Default" ]]; then
    ALL_PROFILES+=("Default")
fi

# Numbered profiles: Profile 1, Profile 2, …
while IFS= read -r -d '' dir; do
    base=$(basename "$dir")
    ALL_PROFILES+=("$base")
done < <(find "$CHROME_DIR" -maxdepth 1 -type d -name "Profile *" -print0 | sort -z)

if [[ ${#ALL_PROFILES[@]} -eq 0 ]]; then
    error "No Chrome profiles found inside $CHROME_DIR"
    exit 1
fi

# ── Step 4b: Let the user pick which profiles to sync ────────
while true; do
    echo ""
    echo -e "${BOLD}  Available Chrome profiles:${RESET}"
    local_idx=1
    for profile_name in "${ALL_PROFILES[@]}"; do
        # Try to read the profile's display name from Preferences JSON
        prefs="$CHROME_DIR/$profile_name/Preferences"
        if [[ -f "$prefs" ]]; then
            display_name=$(python3 - "$prefs" <<'PYNAME'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('profile', {}).get('name', ''))
except:
    print('')
PYNAME
)
        else
            display_name=""
        fi

        excl_marker=""
        is_excluded "$profile_name" && excl_marker=" ${RED}[excluded]${RESET}"

        if [[ -n "$display_name" ]]; then
            echo -e "    ${BOLD}[${local_idx}]${RESET} ${profile_name} — $display_name${excl_marker}"
        else
            echo -e "    ${BOLD}[${local_idx}]${RESET} ${profile_name}${excl_marker}"
        fi
        (( local_idx++ ))
    done
    echo -e "    ${BOLD}[A]${RESET} All profiles (skips excluded)"
    echo -e "    ${BOLD}[X]${RESET} Manage permanent exclusions"
    echo ""
    echo -n "  Enter numbers separated by spaces (e.g. 1 3), A for all, or X to manage exclusions: "
    read -r SELECTION
    echo ""

    if [[ "$(echo "$SELECTION" | tr '[:lower:]' '[:upper:]')" == "X" ]]; then
        manage_exclusions
        continue
    fi
    break
done

PROFILES=()
if [[ "$(echo "$SELECTION" | tr '[:lower:]' '[:upper:]')" == "A" ]]; then
    for p in "${ALL_PROFILES[@]}"; do
        is_excluded "$p" || PROFILES+=("$p")
    done
    info "Syncing ${#PROFILES[@]} profile(s) (excluded profiles skipped)."
else
    for token in ${=SELECTION}; do
        if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#ALL_PROFILES[@]} )); then
            PROFILES+=("${ALL_PROFILES[$token]}")  # zsh arrays are 1-indexed
        else
            warn "  Ignoring invalid selection: '$token'"
        fi
    done
    if [[ ${#PROFILES[@]} -eq 0 ]]; then
        error "No valid profiles selected. Aborting."
        exit 1
    fi
    info "Syncing ${#PROFILES[@]} profile(s): ${PROFILES[*]}"
fi

# ── Step 5: Back up + replace bookmarks in selected profiles ─
mkdir -p "$BACKUP_DIR"
success "Backup folder created: $BACKUP_DIR"

for profile in "${PROFILES[@]}"; do
    profile_path="$CHROME_DIR/$profile"
    bookmarks_file="$profile_path/Bookmarks"
    bak_file="$BACKUP_DIR/${profile}_Bookmarks.bak"

    echo ""
    info "Processing profile: ${BOLD}$profile${RESET}"

    # Back up existing bookmarks (if any)
    if [[ -f "$bookmarks_file" ]]; then
        cp "$bookmarks_file" "$bak_file"
        success "  Backed up → $bak_file"
    else
        warn "  No existing Bookmarks file — skipping backup."
    fi

    # Also remove the Bookmarks.bak Chrome keeps internally
    if [[ -f "$bookmarks_file.bak" ]]; then
        rm -f "$bookmarks_file.bak"
    fi

    # Write new bookmarks
    cp "$TMP_JSON" "$bookmarks_file"
    success "  Replaced bookmarks with Safari import."
done

# ── Step 6: Cleanup ─────────────────────────────────────────
rm -f "$TMP_JSON"

echo ""
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
success "All done! Safari bookmarks synced to: ${PROFILES[*]}"
info   "Your old Chrome bookmarks are backed up on your Desktop:"
info   "  $BACKUP_DIR"
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${YELLOW}Tip:${RESET} Open Chrome → chrome://bookmarks to verify."
echo ""