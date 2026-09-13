#!/usr/bin/env bash
# tests/purity.sh -- spec 009 section 3.
#
# 1. No file under Core/ may touch a WoW API, ambient time or randomness.
# 2. No file anywhere may compare against a hardcoded English item class or
#    subclass string; those are localised in 3.3.5a (spec 004 section 4).

set -u
status=0

core_denylist=(
    CreateFrame UnitName UnitClass GetItemInfo SendAddonMessage SendChatMessage
    GetRaidRosterInfo GetNumRaidMembers GetLootSlotLink GetLootMethod
    GiveMasterLoot GetMasterLootCandidate GetTime "math\.random" GameTooltip print
)

for symbol in "${core_denylist[@]}"; do
    if hits=$(grep -rnE "(^|[^A-Za-z0-9_.])${symbol}[[:space:]]*\(" Core/ 2>/dev/null); then
        echo "Core purity violation: ${symbol}"
        echo "$hits"
        status=1
    fi
done

# `time` and `_G` need their own patterns: bare calls and bare reads.
if hits=$(grep -rnE "(^|[^A-Za-z0-9_.\"])time[[:space:]]*\(" Core/ 2>/dev/null); then
    echo "Core purity violation: time() -- timestamps are passed in"
    echo "$hits"
    status=1
fi
if hits=$(grep -rnE "(^|[^A-Za-z0-9_])_G([^A-Za-z0-9_]|$)" Core/ 2>/dev/null); then
    echo "Core purity violation: _G"
    echo "$hits"
    status=1
fi

# Localised item class and subclass names. Comparing against these breaks on any
# non-English client, silently.
locale_strings=(
    "Cloth" "Leather" "Mail" "Plate" "Shields" "Librams" "Idols" "Totems" "Sigils"
    "One-Handed Swords" "Two-Handed Swords" "One-Handed Axes" "Two-Handed Axes"
    "One-Handed Maces" "Two-Handed Maces" "Daggers" "Fist Weapons" "Polearms"
    "Staves" "Bows" "Crossbows" "Guns" "Wands" "Thrown"
    "Armor" "Weapon" "Miscellaneous"
)

for phrase in "${locale_strings[@]}"; do
    if hits=$(grep -rn --include='*.lua' --exclude-dir=Libs --exclude-dir=tests "\"${phrase}\"" . 2>/dev/null); then
        echo "Hardcoded localised item-class string: \"${phrase}\""
        echo "$hits"
        status=1
    fi
done

# A global read of a one- or two-letter lowercase name is almost always a stray
# quote inside a format string: `"but "%s" is"` parses as `"but " % s(" is")`.
if command -v luac >/dev/null 2>&1; then
    while IFS= read -r file; do
        if hits=$(luac -l -p "$file" | grep -E 'GETGLOBAL' | awk '{print $NF}' \
                | grep -xE '[a-z]{1,2}'); then
            echo "Suspicious global read in ${file}: $(echo "$hits" | sort -u | tr '\n' ' ')"
            status=1
        fi
    done < <(find Core Modules UI Data RaidLootSystem.lua -name '*.lua')
fi

if [ "$status" -eq 0 ]; then
    echo "purity and locale checks passed"
fi
exit "$status"
