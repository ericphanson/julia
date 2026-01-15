using JuliaLowering, Test, Logging, REPL

include("src/collect_qualified_access_warnings2.jl")
# _collect = collect_qualified_access_warnings2
_collect = REPL.collect_qualified_access_warnings
# Mimic of JSON.jl's structure
module JSON54872

module Parser
export parse
function parse end
end # Parser

using .Parser: parse
end # JSON54872

# Test the public mechanism
module JSON54872_public
public tryparse
end # JSON54872_public

# Nested module cases
module JSON54872_nested
module Inner
export parse
function parse end
using Base: tryparse
end # Inner

using .Inner: parse
end # JSON54872_nested

module JSON54872_public_nested
module Inner
public tryparse
function tryparse end
end # Inner
end # JSON54872_public_nested

@testset "warn_on_non_owning_accesses AST transform" begin
    @test REPL.has_ancestor(JSON54872.Parser, JSON54872)
    @test !REPL.has_ancestor(JSON54872, JSON54872.Parser)

    # JSON54872.Parser owns `parse`
    warnings = _collect(@__MODULE__, quote
        JSON54872.Parser.parse
    end)
    @test isempty(warnings)

    # A submodule of `JSON54872` owns `parse`
    warnings = _collect(@__MODULE__, quote
        JSON54872.parse
    end)
    @test isempty(warnings)

    # `JSON54872` does not own `tryparse` (nor is it public)
    warnings = _collect(@__MODULE__, quote
        JSON54872.tryparse
    end)
    @test length(warnings) == 1
    @test only(warnings).owner == Base
    @test only(warnings).name_being_accessed == :tryparse

    # Same for nested access
    warnings = _collect(@__MODULE__, quote
        JSON54872.Parser.tryparse
    end)
    @test length(warnings) == 1
    @test only(warnings).owner == Base
    @test only(warnings).name_being_accessed == :tryparse

    test_logger = TestLogger()
    with_logger(test_logger) do
        REPL.warn_on_non_owning_accesses(@__MODULE__, :(JSON54872.tryparse))
        REPL.warn_on_non_owning_accesses(@__MODULE__, :(JSON54872.tryparse))
    end
    # only 1 logging statement emitted thanks to `maxlog` mechanism
    @test length(test_logger.logs) == 1
    record = only(test_logger.logs)
    @test record.level == Warn
    @test record.message == "tryparse is defined in Base and is not public in $JSON54872"

    # However JSON54872_public has `tryparse` declared public
    warnings = _collect(@__MODULE__, quote
        JSON54872_public.tryparse
    end)
    @test isempty(warnings)

    # Re-exported from nested module; owner is submodule
    warnings = _collect(@__MODULE__, quote
        JSON54872_nested.parse
    end)
    @test isempty(warnings)

    # Direct nested access should also be fine
    warnings = _collect(@__MODULE__, quote
        JSON54872_nested.Inner.parse
    end)
    @test isempty(warnings)

    # Imported from Base in nested module should warn
    warnings = _collect(@__MODULE__, quote
        JSON54872_nested.Inner.tryparse
    end)
    @test length(warnings) == 1
    @test only(warnings).owner == Base
    @test only(warnings).name_being_accessed == :tryparse

    # Public in nested module should not warn
    warnings = _collect(@__MODULE__, quote
        JSON54872_public_nested.Inner.tryparse
    end)
    @test isempty(warnings)

    # Now let us test some tricky cases
    # No warning since `JSON54872` is local (LHS of `=`)
    warnings = _collect(@__MODULE__, quote
        let JSON54872 = (; tryparse=1)
            JSON54872.tryparse
        end
    end)
    @test isempty(warnings)

    # No warning for nested local access either
    warnings = _collect(@__MODULE__, quote
        let JSON54872 = (; Parser = (; tryparse=1))
            JSON54872.Parser.tryparse
        end
    end)
    @test isempty(warnings)

    # No warning since `JSON54872` is local (long-form function arg)
    warnings = _collect(@__MODULE__, quote
        function f(JSON54872=(; tryparse))
            JSON54872.tryparse
        end
    end)
    @test isempty(warnings)

    # No warning since `JSON54872` is local (short-form function arg)
    warnings = _collect(@__MODULE__, quote
        f(JSON54872=(; tryparse)) = JSON54872.tryparse
    end)
    @test isempty(warnings)

    # No warning since `JSON54872` is local (long-form anonymous function)
    warnings = _collect(@__MODULE__, quote
        function (JSON54872=(; tryparse))
            JSON54872.tryparse
        end
    end)
    @test isempty(warnings)

    # No warning since `JSON54872` is local (short-form anonymous function)
    warnings = _collect(@__MODULE__, quote
        (JSON54872 = (; tryparse)) -> begin
            JSON54872.tryparse
        end
    end)
    @test isempty(warnings)

    # Local alias to module should warn
    warnings = _collect(@__MODULE__, quote
        let M = JSON54872
            M.tryparse
        end
    end)
    @test length(warnings) == 1
    @test only(warnings).owner == Base
    @test only(warnings).name_being_accessed == :tryparse

    # Alias chain should warn
    warnings = _collect(@__MODULE__, quote
        let M = JSON54872
            let N = M
                N.tryparse
            end
        end
    end)
    @test length(warnings) == 1
    @test only(warnings).owner == Base
    @test only(warnings).name_being_accessed == :tryparse

    # Shadow module name with non-module local should not warn
    warnings = _collect(@__MODULE__, quote
        let JSON54872 = 1
            JSON54872.tryparse
        end
    end)
    @test isempty(warnings)

    # false-negative: missing warning
    warnings = _collect(@__MODULE__, quote
        let JSON54872 = JSON54872
            JSON54872.tryparse
        end
    end)
    @test !isempty(warnings)

    # false-negative: inner-scope locals leak outward
    warnings = _collect(@__MODULE__, quote
        let JSON54872 = (; tryparse=1)
            nothing
        end
        JSON54872.tryparse
    end)
    @test !isempty(warnings)

    # false-negative: assignment to property marks module name as local
    warnings = _collect(@__MODULE__, quote
        JSON54872.tryparse = 1
        JSON54872.tryparse
    end)
    @test !isempty(warnings)
end
