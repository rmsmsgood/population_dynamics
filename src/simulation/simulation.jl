function initializer(POPULATION, y)
    Npop = sum(POPULATION[:,end])
    gdf = groupby(POPULATION, :location)
    
    location_ = zeros(Int8, Npop)
    for cnpop = cumsum(combine(gdf, y => sum => :npop).npop)
        location_[1:cnpop] .+= 1
    end
    location_ .-= 18
    
    gender_ = Bool[]
    for k ∈ 1:17
        male, female = combine(groupby(gdf[k], :gender), y => sum => :npop).npop
        append!(gender_, zeros(Bool, male))
        append!(gender_, ones(Bool, female))
    end
        
    age_ = Int8[]
    for (age, npop) ∈ zip(mod.((1:3400) .- 1, 100), POPULATION[:,end])
        append!(age_, repeat([age], npop))
    end

    return location_, gender_, age_
end

function validizer(p)
    return min(1, max(0, p))
end

function simulation(seed, POPULATION, MOBILITY)
    location_, gender_, age_ = initializer(POPULATION, :y2021)
    traj = deepcopy(POPULATION)
    dead = deepcopy(POPULATION)
    mgrn = deepcopy(MOBILITY)
    Random.seed!(seed)

    tend = 2100
    for t in 2021:tend

    # 죽음 시작
    print('|')
    bit_location_ = Dict([loc => (location_ .== loc) for loc ∈ -(1:18)])
    bit_age_ = Dict([a => (age_ .== a) for a ∈ 0:100])
    bit_gender_ = Dict([gen => (gender_ .== gen) for gen ∈ [false, true]])
    population = Int64[]
    death = Int64[]
    for loc ∈ -(1:17), gen ∈ [false, true]
        bit_double = bit_location_[loc] .&& bit_gender_[gen] # CPU
        for a ∈ 0:99 # 반복문의 순서 자체는 기록을 위해서 바뀌어선 안 됨
            μ = validizer(tensor_mortality[a+1, -loc, gen+1] * (1 + (ε * randn())))
            # println("loc: $loc, gen: $gen, a: $a")

            bit_triple = (bit_age_[a] .&& bit_double)
            pidx = findall(bit_triple)
            push!(population, length(pidx))
            died = rand(Bernoulli(μ), length(pidx))
            push!(death, count(died))
            location_[pidx[died]] .= -18

            # ▲ Pure CPU

            # bit_triple = (CuArray(bit_age_[a]) .&& bit_double) |> Array |> BitVector
            # pidx = findall(bit_triple) # 연령이 가장 spare하므로 &&에선 앞에 있는게 빠름
            # push!(population, length(pidx))
            # died = rand(Bernoulli(μ), totalpop) # rand() .< μ 랑 속도는 같음
            # location_[pidx[died]] .= -18

            # ▲ semiCPU ▼ GPU 이 방식이 단일 시뮬레이션으로 가장 빠름

            # bit_triple = (CuArray(bit_age_[a]) .&& bit_double)
            # push!(population, count(bit_triple))
            # bit_quadra = ((CUDA.rand(totalpop) .< μ) .&& bit_triple)
            # Cu_location_ = (Cu_location_ .* .!bit_quadra) - 18bit_quadra
            # CUDA.unsafe_free!(bit_quadra)
            # CUDA.unsafe_free!(bit_triple)
        end
        # CUDA.unsafe_free!(bit_double)
    end
    # location_ = Array(Cu_location_)
    # CUDA.unsafe_free!(Cu_location_)

    traj[!, string('y', t)] = population
    dead[!, string('y', t)] = death
    println(Dates.now())
    CSV.write("D:/rslt $(lpad(seed, 4, '0')).csv", traj, encoding = "UTF-8", bom = true)
    CSV.write("D:/dead $(lpad(seed, 4, '0')).csv", dead, encoding = "UTF-8", bom = true)
    if t == tend break end

    location_[age_ .≥ 100] .= -18
    bit_location_ = Dict([loc => (location_ .== loc) for loc ∈ -(1:17)])
    # 죽음 끝

    # 출산 시작
    bit_age5_ = Dict([a => (a .≤ age_ .< (a + 5)) for a ∈ 0:5:80])
    bit_age5_[80] = (80 .≤ age_)
    birth_location = zeros(Int64, 17)
    flow = Int64[]
    for loc ∈ -(1:17), gen ∈ [false, true]
        bit_double = bit_location_[loc] .&& bit_gender_[gen]
        for a ∈ (0:5:80)
            aidx = (a ÷ 5) + 1
            bit_triple = bit_age5_[a] .&& bit_double
            pidx = shuffle(findall(bit_triple))
            
            # 이동 시작
            npop = length(pidx)
            σ = tensor_mobility[aidx, gen+1, :, -loc] # .* (1 .+ (ε * randn(17)))
            moved = trunc.(Int64, σ .* npop)
            append!(flow, moved)
            moved = reverse(cumsum(moved)) # 230107 작동 검증 안 됨
            # moved = reverse(trunc.(Int64, cumsum(σ) .* npop))
            for to in 1:17
                location_[pidx[1:min(npop, moved[to])]] .= (to-18) # 인구수 이상으로는 이동 불가
                # 자연스럽게 만약 다 못간다면 서울이 가장 우선시 됨
            end
            # 이동 끝

            ε_a = ε * randn()
            if gen .&& (15 ≤ a ≤ 45)
                β = validizer((tensor_fertility[-loc, aidx - 3] * (1 + ε_a)) / 1000)
                birth_location[-loc] += sum(rand(Bernoulli(β), npop))
            end
        end
        # CUDA.unsafe_free!(bit_double)
    end
    flow = vcat([vec(reshape(flow, 17, 34, :)[:,:,k]') for k ∈ 1:17]...) # 원본데이터와 일치하도록 수정
    mgrn[!, string('y', t)] = flow
    CSV.write("D:/mgrn $(lpad(seed, 4, '0')).csv", mgrn, encoding = "UTF-8", bom = true)
    age_[location_ .!= (-18)] .+= 1
    append!(gender_, rand(Bernoulli(female_ratio), sum(birth_location))) # 성비는 남:여 = 105:100
    append!(age_, zeros(Int8, sum(birth_location)))
    append!(location_, vcat([repeat([loc], birth_location[-loc]) for loc ∈ -(1:17)]...))
    # 출산 끝

    end
end
