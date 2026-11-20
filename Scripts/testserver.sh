#!/usr/bin/env bash
#
# Local Jellyfin test server for developing and testing Swiftfin tvOS.
#
# Everything lives in .testserver/ (git-ignored): server binaries, generated media, config, data.
#
#   Scripts/testserver.sh setup    # download Jellyfin, generate test media, configure users and libraries
#   Scripts/testserver.sh start    # start in the background (http://localhost:8096)
#   Scripts/testserver.sh stop
#   Scripts/testserver.sh status
#   Scripts/testserver.sh reset    # delete .testserver/ entirely
#
# Accounts created by setup:
#   tester / tester   administrator (used by UI tests to read sessions)
#   demo   / (none)   regular user the app signs in with
#
# Libraries: Movies (multi-audio/subtitle/chapters MKV, HEVC MP4 + external subtitle), Shows (3 episodes).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${TESTSERVER_DIR:-$ROOT/.testserver}"
PORT=8096
URL="http://localhost:$PORT"
JELLYFIN_VERSION="${JELLYFIN_VERSION:-latest-stable}"
if [[ -t 2 ]]; then CURL_PROGRESS=(--progress-bar); else CURL_PROGRESS=(-sS); fi
AUTH_HEADER='MediaBrowser Client="Swiftfin Test Harness", Device="Mac", DeviceId="swiftfin-testserver", Version="1.0"'

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

arch() {
    case "$(uname -m)" in
        arm64) echo arm64 ;;
        x86_64) echo amd64 ;;
        *) die "unsupported architecture $(uname -m)" ;;
    esac
}

is_running() {
    [[ -f "$DIR/server.pid" ]] && kill -0 "$(cat "$DIR/server.pid")" 2>/dev/null
}

is_up() {
    curl -sf "$URL/System/Info/Public" >/dev/null 2>&1
}

wait_up() {
    for _ in $(seq 1 120); do
        if is_up; then return 0; fi
        sleep 1
    done
    die "server did not come up on $URL (see $DIR/server.out)"
}

ffmpeg_bin() {
    if [[ -x "$DIR/bin/ffmpeg" ]]; then echo "$DIR/bin/ffmpeg"
    elif command -v ffmpeg >/dev/null; then command -v ffmpeg
    else die "ffmpeg not found (expected $DIR/bin/ffmpeg or brew install ffmpeg)"
    fi
}

# MARK: - Download

download() {
    if [[ -x "$DIR/bin/jellyfin" && -x "$DIR/bin/ffmpeg" ]]; then
        log "Jellyfin already downloaded"
        return
    fi

    local a listing file tmp
    a="$(arch)"
    listing="https://repo.jellyfin.org/files/server/macos/$JELLYFIN_VERSION/$a/"
    file="$(curl -fsSL "$listing" | grep -oE 'href="jellyfin_[^"]+\.tar\.xz"' | head -1 | cut -d'"' -f2)"
    [[ -n "$file" ]] || die "no Jellyfin tarball found at $listing"

    tmp="$(mktemp -d)"
    log "Downloading $listing$file"
    curl -fL "${CURL_PROGRESS[@]}" -o "$tmp/$file" "$listing$file"

    log "Extracting"
    mkdir -p "$tmp/x"
    tar -xJf "$tmp/$file" -C "$tmp/x"

    # The tarball has a single top-level folder with the server, ffmpeg and jellyfin-web.
    local top
    top="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [[ -x "$top/jellyfin" ]] || die "unexpected tarball layout in $file"

    mkdir -p "$DIR"
    rm -rf "$DIR/bin" "$DIR/web"
    mv "$top" "$DIR/bin"
    if [[ -d "$DIR/bin/jellyfin-web" ]]; then
        mv "$DIR/bin/jellyfin-web" "$DIR/web"
    fi

    # jellyfin-ffmpeg (Jellyfin's patched ffmpeg/ffprobe build) is shipped separately.
    local ff_arch ff_listing ff_file
    if [[ "$a" == arm64 ]]; then ff_arch=arm64; else ff_arch=x86_64; fi
    ff_listing="https://repo.jellyfin.org/files/ffmpeg/macos/latest-8.x/$ff_arch/"
    ff_file="$(curl -fsSL "$ff_listing" | grep -oE 'href="jellyfin-ffmpeg_[^"]+\.tar\.xz"' | head -1 | cut -d'"' -f2)"
    [[ -n "$ff_file" ]] || die "no jellyfin-ffmpeg tarball found at $ff_listing"
    log "Downloading $ff_listing$ff_file"
    curl -fL "${CURL_PROGRESS[@]}" -o "$tmp/$ff_file" "$ff_listing$ff_file"
    tar -xJf "$tmp/$ff_file" -C "$DIR/bin" ffmpeg ffprobe

    xattr -dr com.apple.quarantine "$DIR/bin" "$DIR/web" 2>/dev/null || true
    rm -rf "$tmp"
}

# MARK: - Media

generate_media() {
    local media="$DIR/media" ff fixtures
    if [[ -f "$media/.complete" ]]; then
        log "Test media already generated"
        return
    fi

    ff="$(ffmpeg_bin)"
    fixtures="$DIR/fixtures"
    rm -rf "$media" "$fixtures"
    mkdir -p "$fixtures" \
        "$media/Movies/Test Movie (2024)" \
        "$media/Movies/HEVC Sample (2023)" \
        "$media/Shows/Test Show/Season 01"

    cat >"$fixtures/chapters.txt" <<'EOF'
;FFMETADATA1
title=Test Movie
[CHAPTER]
TIMEBASE=1/1000
START=0
END=30000
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=30000
END=90000
title=Middle
[CHAPTER]
TIMEBASE=1/1000
START=90000
END=180000
title=Finale
EOF

    cat >"$fixtures/en.srt" <<'EOF'
1
00:00:01,000 --> 00:00:20,000
English subtitle line one

2
00:00:20,500 --> 00:02:59,000
English subtitle line two
EOF

    cat >"$fixtures/es.srt" <<'EOF'
1
00:00:01,000 --> 00:02:59,000
Subtítulo en español
EOF

    cat >"$fixtures/forced.srt" <<'EOF'
1
00:00:05,000 --> 00:00:15,000
[FORCED] Alien language translated
EOF

    local q=(-hide_banner -loglevel error -y)

    log "Generating Test Movie (1080p H.264, English stereo + Japanese 5.1, 3 subtitles, chapters)"
    "$ff" "${q[@]}" \
        -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=180" \
        -f lavfi -i "sine=frequency=440:duration=180" \
        -f lavfi -i "sine=frequency=660:duration=180" \
        -i "$fixtures/en.srt" -i "$fixtures/es.srt" -i "$fixtures/forced.srt" \
        -i "$fixtures/chapters.txt" \
        -map 0:v -map 1:a -map 2:a -map 3 -map 4 -map 5 -map_metadata 6 -map_chapters 6 \
        -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p \
        -c:a:0 aac -ac:a:0 2 -b:a:0 128k \
        -c:a:1 ac3 -ac:a:1 6 -b:a:1 384k \
        -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:0 title="English Stereo" \
        -metadata:s:a:1 language=jpn -metadata:s:a:1 title="Japanese 5.1" \
        -metadata:s:s:0 language=eng \
        -metadata:s:s:1 language=spa \
        -metadata:s:s:2 language=eng -metadata:s:s:2 title="Forced" \
        -disposition:a:0 0 -disposition:s:0 0 -disposition:s:2 forced \
        "$media/Movies/Test Movie (2024)/Test Movie (2024).mkv"

    log "Generating HEVC Sample (1080p HEVC MP4, embedded English + external Spanish subtitle)"
    "$ff" "${q[@]}" \
        -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=120" \
        -f lavfi -i "sine=frequency=520:duration=120" \
        -i "$fixtures/en.srt" \
        -map 0:v -map 1:a -map 2 \
        -c:v libx265 -preset veryfast -crf 32 -pix_fmt yuv420p -tag:v hvc1 -x265-params log-level=error \
        -c:a aac -b:a 96k -c:s mov_text \
        -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng \
        "$media/Movies/HEVC Sample (2023)/HEVC Sample (2023).mp4"
    cp "$fixtures/es.srt" "$media/Movies/HEVC Sample (2023)/HEVC Sample (2023).es.srt"

    for episode in 1 2 3; do
        log "Generating Test Show S01E0$episode"
        "$ff" "${q[@]}" \
            -f lavfi -i "testsrc=size=1280x720:rate=24:duration=179" \
            -f lavfi -i "sine=frequency=$((300 + episode * 100)):duration=179" \
            -i "$fixtures/en.srt" \
            -map 0:v -map 1:a -map 2 \
            -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p \
            -c:a aac -b:a 96k -c:s srt \
            -metadata title="Episode $episode" \
            -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng \
            "$media/Shows/Test Show/Season 01/Test Show S01E0$episode.mkv"
    done

    touch "$media/.complete"
}

# MARK: - Server

start() {
    if is_running && is_up; then
        log "Jellyfin already running at $URL"
        return
    fi
    if is_up || lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        die "port $PORT is used by another process ($(lsof -tiTCP:"$PORT" -sTCP:LISTEN | head -1)); stop it first"
    fi
    [[ -x "$DIR/bin/jellyfin" ]] || die "Jellyfin not installed, run: $0 setup"

    mkdir -p "$DIR/data" "$DIR/cache" "$DIR/config" "$DIR/log"
    log "Starting Jellyfin at $URL (log: $DIR/server.out)"
    local web_args=()
    if [[ -d "$DIR/web" ]]; then web_args=(--webdir "$DIR/web"); else web_args=(--nowebclient); fi
    (
        cd "$DIR"
        DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 JELLYFIN_PublishedServerUrl="$URL" \
            nohup "$DIR/bin/jellyfin" \
            --datadir "$DIR/data" \
            --cachedir "$DIR/cache" \
            --configdir "$DIR/config" \
            --logdir "$DIR/log" \
            --ffmpeg "$(ffmpeg_bin)" \
            "${web_args[@]}" \
            >"$DIR/server.out" 2>&1 &
        echo $! >"$DIR/server.pid"
    )
    wait_up
}

stop() {
    if is_running; then
        log "Stopping Jellyfin"
        kill "$(cat "$DIR/server.pid")" || true
        for _ in $(seq 1 20); do is_running || break; sleep 0.5; done
    else
        log "Jellyfin is not running"
    fi
    rm -f "$DIR/server.pid"
}

status() {
    if is_up; then
        echo "Jellyfin running at $URL"
        echo "  admin: tester / tester    app user: demo (no password)"
    else
        echo "Jellyfin not running"
        return 1
    fi
}

# MARK: - Configuration

api() {
    local method="$1" path="$2" body="${3:-}" auth="$AUTH_HEADER"
    if [[ -f "$DIR/token.txt" ]]; then auth="$auth, Token=\"$(cat "$DIR/token.txt")\""; fi
    curl -fsS -X "$method" "$URL$path" \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        ${body:+--data "$body"}
}

urlencode() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

configure() {
    local wizard
    wizard="$(curl -fsS "$URL/System/Info/Public" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("StartupWizardCompleted", False))')"

    if [[ "$wizard" != "True" ]]; then
        log "Running startup wizard"
        rm -f "$DIR/token.txt"
        api POST /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
        api GET /Startup/User >/dev/null
        api POST /Startup/User '{"Name":"tester","Password":"tester"}' >/dev/null
        api POST /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
        api POST /Startup/Complete >/dev/null
    fi

    log "Signing in as tester"
    rm -f "$DIR/token.txt"
    api POST /Users/AuthenticateByName '{"Username":"tester","Pw":"tester"}' |
        python3 -I -c 'import json,sys; print(json.load(sys.stdin)["AccessToken"])' >"$DIR/token.txt"

    if ! api GET /Users | grep -q '"Name":"demo"'; then
        log "Creating user demo (no password)"
        api POST /Users/New '{"Name":"demo"}' >/dev/null
    fi

    local existing
    existing="$(api GET /Library/VirtualFolders)"
    add_library "$existing" Movies movies "$DIR/media/Movies" true
    add_library "$existing" Shows tvshows "$DIR/media/Shows" false

    log "Scanning libraries"
    api POST /Library/Refresh >/dev/null
    for _ in $(seq 1 60); do
        sleep 2
        if api GET "/Items?Recursive=true&IncludeItemTypes=Movie,Episode" |
            python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["TotalRecordCount"] >= 5 else 1)'; then
            break
        fi
    done
}

add_library() {
    local existing="$1" name="$2" type="$3" path="$4" chapters="$5"
    if grep -q "\"Name\":\"$name\"" <<<"$existing"; then return; fi
    log "Adding library $name"
    api POST "/Library/VirtualFolders?name=$name&collectionType=$type&refreshLibrary=false" "$(
        cat <<EOF
{"LibraryOptions":{
  "EnableRealtimeMonitor":false,
  "EnableInternetProviders":false,
  "SaveLocalMetadata":false,
  "EnableTrickplayImageExtraction":false,
  "EnableChapterImageExtraction":$chapters,
  "ExtractChapterImagesDuringLibraryScan":$chapters,
  "PathInfos":[{"Path":"$path"}],
  "TypeOptions":[]
}}
EOF
    )" >/dev/null
}

setup() {
    download
    generate_media
    start
    configure
    status
}

case "${1:-}" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    status) status ;;
    configure) configure ;;
    reset) stop; rm -rf "$DIR"; log "Removed $DIR" ;;
    *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
