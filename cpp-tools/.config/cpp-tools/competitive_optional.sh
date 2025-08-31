# Analyze a Clang trace file using the official Perfetto UI Docker image.
function cpptrace() {
    # 1. Dependency Check.
    if ! command -v docker &>/dev/null; then
        echo "${RED}Error: 'docker' command not found.${RESET}" >&2
        echo "This feature requires Docker Desktop to run the Perfetto UI container." >&2
        echo "Please install and start Docker Desktop." >&2
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "${RED}Error: Docker daemon is not running.${RESET}" >&2
        echo "Please start Docker Desktop and try again." >&2
        return 1
    fi

    # 2. Find the Trace File.
    local target=$(_get_default_target)
    local target_name=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')
    local trace_file_path_host="$(pwd)/build/CMakeFiles/${target_name}.dir/${target_name}.cpp.json"

    if [ ! -f "$trace_file_path_host" ]; then
        echo "${RED}Error: Trace file not found for target '$target_name'.${RESET}" >&2
        echo "Expected at: ${CYAN}$trace_file_path_host${RESET}" >&2
        echo "Please build with ${YELLOW}'cppconf timing=on'${RESET} first, then rebuild the target." >&2
        return 1
    fi

    # 3. Start the Perfetto UI Container.
    local container_name="perfetto-ui-server"
    echo "${CYAN}Checking for existing Perfetto container...${RESET}"

    # Stop and remove any old container with the same name.
    if [ "$(docker ps -a -q -f name=$container_name)" ]; then
        echo "Stopping and removing existing container..."
        docker stop $container_name >/dev/null 2>&1
        docker rm $container_name >/dev/null 2>&1
    fi

    echo "${CYAN}Starting a new Perfetto UI container...${RESET}"
    # Run the official, pre-built Perfetto image.
    # -d: detached mode (runs in background).
    # -p: maps port 10000 on host to port 80 in the container.
    # -v: mounts current project directory into /share inside the container (read-only for security).
    # --rm: automatically removes the container when it's stopped.
    # --name: gives the container a predictable name.
    # --user: run as current user to avoid permission issues.
    if ! docker run \
        -d \
        -p 10000:80 \
        -v "$(pwd)":/share:ro \
        --user "$(id -u):$(id -g)" \
        --name "$container_name" \
        --rm \
        europe-west0-docker.pkg.dev/perfetto-ui/deploys/ui:latest >/dev/null 2>&1; then
        echo "${RED}Error: Failed to start Perfetto UI container.${RESET}" >&2
        echo "Please check your Docker installation and network connectivity." >&2
        return 1
    fi

    # Give the container a moment to initialize.
    echo "Waiting for container to initialize..."
    sleep 3

    # Verify the container is running.
    if ! docker ps --format "table {{.Names}}" | grep -q "^$container_name\$"; then
        echo "${RED}Error: Container failed to start properly.${RESET}" >&2
        return 1
    fi

    # 4. Open the Trace in the Browser.
    # The path to the file "inside the container".
    local trace_file_path_container="/share/build/CMakeFiles/${target_name}.dir/${target_name}.cpp.json"
    local url="http://localhost:10000/?url=file://${trace_file_path_container}"

    echo "${BLUE}Opening trace report in your default browser...${RESET}"
    echo "Trace file: ${CYAN}$(basename "$trace_file_path_host")${RESET}"

    # Cross-platform browser opening.
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "$url"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v xdg-open >/dev/null; then
            xdg-open "$url"
        else
            echo "${YELLOW}Please open this URL manually: $url${RESET}"
        fi
    else
        echo "${YELLOW}Please open this URL manually: $url${RESET}"
    fi

    echo ""
    echo "${BOLD}${GREEN}[*] Perfetto UI is running in a Docker container.${RESET}"
    echo "${YELLOW}To stop the server later, run:${RESET}"
    echo "  ${CYAN}docker stop $container_name${RESET}"
}
