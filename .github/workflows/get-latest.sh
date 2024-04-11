#!/bin/bash
# get-latest.sh
#
# Determine the latest version(s) of the "chromium" package in the Debian
# repositories, download the corresponding source package(s), and look for
# matching ungoogled-chromium release tags.
#

set -e

test -n "$DOWNLOAD_DIR"
test -n "$STATE_DIR"
test -n "$WORK_DIR"
test -d "$GITHUB_WORKSPACE"

debian_suite_list='bookworm sid'

package=chromium

obsolete_list=$WORK_DIR/obsolete.$package.txt

debian_incoming_url=https://incoming.debian.org/debian-buildd
debian_security_url=https://security.debian.org/debian-security

chdist_dir=$STATE_DIR/chdist-data
chdist="chdist --data-dir=$chdist_dir"
uc_git=$GITHUB_WORKSPACE/ungoogled-chromium

tab='	'

do_update=yes
do_download=yes
do_status=no

todo_flag=	# Note: "false" is interpreted by GitHub as true >_<

export LC_COLLATE=C

while [ -n "$1" ]
do
	case "$1" in
		--skip-update)   do_update=no   ;;
		--skip-download) do_download=no ;;
		--exit-status)   do_status=yes  ;;
		'') ;;
		-*) echo "$0: error: unrecognized option \"$1\"";   exit 1 ;;
		*)  echo "$0: error: unrecognized argument \"$1\""; exit 1 ;;
	esac
	shift
done

if [ ! -d $uc_git ]
then
	echo 'Error: ungoogled-chromium Git repository is not present'
	exit 1
fi

run()
{
	echo "+ $*"
	env "$@"
	echo ' '
}

check_debian_suite()
{
	local debian_suite="debian-$1"

	# Latest version of the package in the APT repo
	# (for the specified suite, e.g. "unstable" or "bullseye")
	local deb_version=$($chdist apt-get $debian_suite --print-uris source $package 2>/dev/null \
		| awk '/\.dsc /{print $2}' \
		| sed -r 's/^[^_]+_//; s/\.dsc$//')

	if [ -n "$deb_version" ]
	then
		echo "$debian_suite/$package: current package version $deb_version"
	else
		# Note that Debian's incoming repo doesn't always have
		# a given package available; this is not an error
		echo "$debian_suite/$package: no version available"
		echo ' '
		return
	fi

	# Upstream project version (remove the package-revision suffix)
	local ups_version="${deb_version%-*}"
	if [ -z "$ups_version" ]
	then
		echo "error: package version string is bogus"
		exit 1
	fi

	# Latest matching ungoogled-chromium tag
	local uc_tag=$(cd $uc_git && git tag --list --sort=-version:refname "$ups_version-*" | head -n1)

	if [ -n "$uc_tag" ]
	then
		echo "ungoogled-chromium: latest matching tag $uc_tag"
	else
		echo "ungoogled-chromium: no matching tag for $ups_version"
		echo ' '
		return
	fi

	local combo_line="$debian_suite$tab$deb_version$tab$uc_tag"

	# Have we built this combination before?
	if grep -Fqx "$combo_line" $STATE_DIR/done.$package.txt 2>/dev/null
	then
		echo "Already built DEB($debian_suite, $deb_version) + UC($uc_tag)"
		echo ' '
		return
	else
		echo "Will build DEB($debian_suite, $deb_version) + UC($uc_tag)"
	fi

	if [ $do_download = yes ]
	then
		echo ' '
		echo "$debian_suite/$package: downloading source package files"

		(cd $DOWNLOAD_DIR && run $chdist apt-get $debian_suite --quiet --only-source --download-only source $package)
	fi

	echo ' '

	echo "$combo_line" > $WORK_DIR/todo.$debian_suite.$package.txt
	todo_flag=true
}

find_obsolete_files()
{
	: > $obsolete_list

	local keep_count=$(echo $debian_suite_list | wc -w)
	local dsc_file

	# Delete source packages as a unit, rather than deleting their
	# files separately/individually

	(cd $DOWNLOAD_DIR && ls -1t ${package}_*.dsc 2>/dev/null) \
	| tail -n +$((keep_count + 1)) \
	| while read dsc_file
	do
		echo $dsc_file >> $obsolete_list

		sed -n '/^Files:/,/^$/p' $DOWNLOAD_DIR/$dsc_file \
		| awk '/^ /{print $3}' \
		>> $obsolete_list
	done
}

#
# First-time setup
#

mkdir -p $DOWNLOAD_DIR $STATE_DIR $chdist_dir
new_apt=no

for suite in $debian_suite_list
do
	debian_suite=debian-$suite
	test ! -d $chdist_dir/$debian_suite || continue
	echo "Initializing APT index for $debian_suite ..."

	case $debian_suite in
		debian-sid | debian-unstable)
#		run $chdist create $debian_suite $debian_incoming_url $suite main
		;;

		*)
#		run $chdist create $debian_suite $debian_security_url $suite-security main
		;;
	esac
run $chdist create $debian_suite http://debian-archive.trafficmanager.net/debian $suite main

	new_apt=yes
done

if [ $new_apt = yes ]
then
	# We only need deb-src lines, no binary packages
	find $chdist_dir -type f -name sources.list \
		-exec sed -i '/^deb /s/^/#/' {} +
fi

#
# Do version checks
#

for suite in $debian_suite_list
do
	debian_suite=debian-$suite

	if [ $do_update = yes ]
	then
		echo "Updating APT index for $debian_suite ..."
		run $chdist apt-get $debian_suite update --error-on=any
	fi

	check_debian_suite $suite
done

find_obsolete_files

if [ -n "$GITHUB_OUTPUT" ]
then
	echo todo=$todo_flag >> $GITHUB_OUTPUT
fi

test $do_status = no || test $todo_flag = true || exit 1
exit 0

# end get-latest.sh
