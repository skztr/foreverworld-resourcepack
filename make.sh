#!/bin/bash
set -e
set -o pipefail

usage(){
    echo "build.sh [--version=<minecraft version|latest|latest-snapshot>]"
}

ensure_command(){
    local command="$1"; shift
    local defined="${command^^}"
    if [[ -z "${!defined}" ]]; then
        declare -g "$defined"="$(which "$command")"
        if [[ -z "${!defined}" ]]; then
            printf '%s not found in PATH. Install %s or define a %s env var.\n' "$command" "$command" "$defined" >&2
            return 1
        fi
    fi

    return 0
}

ensure_command "curl"
ensure_command "dirname"
ensure_command "jar"
ensure_command "jq"
ensure_command "zip"
curl(){ "$CURL" "$@"; }
dirname(){ "$DIRNAME" "$@"; }
jar(){ "$JAR" "$@"; }
jq(){ "$JQ" "$@"; }
zip(){ "$ZIP" "$@"; }

versions_json=
versions(){
    if [[ -n "$versions_json" ]]; then
        printf '%s' "$versions_json"
        return 0
    fi

    versions_json="$( curl -s 'https://launchermeta.mojang.com/mc/game/version_manifest.json' )"
    if [[ -z "$versions_json" ]]; then
        printf '%s\n' "Failed to download version manifest" >&2
        return 1
    fi

    printf '%s' "$versions_json"
}

ensure_version(){
    local version="$1"; shift
    local path="$1"; shift
    local target=

    case "$version" in
        latest)
            target=release
            ;;
        latest-snapshot)
            target=snapshot
            ;;
    esac

    if [[ -n "$target" ]]; then
        version="$( jq -r --arg target "$target" '.latest[$target]//""' < <(versions) )"
        if [[ -z "$version" ]]; then
            printf 'Failed to determine %s version\n' "$target" >&2
            return 1
        fi
    fi

    path="$path/minecraft.$version.jar"
    if [[ -e "$path" ]]; then
        printf '%s\n' "$path"
        return 0
    fi

    manifest_url="$( jq -r --arg version "$version" '.versions[]|select(.id == $version)|.url' < <(versions) )"
    if [[ -z "$manifest_url" ]]; then
        printf 'Failed to determine version %s manifest URL\n' "$version" >&2
        return 1
    fi

    local manifest_json
    manifest_json="$( curl -s "$manifest_url" )"
    if [[ -z "$manifest_json" ]]; then
        printf 'Failed to download version %s manifest JSON\n' "$version" >&2
        return 1
    fi

    mkdir -p "${path%/*}"
    curl -s "$( jq -r .downloads.client.url <<<"$manifest_json" )" > "$path"
    printf '%s\n' "$path"
    return 0
}

version=latest
while [ $# -gt 0 ]; do
    arg="$1"; shift

    case "$arg" in
        --version=*)
            version="${arg#*=}"
            ;;
        --versions)
            versions
            exit $?
            ;;
        --help)
            usage
            exit
            ;;
        --)
            args=( "${args[@]}" "$@" )
            break
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

base="$(dirname "${BASH_SOURCE[0]}")"
client_path="$( ensure_version "$version" "$base/.cache" )"

transform_hardcore_icons(){
    local client_path="$1"; shift
    local texture_path="$1"; shift
    jar xf "$client_path" "$texture_path"

    local conversion=(
        '('
            -clone 0

            '('
                # the original image, with the hardcore hearts copied over-top of the non-hardcore hearts
                -clone 0
                '('
                    -clone 0
                    -crop '240x9!+16+45'
                ')'
                -geometry +16+0
                -compose src-over
                -composite
            ')'

            -delete 0

            # set opacity to 33%
            '('
               +clone
               -alpha extract
               '('
                   +clone
                   -fill 'gray(33%)'
                    -draw 'color 0,0 reset'
                ')' \
               -compose multiply
                -composite
                -alpha copy
            ')'
            +geometry
            -compose copy-opacity
            -composite
        ')'

        -compose src-over
        -composite
    )
    convert "$texture_path" "${conversion[@]}" "$texture_path"
}

transform_map_icons(){
    local client_path="$1"; shift
    local texture_path="$1"; shift
    jar xf "$client_path" "$texture_path"
    convert "$texture_path" \
        '(' \
            +clone \
            -alpha extract \
            -strokewidth 0 \
            -fill 'black' \
            -draw 'rectangle 49,0 63,7' \
            -alpha copy \
        ')' \
        +geometry -compose copy_opacity -composite \
        "$texture_path"
}

orig="$PWD"
cd "$base" || exit 1

rm -rf ./assets
transform_hardcore_icons "$client_path" "assets/minecraft/textures/gui/icons.png"
transform_map_icons "$client_path" "assets/minecraft/textures/map/map_icons.png"

zip -r "$orig/foreverworld-resourcepack.zip" . -x '.cache*' -x '.git*' -x '*.zip' -x '*.sh' -x '*.swp' -x '*.xcf'
