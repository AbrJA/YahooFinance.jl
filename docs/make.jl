push!(LOAD_PATH, "../src/")
using YahooFinance
using Documenter

makedocs(
    sitename="YahooFinance.jl",
    format=Documenter.HTML(
        analytics="G-LFRFQ0X1VF",
        canonical="https://AbrJA.github.io/YahooFinance.jl/dev/",
    ),
    modules=[YahooFinance],
    pages=[
        "Home" => "index.md",
        "API Reference" => [
            "Prices" => "prices.md",
            "Dividends & Splits" => "dividends_splits.md",
            "Fundamentals" => "fundamentals.md",
            "Quote Summary" => "quote_summary.md",
            "Options" => "options.md",
            "Search" => "search.md",
            "News" => "news.md",
            "Proxy" => "proxy.md",
            "All Functions" => "api.md",
        ],
        "Examples" => [
            "DataFrames & Tables" => "dataframes.md",
            "Plotting" => "plotting.md",
        ],
        "Changelog" => "changelog.md",
    ],
)

deploydocs(;
    repo="github.com/AbrJA/YahooFinance.jl",
    devurl="dev",
    versions=["stable" => "v^", "v#.#", "dev" => "dev"],
)