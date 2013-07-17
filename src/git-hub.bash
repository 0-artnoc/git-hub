#!/bin/bash
#
# git-hub: Use the GitHub v3 API commands from git
#
# Copyright (c) 2013 Ingy döt Net

set -e

OPTIONS_SPEC="\
git hub <command> <options> <arguments>

Commands:
  config
  user, user-info, user-get, user-set
  repo-list, repo-info, repo-create, repo-delete, repo-get, repo-set
  collab-add, collab-remove
  auth-list, auth-info, auth-create, auth-update, auth-delete

See 'git help hub' for complete documentation and usage of each command.

Options:
--
user=       GitHub user name
repo=       GitHub repository name
token=      GitHub v3 API Authentication Token
c,count=    Number of items to process

h,help      Show this help
q,quiet     Show minimal output
v,verbose   Show verbose output
d,dryrun    Don't run the API command
T           Show API token in the verbose output

O           dev - Show response output
H			dev - Show reponse headers
J           dev - Show parsed JSON response
x           dev - Turn on Bash trace (set -x) output
R           dev - Repeat last command without contacting server
"

main() {
	assert-env
	get-options "$@"
	setup-env

	github-"$command"
	[ -n "$show_output" ] && cat $GIT_HUB_OUTPUT
	[ -s $GIT_HUB_OUTPUT ] && json-load-cache "$(cat $GIT_HUB_OUTPUT)"
	[ -n "$show_json" ] && echo "$json_load_data_cache"

	if OK; then
		if callable "github-$command-success"; then
			"github-$command-success"
		else
			say ${message_success:="'git hub $command' successful"}
		fi
	elif [ -n "$status_code" ] && callable "github-$command-$status_code"; then
		"github-$command-$status_code"
	elif [ -n "$(eval "echo \$message_$status_code")" ]; then
		say $(eval "echo \$message_$status_code")
	elif callable "github-$command-failure"; then
		"github-$command-failure"
	else
		say ${message_failure:="'git hub $command' failed: $status_code $ERROR"}
	fi
}

#------------------------------------------------------------------------------
github-config() {
	if [ -z "$config_key" ]; then
		cat $config_file
	elif [ -z "$config_value" ]; then
		git config -f $config_file github.$config_key
	else
		git config -f $config_file github.$config_key "$config_value"
	fi
	OK=$?
}

github-user-info() {
	require-value user-name "$user"
	api-get "users/$user_name"
}

github-user-info-success() {
	for field in \
		login type name email blog location company \
		followers following public_repos public_gists
	do
		report-value $field
	done
}

github-user-update() {
	require-value user-name "$user"
	[ -z "$field_key" ] || die "Field key required"
	if [ -z "$field_value" ]; then
		api-get "users/$user_name"
	else
		api-patch 'user' $(json-dump $field_key $field_value)
	fi
}

github-repo-list() {
	page_size=100
	per_page=$list_count
	[ $per_page -gt $page_size ] && per_page=$page_size
	local options="sort=pushed;per_page=$per_page"
	if [ -n "$user_name" ]; then
		api-get "users/$user_name/repos?$options"
	else
		api-get "user/repos?$options"
	fi
	counter=1
}

github-repo-list-success() {
	for ((ii=0; ii < $page_size; ii++)); do
		[ $counter -le $list_count ] || return
		name=$(json-get "/$ii/full_name")
		pushed=$(json-get "/$ii/pushed_at")
		pushed=${pushed/T*/}
		desc=$(json-get "/$ii/description")
		[ -z "$name" ] && break
		printf "%3d) (%s)  %-30s %s\n" $((counter++)) $pushed $name "$desc"
	done
	get-next-page github-repo-list-success
}

github-repo-info() {
	require-value repo-name "$repo"
	require-value user-name "$user"
	api-get "repos/$user_name/$repo_name"
}

github-repo-info-success() {
	for field in \
		full_name description homepage language \
		pushed_at \
		url ssh_url \
		forks watchers
	do
		report-value $field
	done
}

github-repo-create() {
	require-value repo-name "$repo"
	api-post 'user/repos' $(json-dump 'name' $repo_name)
	message_success="Repository '$repo_name' created."
	message_422="Repository name '$repo_name' already exists."
}

github-repo-delete() {
	require-value repo-name "$repo"
	require-value user-name "$user"
	api-delete "repos/$user_name/$repo_name"
	message_success="Repository '$repo_name' deleted"
}

github-collab-add() {
	require-value repo-name "$repo"
	require-value user-name "$user"
	require-value collab-name "$collab"
	api-put "repos/$user_name/$repo_name/collabs/$collab_name"
	message_success="Added '$collab_name' as a collaborator to the '$repo_name' repository"
}

github-auth-list() {
	api-get 'authorizations'
	cat $GIT_HUB_OUTPUT
}

#------------------------------------------------------------------------------
api-get() { api-call GET $*; }
api-post() { api-call POST $*; }
api-put() { api-call PUT $*; }
api-patch() { api-call PATCH $*; }
api-delete() { api-call DELETE $*; }

api-call() {
	[ -n "$repeat_command" ] && api-repeat && return
	require-value api-token "$token"
	local action=$1
	local url=$2
	local data=$3
	local regex="^https?:"
	[[ "$url" =~ $regex ]] || url="$GIT_HUB_API_URI/$url"
	[ -n "$data" ] && data="-d $data"
	if [ $GIT_VERBOSE ]; then
		local token=$([ -n "$show_token" ] && echo "$api_token" || echo '********')
		say "curl -s -S -X$action -H \"Authorization: token $token\" $url $data -D \"$GIT_HUB_HEADER\" > $GIT_HUB_OUTPUT 2> $GIT_HUB_ERROR"
	fi
	[ -n "$dry_run" ] && exit 0
	curl -s -S -X$action -H "Authorization: token $api_token" $url $data \
		-D "$GIT_HUB_HEADER" > $GIT_HUB_OUTPUT 2> $GIT_HUB_ERROR
	check-api-call-status $?
}

check-api-call-status() {
	OK=$1
	if [ ! -f $GIT_HUB_HEADER ]; then
		OK=1
		ERROR=$(head -1 $GIT_HUB_ERROR)
		return
	fi
	status_code=$(head -1 $GIT_HUB_HEADER | cut -d ' ' -f2)
	local regex='^[0-9]{3}$'
	[[ $status_code =~ $regex ]] || return
	case "$status_code" in
		200|201|204) OK=0 ;;
		*)
			OK=1
			ERROR=$(head -1 $GIT_HUB_HEADER | cut -d ' ' -f3-)
			;;
	esac
}

OK() {
	return $OK
}

api-repeat() {
	check-api-call-status 0
	true
}

#------------------------------------------------------------------------------
get-next-page() {
    local callback=$1
	regexp='Link: <(https:.+?)>; rel="next"'
	[[ "$(cat $GIT_HUB_HEADER)" =~ $regexp ]] || return
	local link=${BASH_REMATCH[1]}
	api-get "$link"
	if OK; then
		json-load-cache "$(cat $GIT_HUB_OUTPUT)"
		$callback
	fi
}

# Usage: require-value variable-name "possible-user-value"
#   Fetch $variable_name or die
require-value() {
	local key=$1
	local var=${key//-/_}
	fetch-value "$@"
	if [ -z "$(eval echo \$$var)" ]; then
		[ "$var" = "api_token" ] && die_need_api_token
		die "Can't find value for '$var'"
	fi
	true
}

# Usage: fetch-value variable-name "possible-user-value"
#   Sets $variable_name to the first of:
#   - possible-user-value
#   - $GIT_HUB_VARIABLE_NAME
#   - git config github.variable-name
fetch-value() {
	local key=$1
	local var=${key//-/_}
	local env=GIT_HUB_$(echo $var | tr 'a-z' 'A-Z')
	eval $var="$2"
	[ -n "$(eval echo \$$var)" ] && return
	eval $var=\"\$$env\"
	[ -n "$(eval echo \$$var)" ] && return
	eval $var=$(git config --file=$config_file github.$key || echo '')
	[ -n "$(eval echo \$$var)" ] && return
	true
}

die_need_api_token() {
	cat <<eos

Can't determine your API Access Token. Usually this means you haven't set up
your ~/.githubconfig file yet.

First go to https://github.com/settings/applications and retrieve or create a
Personal API Access Token. This is a 40 digit hexadecimal character string.

Next, run these commands:

	git hub config api-token <your-personal-api-access-token>
	git hub config user-name <your-github-login-id>

Now you should be set up to run most commands. Some commands require that you
add certain 'scopes' to your token.
eos
	die
}

#------------------------------------------------------------------------------
# Format a JSON string from an input list of key/value pairs.
json-dump() {
	local json='{'
	while [ $# -gt 0 ]; do
		json="$json\"$1\":\"$2\""
		shift; shift
		if [ $# -gt 0 ]; then
			json="$json,"
		fi
	done
	json="$json}"
	echo $json
}

json-load-cache() {
	json_load_data_cache=$(echo "$1" | tokenize | parse)
}

json-get() {
	local key="^$1\s"
	local data="$2"
	[ -z "$data" ] && data="$json_load_data_cache"
	value=$(echo "$data" | egrep $key | cut -f2)
	if [ "$value" = 'null' ]; then
		echo ''
	else
		echo ${value//\"/}
	fi
}

#------------------------------------------------------------------------------
report-value() {
	local value=$(json-get "/$1")
	local label=$(eval echo \$label_$1)
	if [ -z "$label" ]; then
		label=$(echo "$1" | tr '_' ' ')
		label=${label//ssh/SSH}
		label=${label//url/URL}
		label=$(for word in $label; do title=`echo "${word:0:1}" | tr a-z A-Z`${word:1}; echo -n "$title "; done)
	fi
	if [ -n "$label" -a -n "$value" ]; then
		printf "%-15s %s\n" "$label" "$value"
	fi
}

label_login='ID'
label_email='Email Address'
label_blog='Web Site'

#------------------------------------------------------------------------------
assert-env() {
	GIT_CORE_PATH=$(git --exec-path) || exit $?
	PATH=$GIT_CORE_PATH:$PATH

	: ${GIT_HUB_API_URI:=https://api.github.com}
	GIT_HUB_TMP=/tmp
	GIT_HUB_TMP_PREFIX=$GIT_HUB_TMP/git-hub
	GIT_HUB_INPUT=$GIT_HUB_TMP_PREFIX-in-$$
	GIT_HUB_OUTPUT=$GIT_HUB_TMP_PREFIX-out-$$
	GIT_HUB_ERROR=$GIT_HUB_TMP_PREFIX-err-$$
	GIT_HUB_HEADER=$GIT_HUB_TMP_PREFIX-head-$$
	local cmd
	for cmd in git curl tr egrep head cut; do
		[ -z "$(which $cmd)" ] &&
			echo "Required command not found: '$cmd'" && exit 1
	done
	[ -z "$HOME" ] &&
		echo "Cannot determine HOME directory" && exit 1
	config_file=$GIT_HUB_CONFIG
	[ -n "$config_file" ] || config_file=$HOME/.githubconfig
}

get-options() {
	[ $# -eq 0 ] && set -- --help
	NONGIT_OK=1 source git-sh-setup

	GIT_QUIET=; GIT_VERBOSE=;
	user=; repo=; dry_run=; show_token=; list_count=10
	while [ $# -gt 0 ]; do
		local option="$1"; shift
		case "$option" in
			-h) usage ;;
			--user) user="$1"; shift ;;
			--repo) repo="$1"; shift ;;
			--token) token="$1"; shift ;;
			-c)	list_count=$1; shift ;;
			-d) dry_run="1" ;;
			-T) show_token="1" ;;
			-q) GIT_QUIET=1 ;;
			-v) GIT_VERBOSE="1" ;;
			--) break ;;
			# Dev options:
			-x) set -x ;;
			-R) repeat_command="1" ;;
			-O) show_output="1" ;;
			-J) show_json="1" ;;

			*) die "Unexpected option: $option" ;;
		esac
	done

    command="$1"; shift
	[ "$command" = "user" ] && command="user-info"
	[ "$command" = "repo" ] && command="repo-info"
	[ "$command" = "repos" ] && command="repo-list"

	case "$command" in
		config)
			[ $# -gt 0 ] && config_key="$1" && shift
			[ $# -gt 0 ] && config_value="$1" && shift
			;;
		user-info)
			[ $# -gt 0 ] && user="$1" && shift
			;;
		user-field)
			[ $# -gt 0 ] && field_key="$1" && shift
			[ $# -gt 0 ] && field_value="$1" && shift
			;;
		repo-list)
			[ $# -gt 0 ] && user_name="$1" && shift
			;;
		repo-info|repo-create|repo-delete)
			[ $# -gt 0 ] && repo="$1" && shift
			[[ $repo =~ "/" ]] && user-repo ${repo/\// }
			;;
		collab-add)
			[ $# -gt 0 ] && collab="$1" && shift
			;;
		auth-list) ;;
		*) die "Unknown 'git hub' command: '$command'"
	esac
	[ $# -gt 0 ] && die "Unknown arguments: $*"
	true
}

setup-env() {
    source "$GIT_CORE_PATH/lib/core.bash"
    source "$GIT_CORE_PATH/lib/json.bash"
    if [ -n "$repeat_command" ]; then
		[ -f $GIT_HUB_TMP_PREFIX-out-* ] ||
			die "No previous 'git hub' command to repeat"
		local old_output=$(echo $GIT_HUB_TMP_PREFIX-out-*)
		local pid=${old_output/$GIT_HUB_TMP_PREFIX-out-/}
		GIT_HUB_INPUT=$GIT_HUB_TMP_PREFIX-in-$pid
		GIT_HUB_OUTPUT=$GIT_HUB_TMP_PREFIX-out-$pid
		GIT_HUB_ERROR=$GIT_HUB_TMP_PREFIX-err-$pid
		GIT_HUB_HEADER=$GIT_HUB_TMP_PREFIX-head-$pid
	else
		rm -f $GIT_HUB_TMP_PREFIX-*
	fi
	[ -n "$dry_run" ] &&
		say '*** NOTE: This is a dry run only. ***'
	true
    # require_work_tree
}

user-repo() {
	user=$1
	repo=$2
}

#------------------------------------------------------------------------------
main "$@"

# vim: set tabstop=4 shiftwidth=4 noexpandtab:
