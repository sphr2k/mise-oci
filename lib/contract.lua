local M = {}
M.index_type = "application/vnd.oci.image.index.v1+json"
M.manifest_type = "application/vnd.oci.image.manifest.v1+json"
M.artifact_type = "application/vnd.mise.tool.v1"
M.archive_limit = 128 * 1024 * 1024

local function required(value, name)
    assert(type(value) == "string" and value ~= "", name .. " is required")
    return value
end

function M.digest(value)
    assert(type(value) == "string" and value:match("^sha256:%x+$") and #value == 71, "expected a sha256 digest")
    return value:lower()
end

function M.options(options, tool)
    local repository = required(options.repository, "repository")
    assert(
        repository:match("^[a-z0-9][a-z0-9.:%-]*/[a-z0-9][a-z0-9._/%-]*$"),
        "repository must be registry/path without a tag or digest"
    )
    assert(not repository:find("//", 1, true) and repository:sub(-1) ~= "/", "invalid repository path")
    for component in repository:gmatch("[^/]+") do
        assert(component ~= "." and component ~= "..", "invalid repository component")
    end
    local binary = options.binary or tool:match("([^/]+)$")
    assert(binary and binary:match("^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"), "binary must be a plain filename")
    local prefix = options.tag_prefix or ""
    assert(prefix == "" or prefix:match("^[%w_][%w_.-]*$"), "invalid tag_prefix")
    local key = options.public_key
    local issuer, subject = options.issuer, options.subject
    if key then
        required(key, "public_key")
        assert(not issuer and not subject, "use public_key OR issuer and subject")
    else
        required(issuer, "issuer")
        required(subject, "subject")
        assert(issuer:match("^https://"), "issuer must use https")
    end
    assert(options.verify == nil and options.insecure == nil, "verification cannot be disabled")
    return {
        repository = repository,
        binary = binary,
        prefix = prefix,
        key = key,
        issuer = issuer,
        subject = subject,
        digest = options.digest and M.digest(options.digest),
    }
end

function M.platform(runtime)
    assert(runtime.osType == "linux" or runtime.osType == "darwin", "supported OS: linux, darwin")
    assert(runtime.archType == "amd64" or runtime.archType == "arm64", "supported architecture: amd64, arm64")
    return runtime.osType, runtime.archType
end

function M.descriptor(value, media_type, limit)
    assert(type(value) == "table" and value.mediaType == media_type, "unexpected OCI media type")
    M.digest(value.digest)
    assert(
        type(value.size) == "number" and value.size > 0 and value.size % 1 == 0 and value.size <= limit,
        "invalid or oversized OCI descriptor"
    )
    return value
end

function M.select(index, os_name, arch)
    assert(index.schemaVersion == 2 and index.mediaType == M.index_type, "expected an OCI image index")
    assert(type(index.manifests) == "table", "index has no manifests")
    local selected
    for _, entry in ipairs(index.manifests) do
        local platform = entry.platform or {}
        if platform.os == os_name and platform.architecture == arch then
            assert(not selected, "ambiguous platform in OCI index")
            assert(
                not platform.variant or (arch == "arm64" and platform.variant == "v8"),
                "unsupported platform variant"
            )
            assert(
                not platform["os.version"] and not platform["os.features"],
                "OS-specific platform constraints are unsupported"
            )
            selected = M.descriptor(entry, M.manifest_type, 1024 * 1024)
        end
    end
    assert(selected, "no artifact for " .. os_name .. "/" .. arch)
    return selected
end

function M.archive(manifest)
    assert(manifest.schemaVersion == 2 and manifest.mediaType == M.manifest_type, "expected an OCI image manifest")
    assert(manifest.artifactType == M.artifact_type, "expected artifactType " .. M.artifact_type)
    assert(type(manifest.layers) == "table" and #manifest.layers == 1, "expected exactly one archive layer")
    local layer = M.descriptor(manifest.layers[1], "application/gzip", M.archive_limit)
    local title = layer.annotations and layer.annotations["org.opencontainers.image.title"]
    assert(
        type(title) == "string" and title:match("^[%w_][%w_.-]*%.tar%.gz$"),
        "expected a plain .tar.gz archive title"
    )
    return layer
end

function M.archive_member(listing, verbose, binary)
    local entries = {}
    for line in listing:gmatch("[^\r\n]+") do
        entries[#entries + 1] = line
    end
    assert(#entries == 1, "archive must contain exactly one root-level binary")
    local member = entries[1]
    assert(member == binary or member == "./" .. binary, "archive entry must match binary filename")
    assert(verbose:sub(1, 1) == "-", "archive binary must be a regular file, not a link")
    return member
end

return M
