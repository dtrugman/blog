#/bin/bash

usage() {
    echo "Usage: $0 <run>"
    return 1
}

main() {
    if [[ $# -eq 2 ]]; then
        usage
        exit 1
    fi

    declare -r cmd="$1"

    case "$1" in
        run)
            (cd web; bundle exec jekyll serve --host 0.0.0.0)
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
