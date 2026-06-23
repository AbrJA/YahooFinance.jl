# ─── Unit Tests (no network calls) ────────────────────────────────────────────

@testset "Unit Tests" begin

    @testset "Date Conversion" begin
        @test YahooFinance._to_unix("2000-01-01") == 946684800
        @test YahooFinance._to_unix(Date(2000, 1, 1)) == 946684800
        @test YahooFinance._to_unix(DateTime(2000, 1, 1)) == 946684800
        @test YahooFinance._to_unix(Date(1970, 1, 1)) == 0
        @test YahooFinance._to_unix("2024-06-15") == YahooFinance._to_unix(Date(2024, 6, 15))
    end

    @testset "URL Encoding" begin
        @test YahooFinance._uri_encode("hello world") == "hello%20world"
        @test YahooFinance._uri_encode("AAPL") == "AAPL"
        @test YahooFinance._uri_encode("a&b=c") == "a%26b%3Dc"
        @test YahooFinance._uri_encode("") == ""
        @test YahooFinance._uri_encode("café") == "caf%C3%A9"
        @test YahooFinance._uri_encode("100%") == "100%25"
    end

    @testset "URL Building" begin
        @test YahooFinance._build_url("https://example.com", Dict("a" => "1")) == "https://example.com?a=1"
        @test YahooFinance._build_url("https://example.com", Dict{String,String}()) == "https://example.com"
        # Empty values are skipped
        @test YahooFinance._build_url("https://example.com", Dict("a" => "1", "b" => "")) == "https://example.com?a=1"
    end

    @testset "Vector Cleaning" begin
        # Copy for Float64 (no aliasing)
        v = [1.0, 2.0, 3.0]
        cleaned = YahooFinance._clean_vec(v)
        @test cleaned == v
        @test cleaned !== v  # must be independent copy
        # Integer conversion
        @test YahooFinance._clean_vec([1, 2, 3]) == [1.0, 2.0, 3.0]
        # Nothing → NaN
        result = YahooFinance._clean_vec([nothing, 1.0, nothing])
        @test isnan(result[1])
        @test result[2] == 1.0
        @test isnan(result[3])
        # All nothing
        @test all(isnan, YahooFinance._clean_vec([nothing, nothing]))
    end

    @testset "ResponseError Display" begin
        err = YahooFinance.ResponseError(404, UInt8[])
        @test sprint(showerror, err) == "ResponseError: HTTP 404"
        err2 = YahooFinance.ResponseError(500, Vector{UInt8}("Server Error"))
        @test contains(sprint(showerror, err2), "Server Error")
        # Long body is truncated
        long_body = Vector{UInt8}(repeat("x", 300))
        err3 = YahooFinance.ResponseError(500, long_body)
        @test contains(sprint(showerror, err3), "…")
    end

    @testset "Range Parsing" begin
        s, e = YahooFinance._range_to_unix("5d")
        @test e > s
        @test e - s ≈ 5 * 86400 atol=10

        s2, e2 = YahooFinance._range_to_unix("1y")
        @test e2 - s2 > 364 * 86400

        s3, e3 = YahooFinance._range_to_unix("3mo")
        @test e3 - s3 > 80 * 86400

        s4, _ = YahooFinance._range_to_unix("ytd")
        @test s4 == YahooFinance._to_unix(Date(year(today()), 1, 1))

        s5, _ = YahooFinance._range_to_unix("max")
        @test s5 == 0

        @test_throws ErrorException YahooFinance._range_to_unix("invalid")
    end

    @testset "Type Constructors" begin
        # PriceData empty constructor
        p = PriceData("AAPL", 0)
        @test isempty(p)
        @test length(p) == 0
        @test p.ticker == "AAPL"

        # DividendData
        d = DividendData("AAPL")
        @test isempty(d)
        @test d.ticker == "AAPL"

        # SplitData
        s = SplitData("AAPL")
        @test isempty(s)
        @test s.ticker == "AAPL"

        # SearchResult
        sr = SearchResult("AAPL", "Apple Inc.", "NASDAQ (NMS)", "EQUITY", "Technology", "Consumer Electronics")
        @test sr.symbol == "AAPL"
        @test sr.type == "EQUITY"

        # NewsItem
        ni = NewsItem("Title", "Publisher", "http://example.com", DateTime(2024,1,1), ["AAPL"])
        @test ni.title == "Title"
        @test ni.symbols == ["AAPL"]
    end

    @testset "Tables Interface - PriceData" begin
        p = PriceData("TEST",
            [DateTime(2024,1,1), DateTime(2024,1,2)],
            [100.0, 101.0], [102.0, 103.0], [99.0, 100.0],
            [101.0, 102.0], [101.5, 102.5], [1e6, 1.1e6],
            Float64[], Float64[])

        @test Tables.istable(typeof(p))
        @test Tables.columnaccess(typeof(p))
        @test :open in Tables.columnnames(p)
        @test :adjclose in Tables.columnnames(p)
        @test :dividend in Tables.columnnames(p)  # always present (zeros when empty)
        @test Tables.getcolumn(p, :dividend) == [0.0, 0.0]  # zeros for empty
        @test Tables.getcolumn(p, :split_ratio) == [1.0, 1.0]  # ones for empty
        @test Tables.getcolumn(p, :ticker) == ["TEST", "TEST"]
        @test Tables.getcolumn(p, :open) == [100.0, 101.0]
        @test length(Tables.getcolumn(p, 1)) == 2  # ticker column by index

        # With div/split data
        p2 = PriceData("TEST",
            [DateTime(2024,1,1)], [100.0], [102.0], [99.0],
            [101.0], [101.5], [1e6], [0.5], [2.0])
        @test :dividend in Tables.columnnames(p2)
        @test :split_ratio in Tables.columnnames(p2)
    end

    @testset "Tables Interface - DividendData" begin
        d = DividendData("TEST", [DateTime(2024,1,1)], [0.22])
        @test Tables.istable(typeof(d))
        @test Tables.getcolumn(d, :dividend) == [0.22]
        @test Tables.getcolumn(d, :ticker) == ["TEST"]
    end

    @testset "Tables Interface - SplitData" begin
        s = SplitData("TEST", [DateTime(2024,1,1)], [4], [1], [4.0])
        @test Tables.istable(typeof(s))
        @test Tables.getcolumn(s, :ratio) == [4.0]
        @test Tables.getcolumn(s, :numerator) == [4]
    end

    @testset "Tables Interface - OptionChain" begin
        c = YahooFinance.OptionContract("C1", 150.0, "USD", 5.0, 0.1, 2.0,
                                     100, 500, 4.9, 5.1, "REGULAR",
                                     DateTime(2024,3,15), DateTime(2024,1,10),
                                     0.3, true, "call")
        chain = OptionChain("TEST", [c], YahooFinance.OptionContract[])
        @test Tables.istable(typeof(chain))
        @test Tables.getcolumn(chain, :strike) == [150.0]
        @test Tables.getcolumn(chain, :type) == ["call"]
    end

    @testset "Input Validation" begin
        @test_throws AssertionError get_prices("AAPL", interval="invalid")
        @test_throws ArgumentError search_news("AAPL", lang="xx-yy")
        @test_throws AssertionError get_fundamentals("AAPL", "income_statement", "invalid", "2020-01-01", "2021-01-01")
        @test_throws AssertionError get_fundamentals("AAPL", "NotARealItem", "annual", "2020-01-01", "2021-01-01")
    end

    @testset "Proxy Configuration" begin
        set_proxy!("http://proxy.test:8080", "user", "pass")
        @test YahooFinance._SESSION.proxy == "http://proxy.test:8080"
        @test haskey(YahooFinance._SESSION.proxy_auth, "Proxy-Authorization")
        expected_auth = "Basic " * Base64.base64encode("user:pass")
        @test YahooFinance._SESSION.proxy_auth["Proxy-Authorization"] == expected_auth

        set_proxy!("http://open.test:3128")
        @test YahooFinance._SESSION.proxy == "http://open.test:3128"
        @test isempty(YahooFinance._SESSION.proxy_auth)

        clear_proxy!()
        @test isnothing(YahooFinance._SESSION.proxy)
        @test isempty(YahooFinance._SESSION.proxy_auth)
    end

    @testset "Constants" begin
        @test QUOTE_SUMMARY_ITEMS isa Vector{String}
        @test "price" in QUOTE_SUMMARY_ITEMS
        @test length(QUOTE_SUMMARY_ITEMS) == 34

        @test FUNDAMENTAL_TYPES isa Dict{String,Vector{String}}
        @test haskey(FUNDAMENTAL_TYPES, "income_statement")
        @test haskey(FUNDAMENTAL_TYPES, "balance_sheet")
        @test haskey(FUNDAMENTAL_TYPES, "cash_flow")
        @test haskey(FUNDAMENTAL_TYPES, "valuation")

        @test FUNDAMENTAL_INTERVALS isa Vector{String}
        @test Set(FUNDAMENTAL_INTERVALS) == Set(["annual", "quarterly", "monthly"])
    end

    @testset "Session Struct" begin
        @test YahooFinance._SESSION isa YahooFinance.YahooSession
        @test YahooFinance._SESSION.min_request_interval > 0
        @test YahooFinance._SESSION.max_retries >= 1
    end

    @testset "Header Generation" begin
        h = YahooFinance._random_header()
        @test h isa Dict{String,String}
        @test haskey(h, "User-Agent")
        @test contains(h["User-Agent"], "Mozilla")
        @test haskey(h, "accept")
        @test haskey(h, "upgrade-insecure-requests")
        # Each call produces a header (may differ)
        h2 = YahooFinance._random_header()
        @test h2 isa Dict{String,String}
    end
end
