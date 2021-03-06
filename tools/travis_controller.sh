#!/usr/bin/env bash
################################################################################
#  Licensed to the Apache Software Foundation (ASF) under one
#  or more contributor license agreements.  See the NOTICE file
#  distributed with this work for additional information
#  regarding copyright ownership.  The ASF licenses this file
#  to you under the Apache License, Version 2.0 (the
#  "License"); you may not use this file except in compliance
#  with the License.  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

echo $M2_HOME
echo $PATH
echo $MAVEN_OPTS

mvn -version

echo "Commit: $(git rev-parse HEAD)"

CACHE_DIR="$HOME/flink_cache"
CACHE_BUILD_DIR="$CACHE_DIR/$TRAVIS_BUILD_NUMBER"
CACHE_FLINK_DIR="$CACHE_BUILD_DIR/flink"

echo "Flink cache location: ${CACHE_FLINK_DIR}"

HERE="`dirname \"$0\"`"				# relative
HERE="`( cd \"$HERE\" && pwd )`" 	# absolutized and normalized
if [ -z "$HERE" ] ; then
	# error; for some reason, the path is not accessible
	# to the script (e.g. permissions re-evaled after suid)
	exit 1  # fail
fi

source "${HERE}/travis/fold.sh"
source "${HERE}/travis/stage.sh"
source "${HERE}/travis/shade.sh"

print_system_info() {
	FOLD_ESCAPE="\x0d\x1b"
	COLOR_ON="\x5b\x30\x4b\x1b\x5b\x33\x33\x3b\x31\x6d"
	COLOR_OFF="\x1b\x5b\x30\x6d"

	start_fold "cpu_info" "CPU information"
	lscpu
	end_fold "cpu_info"

	start_fold "mem_info" "Memory information"
	cat /proc/meminfo
	end_fold "mem_info"

	start_fold "disk_info" "Disk information"
	df -hH
	end_fold "disk_info"

	start_fold "cache_info" "Cache information"
	echo "Maven: $(du -s --si $HOME/.m2)"
	echo "Flink: $(du -s --si $HOME/flink_cache)"
	echo "Maven (binaries): $(du -s --si $HOME/maven_cache)"
	echo "gems: $(du -s --si $HOME/gem_cache)"
	end_fold "cache_info"
}

print_system_info

function deleteOldCaches() {
	while read CACHE_DIR; do
		local old_number="${CACHE_DIR##*/}"
		if [ "$old_number" -lt "$TRAVIS_BUILD_NUMBER" ]; then
			echo "Deleting old cache $CACHE_DIR"
			rm -rf "$CACHE_DIR"
		fi
	done
}

# delete leftover caches from previous builds
find "$CACHE_DIR" -mindepth 1 -maxdepth 1 | grep -v "$TRAVIS_BUILD_NUMBER" | deleteOldCaches

STAGE=$1
echo "Current stage: \"$STAGE\""

EXIT_CODE=0

# Run actual compile&test steps
if [ $STAGE == "$STAGE_COMPILE" ]; then
	MVN="mvn clean install -nsu -Dflink.convergence.phase=install -Pcheck-convergence -Dflink.forkCount=2 -Dflink.forkCountTestPackage=2 -Dmaven.javadoc.skip=true -B -DskipTests $PROFILE"
	$MVN
	EXIT_CODE=$?

    if [ $EXIT_CODE == 0 ]; then
        printf "\n\n==============================================================================\n"
        printf "Checking scala suffixes\n"
        printf "==============================================================================\n"

        ./tools/verify_scala_suffixes.sh "${PROFILE}"
        EXIT_CODE=$?
    else
        printf "\n==============================================================================\n"
        printf "Previous build failure detected, skipping scala-suffixes check.\n"
        printf "==============================================================================\n"
    fi
    
    if [ $EXIT_CODE == 0 ]; then
        check_shaded_artifacts
        EXIT_CODE=$(($EXIT_CODE+$?))
        check_shaded_artifacts_s3_fs hadoop
        EXIT_CODE=$(($EXIT_CODE+$?))
        check_shaded_artifacts_s3_fs presto
        EXIT_CODE=$(($EXIT_CODE+$?))
        check_shaded_artifacts_connector_elasticsearch ""
        EXIT_CODE=$(($EXIT_CODE+$?))
        check_shaded_artifacts_connector_elasticsearch 2
        EXIT_CODE=$(($EXIT_CODE+$?))
        check_shaded_artifacts_connector_elasticsearch 5
        EXIT_CODE=$(($EXIT_CODE+$?))
    else
        echo "=============================================================================="
        echo "Previous build failure detected, skipping shaded dependency check."
        echo "=============================================================================="
    fi

    if [[ ${PROFILE} == *"jdk9"* ]]; then
        printf "\n\n==============================================================================\n"
        printf "Skipping end-to-end tests since they fail on Java 9.\n"
        printf "==============================================================================\n"
    else
        if [ $EXIT_CODE == 0 ]; then
            printf "\n\n==============================================================================\n"
            printf "Running end-to-end tests\n"
            printf "==============================================================================\n"

            FLINK_DIR=build-target flink-end-to-end-tests/run-pre-commit-tests.sh

            EXIT_CODE=$?
        else
            printf "\n==============================================================================\n"
            printf "Previous build failure detected, skipping end-to-end tests.\n"
            printf "==============================================================================\n"
        fi
    fi

    if [ $EXIT_CODE == 0 ]; then
        echo "Creating cache build directory $CACHE_FLINK_DIR"
        mkdir -p "$CACHE_FLINK_DIR"
    
        cp -r . "$CACHE_FLINK_DIR"

        function minimizeCachedFiles() {
            # reduces the size of the cached directory to speed up
            # the packing&upload / download&unpacking process
            # by removing files not required for subsequent stages
    
            # jars are re-built in subsequent stages, so no need to cache them (cannot be avoided)
            find "$CACHE_FLINK_DIR" -maxdepth 8 -type f -name '*.jar' | xargs rm -rf
    
            # .git directory
            # not deleting this can cause build stability issues
            # merging the cached version sometimes fails
            rm -rf "$CACHE_FLINK_DIR/.git"
        }
    
        start_fold "minimize_cache" "Minimizing cache"
        travis_time_start
        minimizeCachedFiles
        travis_time_finish
        end_fold "minimize_cache"
    else
        echo "=============================================================================="
        echo "Previous build failure detected, skipping cache setup."
        echo "=============================================================================="
    fi
elif [ $STAGE != "$STAGE_CLEANUP" ]; then
	if ! [ -e $CACHE_FLINK_DIR ]; then
		echo "Cached flink dir $CACHE_FLINK_DIR does not exist. Exiting build."
		exit 1
	fi
	# merged compiled flink into local clone
	# this prevents the cache from being re-uploaded
	start_fold "merge_cache" "Merging cache"
	travis_time_start
	cp -RT "$CACHE_FLINK_DIR" "."
	travis_time_finish
	end_fold "merge_cache"

	start_fold "adjust_timestamps" "Adjusting timestamps"
	travis_time_start
	# adjust timestamps to prevent recompilation
	find . -type f -name '*.java' | xargs touch
	find . -type f -name '*.scala' | xargs touch
	find . -type f -name '*.class' | xargs touch
	find . -type f -name '*.timestamp' | xargs touch
	travis_time_finish
	end_fold "adjust_timestamps"

	TEST="$STAGE" "./tools/travis_mvn_watchdog.sh" 300
	EXIT_CODE=$?
elif [ $STAGE == "$STAGE_CLEANUP" ]; then
	echo "Cleaning up $CACHE_BUILD_DIR"
	rm -rf "$CACHE_BUILD_DIR"
else
    echo "Invalid Stage specified: $STAGE"
    exit 1
fi

# Exit code for Travis build success/failure
exit $EXIT_CODE
