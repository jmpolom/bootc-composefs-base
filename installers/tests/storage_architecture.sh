#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
storage=$root/installers/lib/storage.sh
common=$root/installers/lib/common.sh
state=$root/installers/lib/state.sh

# Count logical commands rather than physical lines. Case terminators and the
# separators introducing then/do/fi/etc. are shell grammar, not commands; other
# semicolons still count, so compound-line packing cannot lower the metric.
# Complexity counts control keywords and short-circuit operators as decisions.
measure_functions() {
    awk '
    function emit(    ) {
        if (function_name != "") {
            function_count++
            executable_total += executable
            complexity_total += complexity
            if (executable > max_executable) {
                max_executable = executable; max_executable_name = function_name
            }
            if (complexity > max_complexity) {
                max_complexity = complexity; max_complexity_name = function_name
            }
        }
    }
    function count_line(line,    n,i,word) {
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line == "" || line ~ /^#/ || line ~ /^(then|do|done|fi|else|elif|esac)[[:space:]]*;?[[:space:]]*$/) return
        gsub(/;;/, "", line)
        gsub(/;[[:space:]]*(then|do|done|fi|else|elif|esac)([[:space:]]|$)/, " ", line)
        executable += 1 + gsub(/;/, ";", line)
        gsub(/&&/, " && ", line); gsub(/\|\|/, " || ", line)
        gsub(/[^[:alnum:]_&|]+/, " ", line)
        n = split(line, words, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
            word = words[i]
            if (word == "if" || word == "elif" || word == "for" ||
                word == "while" || word == "until" || word == "case" ||
                word == "&&" || word == "||") complexity++
        }
    }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ {
        emit(); function_name = $1; executable = 0; complexity = 0; next
    }
    function_name != "" {
        if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) { emit(); function_name = ""; next }
        count_line($0)
    }
    END {
        emit()
        printf "%d %d %d %d %s %s %d\n", executable_total, complexity_total,
            max_executable, max_complexity, max_executable_name, max_complexity_name,
            function_count
    }' "$1"
}

print_metrics() {
    local label=$1 path=$2 physical metrics executable aggregate max_loc max_cc max_loc_name max_cc_name functions
    physical=$(wc -l <"$path")
    metrics=$(measure_functions "$path")
    read -r executable aggregate max_loc max_cc max_loc_name max_cc_name functions <<< "$metrics"
    printf '%s: physical=%s executable=%s aggregate_cc=%s max_function_loc=%s(%s) max_function_cc=%s(%s) functions=%s\n' \
        "$label" "$physical" "$executable" "$aggregate" "$max_loc" "$max_loc_name" \
        "$max_cc" "$max_cc_name" "$functions"
}

physical=$(wc -l <"$storage")
if rg -n 'declare -[ag]*[[:space:]]+vol_[a-zA-Z0-9_]+\[' "$storage" "$common" "$state" >/dev/null; then exit 1; fi
legacy_prefix='ext''_vol_'
if rg -n "$legacy_prefix" "$root/installers" "$root/test-configs" --glob '!qemu-test*/**' >/dev/null; then exit 1; fi
forbidden_device_key='parent''_disk'
if rg -n "$forbidden_device_key" "$root/installers" "$root/test-configs" --glob '!qemu-test*/**' >/dev/null; then exit 1; fi
for suffix in role public_index backing_index partition_index; do
    if rg -n "vol_${suffix}" "$storage" "$common" "$state" >/dev/null; then exit 1; fi
done
for field in mountpoint fs; do
    if rg -n "vol_${field}"'\[' "$storage" "$common" "$state" >/dev/null; then exit 1; fi
done
[[ $(rg -n 'cryptsetup luksFormat' "$storage" | wc -l | tr -d ' ') == 1 ]]
[[ $(rg -n 'cryptsetup open' "$storage" | rg -v -- '--test-passphrase' | wc -l | tr -d ' ') == 1 ]]
[[ $(rg -n 'wipe-slot=password' "$storage" | wc -l | tr -d ' ') == 1 ]]
[[ $(rg -n 'btrfs subvolume create' "$storage" | wc -l | tr -d ' ') == 1 ]]
[[ $(rg -n 'wipefs --all' "$storage" | wc -l | tr -d ' ') == 1 ]]
[[ $(rg -n 'sgdisk --zap-all' "$storage" | wc -l | tr -d ' ') == 1 ]]
[[ $(rg -n '^vol_format_filesystem' "$storage" | wc -l | tr -d ' ') == 1 ]]
for name in vol_format_filesystem vol_activate_luks vol_create_subvolume; do
    body=$(awk -v n="$name" '$0 ~ "^" n "[[:space:]]*\\(" {on=1} on{print} on && /^}/ {exit}' "$storage")
    ! grep -E 'root_|/boot|/boot/efi|separate_|/var|/state' <<<"$body" >/dev/null || { printf 'role branch in %s\n' "$name" >&2; exit 1; }
done

current_metrics=$(measure_functions "$storage")
read -r current_exec current_cc current_max_exec current_max_cc current_max_exec_name current_max_cc_name _ <<< "$current_metrics"
head_metrics=$(measure_functions <(git show HEAD:installers/lib/storage.sh))
read -r head_exec head_cc head_max_exec head_max_cc head_max_exec_name head_max_cc_name head_functions <<< "$head_metrics"
print_metrics current "$storage"
printf 'HEAD: physical=%s executable=%s aggregate_cc=%s max_function_loc=%s(%s) max_function_cc=%s(%s) functions=%s\n' \
    "$(git show HEAD:installers/lib/storage.sh | wc -l)" "$head_exec" "$head_cc" \
    "$head_max_exec" "$head_max_exec_name" "$head_max_cc" "$head_max_cc_name" "$head_functions"
whole_current=$(measure_functions <(cat "$storage" "$common" "$state"))
whole_head=$(measure_functions <(git show HEAD:installers/lib/storage.sh; git show HEAD:installers/lib/common.sh; git show HEAD:installers/lib/state.sh))
read -r whole_exec whole_cc whole_max_exec whole_max_cc whole_max_exec_name whole_max_cc_name whole_functions <<< "$whole_current"
read -r whole_head_exec whole_head_cc whole_head_max_exec whole_head_max_cc whole_head_max_exec_name whole_head_max_cc_name whole_head_functions <<< "$whole_head"
printf 'whole current: physical=%s executable=%s aggregate_cc=%s max_function_loc=%s(%s) max_function_cc=%s(%s) functions=%s\n' \
    "$(wc -l < <(cat "$storage" "$common" "$state"))" "$whole_exec" "$whole_cc" "$whole_max_exec" "$whole_max_exec_name" "$whole_max_cc" "$whole_max_cc_name" "$whole_functions"
printf 'whole HEAD: physical=storage:%s common:%s state:%s executable=%s aggregate_cc=%s max_function_loc=%s(%s) max_function_cc=%s(%s) functions=%s\n' \
    "$(git show HEAD:installers/lib/storage.sh | wc -l)" "$(git show HEAD:installers/lib/common.sh | wc -l)" "$(git show HEAD:installers/lib/state.sh | wc -l)" "$whole_head_exec" "$whole_head_cc" "$whole_head_max_exec" "$whole_head_max_exec_name" "$whole_head_max_cc" "$whole_head_max_cc_name" "$whole_head_functions"
metric_failure=false
((current_cc <= 160)) || { printf 'UNMET storage aggregate CC target: %s > 160\n' "$current_cc" >&2; metric_failure=true; }
((current_max_cc <= 18)) || { printf 'UNMET max function CC: %s > 18 (%s)\n' "$current_max_cc" "$current_max_cc_name" >&2; metric_failure=true; }
[[ $metric_failure == true ]] && exit 1
printf 'storage architecture checks passed (physical LOC=%s)\n' "$physical"
