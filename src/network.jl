# ─────────────────────────────────────────────────────────────────────────────
# network.jl — Core networking layer for YahooFinance.jl
# Provides: YahooSession, rate-limited requests, retry logic, URL building,
#           connection pooling via persistent Downloader
# ─────────────────────────────────────────────────────────────────────────────

"""
    _rand_header() -> Dict{String,String}

Generate a random browser header for anti-fingerprinting.
"""
_rand_header()::Dict{String,String} = _random_header()

# ─── URL Encoding ─────────────────────────────────────────────────────────────

const _SAFE_URI_CHARS = Set{Char}(vcat(
    collect('A':'Z'), collect('a':'z'), collect('0':'9'),
    ['-', '.', '_', '~']
))

"""
    _uri_encode(s::AbstractString) -> String

Percent-encode a string for use in URLs (RFC 3986).
"""
function _uri_encode(s::AbstractString)::String
    io = IOBuffer(sizehint=ncodeunits(s))
    for c in s
        if c in _SAFE_URI_CHARS
            write(io, c)
        else
            for byte in codeunits(string(c))
                write(io, '%', uppercase(string(byte; base=16, pad=2)))
            end
        end
    end
    return String(take!(io))
end

"""
    _build_query_string(params) -> String

Build a URL query string from key-value pairs. Skips empty string values.
"""
function _build_query_string(params)::String
    parts = String[]
    for (k, v) in params
        sv = string(v)
        isempty(sv) && continue
        push!(parts, "$(_uri_encode(string(k)))=$(_uri_encode(sv))")
    end
    return join(parts, '&')
end

"""
    _build_url(base::AbstractString, params) -> String

Append query parameters to a base URL.
"""
function _build_url(base::AbstractString, params)::String
    qs = _build_query_string(params)
    return isempty(qs) ? String(base) : "$base?$qs"
end

# ─── Response Error Type ──────────────────────────────────────────────────────

"""
    ResponseError <: Exception

Represents an HTTP error response from the Yahoo Finance API.
"""
struct ResponseError <: Exception
    status::Int
    body::Vector{UInt8}
end

function Base.showerror(io::IO, e::ResponseError)
    print(io, "ResponseError: HTTP ", e.status)
    if !isempty(e.body)
        text = String(copy(e.body))
        if length(text) > 200
            text = text[1:200] * "…"
        end
        print(io, " — ", text)
    end
end

# ─── Yahoo Session (singleton, thread-safe) ───────────────────────────────────

"""
    YahooSession

Holds authentication state (cookie, crumb), rate-limiting configuration,
and a persistent `Downloads.Downloader` for connection reuse.
Thread-safe via `ReentrantLock`.
"""
mutable struct YahooSession
    # Auth state
    cookie::Dict{String,String}
    crumb::String
    header::Dict{String,String}

    # Proxy config
    proxy::Union{Nothing,String}
    proxy_auth::Dict{String,String}

    # Rate limiting
    last_request_time::Float64
    const min_request_interval::Float64  # seconds between requests
    const max_retries::Int
    const retry_base_delay::Float64      # base delay for exponential backoff

    # Connection pooling
    downloader::Union{Nothing,Downloads.Downloader}

    # State
    initialized::Bool
    crumb_failed_at::Float64      # timestamp of last crumb failure (0.0 = never)
    const lock::ReentrantLock
end

function YahooSession(;
    min_request_interval::Float64=0.5,
    max_retries::Int=3,
    retry_base_delay::Float64=2.0
)
    return YahooSession(
        Dict{String,String}(),   # cookie
        "",                       # crumb
        Dict{String,String}(),   # header
        nothing,                  # proxy
        Dict{String,String}(),   # proxy_auth
        0.0,                      # last_request_time
        min_request_interval,
        max_retries,
        retry_base_delay,
        nothing,                  # downloader (lazy init)
        false,                    # initialized
        0.0,                      # crumb_failed_at
        ReentrantLock()
    )
end

"""Global singleton session — all requests go through this."""
const _SESSION = YahooSession()

# ─── Connection Pooling ───────────────────────────────────────────────────────

"""
    _get_downloader() -> Downloads.Downloader

Returns the persistent Downloader instance (connection pool).
Creates one on first use. Thread-safe (double-checked locking).
"""
function _get_downloader()::Downloads.Downloader
    dl = _SESSION.downloader
    if !isnothing(dl)
        return dl
    end
    lock(_SESSION.lock) do
        dl = _SESSION.downloader
        if isnothing(dl)
            dl = Downloads.Downloader()
            _SESSION.downloader = dl
        end
        return dl
    end
end

# ─── Session Management ───────────────────────────────────────────────────────

"""Seconds to wait before retrying crumb fetch after a failure."""
const _CRUMB_COOLDOWN = 120.0

const _CRUMB_URLS = (
    "https://query2.finance.yahoo.com/v1/test/getcrumb",
    "https://query1.finance.yahoo.com/v1/test/getcrumb",
)

const _COOKIE_URLS = (
    "https://fc.yahoo.com",
    "https://finance.yahoo.com",
)

"""
    _ensure_session!()

Thread-safe initialization of the Yahoo session (cookie + crumb).
Only fetches if not already initialized.
"""
function _ensure_session!()
    lock(_SESSION.lock) do
        if !_SESSION.initialized
            _SESSION.header = _rand_header()
            _fetch_cookie!()
            _fetch_crumb!()
            _SESSION.initialized = true
        end
    end
    return nothing
end

"""
    _renew_session!()

Forces a fresh cookie+crumb fetch regardless of current state.
Call when receiving 401/403 responses. Respects crumb cooldown to avoid
hammering Yahoo when the endpoint is blocked.
"""
function _renew_session!()
    lock(_SESSION.lock) do
        _SESSION.header = _rand_header()
        _fetch_cookie!()
        _fetch_crumb!()
        _SESSION.initialized = true
    end
    return nothing
end

"""
    _fetch_cookie!() -> Bool

Fetch session cookies from Yahoo. Tries multiple endpoints.
Returns `true` if cookies were obtained.
"""
function _fetch_cookie!()::Bool
    for (i, url) in enumerate(_COOKIE_URLS)
        headers = _build_headers(Dict{String,String}())
        resp = _raw_request(url; headers=headers, timeout=10, throw_on_error=false)
        if resp.status != 0
            cookies = _parse_set_cookie(resp.headers)
            if !isempty(cookies)
                _SESSION.cookie = cookies
                return true
            end
        end
        i < length(_COOKIE_URLS) && sleep(1.0)
    end
    _SESSION.cookie = Dict{String,String}()
    return false
end

"""
    _fetch_crumb!() -> Bool

Fetch the CSRF crumb token from Yahoo. Respects a cooldown period after
failure to avoid triggering further rate-limits. Returns `true` on success.
"""
function _fetch_crumb!()::Bool
    # Cooldown: skip if we recently failed (avoids hammering a blocked endpoint)
    if _SESSION.crumb_failed_at > 0.0
        elapsed = time() - _SESSION.crumb_failed_at
        if elapsed < _CRUMB_COOLDOWN
            return false
        end
    end

    # Can't get crumb without cookies
    if isempty(_SESSION.cookie)
        _SESSION.crumb = ""
        _SESSION.crumb_failed_at = time()
        @warn "Cannot fetch crumb: no session cookies obtained from Yahoo."
        return false
    end

    for attempt in 1:3
        url = _CRUMB_URLS[mod1(attempt, length(_CRUMB_URLS))]
        headers = _build_headers(_SESSION.cookie)
        resp = _raw_request(url; headers=headers, timeout=10, throw_on_error=false)
        if resp.status in 200:299
            crumb = String(resp.body)
            if !isempty(crumb) && !startswith(crumb, "<") && !startswith(crumb, "{")
                _SESSION.crumb = crumb
                _SESSION.crumb_failed_at = 0.0  # reset on success
                return true
            end
        end
        attempt < 3 && sleep(2.0^attempt)  # 2s, 4s exponential
    end

    _SESSION.crumb = ""
    _SESSION.crumb_failed_at = time()
    @warn "Crumb retrieval failed (Yahoo is likely rate-limiting this IP). " *
          "Endpoints requiring authentication will not work. " *
          "Will retry automatically after $(_CRUMB_COOLDOWN)s cooldown."
    return false
end

# ─── Header Building ─────────────────────────────────────────────────────────

function _build_headers(cookies::Dict{String,String})::Vector{Pair{String,String}}
    headers = Pair{String,String}[]
    sizehint!(headers, 12)

    # Browser headers (override accept-encoding to avoid gzip issues)
    for (k, v) in _SESSION.header
        lowercase(k) == "accept-encoding" && continue
        push!(headers, k => v)
    end
    push!(headers, "Accept-Encoding" => "identity")

    # Proxy auth headers
    for (k, v) in _SESSION.proxy_auth
        push!(headers, k => v)
    end

    # Cookies
    if !isempty(cookies)
        cookie_str = join(("$k=$v" for (k, v) in cookies), "; ")
        push!(headers, "Cookie" => cookie_str)
    end

    return headers
end

# ─── Cookie Parsing ───────────────────────────────────────────────────────────

function _parse_set_cookie(headers::Vector)::Dict{String,String}
    cookies = Dict{String,String}()
    for (name, value) in headers
        if lowercase(name) == "set-cookie"
            cookie_part = first(split(value, ';'))
            eq_pos = findfirst('=', cookie_part)
            if !isnothing(eq_pos)
                cname = strip(String(cookie_part[1:eq_pos-1]))
                cvalue = strip(String(cookie_part[eq_pos+1:end]))
                cookies[cname] = cvalue
            end
        end
    end
    return cookies
end

# ─── Rate Limiting ────────────────────────────────────────────────────────────

"""
    _throttle!()

Enforces minimum interval between requests. Thread-safe.
Computes wait time under lock, then sleeps outside the lock to avoid blocking
other threads.
"""
function _throttle!()
    wait_time = lock(_SESSION.lock) do
        elapsed = time() - _SESSION.last_request_time
        remaining = _SESSION.min_request_interval - elapsed
        if remaining > 0.0
            return remaining
        end
        _SESSION.last_request_time = time()
        return 0.0
    end
    if wait_time > 0.0
        sleep(wait_time)
        lock(_SESSION.lock) do
            _SESSION.last_request_time = time()
        end
    end
    return nothing
end

# ─── Raw Request (no retry, no rate limit) ────────────────────────────────────

"""
    _raw_request(url; headers, timeout, throw_on_error) -> NamedTuple

Low-level GET request using the persistent Downloader. No retry or rate limiting.
"""
function _raw_request(url::AbstractString;
    headers::Vector{Pair{String,String}}=Pair{String,String}[],
    timeout::Real=10,
    throw_on_error::Bool=true
)
    output = IOBuffer()
    downloader = _get_downloader()

    proxy = _SESSION.proxy
    resp = if !isnothing(proxy)
        Downloads.request(url;
            method="GET", headers=headers, output=output,
            timeout=Float64(timeout), downloader=downloader,
            throw=false, proxy=proxy)
    else
        Downloads.request(url;
            method="GET", headers=headers, output=output,
            timeout=Float64(timeout), downloader=downloader,
            throw=false)
    end

    # Downloads.request with throw=false returns RequestError on connection failures
    if resp isa Downloads.RequestError
        if throw_on_error
            throw(ResponseError(0, Vector{UInt8}(resp.message)))
        end
        return (status=0, body=Vector{UInt8}(resp.message), headers=Pair{String,String}[])
    end

    body = take!(output)
    resp_status = resp.status
    resp_headers = Pair{String,String}[String(k) => String(v) for (k, v) in resp.headers]

    if throw_on_error && resp_status >= 400
        throw(ResponseError(resp_status, body))
    end

    return (status=resp_status, body=body, headers=resp_headers)
end

# ─── Main Request Function (rate-limited + retry) ─────────────────────────────

"""
    _request(url; timeout=10, throw_on_error=true) -> NamedTuple

Makes a rate-limited, retrying GET request using the current session.
- Throttles to respect `min_request_interval`
- Retries on 429 with exponential backoff
- Renews session on 401/403 before retrying
- Retries on transient network errors
"""
function _request(url::AbstractString; timeout::Real=10, throw_on_error::Bool=true)
    _ensure_session!()
    headers = lock(_SESSION.lock) do
        _build_headers(_SESSION.cookie)
    end
    current_url = String(url)

    for attempt in 1:_SESSION.max_retries
        _throttle!()

        try
            # Always throw internally so retry logic works; handle throw_on_error at the end
            return _raw_request(current_url; headers=headers, timeout=timeout, throw_on_error=true)
        catch e
            is_last = attempt == _SESSION.max_retries

            if !(e isa ResponseError)
                # Network/timeout error — retry with backoff
                is_last && (throw_on_error ? rethrow() : return _error_response(e))
                sleep(min(5.0, _SESSION.retry_base_delay * attempt))
                continue
            end

            if e.status == 429
                # Rate limited — backoff + renew session identity
                is_last && (throw_on_error ? rethrow() : return (status=e.status, body=e.body, headers=Pair{String,String}[]))
                _renew_session!()
                headers = lock(_SESSION.lock) do
                    _build_headers(_SESSION.cookie)
                end
                current_url = _update_crumb(current_url)
                sleep(min(5.0, _SESSION.retry_base_delay * attempt))
                continue
            elseif e.status in (401, 403)
                # Auth expired — renew and retry
                is_last && (throw_on_error ? rethrow() : return (status=e.status, body=e.body, headers=Pair{String,String}[]))
                _renew_session!()
                headers = lock(_SESSION.lock) do
                    _build_headers(_SESSION.cookie)
                end
                current_url = _update_crumb(current_url)
                continue
            else
                # Other HTTP error — don't retry
                throw_on_error ? rethrow() : return (status=e.status, body=e.body, headers=Pair{String,String}[])
            end
        end
    end

    # Unreachable, but satisfies the compiler
    error("Request failed after $(_SESSION.max_retries) attempts: $url")
end

"""Convert a non-HTTP exception into a response tuple for throw_on_error=false mode."""
function _error_response(e::Exception)
    msg = sprint(showerror, e)
    return (status=0, body=Vector{UInt8}(msg), headers=Pair{String,String}[])
end

"""Replace stale crumb in URL with the current session crumb."""
function _update_crumb(url::String)::String
    m = match(r"([?&])crumb=[^&]*", url)
    isnothing(m) && return url
    return replace(url, m.match => "$(m.captures[1])crumb=$(_uri_encode(_SESSION.crumb))")
end

# ─── Yahoo Error Parsing ──────────────────────────────────────────────────────

"""
    _parse_yahoo_error(body, status, symbol) -> String

Parses Yahoo Finance error response bodies. Handles both JSON and plain-text.
"""
function _parse_yahoo_error(body::Vector{UInt8}, status::Int, symbol::String="")::String
    try
        yahoo_error = JSON.parse(String(copy(body)))
        if haskey(yahoo_error, "finance") &&
           yahoo_error["finance"] isa AbstractDict &&
           haskey(yahoo_error["finance"], "error") &&
           yahoo_error["finance"]["error"] isa AbstractDict &&
           haskey(yahoo_error["finance"]["error"], "description")
            return string(yahoo_error["finance"]["error"]["description"])
        elseif haskey(yahoo_error, "chart") &&
               yahoo_error["chart"] isa AbstractDict &&
               haskey(yahoo_error["chart"], "error") &&
               yahoo_error["chart"]["error"] isa AbstractDict &&
               haskey(yahoo_error["chart"]["error"], "description")
            desc = string(yahoo_error["chart"]["error"]["description"])
            date_matches = collect(eachmatch(r"(-)?[0-9]{1,}", desc))
            if length(date_matches) >= 2
                error_dates = unix2datetime.(parse.(Float64, [m.match for m in date_matches[1:2]]))
                return "Data doesn't exist for startDate = $(error_dates[1]), endDate = $(error_dates[2]) for $symbol"
            end
            return desc
        else
            return "HTTP error $status for $symbol"
        end
    catch
        text = String(copy(body))
        return isempty(text) ? "HTTP error $status for $symbol" : first(text, 200)
    end
end

# ─── High-level Yahoo Request ─────────────────────────────────────────────────

"""
    _yahoo_get(url, symbol; timeout=10, throw_error=false, empty_result=nothing)

Standard pattern for all Yahoo Finance GET requests.
Returns the response NamedTuple on success, or `nothing` on failure (when `throw_error=false`).
"""
function _yahoo_get(url::AbstractString, symbol::String=""; timeout::Real=10, throw_error::Bool=false, empty_result=nothing)
    try
        return _request(url; timeout=timeout)
    catch e
        msg = if e isa ResponseError
            if e.status == 404
                "$symbol — not a valid symbol (Yahoo returned 404)."
            elseif e.status == 429
                "$symbol — Yahoo rate limit (HTTP 429) after $(_SESSION.max_retries) attempts. Your IP is temporarily blocked. Wait 1-5 minutes and retry."
            elseif e.status in (401, 403)
                "$symbol — Yahoo authentication failed (HTTP $(e.status)) after session renewal. Cookie/crumb may be blocked."
            else
                desc = _parse_yahoo_error(e.body, e.status, symbol)
                "$symbol — Yahoo returned HTTP $(e.status): $desc"
            end
        else
            "$symbol — network error: $(sprint(showerror, e))"
        end

        if throw_error
            error(msg)
        else
            @warn msg
            return nothing
        end
    end
end
