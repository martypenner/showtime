#!/usr/bin/env bash

API_URL=https://api.canva.com/rest/v1
AUTH_URL=https://www.canva.com/api/oauth/authorize
REDIRECT_URI=http://127.0.0.1:8765/callback

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'HELP'
Usage: bash scripts/canva_export.sh [--token-file PATH] auth [--redirect-uri URI]
       bash scripts/canva_export.sh [--token-file PATH] export DESIGN_ID --page NUMBERS=ID [...]

auth                  OAuth PKCE authorization; paste the full callback URL at the hidden prompt.
--redirect-uri URI    Registered redirect URL (default: http://127.0.0.1:8765/callback).
--token-file PATH     Cache (default: ~/.config/showtime/canva-token.json); put before auth/export.
--page NUMBERS=ID     Canva pages (1..500) for one MP4, e.g. 1,2,3=opener; repeat as needed.
--output-dir PATH     Destination (default: this repository's assets/videos).
--quality VALUE       horizontal_480p, horizontal_720p, horizontal_1080p (default), horizontal_4k,
                      vertical_480p, vertical_720p, vertical_1080p, vertical_4k.
--export-quality MODE regular (default) or pro.
--timeout SECONDS     Positive whole seconds per export/download (default: 600).

Requires Bash 3.2+, curl, jq, OpenSSL, and ffprobe for exports.
Auth/refresh uses CANVA_CLIENT_ID and CANVA_CLIENT_SECRET.
CANVA_ACCESS_TOKEN overrides the cache for exports and is not refreshed.
HELP
}

cleanup() {
	[[ -z ${video_tmp:-} ]] || rm -f -- "$video_tmp"
	[[ -z ${token_tmp:-} ]] || rm -f -- "$token_tmp"
	[[ -z ${scratch:-} ]] || rm -rf -- "$scratch"
}

initialize() {
	umask 077
	scratch='' token_tmp='' video_tmp=''
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	scratch=$(mktemp -d "${TMPDIR:-/tmp}/showtime-canva.XXXXXX")
	response=$scratch/response.json
	headers=$scratch/response-headers
	body=$scratch/request-body
}

require_commands() {
	local command
	for command in "$@"; do
		command -v "$command" >/dev/null || die "Install $command before running this command."
	done
}

credentials() {
	[[ -n ${CANVA_CLIENT_ID:-} && -n ${CANVA_CLIENT_SECRET:-} ]] ||
		die 'Set CANVA_CLIENT_ID and CANVA_CLIENT_SECRET first.'
}

urlencode() { jq -sRr @uri; }

# Decode each escape independently so callback content is never evaluated as shell code.
urldecode() {
	local input=$1 character hex
	decoded=
	while [[ -n $input ]]; do
		character=${input:0:1}
		input=${input:1}
		case $character in
			+) decoded+=' ' ;;
			%)
				hex=${input:0:2}
				[[ $hex =~ ^[0-9A-Fa-f]{2}$ ]] || die 'Invalid URL encoding in callback.'
				case $hex in 00|0a|0A|0d|0D) die 'Invalid control character in callback.' ;; esac
				printf -v character '%b' "\\x$hex"
				decoded+=$character
				input=${input:2}
				;;
			*) decoded+=$character ;;
		esac
	done
}

callback_code() {
	local callback=$1 expected_state=$2 query pair key value received_state='' count=0 state_count=0
	[[ $callback == "$redirect_uri?"* ]] || die 'Callback URL does not match the registered redirect URI.'
	query=${callback#*\?}
	query=${query%%#*}
	code=
	while :; do
		pair=${query%%&*}
		urldecode "${pair%%=*}"; key=$decoded
		value=
		if [[ $pair == *=* ]]; then urldecode "${pair#*=}"; value=$decoded; fi
		case $key in
			state) received_state=$value; state_count=$((state_count + 1)) ;;
			code) code=$value; count=$((count + 1)) ;;
			error) die 'Canva authorization was denied; run auth again.' ;;
		esac
		[[ $query == *'&'* ]] || break
		query=${query#*&}
	done
	[[ $state_count == 1 && $received_state == "$expected_state" ]] || die 'OAuth state mismatch; authorization stopped.'
	[[ $count == 1 && -n $code ]] || die 'Expected one authorization code in the callback URL.'
}

# Headers and request bodies stay in private files, not process arguments or logs.
http_request() {
	local method=$1 path=$2 content_type=$3 authorization=$4
	local options=()
	printf 'Authorization: %s\n' "$authorization" > "$scratch/request-headers"
	if [[ $method == POST ]]; then
		printf 'Content-Type: %s\n' "$content_type" >> "$scratch/request-headers"
		options=(--data-binary "@$body")
	fi
	if ! http_status=$(curl --disable --silent --show-error --proto '=https' --proto-redir '=https' \
		--connect-timeout 10 --max-time 30 --request "$method" --header "@$scratch/request-headers" \
		${options[@]+"${options[@]}"} --output "$response" --dump-header "$headers" \
		--write-out '%{http_code}' "$API_URL$path" 2> "$scratch/curl-errors"); then
		die 'Network request failed; retry the command. Existing video was not replaced.'
	fi
}

exchange_tokens() {
	local basic directory
	credentials
	basic=$(printf '%s:%s' "$CANVA_CLIENT_ID" "$CANVA_CLIENT_SECRET" | openssl base64 -A)
	http_request POST /oauth/token application/x-www-form-urlencoded "Basic $basic"
	[[ $http_status == 200 ]] || die "Token exchange failed (HTTP $http_status); run auth again."
	jq -e '(.access_token | type == "string" and length > 0) and
		(.refresh_token | type == "string" and length > 0) and
		(.expires_in | type == "number" and . > 0)' "$response" >/dev/null 2>&1 ||
		die 'Invalid token response; run auth again.'
	directory=$(dirname -- "$token_file")
	mkdir -p -- "$directory"
	[[ ! -d $token_file ]] || die 'Token cache path is a directory.'
	token_tmp=$(mktemp "$directory/.canva-token.XXXXXX")
	jq '. + {expires_at: (now + .expires_in), client_id: env.CANVA_CLIENT_ID}' "$response" > "$token_tmp"
	mv -f -- "$token_tmp" "$token_file" || die 'Cannot save token cache; previous cache was not replaced.'
	token_tmp=
}

refresh_tokens() {
	[[ -z ${CANVA_ACCESS_TOKEN:-} ]] || die 'CANVA_ACCESS_TOKEN expired or invalid; replace it or run auth.'
	credentials
	[[ $(jq -r '.client_id' "$token_file") == "$CANVA_CLIENT_ID" ]] ||
		die 'Token cache belongs to a different CANVA_CLIENT_ID; run auth again.'
	printf 'grant_type=refresh_token&refresh_token=%s' \
		"$(jq -jr '.refresh_token' "$token_file" | urlencode)" > "$body"
	exchange_tokens
}

api_request() {
	local method=$1 path=$2 payload=${3:-} token expiry retry refreshed=0 deadline=$((SECONDS + 60))
	if [[ -z ${CANVA_ACCESS_TOKEN:-} ]]; then
		[[ -f $token_file ]] || die 'No token cache; run auth first or set CANVA_ACCESS_TOKEN.'
		expiry=$(jq -er '.expires_at | numbers' "$token_file" 2>/dev/null) || die 'Invalid token cache; run auth again.'
		if jq -en --argjson expiry "$expiry" '$expiry <= now + 60' >/dev/null; then refresh_tokens; fi
	fi
	while :; do
		if [[ -n ${CANVA_ACCESS_TOKEN:-} ]]; then token=$CANVA_ACCESS_TOKEN
		else token=$(jq -er '.access_token | strings | select(length > 0)' "$token_file"); fi
		if [[ $method == POST ]]; then cp -- "$payload" "$body"; fi
		http_request "$method" "$path" application/json "Bearer $token"
		case $http_status in
			200)
				jq -e 'type == "object"' "$response" >/dev/null 2>&1 || die 'Invalid JSON response from Canva.'
				return
				;;
			401)
				if [[ $refreshed == 0 ]]; then refresh_tokens; refreshed=1; continue; fi
				;;
			429)
				retry=$(awk 'tolower($1) == "retry-after:" {gsub("\r", "", $2); wait=$2} END {print wait}' "$headers")
				if [[ $retry =~ ^[0-9]{1,5}$ ]]; then retry=$((10#$retry)); else retry=5; fi
				if ((retry < 1)); then retry=1; fi
				if ((SECONDS + retry < deadline)); then sleep "$retry"; continue; fi
				;;
		esac
		local detail
		detail=$(jq -r '"\(.code // "request_failed"): \(.message // "Check permissions, scopes and export quotas.")"' \
			"$response" 2>/dev/null) || detail=request_failed
		die "Canva HTTP $http_status: $detail"
	done
}

authorize() {
	local verifier challenge state callback url
	credentials
	[[ ($redirect_uri == https://* || $redirect_uri == http://127.0.0.1:*) &&
		$redirect_uri != *'?'* && $redirect_uri != *'#'* ]] || die 'Use a registered HTTPS or loopback redirect URI without query/fragment.'
	verifier=$(openssl rand -base64 64 | tr '+/' '-_' | tr -d '=\n')
	challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
	state=$(openssl rand -hex 32)
	url="$AUTH_URL?response_type=code&code_challenge_method=S256&scope=design%3Acontent%3Aread"
	url+="&client_id=$(printf '%s' "$CANVA_CLIENT_ID" | urlencode)&redirect_uri=$(printf '%s' "$redirect_uri" | urlencode)"
	url+="&state=$state&code_challenge=$challenge"
	printf 'Open this URL in your browser:\n%s\n' "$url"
	printf 'Allow access, then copy the full redirect URL from the address bar (a connection error is expected).\n'
	if ! IFS= read -r -s -t 300 -p 'Redirect URL (hidden): ' callback; then
		printf '\n' >&2; die 'Authorization input timed out or closed; run auth again.'
	fi
	printf '\n' >&2
	callback_code "$callback" "$state"
	printf 'grant_type=authorization_code&code=%s&code_verifier=%s&redirect_uri=%s' \
		"$(printf '%s' "$code" | urlencode)" "$verifier" "$(printf '%s' "$redirect_uri" | urlencode)" > "$body"
	exchange_tokens
	printf 'Authorized. Token cache: %s\n' "$token_file"
}

wait_for_export() {
	local pages=$1 job status remaining deadline=$((SECONDS + timeout))
	jq -n --arg design "$design_id" --arg quality "$quality" --arg export_quality "$export_quality" \
		--argjson pages "[$pages]" '{design_id: $design, format: {type: "mp4", quality: $quality,
		export_quality: $export_quality, pages: $pages}}' > "$scratch/export-payload"
	api_request POST /exports "$scratch/export-payload"
	while :; do
		status=$(jq -er '.job.status | strings' "$response") || die 'Invalid export job response.'
		case $status in
			success)
				jq -e '(.job.urls | type == "array" and length == 1) and (.job.urls[0] | type == "string")' \
					"$response" >/dev/null || die "Expected one MP4 download URL for pages $pages."
				download_url=$(jq -r '.job.urls[0]' "$response")
				return
				;;
			in_progress)
				job=$(jq -er '.job.id | strings | select(length > 0)' "$response")
				remaining=$((deadline - SECONDS))
				((remaining > 0)) || die "Export job $job timed out; existing video was not replaced."
				if ((remaining > 2)); then sleep 2; else sleep "$remaining"; fi
				((SECONDS < deadline)) || die "Export job $job timed out; existing video was not replaced."
				api_request GET "/exports/$(printf '%s' "$job" | urlencode)"
				;;
			*) die "Export failed: $(jq -r '"\(.job.error.code // .job.status): \(.job.error.message // "")"' "$response")" ;;
		esac
	done
}

download_video() {
	local url=$1 destination=$2 config_url
	[[ $url == https://* && $url != *$'\n'* && $url != *$'\r'* ]] || die 'Canva download URL must use HTTPS without control characters.'
	[[ ! -d $destination ]] || die 'Video destination is a directory.'
	video_tmp=$(mktemp "$output_dir/.canva.XXXXXX")
	config_url=${url//\\/\\\\}
	config_url=${config_url//\"/\\\"}
	printf 'url = "%s"\n' "$config_url" > "$scratch/download-config"
	# Signed URLs need no bearer token. Disable curlrc and restrict redirects to HTTPS.
	if ! curl --disable --silent --show-error --fail --location --proto '=https' --proto-redir '=https' \
		--connect-timeout 10 --max-time "$timeout" --config "$scratch/download-config" \
		--output "$video_tmp" 2> "$scratch/curl-errors"; then
		die 'Video download failed or incomplete; existing video was not replaced.'
	fi
	ffprobe -v error -select_streams v:0 -show_entries 'stream=width,height,r_frame_rate:format=format_name' \
		-of json "$video_tmp" > "$scratch/probe.json" 2> "$scratch/probe-errors" ||
		die 'Downloaded file is not a readable video; existing video was not replaced.'
	jq -e '.streams[0] as $s | ($s.r_frame_rate // "" | split("/") | map(tonumber?)) as $fps |
		(.format.format_name | split(",") | index("mp4")) != null and
		($s.width > 0) and ($s.height > 0) and ($fps | length == 2) and ($fps[0] > 0) and ($fps[1] > 0)' \
		"$scratch/probe.json" >/dev/null 2>&1 || die 'Downloaded video is not an MP4 with valid dimensions and frame rate.'
	mv -f -- "$video_tmp" "$destination" || die 'Cannot replace video; existing video was not replaced.'
	video_tmp=
}

export_pages() {
	local index page_id page_group lower seen='|' next_export=0 delay
	for page_id in "${page_ids[@]}"; do
		lower=$(printf '%s' "$page_id" | tr '[:upper:]' '[:lower:]')
		[[ $seen != *"|$lower|"* ]] || die 'Each output PAGE_ID must be unique (ignoring case).'
		seen+="$lower|"
	done
	require_commands ffprobe
	mkdir -p -- "$output_dir"
	for ((index=0; index<${#page_ids[@]}; index++)); do
		page_id=${page_ids[index]}; page_group=${page_groups[index]}
		delay=$((next_export - SECONDS))
		if ((delay > 0)); then sleep "$delay"; fi
		# Five-second spacing respects both 20/minute and 75/5-minute creation limits.
		next_export=$((SECONDS + 5))
		printf 'Exporting Canva pages %s as %s.mp4...\n' "$page_group" "$page_id"
		wait_for_export "$page_group"
		download_video "$download_url" "$output_dir/$page_id.mp4"
		printf 'Saved %s/%s.mp4\n' "$output_dir" "$page_id"
	done
}

main() {
	set +x
	set -euo pipefail
	export LC_ALL=C
	local action option value page_number page_group page_list
	token_file=$HOME/.config/showtime/canva-token.json
	output_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/assets/videos
	redirect_uri=$REDIRECT_URI quality=horizontal_1080p export_quality=regular timeout=600
	page_groups=() page_ids=()
	if [[ ${1:-} == --token-file ]]; then
		(($# >= 2)) || die '--token-file needs a path.'
		token_file=$2; shift 2
	fi
	action=${1:-}; if (($#)); then shift; fi
	case $action in auth|export) ;; -h|--help|'') usage; return ;; *) die "Unknown command: $action" ;; esac
	design_id=
	while (($#)); do
		option=$1
		case $option in -h|--help) usage; return ;; esac
		if [[ $action == export && $option != -* ]]; then
			[[ -z $design_id ]] || die 'Provide one design ID.'
			design_id=$option; shift; continue
		fi
		(($# >= 2)) || die "$option needs a value."
		value=$2; shift 2
		case "$action:$option" in
			auth:--redirect-uri) redirect_uri=$value ;;
			export:--page)
				[[ $value =~ ^([0-9]{1,3}(,[0-9]{1,3})*)=([A-Za-z0-9][A-Za-z0-9_-]*)$ ]] ||
					die 'Use PAGE_NUMBERS=PAGE_ID (comma-separated pages 1..500; ID: letters, digits, _ or -).'
				IFS=, read -r -a page_list <<< "${value%%=*}"
				page_group=
				for page_number in "${page_list[@]}"; do
					page_number=$((10#$page_number))
					((page_number >= 1 && page_number <= 500)) || die 'Page number must be 1..500.'
					page_group+="${page_group:+,}$page_number"
				done
				page_groups+=("$page_group"); page_ids+=("${value#*=}")
				;;
			export:--output-dir) output_dir=$value ;;
			export:--quality)
				[[ $value =~ ^(horizontal|vertical)_(480p|720p|1080p|4k)$ ]] || die 'Unsupported MP4 quality.'
				quality=$value
				;;
			export:--export-quality) [[ $value == regular || $value == pro ]] || die 'Use regular or pro export quality.'; export_quality=$value ;;
			export:--timeout)
				if ! [[ $value =~ ^[0-9]{1,9}$ ]] || ((10#$value <= 0)); then
					die 'Timeout must be positive whole seconds (up to nine digits).'
				fi
				timeout=$((10#$value))
				;;
			*) die "Unknown option: $option" ;;
		esac
	done
	if [[ $action == export ]]; then
		[[ -n $design_id && -n ${page_ids[0]:-} ]] || die 'Provide DESIGN_ID and at least one --page NUMBERS=ID.'
	fi
	require_commands curl jq openssl
	initialize
	if [[ $action == auth ]]; then authorize; else export_pages; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
