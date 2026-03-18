#!/bin/bash
# Line 1: <model>                        | current: <progressbar> X% / totalTokens
# Line 2: effor: <effortLevel>        | hoursly: <progressbar> X% resets <time>
# Line 3: <current_dir>                  | weekly: <progressbar> X% resets <datetime>
# Line 4: <git_branch>                   (optional, omitted if not in a git repo)
#
# Usage API calls are cached for 600s (10 min) in /tmp/claude/statusline-usage-cache.json

set -f  # disable globbing

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ═══ CONSTANTS ═══

readonly blue='\033[38;2;0;153;255m'
readonly orange='\033[38;2;255;176;85m'
readonly green='\033[38;2;0;160;0m'
readonly cyan='\033[38;2;46;149;153m'
readonly red='\033[38;2;255;85;85m'
readonly yellow='\033[38;2;230;200;0m'
readonly amber='\033[38;2;210;140;50m'
readonly white='\033[38;2;220;220;220m'
readonly dim='\033[2m'
readonly reset='\033[0m'

readonly bar_filled="●"
readonly bar_empty="○"

readonly col0_width=50
readonly bar_width=10
readonly cache_max_age=600  # seconds between API calls

readonly cache_file="/tmp/claude/statusline-usage-cache.json"
readonly settings_path="$HOME/.claude/settings.json"
readonly sep=" ${dim}│${reset} "

# ═══ HELPERS ═══

format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Usage: build_bar <pct> <width>
build_bar() {
    local pct=$1
    local width=$2
    pct=$(( 10#$pct ))  # force base 10 (évite l'interprétation octale de "08", "09")
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    local bar_color
    if [ "$pct" -ge 90 ]; then bar_color="$red"
    elif [ "$pct" -ge 70 ]; then bar_color="$yellow"
    elif [ "$pct" -ge 50 ]; then bar_color="$orange"
    else bar_color="$green"
    fi

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="$bar_filled"; done
    for ((i=0; i<empty; i++)); do empty_str+="$bar_empty"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

# Usage: pad_column <text_with_ansi> <visible_length> <column_width>
pad_column() {
    local text="$1"
    local visible_len=$2
    local col_width=$3
    local padding=$(( col_width - visible_len ))
    if [ "$padding" -gt 0 ]; then
        printf "%s%*s" "$text" "$padding" ""
    else
        printf "%s" "$text"
    fi
}

# Tries credential sources in order: env var → macOS Keychain → Linux creds file → GNOME Keyring
get_oauth_token() {
    local token=""

    # 1. Explicit env var override
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    # 2. macOS Keychain
    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    # 3. Linux credentials file
    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    # 4. GNOME Keyring via secret-tool (Linux)
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    echo ""
}

# Converts ISO 8601 timestamp to epoch seconds (cross-platform: GNU date + BSD date)
iso_to_epoch() {
    local iso_str="$1"

    # GNU date (Linux) handles ISO 8601 automatically
    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    # BSD date (macOS) — strip fractional seconds and timezone
    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# Usage: format_reset_time <iso_string> <style: time|datetime|date>
format_reset_time() {
    local iso_str="$1"
    local style="$2"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return

    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    # BSD date first, then GNU date
    local result
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%H:%M" 2>/dev/null)
            if [ -n "$result" ]; then
                echo "$result"
            else
                date -d "@$epoch" +"à %H:%M" 2>/dev/null
            fi
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %H:%M" 2>/dev/null)
            if [ -n "$result" ]; then
                echo "$result" | sed 's/  / /g; s/^ //' | tr '[:upper:]' '[:lower:]'
            else
                LC_TIME=fr_FR.UTF-8 date -d "@$epoch" +"%a %-d %B à %H:%M" 2>/dev/null
            fi
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            if [ -n "$result" ]; then
                echo "$result" | tr '[:upper:]' '[:lower:]'
            else
                date -d "@$epoch" +"%b %-d" 2>/dev/null
            fi
            ;;
    esac
}

# Usage: build_col0_field <label> <value> <color> [truncate: end|start]
# label: exactement 6 caractères visibles (e.g. " model", "effort", "   dir", "branch")
# truncate: "end" (défaut) garde le début + "…", "start" garde la fin + "…" au début
build_col0_field() {
    local label="$1" value="$2" color="$3" truncate="${4:-end}"
    local prefix_width=$(( ${#label} + 2 ))  # label + ':' + ' '
    local max_value_len=$(( col0_width - prefix_width ))
    if [ "${#value}" -gt "$max_value_len" ]; then
        if [ "$truncate" = "start" ]; then
            value="…${value: -$(( max_value_len - 1 ))}"
        else
            value="${value:0:$(( max_value_len - 1 ))}…"
        fi
    fi
    pad_column "${white}${label}:${reset} ${color}${value}${reset}" "$(( prefix_width + ${#value} ))" "$col0_width"
}

# Usage: build_col0_effort <effort_level> [cost_usd]
build_col0_effort() {
    local effort_level="$1" cost_usd="$2" color value
    case "$effort_level" in
        high)   color="$orange" ;;
        medium) color="$cyan"   ;;
        low)    color="$dim"    ;;
        auto|?) color="$blue"   ;;
        *)      color="$dim"    ;;
    esac
    value="$effort_level"
    if [ -n "$cost_usd" ] && [ "$cost_usd" != "null" ] && [ "$cost_usd" != "0" ]; then
        local cost_fmt
        cost_fmt=$(awk "BEGIN {printf \"%.3f\", $cost_usd}")
        value="${value}, cost: \$${cost_fmt}"
    fi
    build_col0_field "effort" "$value" "$color"
}

# Loads usage data from cache or API. Sets global $usage_data.
fetch_usage_data() {
    mkdir -p /tmp/claude
    usage_data=""

    if [ -f "$cache_file" ]; then
        local cache_mtime now cache_age
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        now=$(date +%s)
        cache_age=$(( now - cache_mtime ))
        if [ "$cache_age" -lt "$cache_max_age" ]; then
            usage_data=$(cat "$cache_file" 2>/dev/null)
            return
        fi
    fi

    local token
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        local response
        response=$(curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq . >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "$cache_file"
            return
        fi
    fi

    # Fall back to stale cache
    if [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
}

# ═══ MAIN ═══

main() {
    # ── Parse input ──
    local model_name size input_tokens cache_create cache_read current
    model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
    size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
    [ "$size" -eq 0 ] 2>/dev/null && size=200000
    input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
    cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
    cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
    current=$(( input_tokens + cache_create + cache_read ))

    local pct_used total_tokens
    total_tokens=$(format_tokens "$size")
    if [ "$size" -gt 0 ]; then
        pct_used=$(printf "%02d" $(( current * 100 / size )))
    else
        pct_used="00"
    fi

    local effort_level="?"
    local thinking_on=false
    if [ -f "$settings_path" ]; then
        effort_level=$(jq -r '.effortLevel // "?"' "$settings_path" 2>/dev/null)
        local thinking_val
        thinking_val=$(jq -r '.alwaysThinkingEnabled // false' "$settings_path" 2>/dev/null)
        [ "$thinking_val" = "true" ] && thinking_on=true
    fi

    local cwd display_cwd git_branch
    cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty')
    [ -z "$cwd" ] && cwd=$(pwd)
    display_cwd="${cwd/#$HOME/\~}"
    git_branch=$(git -C "$cwd" branch --show-current 2>/dev/null)

    # Git dirty state
    local git_staged=0 git_modified=0 git_untracked=0
    local git_ahead=0 git_behind=0 git_stash=0 git_pr_state="" git_pr_number=""
    if [ -n "$git_branch" ]; then
        git_staged=$(git -C "$cwd" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
        git_modified=$(git -C "$cwd" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
        git_untracked=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
        git_stash=$(git -C "$cwd" stash list 2>/dev/null | wc -l | tr -d ' ')

        # Ahead/behind remote
        local ab
        ab=$(git -C "$cwd" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)
        if [ -n "$ab" ]; then
            git_ahead=$(echo "$ab" | awk '{print $1}')
            git_behind=$(echo "$ab" | awk '{print $2}')
        fi

        # PR status (cached per branch, 60s TTL)
        if command -v gh >/dev/null 2>&1; then
            local branch_hash pr_cache_file pr_cache_max_age=60
            branch_hash=$(echo "$git_branch" | md5 2>/dev/null || echo "$git_branch" | md5sum 2>/dev/null | awk '{print $1}')
            pr_cache_file="/tmp/claude/pr-${branch_hash}.json"
            local needs_pr_refresh=true
            if [ -f "$pr_cache_file" ]; then
                local pr_mtime pr_age
                pr_mtime=$(stat -f %m "$pr_cache_file" 2>/dev/null || stat -c %Y "$pr_cache_file" 2>/dev/null)
                pr_age=$(( $(date +%s) - pr_mtime ))
                [ "$pr_age" -lt "$pr_cache_max_age" ] && needs_pr_refresh=false
            fi
            if $needs_pr_refresh; then
                gh pr view --json state,number 2>/dev/null > "$pr_cache_file" || rm -f "$pr_cache_file"
            fi
            if [ -f "$pr_cache_file" ]; then
                git_pr_state=$(jq -r '.state // empty' "$pr_cache_file" 2>/dev/null)
                git_pr_number=$(jq -r '.number // empty' "$pr_cache_file" 2>/dev/null)
            fi
        fi
    fi

    # ── Fetch usage ──
    fetch_usage_data

    # ── Build lines ──
    local col0_model col0_effort col0_cwd col0_branch
    col0_model=$(build_col0_field " model" "$model_name" "$blue")
    local cost_usd
    cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
    col0_effort=$(build_col0_effort "$effort_level" "$cost_usd")
    col0_cwd=$(build_col0_field "   dir" "$display_cwd" "$amber" "start")
    if [ -n "$git_pr_number" ]; then
        local pr_state_color="$dim"
        case "$git_pr_state" in
            OPEN)   pr_state_color="$green" ;;
            MERGED) pr_state_color="$cyan"  ;;
            CLOSED) pr_state_color="$red"   ;;
        esac
        # Build branch label manually to keep correct visible-length for padding
        local label="branch" prefix_width=$(( 6 + 2 ))  # "branch": 6 chars + ':' + ' '
        local pr_suffix=" #${git_pr_number}"
        local max_value_len=$(( col0_width - prefix_width ))
        local branch_val="$git_branch"
        local visible_len=$(( ${#branch_val} + ${#pr_suffix} ))
        if [ "$visible_len" -gt "$max_value_len" ]; then
            local trim=$(( max_value_len - ${#pr_suffix} - 1 ))
            branch_val="${branch_val:0:$trim}…"
            visible_len=$(( ${#branch_val} + ${#pr_suffix} ))
        fi
        local colored_branch="${white}${label}:${reset} ${amber}${branch_val}${reset} ${pr_state_color}#${git_pr_number}${reset}"
        col0_branch=$(pad_column "$colored_branch" "$(( prefix_width + visible_len ))" "$col0_width")
    else
        col0_branch=$(build_col0_field "branch" "$git_branch" "$amber")
    fi

    local ctx_bar ctx_text
    ctx_bar=$(build_bar "$pct_used" "$bar_width")
    local thinking_label thinking_color
    if $thinking_on; then thinking_label="on"; thinking_color="$orange"
    else thinking_label="off"; thinking_color="$dim"
    fi
    # Session duration
    local session_duration=""
    local session_file="/tmp/claude/session-start"
    if [ -f "$session_file" ]; then
        local session_start elapsed
        session_start=$(cat "$session_file" 2>/dev/null)
        elapsed=$(( $(date +%s) - session_start ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi

    ctx_text="${white}current:${reset} ${ctx_bar} ${cyan}${pct_used}%${reset} ${dim}/${reset} ${orange}${total_tokens}${reset} ${dim}|${reset} ${white}thinking:${reset} ${thinking_color}${thinking_label}${reset}"
    [ -n "$session_duration" ] && ctx_text+=" ${dim}|${reset} ${white}session:${reset} ${cyan}${session_duration}${reset}"

    # Git columns for line4
    local git_dirty_text="" git_remote_text=""
    if [ -n "$git_branch" ]; then
        # col1 — local changes
        local dirty_parts=""
        [ "$git_staged" -gt 0 ]    && dirty_parts+="${green}+${git_staged}${reset} "
        [ "$git_modified" -gt 0 ]  && dirty_parts+="${orange}~${git_modified}${reset} "
        [ "$git_untracked" -gt 0 ] && dirty_parts+="${dim}?${git_untracked}${reset} "
        if [ -z "$dirty_parts" ]; then
            git_dirty_text="${white}changes:${reset} ${dim}clean${reset}"
        else
            git_dirty_text="${white}changes:${reset} ${dirty_parts}"
        fi

        # col2 — remote info (ahead/behind, stash, PR)
        local remote_parts=""
        [ "$git_ahead" -gt 0 ]  && remote_parts+="${green}↑${git_ahead}${reset} "
        [ "$git_behind" -gt 0 ] && remote_parts+="${orange}↓${git_behind}${reset} "
        [ "$git_stash" -gt 0 ]  && remote_parts+="${dim}stash:${reset} ${cyan}${git_stash}${reset} "
        git_remote_text="$remote_parts"
    fi

    local line1 line2 line3 line4
    line1="${col0_model}${sep}${ctx_text}"
    line2="${col0_effort}${sep}"
    line3="${col0_cwd}${sep}"
    line4="${col0_branch}${sep}${git_dirty_text}${sep}${git_remote_text}"

    if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
        local five_hour_pct five_hour_reset_iso five_hour_reset five_hour_bar
        five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%02.0f", $1}')
        five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
        five_hour_reset=$(format_reset_time "$five_hour_reset_iso" "time")
        five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")

        local seven_day_pct seven_day_reset_iso seven_day_reset seven_day_bar
        seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%02.0f", $1}')
        seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
        seven_day_reset=$(format_reset_time "$seven_day_reset_iso" "datetime")
        seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")

        line2+="${white}hourly:${reset} ${five_hour_bar} ${cyan}${five_hour_pct}%${reset} ${white}resets ${five_hour_reset}${reset}"
        if [ -n "$cost_usd" ] && [ "$cost_usd" != "null" ] && [ "$cost_usd" != "0" ]; then
            local cost_fmt
            cost_fmt=$(awk "BEGIN {printf \"%.3f\", $cost_usd}")
            line2+=" ${dim}|${reset} ${white}cost:${reset} ${orange}\$${cost_fmt}${reset}"
        fi
        line3+=" ${white}weekly:${reset} ${seven_day_bar} ${cyan}${seven_day_pct}%${reset} ${white}resets ${seven_day_reset}${reset}"

        # Extra usage (line5, only if enabled)
        local extra_enabled
        extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
        if [ "$extra_enabled" = "true" ]; then
            local extra_pct extra_used extra_limit extra_bar extra_reset_str
            extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%02.0f", $1}')
            extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
            extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
            extra_bar=$(build_bar "$extra_pct" "$bar_width")
            extra_reset_str=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]' \
                || date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null)
            local col0_extra
            col0_extra=$(build_col0_field " extra" "credits" "$cyan")
            line5="${col0_extra}${sep}${white}extra:${reset} ${extra_bar} ${cyan}${extra_pct}%${reset} ${dim}\$${extra_used}/\$${extra_limit}${reset} ${white}resets ${extra_reset_str}${reset}"
        fi
    fi

    # ── Print lines ──
    local line5=""
    printf "%b" "$line1"
    printf "\n%b" "$line2"
    printf "\n%b" "$line3"
    [ -n "$git_branch" ] && printf "\n%b" "$line4"
    [ -n "$line5" ] && printf "\n%b" "$line5"
    printf "\n"
    return 0
}

main
