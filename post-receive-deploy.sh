#!/bin/sh

REF_TO_DEPLOY="refs/heads/master"
JOB_PATH="/home/damien/infrastructure/jobs/damienradtkecom.nomad.erb"

while IFS=$'\n' read -r line; do
        args=(${line})
        if [[ "${args[2]}" = "${REF_TO_DEPLOY}" ]]; then
                export REF="${args[1]}"
                echo "Deploying ${REF}"
                nomad-compile "${JOB_PATH}" | nomad job run -
        fi
done
