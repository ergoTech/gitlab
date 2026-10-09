#!/bin/bash
# Run the tests for scripts/: every tests/test-*.sh, each in a fresh container
# of the image in tests/Dockerfile, with scripts/ mounted read-only and no
# network. Nothing runs on this machine itself, so the tests are free to stub
# docker and df, trust a throwaway CA and write all over /tmp. Needs Docker;
# the scripts need GNU tools a Mac does not have, so they cannot run here
# directly anyway.
#
# Usage: ./tests/run.sh [test-name.sh ...]   (default: all of them)
#        VERBOSE=1 ./tests/run.sh            also lists the checks that pass

set -euo pipefail

cd "$(dirname "$0")/.."
image=gitlab-infra-tests
docker build -q -t "$image" tests >/dev/null

if [ $# -eq 0 ]; then
    set -- tests/test-*.sh
fi
failed=0
for t in "$@"; do
    name=$(basename "$t")
    echo "=== $name"
    docker run --rm --network none -e VERBOSE -v "$PWD/scripts:/s:ro" -v "$PWD/tests:/t:ro" "$image" bash "/t/$name" || failed=1
done
exit "$failed"
