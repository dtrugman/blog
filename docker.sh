#/bin/bash

usage() {
    echo "Usage: $0 <build|run>"
    return 1
}

main() {
    if [[ $# -eq 2 ]]; then
        usage
        exit 1
    fi

    declare -r cmd="$1"

    declare -r cwd="$(pwd)"
    declare -r workdir="/app"

    declare -r tag="jekyll:latest"
    declare -r port="4000"

    case "$1" in
        build)
            docker build --tag "$tag" .
            ;;
        run)
            docker run -it --rm -p "$port:$port" -v "$cwd:/app" "$tag"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
