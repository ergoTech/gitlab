#!/bin/bash
# registry-prune-tags.sh on a synthetic registry storage tree: which tags it
# untags, which it never touches, and how it fails — including that it refuses
# to run once the registry keeps its metadata in the database.
set -u
. /t/lib.sh || exit 2
S=/s

R=$(mktemp -d)/docker/registry/v2/repositories
mk() { # repo tag age_days
    local d="$R/$1/_manifests/tags/$2/current"
    mkdir -p "$d" "$R/$1/_manifests/tags/$2/index/sha256/abc"
    echo "sha256:deadbeef" >"$d/link"
    touch -d "@$(( $(date +%s) - $3 * 86400 ))" "$d/link"
}
# backend/core: 15 sha tags aged 1..15*3 days, plus named tags, all old
for i in $(seq 1 15); do mk backend/core "$(printf 'a%07x' "$i")" $((i * 3)); done
mk backend/core latest 100
mk backend/core master 100
mk backend/core v1.2.3 100
mk backend/core calendar.3 100
mk backend/core 1234567 100      # 7 hex chars: not a sha tag here
mk backend/core abcdef012 100    # 9 hex chars
mk backend/core ABCDEF01 100     # upper case
# nested repo
for i in $(seq 1 12); do mk backend/core/backoffice "$(printf 'b%07x' "$i")" $((i * 10)); done
# repo with few tags
mk frontend/site c0000001 300
mk frontend/site c0000002 200
# _layers noise that must not be walked as a repo
mkdir -p "$R/backend/core/_layers/sha256/x/_manifests"

out=$(REGISTRY_REPOS="$R" bash $S/registry-prune-tags.sh --dry-run 2>&1); rc=$?
check '[ $rc -eq 0 ]' "dry-run exit 0"
check '[ $(find $R -path "*/_manifests/tags/*" -maxdepth 6 -name current | wc -l) -gt 0 ] && [ -d $R/backend/core/_manifests/tags/a000000f ]' "dry-run removed nothing"
[ -z "${VERBOSE:-}" ] || echo "$out" | tail -4

REGISTRY_REPOS="$R" bash $S/registry-prune-tags.sh >/dev/null; rc=$?
check '[ $rc -eq 0 ]' "real run exit 0"
T=$R/backend/core/_manifests/tags
# core: ages 3,6,...45. newest 10 = ages 3..30 kept. older than 14d among rest: 33..45 -> removed (i=11..15)
for i in $(seq 1 10); do check "[ -d $T/$(printf 'a%07x' $i) ]" "core keeps newest #$i"; done
for i in $(seq 11 15); do check "[ ! -e $T/$(printf 'a%07x' $i) ]" "core untags old #$i"; done
for t in latest master v1.2.3 calendar.3 1234567 abcdef012 ABCDEF01; do check "[ -d $T/$t ]" "core keeps named $t"; done
B=$R/backend/core/backoffice/_manifests/tags
for i in $(seq 1 10); do check "[ -d $B/$(printf 'b%07x' $i) ]" "nested keeps #$i"; done
for i in 11 12; do check "[ ! -e $B/$(printf 'b%07x' $i) ]" "nested untags #$i"; done
check "[ -d $R/frontend/site/_manifests/tags/c0000001 ] && [ -d $R/frontend/site/_manifests/tags/c0000002 ]" "keep_n protects small repo"
check "[ -d $R/backend/core/_layers/sha256/x/_manifests ]" "_layers untouched"

# retention days protects young tags beyond keep_n
R2=$(mktemp -d)/docker/registry/v2/repositories
for i in $(seq 1 5); do d=$R2/p/_manifests/tags/$(printf 'd%07x' $i)/current; mkdir -p $d; echo x>$d/link; touch -d "@$(( $(date +%s) - i*3600 ))" $d/link; done
REGISTRY_REPOS="$R2" REGISTRY_TAG_KEEP_N=1 bash $S/registry-prune-tags.sh >/dev/null; check "[ \$(ls $R2/p/_manifests/tags | wc -l) -eq 5 ]" "young tags kept beyond keep_n"
REGISTRY_REPOS="$R2" REGISTRY_TAG_KEEP_N=0 REGISTRY_TAG_RETENTION_DAYS=1 bash $S/registry-prune-tags.sh >/dev/null; check "[ \$(ls $R2/p/_manifests/tags | wc -l) -eq 5 ]" "all younger than 1 day kept"

# bad inputs
REGISTRY_REPOS=/nonexistent bash $S/registry-prune-tags.sh >/dev/null 2>&1; check '[ $? -eq 1 ]' "missing path -> 1"
E=$(mktemp -d)/docker/registry/v2/repositories; mkdir -p $E; REGISTRY_REPOS=$E bash $S/registry-prune-tags.sh >/dev/null 2>&1; check '[ $? -eq 1 ]' "no repos -> 1"
REGISTRY_REPOS="$R" REGISTRY_TAG_RETENTION_DAYS=14d bash $S/registry-prune-tags.sh >/dev/null 2>&1; check '[ $? -eq 2 ]' "14d rejected"
REGISTRY_REPOS="$R" REGISTRY_TAG_RETENTION_DAYS=0 bash $S/registry-prune-tags.sh >/dev/null 2>&1; check '[ $? -eq 2 ]' "0 days rejected"
REGISTRY_REPOS="$R" REGISTRY_TAG_KEEP_N=08 bash $S/registry-prune-tags.sh --dry-run >/dev/null 2>&1; check '[ $? -eq 0 ]' "leading zero ok"
bash $S/registry-prune-tags.sh --bogus >/dev/null 2>&1; check '[ $? -eq 2 ]' "unknown arg -> 2"
bash $S/registry-prune-tags.sh --help | grep -q "dry-run"; check '[ $? -eq 0 ]' "help prints usage"

# removal failure is reported (read-only dir)
T3=$(mktemp -d); R3=$T3/docker/registry/v2/repositories; for i in $(seq 1 3); do d=$R3/p/_manifests/tags/$(printf 'e%07x' $i)/current; mkdir -p $d; echo x>$d/link; touch -d "@$(( $(date +%s) - (i+20)*86400 ))" $d/link; done
chmod -R a+rX "$T3"; chmod 555 $R3/p/_manifests/tags
su nobody -s /bin/bash -c "REGISTRY_REPOS=$R3 REGISTRY_TAG_KEEP_N=1 bash $S/registry-prune-tags.sh" >/dev/null 2>&1; check '[ $? -eq 1 ]' "rm failure -> exit 1"

# only the whole repositories tree, so the lockfile check looks in the right place
REGISTRY_REPOS="$R/backend" bash $S/registry-prune-tags.sh --dry-run >/dev/null 2>&1; check '[ $? -eq 2 ]' "a subtree -> 2"
REGISTRY_REPOS="$R/" bash $S/registry-prune-tags.sh --dry-run >/dev/null 2>&1; check '[ $? -eq 0 ]' "trailing slash accepted"

# after the import: database-in-use next to v2/ -> refuses, removes nothing
R4=$(mktemp -d)/docker/registry/v2/repositories
for i in $(seq 1 3); do d=$R4/p/_manifests/tags/$(printf 'f%07x' $i)/current; mkdir -p $d; echo x>$d/link; touch -d "@$(( $(date +%s) - (i+20)*86400 ))" $d/link; done
mkdir -p "$R4/../../lockfiles"; echo '{"version":1}' >"$R4/../../lockfiles/database-in-use"
out=$(REGISTRY_REPOS="$R4" REGISTRY_TAG_KEEP_N=1 bash $S/registry-prune-tags.sh 2>&1); rc=$?
check '[ $rc -eq 1 ] && [ $(ls $R4/p/_manifests/tags | wc -l) -eq 3 ] && echo "$out" | grep -q "uses its metadata database"' "database-in-use -> 1, nothing untagged"
REGISTRY_REPOS="$R4/" bash $S/registry-prune-tags.sh --dry-run >/dev/null 2>&1; check '[ $? -eq 1 ]' "database-in-use, trailing slash, dry run -> still 1"

finish registry-prune-tags
