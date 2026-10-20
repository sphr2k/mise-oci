local cmd = require("cmd")
local file = require("file")
local json = require("json")
local contract = require("contract")
local versions = require("versions")
local M = {}

local function run(command, env)
    env = env or {}
    env.LC_ALL = "C"
    return cmd.exec(command, { env = env, timeout = 120 })
end

local function hash(path)
    local command = RUNTIME.osType == "darwin" and 'shasum -a 256 "$FILE"' or 'sha256sum "$FILE"'
    local result = run(command, { FILE = path }):match("^(%x+)")
    assert(result and #result == 64, "could not hash downloaded content")
    return "sha256:" .. result:lower()
end

local function check_file(path, descriptor)
    local stat = file.stat(path)
    assert(stat and stat.is_file and not stat.is_symlink and stat.size == descriptor.size, "download size mismatch")
    assert(hash(path) == contract.digest(descriptor.digest), "download digest mismatch")
end

local function manifest(repository, digest, path, descriptor)
    run('oras manifest fetch --output "$FILE" "$REF"', { FILE = path, REF = repository .. "@" .. digest })
    if descriptor then
        check_file(path, descriptor)
    else
        local stat = file.stat(path)
        assert(stat and stat.is_file and stat.size <= 1024 * 1024, "oversized OCI index")
        assert(hash(path) == digest, "index digest mismatch")
    end
    return json.decode(file.read(path))
end

local function verify(ref, options)
    if options.key then
        run('cosign verify --timeout 90s --key "$KEY" "$REF"', { KEY = options.key, REF = ref })
    else
        run(
            'cosign verify --timeout 90s --certificate-oidc-issuer "$ISSUER" --certificate-identity "$SUBJECT" "$REF"',
            {
                ISSUER = options.issuer,
                SUBJECT = options.subject,
                REF = ref,
            }
        )
    end
end

function M.list_versions(ctx)
    local options = contract.options(ctx.options, ctx.tool)
    local tags = run('oras repo tags "$REPOSITORY"', { REPOSITORY = options.repository })
    return versions.from_tags(tags, options.prefix)
end

function M.install(ctx)
    local options = contract.options(ctx.options, ctx.tool)
    local os_name, arch = contract.platform(RUNTIME)
    assert(versions.parse(ctx.version), "version must be SemVer without build metadata")
    local tag = options.prefix .. ctx.version
    assert(#tag <= 128, "OCI tag exceeds 128 characters")
    run('mkdir -p "$DIR"', { DIR = ctx.download_path })

    local resolved =
        run('oras resolve "$REF"', { REF = options.repository .. ":" .. tag }):match("^%s*(sha256:%x+)%s*$")
    local digest = contract.digest(resolved)
    assert(not options.digest or digest == options.digest, "configured index digest does not match resolved tag")
    local ref = options.repository .. "@" .. digest
    verify(ref, options)

    local index = manifest(options.repository, digest, file.join_path(ctx.download_path, "index.json"))
    local selected = contract.select(index, os_name, arch)
    local child =
        manifest(options.repository, selected.digest, file.join_path(ctx.download_path, "manifest.json"), selected)
    local layer = contract.archive(child)
    local archive = file.join_path(ctx.download_path, "tool.tar.gz")
    run('oras blob fetch --output "$FILE" "$REF"', { FILE = archive, REF = options.repository .. "@" .. layer.digest })
    check_file(archive, layer)

    local listing = run('tar -tzf "$ARCHIVE"', { ARCHIVE = archive })
    local verbose = run('tar -tvzf "$ARCHIVE"', { ARCHIVE = archive })
    local member = contract.archive_member(listing, verbose, options.binary)
    local staged = file.join_path(ctx.download_path, "binary")
    -- Stream one regular member to a fixed file; never let tar choose filesystem paths.
    run(
        'ulimit -f 524288; tar -xOzf "$ARCHIVE" "$MEMBER" > "$FILE"',
        { ARCHIVE = archive, MEMBER = member, FILE = staged }
    )
    local stat = file.stat(staged)
    assert(
        stat and stat.is_file and not stat.is_symlink and stat.size > 0 and stat.size <= 256 * 1024 * 1024,
        "invalid or oversized executable"
    )
    run('chmod 755 "$FILE"', { FILE = staged })
    local destination = file.join_path(ctx.install_path, "bin", options.binary)
    -- Stage on the installation filesystem, then publish by rename.
    run('mkdir -p "$DIR"; cp "$SOURCE" "$STAGED"; chmod 755 "$STAGED"', {
        DIR = file.join_path(ctx.install_path, "bin"),
        SOURCE = staged,
        STAGED = destination .. ".partial",
    })
    file.move(destination .. ".partial", destination)
    print("Verified OCI index " .. digest .. " (" .. os_name .. "/" .. arch .. ")")
end

return M
