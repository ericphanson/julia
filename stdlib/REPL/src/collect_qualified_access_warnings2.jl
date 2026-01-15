const jl = JuliaLowering

struct QualifiedAccessContext
    current_mod::Module
    bindings::jl.Bindings
    assignments::Dict{Int, Vector{jl.SyntaxTree}}
    alias_modules::Dict{Int, Module}
    non_module_bindings::Set{Int}
end

function QualifiedAccessContext(current_mod::Module, bindings::jl.Bindings)
    QualifiedAccessContext(
        current_mod,
        bindings,
        Dict{Int, Vector{jl.SyntaxTree}}(),
        Dict{Int, Module}(),
        Set{Int}(),
    )
end

function qa_symbol_from_leaf(node)
    jl.kind(node) == jl.K"Symbol" || return nothing
    name = get(node, :name_val, nothing)
    name === nothing && return nothing
    return name isa Symbol ? name : Symbol(name)
end

function qa_is_getproperty_call(ctx::QualifiedAccessContext, node)
    if jl.kind(node) != jl.K"call" || jl.numchildren(node) < 3
        return false
    end
    f = node[1]
    if jl.kind(f) == jl.K"top"
        return f.name_val == "getproperty"
    elseif jl.kind(f) == jl.K"BindingId"
        binfo = jl.get_binding(ctx.bindings, f)
        return binfo.kind === :global && binfo.name == "getproperty"
    end
    return false
end

function qa_collect_assignments!(ctx::QualifiedAccessContext, node)
    node isa jl.SyntaxTree || return
    if jl.kind(node) == jl.K"=" && jl.numchildren(node) == 2
        lhs = node[1]
        rhs = node[2]
        if jl.kind(lhs) == jl.K"BindingId"
            push!(get!(ctx.assignments, lhs.var_id, jl.SyntaxTree[]), rhs)
        end
    end
    for child in jl.children(node)
        qa_collect_assignments!(ctx, child)
    end
    return
end

function qa_module_from_global_binding(binfo)
    binfo.mod === nothing && return nothing
    name = Symbol(binfo.name)
    mod_value = try
        getproperty(binfo.mod, name)
    catch
        return nothing
    end
    return mod_value isa Module ? mod_value : nothing
end

function qa_module_from_node_for_alias(ctx::QualifiedAccessContext, node)
    if jl.kind(node) == jl.K"BindingId"
        binfo = jl.get_binding(ctx.bindings, node)
        if binfo.kind === :global
            return qa_module_from_global_binding(binfo)
        end
        return get(ctx.alias_modules, binfo.id, missing)
    elseif jl.kind(node) == jl.K"Identifier"
        name = qa_symbol_from_leaf(node)
        name === nothing && return nothing
        mod_value = try
            getproperty(ctx.current_mod, name)
        catch
            return nothing
        end
        return mod_value isa Module ? mod_value : nothing
    elseif jl.kind(node) == jl.K"Value"
        val = get(node, :value, nothing)
        return val isa Module ? val : nothing
    end
    return nothing
end

function qa_resolve_alias_modules!(ctx::QualifiedAccessContext, ex3)
    qa_collect_assignments!(ctx, ex3)
    changed = true
    while changed
        changed = false
        for (id, rhs_list) in ctx.assignments
            haskey(ctx.alias_modules, id) && continue
            id in ctx.non_module_bindings && continue
            resolved = nothing
            unresolved = false
            invalid = false
            for rhs in rhs_list
                rhs_mod = qa_module_from_node_for_alias(ctx, rhs)
                if rhs_mod === missing
                    unresolved = true
                elseif rhs_mod === nothing
                    invalid = true
                    break
                elseif resolved === nothing
                    resolved = rhs_mod
                elseif resolved !== rhs_mod
                    invalid = true
                    break
                end
            end
            if invalid
                push!(ctx.non_module_bindings, id)
            elseif !unresolved && resolved !== nothing
                ctx.alias_modules[id] = resolved
                changed = true
            end
        end
    end
    return
end

function qa_module_from_binding(ctx::QualifiedAccessContext, node)
    if jl.kind(node) == jl.K"BindingId"
        binfo = jl.get_binding(ctx.bindings, node)
        if binfo.kind === :global
            return qa_module_from_global_binding(binfo)
        end
        return get(ctx.alias_modules, binfo.id, nothing)
    elseif jl.kind(node) == jl.K"Identifier"
        name = qa_symbol_from_leaf(node)
        name === nothing && return nothing
        mod_value = try
            getproperty(ctx.current_mod, name)
        catch
            return nothing
        end
        return mod_value isa Module ? mod_value : nothing
    end
    return nothing
end

function qa_resolve_module_chain(ctx::QualifiedAccessContext, node)
    if qa_is_getproperty_call(ctx, node) && jl.kind(node[3]) == jl.K"Symbol"
        parent = qa_resolve_module_chain(ctx, node[2])
        parent === nothing && return nothing
        outer_mod, mod = parent
        name = qa_symbol_from_leaf(node[3])
        name === nothing && return nothing
        mod_value = try
            getproperty(mod, name)
        catch
            return nothing
        end
        mod_value isa Module || return nothing
        return (outer_mod, mod_value)
    end
    mod = qa_module_from_binding(ctx, node)
    mod === nothing && return nothing
    return (mod, mod)
end

function qa_annotate_qualified_accesses_rec!(ctx::QualifiedAccessContext, node)
    node isa jl.SyntaxTree || return
    jl.kind(node) == jl.K"module" && return
    if qa_is_getproperty_call(ctx, node) && jl.kind(node[3]) == jl.K"Symbol"
        mods = qa_resolve_module_chain(ctx, node[2])
        mods === nothing && return
        outer_mod, mod = mods
        name = qa_symbol_from_leaf(node[3])
        name === nothing && return
        jl.setattr!(node, :qualified_access, (outer_mod, mod, name))
        return
    end
    for child in jl.children(node)
        qa_annotate_qualified_accesses_rec!(ctx, child)
    end
    return
end

function qa_annotate_qualified_accesses!(ctx::QualifiedAccessContext, ex3)
    graph = jl.syntax_graph(ex3)
    jl.ensure_attributes!(graph; qualified_access=Union{Nothing, Tuple{Module, Module, Symbol}})
    qa_resolve_alias_modules!(ctx, ex3)
    qa_annotate_qualified_accesses_rec!(ctx, ex3)
    return ex3
end

function annotate_qualified_accesses!(current_mod, ctx3, ex3)
    ctx = QualifiedAccessContext(current_mod, ctx3.bindings)
    qa_annotate_qualified_accesses!(ctx, ex3)
    return ex3
end

function qa_collect_qualified_accesses!(accesses, node)
    node isa jl.SyntaxTree || return
    access = get(node, :qualified_access, nothing)
    if access !== nothing
        outer_mod, mod, name = access
        push!(accesses, (; outer_mod, mod, name))
    end
    for child in jl.children(node)
        qa_collect_qualified_accesses!(accesses, child)
    end
    return
end

function qualified_accesses_scoped(current_mod, ctx3, ex3)
    annotate_qualified_accesses!(current_mod, ctx3, ex3)
    accesses = Vector{NamedTuple{(:outer_mod, :mod, :name), Tuple{Module, Module, Symbol}}}()
    qa_collect_qualified_accesses!(accesses, ex3)
    return accesses
end

function collect_qualified_access_warnings2(current_mod, ast)
    ast isa Expr || return Set()
    st = jl.expr_to_syntaxtree(ast)
    ctx1, ex1 = jl.expand_forms_1(current_mod, st, true, Base.get_world_counter())
    ctx2, ex2 = jl.expand_forms_2(ctx1, ex1)
    ctx3, ex3 = jl.resolve_scopes(ctx2, ex2)
    warnings = Set()
    for (; outer_mod, mod, name) in qualified_accesses_scoped(current_mod, ctx3, ex3)
        owner = try
            which(mod, name)
        catch
            continue
        end
        REPL.has_ancestor(owner, mod) && continue
        Base.ispublic(mod, name) && continue
        mod === Base && Base.ispublic(Core, name) && continue
        push!(warnings, (; outer_mod, mod, owner, name_being_accessed=name))
    end
    return warnings
end
collect_qualified_access_warnings2(ast) = collect_qualified_access_warnings2(Base.active_module(), ast)
