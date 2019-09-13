#!/bin/bash

failed=0

for f in *.in; do
    name=$(echo $f | cut -f1 -d.)
    tmp=$(echo $f | cut -f2 -d.)
    if [ "$tmp" == "in" ]; then
        flags=""
    else
        flags=$(echo "$tmp" | sed -e 's/,/ /')
    fi
    echo "Test $name, flags '$flags'"
    ../wedepend $flags $f > $name.tmp 2> $name.err
    diff -u $name.tmp $name.out
    if [ $? -ne 0 ]; then
        failed=1
    fi
done 

if [ $failed -eq 1 ]; then
    echo "Failed!"
    exit 1
else
    echo "Passed!"
fi

exit 0
