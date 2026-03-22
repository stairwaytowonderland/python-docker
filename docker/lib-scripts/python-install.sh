#!/bin/sh

# Only check for errors (set -e)
# Don't check for unset variables (set -u) since variables are set in Dockerfile
# Pipepail (set -o pipefail) is not available in sh
set -e

LEVEL='ƒ' $LOGGER "Installing Python utilities..."

VERSION="${PYTHON_VERSION:-latest}"
PYTHON_VERSION="$VERSION"
PYTHON_INSTALL_PREFIX="${PYTHON_INSTALL_PREFIX%/:-/opt/python}"
PYTHON_INSTALL_PATH="${PYTHON_INSTALL_PATH:-"${PYTHON_INSTALL_PREFIX%/}/lib"}"
PYTHON_DEV="${PYTHON_DEV:-false}"

# shellcheck disable=SC1090
. "$INSTALL_HELPER"

download_cpython_version() {
    LEVEL='*' $LOGGER "Downloading Python version ${1}..."

    cd /tmp
    cpython_download_prefix="Python-${1}"
    if type xz > /dev/null 2>&1; then
        cpython_download_filename="${cpython_download_prefix}.tar.xz"
    elif type gzip > /dev/null 2>&1; then
        cpython_download_filename="${cpython_download_prefix}.tgz"
    else
        LEVEL='error' $LOGGER "Required package (xz-utils or gzip) not found."
        return 1
    fi

    DOWNLOAD_URL="https://www.python.org/ftp/python/${1}/${cpython_download_filename}"

    __install_from_tarball "$DOWNLOAD_URL" "$PWD" && DOWNLOAD_DIR="${PWD}/${cpython_download_prefix}"
}

install_cpython() {
    LEVEL='*' $LOGGER "Preparing to install Python version ${VERSION} ($PYTHON_VERSION) to ${INSTALL_PATH}..."

    # Check if the specified Python version is already installed
    if [ -d "$INSTALL_PATH" ]; then
        LEVEL='!' $LOGGER "Requested Python version ${VERSION} already installed at ${INSTALL_PATH}."
    else
        cwd="$PWD"
        mkdir -p "$INSTALL_PATH"
        download_cpython_version "${VERSION}"
        if [ -d "$DOWNLOAD_DIR" ]; then
            cd "$DOWNLOAD_DIR"
        else
            LEVEL='error' $LOGGER "Failed to download Python version ${VERSION}."
            exit 1
        fi
        install_packages "${PYTHON_BUILD_DEPENDENCIES# }"

        LEVEL='*' $LOGGER "Configuring and building Python ${VERSION}..."
        LEVEL='*' $LOGGER "Installation prefix: ${PYTHON_INSTALL_PREFIX}"
        LEVEL='*' $LOGGER "Library directory: ${PYTHON_LIBDIR}"
        _configure_libdir="${PYTHON_LIBDIR:+--libdir="$PYTHON_LIBDIR"}"
        # shellcheck disable=SC2086
        ./configure --prefix="$PYTHON_INSTALL_PREFIX" ${_configure_libdir} --with-ensurepip=install --enable-optimizations
        make -j 8
        make install
        cd "$cwd" && rm -rf "$DOWNLOAD_DIR"

        # Cleanup
        remove_packages "${PYTHON_BUILD_DEPENDENCIES# }"

        # Strip unnecessary files to reduce image size
        find "$PYTHON_INSTALL_PATH" -type d -name 'test' -exec rm -rf {} + 2> /dev/null || true
        find "$PYTHON_INSTALL_PATH" -type d -name '__pycache__' -exec rm -rf {} + 2> /dev/null || true
        find "$PYTHON_INSTALL_PATH" -type f -name '*.pyc' -delete
        find "$PYTHON_INSTALL_PATH" -type f -name '*.pyo' -delete
        find "$PYTHON_INSTALL_PATH"/python* -name 'config-*' -exec rm -rf {} + 2> /dev/null || true

        if [ "$PYTHON_DEV" != "true" ]; then
            find "$PYTHON_INSTALL_PATH" -type f -name '*.a' -delete
        fi
    fi
}

ESSENTIAL_PACKAGES="${ESSENTIAL_PACKAGES% } $(
    cat << EOF
build-essential
ca-certificates
wget
gcc
git
make
EOF
)"

PYTHON_BUILD_DEPENDENCIES="${PYTHON_BUILD_DEPENDENCIES% } $(
    cat << EOF
libbz2-dev
libffi-dev
libgdbm-dev
liblzma-dev
libncurses5-dev
libreadline-dev
libssl-dev
libsqlite3-dev
libxml2-dev
libxmlsec1-dev
pkg-config
tk-dev
EOF
)"

install_python() {
    for pkg in $ESSENTIAL_PACKAGES; do
        if ! dpkg -s "$pkg" > /dev/null 2>&1; then
            PACKAGES_TO_INSTALL="${PACKAGES_TO_INSTALL% } $pkg"
        fi
    done

    update_and_install "${PACKAGES_TO_INSTALL# }"

    __find_version_from_git_tags "python/cpython" "${VERSION}" "tags/v" "."

    # major_version="${VERSION%%.*}"
    # major_minor_version="${VERSION%.*}"
    major_version=$(get_major_version "$VERSION")
    major_minor_version=$(get_major_minor_version "$VERSION")

    INSTALL_PATH="${INSTALL_PATH:-"${PYTHON_INSTALL_PATH}/python${major_minor_version}"}"
    PYTHON_LIBDIR="${PYTHON_INSTALL_PATH%/lib}/lib"

    install_cpython "$VERSION"

    updaterc "if [[ \"\${PATH}\" != *\"${PYTHON_INSTALL_PREFIX}/bin\"* ]]; then export \"PATH=${PYTHON_INSTALL_PREFIX}/bin:\${PATH}\"; fi" true

    PYTHON_SRC_ACTUAL="${PYTHON_INSTALL_PREFIX}/bin/python${major_minor_version}"
    PATH="${PYTHON_INSTALL_PREFIX}/bin:${PATH}"

    cat >> "${PYTHON_INSTALL_PATH}/.manifest" << EOF
{"path":"${PYTHON_SRC_ACTUAL}","url":"${DOWNLOAD_URL}","version":"${VERSION}","major_version":"${major_version}","major_minor_version":"${major_minor_version}"}
EOF
}

create_setup() {
    LEVEL='*' "$LOGGER" "Creating configuration script for Python ${PYTHON_VERSION}..."

    # shellcheck disable=SC2154
    touch "${PYTHON_LIBDIR}/python-setup" \
        && chmod +x "${PYTHON_LIBDIR}/python-setup" \
        && cat > "${PYTHON_LIBDIR}/python-setup" << EOF
#!/bin/sh
LEVEL='*' "$LOGGER" "Configuring Python ${PYTHON_VERSION}..."

VERSION="$VERSION"
PYTHON_VERSION="$PYTHON_VERSION"
PYTHON_INSTALL_PREFIX="$PYTHON_INSTALL_PREFIX"
INSTALL_PATH="$INSTALL_PATH"
INSTALL_TOOLS="\${INSTALL_TOOLS:-false}"

# shellcheck disable=SC1090
. "$INSTALL_HELPER"

major_version=\$(get_major_version "\$VERSION")
major_minor_version=\$(get_major_minor_version "\$VERSION")

SYSTEM_PYTHON="\$(command -v "/usr/bin/python\${major_minor_version}" || true)"
ALTERNATIVES_PATH="\${ALTERNATIVES_PATH:-/usr/local/bin}"

make_links() {
    "$LOGGER" "Creating symbolic links for Python binaries and libraries..."
    for py in python pip idle pydoc; do
        type "\${PYTHON_INSTALL_PREFIX}/bin/\${py}" >/dev/null 2>&1 || ln -s "\${py}\${major_version}" "\${PYTHON_INSTALL_PREFIX}/bin/\${py}"
    done
    type "\${PYTHON_INSTALL_PREFIX}/bin/python-config" >/dev/null 2>&1 || ln -s "python\${major_version}-config" "\${PYTHON_INSTALL_PREFIX}/bin/python-config"
}

update_env() {
    "$LOGGER" "Updating environment variables for Python \${PYTHON_VERSION}..."
    updaterc "if [[ \"\\\${PATH}\" != *\"\${PYTHON_INSTALL_PREFIX}/bin\"* ]]; then export \"PATH=\${PYTHON_INSTALL_PREFIX}/bin:\\\${PATH}\"; fi" true
    (
        . /etc/environment
        case ":\${PATH}:" in
            *":\${PYTHON_INSTALL_PREFIX}/bin:"*) ;;
            *) printf 'PATH="%s/bin:%s"\n' "\${PYTHON_INSTALL_PREFIX}" "\${PATH}" >> /etc/environment ;;
        esac
    )
    updaterc "PYTHON_VERSION=\${VERSION}" true
    {
        echo "PYTHON_VERSION=\"\${VERSION}\""
        echo "PYTHON_INSTALL_PATH=\"\${INSTALL_PATH}\""
    } >> /etc/environment
}

update_alternatives() {
    "$LOGGER" "Configuring update-alternatives for Python \${PYTHON_VERSION}..."
    for py in python pip idle pydoc; do
        priority=\$((\$( get_alternatives_priority "\$py" "\$major_version") + 1))
        [ "\$priority" -ge 0 ] || priority=\$((priority + 1))
        if [ "\${ALTERNATIVES_PATH}" != "\${PYTHON_INSTALL_PREFIX}/bin" ]; then
            syspy="\$(readlink -f "\${SYSTEM_PYTHON%/bin/python*}/bin/\${py}\${major_minor_version}")"
            if type "\$syspy" > /dev/null 2>&1; then
                (set -x ; update-alternatives --install "\${ALTERNATIVES_PATH}/\${py}\${major_version}" "\${py}\${major_version}" "\$syspy" "\$priority" && priority="\$((priority + 1))")
            fi
        fi
        [ "\$priority" -ge 1 ] || priority=\$((priority + 1))
        {
            if type "\${PYTHON_INSTALL_PREFIX}/bin/\${py}" > /dev/null 2>&1 && ! type "\${ALTERNATIVES_PATH}/\${py}" >/dev/null 2>&1; then
                (set -x ; update-alternatives --install "\${ALTERNATIVES_PATH}/\${py}" "\${py}" "\${PYTHON_INSTALL_PREFIX}/bin/\${py}" "\$priority")
            fi
            if type "\${PYTHON_INSTALL_PREFIX}/bin/\${py}\${major_version}" > /dev/null 2>&1 && ! type "\${ALTERNATIVES_PATH}/\${py}" >/dev/null 2>&1; then
                (set -x ; update-alternatives --install "\${ALTERNATIVES_PATH}/\${py}" "\${py}" "\${PYTHON_INSTALL_PREFIX}/bin/\${py}\${major_version}" "\$priority")
            fi
            if type "\${PYTHON_INSTALL_PREFIX}/bin/\${py}\${major_version}" > /dev/null 2>&1 && ! type "\${ALTERNATIVES_PATH}/\${py}\${major_version}" >/dev/null 2>&1; then
                (set -x ; update-alternatives --install "\${ALTERNATIVES_PATH}/\${py}\${major_version}" "\${py}\${major_version}" "\${PYTHON_INSTALL_PREFIX}/bin/\${py}\${major_version}" "\$priority")
            fi
        } && priority="\$((priority + 1))"
    done
    for suffix in "-config"; do
        prefix="python"
        for version in \${major_minor_version}; do
            tool="\${prefix}\${suffix}"
            py_major="\${prefix}\${version%.*}\${suffix}"
            py="\${prefix}\${version}\${suffix}"
            priority=\$((\$( get_alternatives_priority "\$py") + 1))
            [ "\$priority" -ge 0 ] || priority=\$((priority + 1))
            if [ "\${ALTERNATIVES_PATH}" != "\${PYTHON_INSTALL_PREFIX}/bin" ]; then
                syspy="\$(readlink -f "\${SYSTEM_PYTHON%/bin/python*}/bin/\${py}")"
                if type "\$syspy" >/dev/null 2>&1; then
                    (set -x ; update-alternatives --install "\${ALTERNATIVES_PATH}/\${py}" "\${py}" "\$syspy" "\$priority" && priority="\$((priority + 1))")
                fi
            fi
            [ "\$priority" -ge 1 ] || priority=\$((priority + 1))
            {
                if type "\${PYTHON_INSTALL_PREFIX}/bin/\${py_major}" > /dev/null 2>&1 && ! type "\${ALTERNATIVES_PATH}/\${tool}" >/dev/null 2>&1; then
                    (set -x ; update-alternatives --install "\${ALTERNATIVES_PATH}/\${tool}" "\${tool}" "\${PYTHON_INSTALL_PREFIX}/bin/\${py_major}" "\$priority")
                fi
                if type "\${PYTHON_INSTALL_PREFIX}/bin/\${py_major}" > /dev/null 2>&1 && ! type "\${ALTERNATIVES_PATH}/\${py}" >/dev/null 2>&1; then
                    (set -x ; update-alternatives --install "\${ALTERNATIVES_PATH}/\${py}" "\${py}" "\${PYTHON_INSTALL_PREFIX}/bin/\${py_major}" "\$priority")
                fi
                if type "\${PYTHON_INSTALL_PREFIX}/bin/\${py}" > /dev/null 2>&1 && ! type "\${ALTERNATIVES_PATH}/\${py}" >/dev/null 2>&1; then
                    (set -x ; update-alternatives --install "\${ALTERNATIVES_PATH}/\${py}" "\${py}" "\${PYTHON_INSTALL_PREFIX}/bin/\${py}" "\$priority")
                fi
            } && priority="\$((priority + 1))"
        done
    done
}

install_tools() {
    "$LOGGER" "Installing Python tools: {\${PYTHON_TOOLS}}..."
    for tool in $PYTHON_TOOLS; do
        ! type "\${PYTHON_INSTALL_PREFIX}/bin/\${tool}" >/dev/null 2>&1 || continue
        LEVEL='*' "$LOGGER" "Installing Python tool: \${tool}..."
        "$PIP_INSTALL" "\${tool}"
    done
}

main() {
    if [ "\${1-}" = "false" ]; then
        update_env
    elif [ "\${1-}" = "true" ]; then
        $PIP_INSTALL --upgrade pip
        # make_links
        update_alternatives
        [ "\${2:-false}" != "true" ] || install_tools
    else
        update_env
        # make_links
        update_alternatives
    fi
}

main "\$@"

LEVEL='√' "$LOGGER" "Python \${PYTHON_VERSION} configuration complete. Installed at \${INSTALL_PATH}."
EOF
}

main() {
    install_python
    create_setup
    remove_packages "${PACKAGES_TO_INSTALL# }"
}

main "$@"

LEVEL='√' $LOGGER "Done! Python ${VERSION} installed at ${INSTALL_PATH}."
