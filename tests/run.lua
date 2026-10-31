package.path = "lib/?.lua;" .. package.path
local contract = require("contract")
local versions = require("versions")
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        error(name .. ": " .. tostring(err))
    end
    count = count + 1
    print("ok " .. count .. " - " .. name)
end
local function rejects(pattern, fn)
    local ok, err = pcall(fn)
    assert(not ok, "unexpected success")
    assert(tostring(err):find(pattern, 1, true), tostring(err))
end
local digest = "sha256:" .. string.rep("a", 64)
local child = {
    mediaType = contract.manifest_type,
    digest = digest,
    size = 123,
    platform = { os = "linux", architecture = "amd64" },
}
local function index(manifests)
    return { schemaVersion = 2, mediaType = contract.index_type, manifests = manifests }
end
local function options(extra)
    local result = { repository = "ghcr.io/example/tool", public_key = "/path with spaces/key.pub" }
    for k, v in pairs(extra or {}) do
        result[k] = v
    end
    return result
end

test("public key trust config", function()
    assert(contract.options(options(), "tool").key == "/path with spaces/key.pub")
end)
test("exact keyless trust config", function()
    local result = contract.options(
        { repository = "ghcr.io/example/tool", issuer = "https://issuer.example", subject = "https://pipeline.example" },
        "tool"
    )
    assert(result.subject == "https://pipeline.example")
end)
test("missing and ambiguous trust rejected", function()
    rejects("issuer is required", function()
        contract.options({ repository = "ghcr.io/example/tool" }, "tool")
    end)
    rejects("OR", function()
        contract.options(options({ issuer = "https://issuer", subject = "subject" }), "tool")
    end)
end)
test("unsafe options rejected", function()
    for _, repository in ipairs({
        "https://ghcr.io/example/tool",
        "ghcr.io/example/tool:latest",
        "ghcr.io/example/../tool",
        "ghcr.io/example//tool",
        "$(touch bad)",
        "ghcr.io/example/tool@sha256:bad",
    }) do
        rejects("", function()
            contract.options(options({ repository = repository }), "tool")
        end)
    end
    rejects("filename", function()
        contract.options(options({ binary = "../escape" }), "tool")
    end)
    rejects("skip flags", function()
        contract.options(options({ verify = "false" }), "tool")
    end)
end)
test("digest-only requires a pin and rejects ambiguous trust", function()
    local config = { repository = "ghcr.io/example/tool", verification = "digest", digest = digest }
    assert(contract.options(config, "tool").verification == "digest")
    config.digest = nil
    rejects("requires an explicit", function()
        contract.options(config, "tool")
    end)
    config.digest = digest
    config.public_key = "/key.pub"
    rejects("does not accept signer", function()
        contract.options(config, "tool")
    end)
    config.public_key = nil
    config.verification = "none"
    rejects("verification must be", function()
        contract.options(config, "tool")
    end)
end)

test("digest validation", function()
    assert(contract.digest(digest) == digest)
    rejects("sha256", function()
        contract.digest("sha256:abc")
    end)
    rejects("sha256", function()
        contract.digest(digest .. "\n")
    end)
end)
test("supported runtime boundaries", function()
    assert(contract.platform({ osType = "darwin", archType = "arm64" }) == "darwin")
    rejects("supported OS", function()
        contract.platform({ osType = "windows", archType = "amd64" })
    end)
end)
test("select platform from signed index", function()
    assert(contract.select(index({ child }), "linux", "amd64") == child)
    rejects("no artifact", function()
        contract.select(index({ child }), "darwin", "arm64")
    end)
end)
test("ambiguous and constrained platform rejected", function()
    rejects("ambiguous", function()
        contract.select(index({ child, child }), "linux", "amd64")
    end)
    local entry = {
        mediaType = child.mediaType,
        digest = digest,
        size = 123,
        platform = { os = "linux", architecture = "amd64", variant = "v3" },
    }
    rejects("variant", function()
        contract.select(index({ entry }), "linux", "amd64")
    end)
end)
test("image manifest cannot masquerade as index", function()
    rejects("index", function()
        contract.select({ schemaVersion = 2, mediaType = contract.manifest_type }, "linux", "amd64")
    end)
end)
test("archive format and bounds", function()
    local layer = {
        mediaType = "application/gzip",
        digest = digest,
        size = 42,
        annotations = { ["org.opencontainers.image.title"] = "tool.tar.gz" },
    }
    local manifest = {
        schemaVersion = 2,
        mediaType = contract.manifest_type,
        artifactType = contract.artifact_type,
        layers = { layer },
    }
    assert(contract.archive(manifest) == layer)
    layer.size = contract.archive_limit + 1
    rejects("oversized", function()
        contract.archive(manifest)
    end)
    layer.size = 42
    layer.annotations["org.opencontainers.image.title"] = "../escape.tar.gz"
    rejects("title", function()
        contract.archive(manifest)
    end)
    manifest.layers = { layer, layer }
    rejects("exactly one", function()
        contract.archive(manifest)
    end)
end)
test("archive traversal, links and extra entries rejected", function()
    assert(contract.archive_member("./tool\n", "-rwxr-xr-x info", "tool") == "./tool")
    for _, name in ipairs({ "../tool", "/tool", "bin/tool", "other", "tool\nother" }) do
        rejects("", function()
            contract.archive_member(name .. "\n", "-rwxr-xr-x info", "tool")
        end)
    end
    for _, kind in ipairs({ "l", "h", "d", "b", "c", "p" }) do
        rejects("regular", function()
            contract.archive_member("tool\n", kind .. " info", "tool")
        end)
    end
end)
test("SemVer sorting includes prerelease precedence", function()
    local tags =
        "v1.10.0\nv1.2.0\nv2.0.0\nv2.0.0-rc.10\nv2.0.0-rc.2\nv2.0.0-beta\nv2.0.0-1\nv1.2.0\nsha256-dead.sig\nlatest\n"
    local actual = versions.from_tags(tags, "v")
    assert(table.concat(actual, ",") == "1.2.0,1.10.0,2.0.0-1,2.0.0-beta,2.0.0-rc.2,2.0.0-rc.10,2.0.0")
end)
test("invalid tags are not versions", function()
    for _, version in ipairs({
        "latest",
        "1.2",
        "01.2.3",
        "1.2.3+build",
        "1.2.3-01",
        "1.2.3-foo..bar",
        "1.2.3-.foo",
        "1.2.3-foo.",
        "1.2.3;echo",
    }) do
        assert(not versions.parse(version), version)
    end
end)

-- Exercise the real orchestration with mocked boundaries, including stop-on-failure.
local calls, files, fail, raw_index, raw_manifest, cache_root, cached_bytes
package.loaded.env = {
    getenv = function()
        return cache_root
    end,
}
package.loaded.cmd = {
    exec = function(command, ctx)
        calls[#calls + 1] = { command = command, env = ctx.env }
        if command:find("${MISE_CACHE_DIR-}", 1, true) then
            return cache_root or ""
        end
        if fail and command:find(fail, 1, true) then
            error("fixture failure: " .. fail)
        end
        if command:find('test -f "$CACHE"', 1, true) then
            assert(cached_bytes, "cache miss")
            files[ctx.env.FILE] = cached_bytes
        elseif command:find("mktemp -d", 1, true) then
            cached_bytes = files[ctx.env.FILE]
        elseif command:find("oras blob fetch", 1, true) then
            files[ctx.env.FILE] = "valid archive"
        end
        if command:find("oras resolve", 1, true) then
            return digest .. "\n"
        end
        if command:find("oras manifest fetch", 1, true) then
            files[ctx.env.FILE] = ctx.env.FILE:match("index.json$") and raw_index or raw_manifest
        end
        if command:find("sha256sum", 1, true) then
            return string.rep(files[ctx.env.FILE] == "corrupt" and "b" or "a", 64) .. "  file\n"
        end
        if command:find("tar -tzf", 1, true) then
            return "tool\n"
        end
        if command:find("tar -tvzf", 1, true) then
            return "-rwxr-xr-x fixture\n"
        end
        return ""
    end,
}
package.loaded.file = {
    join_path = function(...)
        return table.concat({ ... }, "/")
    end,
    stat = function(path)
        return { is_file = true, is_symlink = false, size = files[path] == "wrong size" and 122 or 123 }
    end,
    read = function(path)
        return files[path]
    end,
    move = function()
        calls[#calls + 1] = { command = "publish" }
    end,
}
package.loaded.json = {
    decode = function(value)
        return value
    end,
}
RUNTIME = { osType = "linux", archType = "amd64" }
local oci = require("oci")
local function setup()
    calls, files, fail = {}, {}, nil
    cache_root, cached_bytes = nil, nil
    raw_index = index({ child })
    raw_manifest = {
        schemaVersion = 2,
        mediaType = contract.manifest_type,
        artifactType = contract.artifact_type,
        layers = {
            {
                mediaType = "application/gzip",
                digest = digest,
                size = 123,
                annotations = { ["org.opencontainers.image.title"] = "tool.tar.gz" },
            },
        },
    }
    return {
        tool = "tool",
        version = "1.2.3",
        options = options({ digest = digest }),
        install_path = "/install with spaces",
        download_path = "/download with spaces",
    }
end
local function command_index(pattern)
    for i, call in ipairs(calls) do
        if call.command:find(pattern, 1, true) then
            return i
        end
    end
end

test("verify signed index before fetching children; publish last", function()
    oci.install(setup())
    assert(command_index("cosign verify") < command_index("oras manifest fetch"))
    assert(command_index("oras blob fetch") < command_index("tar -tzf"))
    assert(calls[#calls].command == "publish")
    for _, call in ipairs(calls) do
        if call.command:find("oras manifest fetch", 1, true) or call.command:find("oras blob fetch", 1, true) then
            assert(call.env.REF == "ghcr.io/example/tool@" .. digest)
        end
    end
end)
test("digest-only installs without calling Cosign", function()
    local ctx = setup()
    ctx.options.public_key = nil
    ctx.options.verification = "digest"
    fail = "cosign verify"
    oci.install(ctx)
    assert(not command_index("cosign verify"))
    assert(calls[#calls].command == "publish")
end)
test("digest-only rejects mismatching content before publication", function()
    local ctx = setup()
    ctx.options.public_key = nil
    ctx.options.verification = "digest"
    raw_manifest.layers[1].digest = "sha256:" .. string.rep("b", 64)
    rejects("digest mismatch", function()
        oci.install(ctx)
    end)
    assert(not command_index("publish"))
end)

test("signature failure prevents download and publication", function()
    local ctx = setup()
    fail = "cosign verify"
    rejects("fixture failure", function()
        oci.install(ctx)
    end)
    assert(not command_index("oras blob fetch") and not command_index("publish"))
end)
test("pin mismatch stops before signature or download", function()
    local ctx = setup()
    ctx.options.digest = "sha256:" .. string.rep("b", 64)
    rejects("does not match", function()
        oci.install(ctx)
    end)
    assert(not command_index("cosign verify") and not command_index("publish"))
end)
test("download integrity failure prevents archive handling", function()
    local ctx = setup()
    raw_manifest.layers[1].digest = "sha256:" .. string.rep("b", 64)
    rejects("digest mismatch", function()
        oci.install(ctx)
    end)
    assert(not command_index("tar -tzf") and not command_index("publish"))
end)
test("exact keyless identity is passed without shell interpolation", function()
    local ctx = setup()
    ctx.options.public_key = nil
    ctx.options.issuer = "https://issuer.example"
    ctx.options.subject = "https://pipeline.example/$(touch nope)"
    oci.install(ctx)
    local call = calls[command_index("cosign verify")]
    assert(call.env.SUBJECT == ctx.options.subject)
    assert(not call.command:find("pipeline.example", 1, true))
    assert(not call.command:find("regexp", 1, true))
end)
test("archive cache reuses bytes but always verifies signatures and integrity", function()
    local ctx = setup()
    cache_root = "/cache with spaces"
    oci.install(ctx)
    assert(command_index("oras blob fetch"))
    assert(cached_bytes == "valid archive")
    calls = {}
    oci.install(ctx)
    assert(not command_index("oras blob fetch"))
    assert(command_index("cosign verify"))
    assert(command_index("sha256sum"))
    cached_bytes = "corrupt"
    calls = {}
    oci.install(ctx)
    assert(command_index("oras blob fetch"))
    assert(cached_bytes == "valid archive")
    cached_bytes = "wrong size"
    calls = {}
    oci.install(ctx)
    assert(command_index("oras blob fetch"))
    assert(cached_bytes == "valid archive")
end)
test("cache publication failure does not prevent installation", function()
    local ctx = setup()
    cache_root = "/unwritable cache"
    fail = "mktemp -d"
    oci.install(ctx)
    assert(command_index("oras blob fetch"))
    assert(calls[#calls].command == "publish")
end)
print("1.." .. count)
