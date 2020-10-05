using QuadraticModels, QPSReader
using Quadmath
# path_pb = "C:\\Users\\Geoffroy Leconte\\Documents\\cours\\TFE\\code\\quadLP\\data\\MPS"
path_pb = "/home/mgi.polymtl.ca/geleco/quad_optim/problems/quadLP/data/MPS"

function rm_ifix!(ifix, Qrows, Qcols, Qvals, c, c0, Arows, Acols, Avals,
                  Lcon, Ucon, lvar, uvar, n_rows, n_cols)
    T = eltype(c)
    # get Qii
    diag_Q = zeros(T, n_cols)
    for i=1:length(Qvals)
        if Qrows[i] == Qcols[i]
            diag_Q[Qrows[i]] = Qvals[i]
        end
    end
    ifix = sort!(ifix)
    # update c0, c
    Qji = zero(T)
    for i=1:length(ifix)
        c0 += c[ifix[i]] * lvar[ifix[i]] + diag_Q[ifix[i]] * lvar[ifix[i]]^2 / 2
        for j=1:n_cols
            Qji = zero(T)
            for k=1:length(Qvals)
                if (Qrows[k] == i && Qcols[k] == j) || (Qrows[k] == j && Qcols[k] == i)
                    Qji += Qvals[k]
                end
            end
            c[j] += lvar[ifix[i]] * Qji
        end
    end

    # remove columns in ifix
    ifix_cols_A = findall(x->x in ifix, Acols)
    ifix_cols_A = sort!(ifix_cols_A)
    for i=1:length(Acols)
        if i in ifix_cols_A
            Lcon[Arows[i]] -= Avals[i] * lvar[Acols[i]]
            Ucon[Arows[i]] -= Avals[i] * lvar[Acols[i]]
        end
    end
    Arows_rm_fix = Arows[ifix_cols_A]
    Acols_rm_fix = Acols[ifix_cols_A]
    Avals_rm_fix = Avals[ifix_cols_A]
    Arows = deleteat!(Arows, ifix_cols_A)
    Acols = deleteat!(Acols, ifix_cols_A)
    Avals = deleteat!(Avals, ifix_cols_A)

    for i=1:length(Acols)
        if Acols[i] > ifix[1]
            Acols[i] -= findlast(ifix .<= Acols[i])
        end
    end
    # remove rows and columns in ifix
    ifix_cols_Q = findall(x-> x in ifix, Qcols)

    Q_rm_idx = [] #unique(hcat(ifix_rows_Q, ifix_cols_Q))
    Qrows_rm_fix = Qrows[Q_rm_idx]
    Qcols_rm_fix = Qcols[Q_rm_idx]
    Qvals_rm_fix = Qvals[Q_rm_idx]
    for i=1:length(ifix_cols_Q)
        Qrows_rm_fix = push!(Qrows_rm_fix, splice!(Qrows, ifix_cols_Q[i]-i+1))
        Qcols_rm_fix = push!(Qcols_rm_fix, splice!(Qcols, ifix_cols_Q[i]-i+1))
        Qvals_rm_fix = push!(Qvals_rm_fix, splice!(Qvals, ifix_cols_Q[i]-i+1))
    end
    ifix_rows_Q = findall(x-> x in ifix, Qrows)
    for i=1:length(ifix_rows_Q)
        Qrows_rm_fix = push!(Qrows_rm_fix, splice!(Qrows, ifix_rows_Q[i]-i+1))
        Qcols_rm_fix = push!(Qcols_rm_fix, splice!(Qcols, ifix_rows_Q[i]-i+1))
        Qvals_rm_fix = push!(Qvals_rm_fix, splice!(Qvals, ifix_rows_Q[i]-i+1))
    end

    for i=1:length(Qcols)
        if  Qrows[i] > ifix[1]
            Qrows[i] -= findlast(ifix .<= Qrows[i])
        end
        if Qcols[i] > ifix[1]
            Qcols[i] -= findlast(ifix .<= Qcols[i])
        end
    end

    c_rm_fix = c[ifix]
    x_rm_fix = lvar[ifix]
    c = deleteat!(c, ifix)
    lvar = deleteat!(lvar, ifix)
    uvar = deleteat!(uvar, ifix)
    n_cols -= length(ifix)

    return Qrows, Qcols, Qvals, c, c0, Arows, Acols, Avals, Lcon, Ucon,
            lvar, uvar, n_cols, Arows_rm_fix, Acols_rm_fix, Avals_rm_fix,
            Qrows_rm_fix, Qcols_rm_fix, Qvals_rm_fix, c_rm_fix, x_rm_fix, ifix
end

function createQuadraticModel128(qpdata; name="qp_pb")
    return QuadraticModel(convert(Array{Float128}, qps1.c), qpdata.qrows, qpdata.qcols,
            convert(Array{Float128}, qps1.qvals),
            Arows=qpdata.arows, Acols=qpdata.acols,
            Avals=convert(Array{Float128}, qps1.avals),
            lcon=convert(Array{Float128}, qps1.lcon),
            ucon=convert(Array{Float128}, qps1.ucon),
            lvar=convert(Array{Float128}, qps1.lvar),
            uvar=convert(Array{Float128}, qps1.uvar),
            c0=Float128(qpdata.c0), name=name)
end

# qps1 = readqps(string(path_pb, "\\TMA_ME.mps"))
qps1 = readqps(string(path_pb, "/TMA_ME.mps"))
qps1.qrows, qps1.qcols, qps1.qvals,
    qps1.c, qps1.c0, qps1.arows,
    qps1.acols, qps1.avals, qps1.lcon,
    qps1.ucon, qps1.lvar, qps1.uvar,
    qps1.nvar,
    Arows_rm_fix, Acols_rm_fix, Avals_rm_fix,
    Qrows_rm_fix, Qcols_rm_fix, Qvals_rm_fix,
    c_rm_fix, x_rm_fix, ifix = rm_ifix!(findall(qps1.uvar .== qps1.lvar),
                                        qps1.qrows, qps1.qcols, qps1.qvals,
                                        qps1.c, qps1.c0, qps1.arows, qps1.acols,
                                        qps1.avals, qps1.lcon, qps1.ucon, qps1.lvar,
                                        qps1.uvar, qps1.ncon, qps1.nvar)
qm1 = createQuadraticModel128(qps1)
# qm1 = QuadraticModel(qps1)
# include(raw"C:\Users\Geoffroy Leconte\Documents\cours\TFE\code\StageOptim\amdahl_benchmarks\src128\RipQP.jl")
include("/home/mgi.polymtl.ca/geleco/git_workspace/StageOptim/amdahl_benchmarks/src128/RipQP.jl")

stats1 = RipQP.ripqp(qm1, mode=:multi, max_iter=20000)
println(stats1)

# qps2 = readqps(string(path_pb, "\\GlcAerWT.mps"))
# qm2 = QuadraticModel(qps1)