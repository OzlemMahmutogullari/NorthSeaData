using CSV, DataFrames
using Plots
using JuMP
using Gurobi
using LinearAlgebra
using Printf
import Pkg
#Add pathes
#Change design_choice 
#Change case A-F (before SOLVE CCG)

const DATA_DIR    = raw"path\\data"
const ZPTDF_DIR   = raw"path\\ZPTDF"
const RESULTS_DIR = "."

design_choice="HM" #or "OBZ"
day_choice="DEC21"
day_consider=true


println("Data Loading")
df_busAC = CSV.read(joinpath(DATA_DIR, "busAC.txt"), DataFrame; delim='\t', ignorerepeated=true)
busAC_info = Dict(
    row.bus_i => Dict(
        "lat" => row.lat,
        "lon" => row.lon,
        "zone" => row.zone,
        "index" => row.index,
    )
    for row in eachrow(df_busAC)
)

df_branchAC = CSV.read(joinpath(DATA_DIR, "branchAC.txt"), DataFrame; delim='\t', ignorerepeated=true)
branchAC_info = Dict(
    row.index => Dict(
        "fbus" => row.f_bus,
        "tbus" => row.t_bus,
        "type" => row.type,
        "capacity" => row.rate_a,
        "reactanceX" => row.br_x,
        "resistanceR" => row.br_r,
        "index" => row.index,
    )
    for row in eachrow(df_branchAC)
)

#One line between each pair of buses
branchAC_info[8364]["capacity"]+=branchAC_info[8365]["capacity"]
delete!(branchAC_info, 8365)

branchAC_info[8424]["capacity"]+=branchAC_info[8425]["capacity"]
delete!(branchAC_info, 8425)

branchAC_info[8643]["capacity"]+=branchAC_info[8644]["capacity"]
delete!(branchAC_info, 8644)

df_gen = CSV.read(joinpath(DATA_DIR, "gen.txt"), DataFrame; delim='\t', ignorerepeated=true)
gen_info = Dict(
    row.index => Dict(
        "zone" => row.zone,
        "type_tyndp" => row.type_tyndp,
        "index" => row.index,
        "cost" => row.unit_cost,
        "gen_bus" => row.gen_bus,
        "type" => row.type,
        "pmax" => parse(Float64, replace(String(row.pmax), ',' => "")),
    )
    for row in eachrow(df_gen)
)


df_load = CSV.read(joinpath(DATA_DIR, "load.txt"), DataFrame; delim='\t', ignorerepeated=true)
load_info = Dict(
    row.index=> Dict(
        "zone" => row.zone,
        "bus" => row.load_bus,
        "index" => row.index,
        "capacity" => row.pmax,
    )
    for row in eachrow(df_load)
)

df_busDC = CSV.read(joinpath(DATA_DIR, "busDC.txt"), DataFrame; delim='\t', ignorerepeated=true)
busDC_info = Dict(
    row.busdc_i => Dict(
        "lat" => row.lat,
        "lon" => row.lon,
        "zone" => row.zone,
        "index" => row.index,
        "name" => row.name,
    )
    for row in eachrow(df_busDC)
)

df_branchDC = CSV.read(joinpath(DATA_DIR, "branchDC.txt"), DataFrame; delim='\t', ignorerepeated=true)
branchDC_info = Dict(
    row.index => Dict(
        "index" => row.index,
        "capacity" => row.rateA,
        "fbus" => row.fbusdc,
        "fzone" => row.fZone,
        "tbus" => row.tbusdc,
        "tzone" => row.tZone,
    )
    for row in eachrow(df_branchDC)
)


df_branchACDC = CSV.read(joinpath(DATA_DIR, "convdc.txt"), DataFrame; delim='\t', ignorerepeated=true)
branchACDC_info = Dict(
    row.index => Dict(
        "capacity" => row.Pacrated,
        "index" => row.index,
        "busdc" => row.busdc_i,
        "busac" => row.busac_i,
    )
    for row in eachrow(df_branchACDC)
)

# Fix OWF-to-hub converters (301–305) 
owf_converter_cap = Dict(
    301 => 3500.0,    # Belgian PEI       (OWF = 3 500 MW)
    302 => 10000.0,   # NL Energy Hub     (OWF = 10 000 MW)
    303 => 10000.0,   # German Cluster    (OWF = 10 000 MW)
    304 => 3000.0,    # Danish EI         (OWF = 3 000 MW)
    305 => 3000.0,    # Sørlige Nordsjø 2 (OWF = 3 000 MW)
)
# OWF Converter Resizing
for (idx, cap) in sort(collect(owf_converter_cap))
    if haskey(branchACDC_info, idx)
        old = branchACDC_info[idx]["capacity"]
        branchACDC_info[idx]["capacity"] = cap
    end
end


df_interAC = CSV.read(joinpath(DATA_DIR, "interZonal_branchAC.txt"), DataFrame; delim='\t', ignorerepeated=true)
branchACinter_info = Dict(
    row.index => Dict(
        "index" => row.index,
        "fbus" => row.f_bus,
        "fzone" => row.f_zone,
        "tbus" => row.t_bus,
        "tzone" => row.t_zone,
    )
    for row in eachrow(df_interAC)
)

N_ac = sort([busAC_info[b]["index"] for b in keys(busAC_info)])
N_dc = sort([busDC_info[b]["index"] for b in keys(busDC_info)])
G = Int64[gen_info[b]["index"] for b in keys(gen_info)]

G_con = Int64[]
G_res = Int64[]
for g in G
    if gen_info[g]["type"] in ["Solar PV", "Onshore", "Offshore"]
        push!(G_res, g)
    else
        push!(G_con, g)
    end
end

 
# Sorted list of DC line tuples
L_dc = sort([(branchDC_info[b]["fbus"], branchDC_info[b]["tbus"])
             for b in keys(branchDC_info)])
 
# Sorted list of converter tuples
L_acdc = sort([(branchACDC_info[b]["busac"], branchACDC_info[b]["busdc"])
               for b in keys(branchACDC_info)])
 
# Union of DC cables and converters
L = vcat(L_dc, L_acdc)
 
# Capacity dictionaries
F_dc = Dict((branchDC_info[b]["fbus"], branchDC_info[b]["tbus"]) =>
            branchDC_info[b]["capacity"] for b in keys(branchDC_info))
F_acdc = Dict((branchACDC_info[b]["busac"], branchACDC_info[b]["busdc"]) =>
              branchACDC_info[b]["capacity"] for b in keys(branchACDC_info))
 
# Combined capacity dictionary for all L lines
F_cap = Dict(l => 0.0 for l in L)
for l in L
    F_cap[l] = (l[1] in N_ac) ? F_acdc[l] : F_dc[l]
end
 
# Update barF, hatF (used in uncertainty)
barF = F_cap
hatF = Dict(key => F_cap[key] for key in keys(F_cap))

L_ac  = sort([(branchAC_info[b]["fbus"],   branchAC_info[b]["tbus"])   for b in keys(branchAC_info)])
CL    = sort([(branchACinter_info[b]["fbus"],branchACinter_info[b]["tbus"]) for b in keys(branchACinter_info)])

G_gens = Dict(gen_info[b]["index"] => gen_info[b]["gen_bus"] for b in keys(gen_info))

G_i = Dict(i_bus => Int64[] for i_bus in N_ac)
for g in G
    bus = G_gens[g]
    if haskey(G_i, bus)
        push!(G_i[bus], g)
    end
end

P_max  = Dict(gen_info[b]["index"]   => gen_info[b]["pmax"]  for b in keys(gen_info))
if !day_consider
    for g in G
        if gen_info[g]["type"]=="Hydro Pumped Storage"
            P_max[g]=P_max[g]*0.3
        end
    end
end

gen_types = unique([gen_info[g]["type"] for g  in G])
c      = Dict(gen_info[b]["index"]   => gen_info[b]["cost"]  for b in keys(gen_info))

d_load = Dict(busAC_info[b]["index"] => 0.0 for b in keys(busAC_info))
for b in keys(load_info)
    d_load[load_info[b]["bus"]] = load_info[b]["capacity"]
end

F_ac   = Dict((branchAC_info[b]["fbus"],  branchAC_info[b]["tbus"])   => branchAC_info[b]["capacity"]   for b in keys(branchAC_info))

# ── Create F_ac_zonal with NTC-capped values for market clearing ─────────
F_ac_zonal = copy(F_ac)   # start with real capacities
 

#Load, (bus) => load
O = Dict(
    (gen_info[b]["index"] => 0.0) for b in keys(gen_info) 
)

    # Set realistic commitment (no-load + startup) costs
    # These represent the cost of having the unit synchronized to the grid
    # In a single-period model, this is the hourly no-load cost
for b in keys(gen_info)
    pmax = gen_info[b]["pmax"]
    if gen_info[b]["type"] == "Nuclear"
        O[gen_info[b]["index"]] = 5.0 * pmax * 0.40   # Low — nuclear is baseload, rarely cycles
    elseif gen_info[b]["type"] == "Lignite"
        O[gen_info[b]["index"]] = 7.0 * pmax * 0.50   # Moderate — inflexible baseload
    elseif gen_info[b]["type"] == "Hard Coal"
        O[gen_info[b]["index"]] = 6.0 * pmax  * 0.35 # Moderate
    elseif gen_info[b]["type"] == "Biomass"
        O[gen_info[b]["index"]] = 6.0 * pmax * 0.40  # Moderate
    elseif gen_info[b]["type"] == "Gas"
        O[gen_info[b]["index"]] = 4.0 * pmax *0.40  # Higher — flexible, expensive to keep online
    elseif gen_info[b]["type"] == "Oil"
        O[gen_info[b]["index"]] = 3.0 * pmax * 0.20  # Highest — peaker, expensive
    else
        O[gen_info[b]["index"]] = 0.0           # Renewables, hydro — no commitment cost
    end
end

for g in G
    c[g]=c[g]/1000
    O[g]=O[g]/1000
end
#Inertia
H = Dict(
    (g => 0.0) for g in G 
)

for g in G
    if gen_info[g]["type"]=="Hydro Run-of-River"
        H[g]= 3
    end
    if gen_info[g]["type"]=="Oil"
        H[g]= 4
    end
    if gen_info[g]["type"]=="Gas"
        H[g]= 5
    end
    if gen_info[g]["type"]=="Nuclear"
        H[g]= 6
    end
    if gen_info[g]["type"]=="Hard Coal"
        H[g]= 4
    end
    if gen_info[g]["type"]=="Lignite"
        H[g]= 4
    end
end

 
VOLL = 1000 / 1000    
 
CF_base = Dict{String,Dict{String,Float64}}()
 
# ── December 21 capacity factors by zone ──
CF_base["DEC21"] = Dict(
    # Solar PV
    "Solar PV_FR"  => 0.06,  "Solar PV_DE"  => 0.05,  "Solar PV_BE"  => 0.04,
    "Solar PV_NL"  => 0.04,  "Solar PV_UK"  => 0.03,  "Solar PV_DK1" => 0.02,
    "Solar PV_DK2" => 0.02,  "Solar PV_NO1" => 0.01,  "Solar PV_NO2" => 0.01,
    "Solar PV_NO3" => 0.01,  "Solar PV_NO4" => 0.00,  "Solar PV_NO5" => 0.01,
    "Solar PV_SE1" => 0.01,  "Solar PV_SE2" => 0.01,  "Solar PV_SE3" => 0.02,
    "Solar PV_SE4" => 0.02,
    # Offshore wind
    "Offshore_FR"  => 0.55,  "Offshore_DE"  => 0.55,  "Offshore_BE"  => 0.55,
    "Offshore_NL"  => 0.55,  "Offshore_UK"  => 0.50,  "Offshore_DK1" => 0.50,
    "Offshore_DK2" => 0.50,  "Offshore_NO2" => 0.50,  "Offshore_SE4" => 0.50,
    # Onshore wind
    "Onshore_FR"   => 0.28,  "Onshore_DE"   => 0.30,  "Onshore_BE"   => 0.28,
    "Onshore_NL"   => 0.30,  "Onshore_UK"   => 0.32,  "Onshore_DK1"  => 0.35,
    "Onshore_DK2"  => 0.35,  "Onshore_NO1"  => 0.30,  "Onshore_NO2"  => 0.30,
    "Onshore_NO3"  => 0.30,  "Onshore_NO4"  => 0.32,  "Onshore_NO5"  => 0.30,
    "Onshore_SE1"  => 0.32,  "Onshore_SE2"  => 0.32,  "Onshore_SE3"  => 0.30,
    "Onshore_SE4"  => 0.28,
)
 
# ── Forecast deviation fractions (what fraction of barP can deviate) ──
# These determine hatP = barP * dev_frac
dev_frac = Dict{String,Dict{String,Float64}}()
dev_frac["DEC21"] = Dict(
    "Solar PV" => 0.50,   # Solar forecast in winter is very uncertain
    "Offshore"  => 0.25,   # Offshore wind is more predictable
    "Onshore"   => 0.20,   # Onshore wind has moderate forecast error
)

# Look up CF for a generator 
function get_cf(g, day, gen_info, CF)
    typ  = gen_info[g]["type"]        # "Solar PV", "Offshore", "Onshore"
    zone = gen_info[g]["zone"]        # "FR", "DE", ...
    key  = typ * "_" * zone
    # If the zone has an OBZ prefix in the OBZ design, strip it
    # (OWF generators still have their home-country zone in gen_info)
    return get(CF[day], key, 0.30)    # fallback 0.30 if key missing
end
 

# Scale offshore hub generation 
offshore_hub_buses = Set([30001, 30002, 30003, 30004, 30005])

# Build barP with realistic capacity factors
barP = Dict{Int,Float64}()
for g in G_res
    if day_consider
        cf = get_cf(g, day_choice, gen_info, CF_base)
    else
        cf = 0.50   # generic mid-range if no specific day
    end
    barP[g] = P_max[g] * cf
end
 
# Build hatP as a fraction of the FORECAST (barP), not of installed cap 
hatP = Dict{Int,Float64}()
if day_consider
    for g in G_res
        typ = gen_info[g]["type"]
        dfrac = get(dev_frac[day_choice], typ, 0.30)
        hatP[g] = barP[g] * dfrac
    end
else
    for g in G_res
        hatP[g] = barP[g] * 0.30       # default 30 % of forecast
    end
end
 
# Load scaling for the specific hour 
load_level = Dict("DEC21" => 0.90)
 
bard = Dict{Int,Float64}()
for i in N_ac
    if day_consider
        bard[i] = d_load[i] * get(load_level, day_choice, 0.80)
    else
        bard[i] = d_load[i]
    end
end
 
# Load uncertainty (hatd) — kept similar to your original
hatd = Dict{Int,Float64}()
for i in N_ac
    hatd[i] = bard[i] * 0.15     
end

K_freq=0.016
T_ffr_dc=0.75

L_freq=L

for g in G_res
    c[g]=1/1000
end

# Hydro Reservoir / Pumped Storage 
for g in G
    if gen_info[g]["type"] in ["Hydro Reservoir", "Hydro Pumped Storage"]
        if !(g in G_con)
            push!(G_con, g)
            # Also add inertia if you want them to contribute
            H[g] = 3.0    # Hydro inertia constant
        end
    end
end

if design_choice == "HM"
    Z = unique([busAC_info[b]["zone"] for b in keys(busAC_info)])

    N_ac_z = Dict(i_zone => Int64[] for i_zone in Z)
    for j_bus in N_ac
        push!(N_ac_z[busAC_info[j_bus]["zone"]], j_bus)
    end

    N_dc_z = Dict(i_zone => Int64[] for i_zone in Z)
    for j_bus in N_dc
        push!(N_dc_z[busDC_info[j_bus]["zone"]], j_bus)
    end


    z_ac_i = Dict(i => z for z in Z for i in N_ac_z[z])
    z_dc_i = Dict(i => z for z in Z for i in N_dc_z[z])
    z_g    = Dict(g   => z_ac_i[G_gens[g]]  for g in G)


    #NPTDF, (line, bus) => value
    L_ac=sort(L_ac)
    N_ac=sort(N_ac)

    ZPTDF = Dict(     
        (l,j_zone) => 0.0 for l in CL for j_zone in Z 
    )


    using DelimitedFiles

    # Regex to match: (int, int) ZONE_STR float_value
    pattern = r"\((\d+),\s*(\d+)\)\s+(\S+)\s+([-\d.eE+]+)"

    for line in eachline(joinpath(ZPTDF_DIR, "ZPTDF_CL.txt"))
        for m in eachmatch(pattern, line)
            l     = parse(Int,     m.captures[1])
            z     = parse(Int,     m.captures[2])
            zone  = m.captures[3]
            v     = parse(Float64, m.captures[4])
            ZPTDF[((l, z), zone)] = v   # key is ((line_id, node_id), zone_string)
        end
    end


    # Precompute set for fast membership tests
    N_ac_set = Set(N_ac)
    N_dc_set = Set(N_dc)

    S = Dict(
        1 => ["UK"],
        2 => ["DK2", "SE1", "SE2", "SE3", "SE4", "NO1", "NO2", "NO3", "NO4", "NO5"],
        3 => ["FR", "BE", "DE", "NL", "DK1"],
    )

    s_z = Dict(z => s for z in Z for s in keys(S) if z in S[s])
    s_dc_i = Dict(i => s_z[z_dc_i[i]] for i in N_dc)


    # Unified bus → sync area mapping (works for both AC and DC buses)
    s_bus = merge(Dict(i => s_z[z_ac_i[i]] for i in N_ac), s_dc_i)

    # L_in/L_out over ALL lines in L (DC + converter), using sync areas
    L_in = Dict(
        key => [l for l in L if s_bus[l[1]] != key && s_bus[l[2]] == key] 
        for key in keys(S)
    )
    L_out = Dict(
        key => [l for l in L if s_bus[l[2]] != key && s_bus[l[1]] == key] 
        for key in keys(S)
    )

else
    # ── OBZ: 5 separate offshore bidding zones ───────────────────────────
    # Map each offshore hub to its own zone
    obz_ac_map = Dict(
        30001 => "OBZ_BE",    # Princess Elisabeth Island
        30002 => "OBZ_NL",    # NL Energy Hub
        30003 => "OBZ_DE",    # German Offshore Cluster
        30004 => "OBZ_DK",    # Danish Energy Island
        30005 => "OBZ_NO",    # Sørlige Nordsjø 2
    )
    obz_dc_map = Dict(
        20001 => "OBZ_BE",
        20002 => "OBZ_NL",
        20003 => "OBZ_DE",
        20004 => "OBZ_DK",
        20005 => "OBZ_NO",
    )

    obz_zones = unique(collect(values(obz_ac_map)))
    
    Z = String.(unique([busAC_info[b]["zone"] for b in keys(busAC_info)]))
    for oz in obz_zones
        push!(Z, oz)
    end
    
    # ── N_ac_z: move offshore AC buses to their OBZ zone ─────────────────
    N_ac_z = Dict(z => Int64[] for z in Z)
    for j_bus in N_ac
        if haskey(obz_ac_map, j_bus)
            push!(N_ac_z[obz_ac_map[j_bus]], j_bus)
        else
            push!(N_ac_z[busAC_info[j_bus]["zone"]], j_bus)
        end
    end

    # ── N_dc_z: move offshore DC buses to their OBZ zone ─────────────────
    N_dc_z = Dict(z => Int64[] for z in Z)
    for j_bus in N_dc
        if haskey(obz_dc_map, j_bus)
            push!(N_dc_z[obz_dc_map[j_bus]], j_bus)
        else
            push!(N_dc_z[busDC_info[j_bus]["zone"]], j_bus)
        end
    end

    z_ac_i = Dict(i => z for z in Z for i in N_ac_z[z])
    z_dc_i = Dict(i => z for z in Z for i in N_dc_z[z])
    z_g    = Dict(g   => z_ac_i[G_gens[g]]  for g in G)

    

    #NPTDF, (line, bus) => value
    L_ac=sort(L_ac)
    N_ac=sort(N_ac)

    ZPTDF = Dict(     
        (l,j_zone) => 0.0 for l in CL for j_zone in Z 
    )

    using DelimitedFiles

    # Regex to match: (int, int) ZONE_STR float_value
    pattern = r"\((\d+),\s*(\d+)\)\s+(\S+)\s+([-\d.eE+]+)"

    for line in eachline(joinpath(ZPTDF_DIR, "ZPTDF_OBZ.txt"))
        for m in eachmatch(pattern, line)
            l     = parse(Int,     m.captures[1])
            z     = parse(Int,     m.captures[2])
            zone  = m.captures[3]
            v     = parse(Float64, m.captures[4])
            ZPTDF[((l, z), zone)] = v   # key is ((line_id, node_id), zone_string)
        end
    end


    # Precompute set for fast membership tests
    N_ac_set = Set(N_ac)
    N_dc_set = Set(N_dc)

    S = Dict(
        1 => ["UK"],
        2 => ["DK2", "SE1", "SE2", "SE3", "SE4", "NO1", "NO2", "NO3", "NO4", "NO5"],
        3 => ["FR", "BE", "DE", "NL", "DK1"],
    )


    # Offshore DC buses: assign to home-country sync area for frequency purposes
    obz_dc_sync = Dict(
        20001 => 3,   # OBZ_BE → Continental
        20002 => 3,   # OBZ_NL → Continental
        20003 => 3,   # OBZ_DE → Continental
        20004 => 2,   # OBZ_DK → Nordic (DK2 side)
        20005 => 2,   # OBZ_NO → Nordic
    )

    s_z = Dict(z => s for z in Z for s in keys(S) if z in S[s])

    s_dc_i = Dict{Int,Int}()
    for i in N_dc
        if haskey(obz_dc_sync, i)
            s_dc_i[i] = obz_dc_sync[i]
        else
            s_dc_i[i] = s_z[z_dc_i[i]]
        end
    end

    # Offshore AC buses: assign to home-country sync area
    obz_ac_sync = Dict(
        30001 => 3, 30002 => 3, 30003 => 3,   # Continental
        30004 => 2, 30005 => 2,                 # Nordic
    )

    s_bus = Dict{Int,Int}()
    for i in N_ac
        if haskey(obz_ac_sync, i)
            s_bus[i] = obz_ac_sync[i]
        else
            s_bus[i] = s_z[z_ac_i[i]]
        end
    end
    merge!(s_bus, s_dc_i)

    L_in = Dict(
        key => [l for l in L if s_bus[l[1]] != key && s_bus[l[2]] == key] 
        for key in keys(S)
    )
    L_out = Dict(
        key => [l for l in L if s_bus[l[2]] != key && s_bus[l[1]] == key] 
        for key in keys(S)
    )
end

# Define which zones are offshore-only
if design_choice == "OBZ"
    # OBZ zones where ALL buses are offshore (only DC connection to mainland)
    offshore_only_zones = Set(["OBZ_BE", "OBZ_NL", "OBZ_DE", "OBZ_DK", "OBZ_NO"])
 
    # Offshore AC buses (for the nodal subproblem)
    offshore_only_buses = Set([30001, 30002, 30003, 30004, 30005])
 
    println("\n── Offshore-only zones (x[z]=0 will be enforced): ──")
    for z in sort(collect(offshore_only_zones))
        buses = N_ac_z[z]
        println("  $z: AC buses = $buses")
    end
else
    offshore_only_zones = Set{String}()
    offshore_only_buses = Set([30001, 30002, 30003, 30004, 30005])
end

# Converter contingency data structures 
 
# Each converter (AC_bus, DC_bus) isolates its DC bus when it trips
conv_dc_bus = Dict(l => l[2] for l in L_acdc)
 
# For each converter, find all DC cables that fail when its DC bus is isolated
affected_dc_lines = Dict(
    conv => [l for l in L
             if l[1] == conv_dc_bus[conv] || l[2] == conv_dc_bus[conv]]
    for conv in L_acdc
)
 
CONV_FREQ = [conv for conv in L_acdc
             if (conv in L_freq) && 
                all(l in L_freq for l in affected_dc_lines[conv])]

#NPTDF, (line, bus) => value
L_ac=sort(L_ac)
N_ac=sort(N_ac)
NPTDF = Dict(
    ((a,b) => 0.0) for a in L_ac for b in N_ac 
)

#B_d matrix
B_d = zeros(length(L_ac), length(L_ac))

#susceptance dictionary of AC lines, (line) => susceptance
susceptance_ac = Dict(
    ((branchAC_info[b]["fbus"],branchAC_info[b]["tbus"]) => imag(-(1/complex(branchAC_info[b]["resistanceR"],branchAC_info[b]["reactanceX"])))) for b in keys(branchAC_info)
)

for (j_b, i) in enumerate(L_ac)
    #println("i = ", i, "  and j_b = ", j_b)
    B_d[j_b, j_b] = susceptance_ac[(i[1], i[2])]
end

#A matrix
A = zeros(length(L_ac), length(N_ac))

for (j_a,i) in enumerate(L_ac)
    f_b=0
    t_b=0
    #println("the line is", i)
    for (j_n,i_n) in enumerate(N_ac)
        if i[1]==i_n
            f_b=j_n
        end
        if i[2]==i_n
            t_b=j_n
        end
    end
    A[j_a, f_b]=1
    A[j_a, t_b]=-1
end

firstPart=B_d*A

secondPart=A'*firstPart

r=rank(secondPart)
n=size(secondPart,1)
F=qr(secondPart, Val(true))
p=Vector(F.p)
remove_indices = p[r+1:end]
remove_indices=sort(remove_indices)
keep = p[1:r]
keep=sort(keep)

secondPart_updated=secondPart[keep,keep]
firstPart_updated=firstPart[:, keep]


NPTDF_m=firstPart_updated*inv(secondPart_updated)
NPTDF_matrix=zeros(length(L_ac), length(N_ac))

kept_indices = setdiff(1:length(N_ac), remove_indices)

NPTDF_matrix[:, kept_indices]=NPTDF_m

for (index_a, a) in enumerate(L_ac) 
    for (index_b, b) in enumerate(N_ac)
        NPTDF[(a,b)]=NPTDF_matrix[index_a,index_b]
    end
end

NPTDF=sort(NPTDF)
 

function build_master_problem()
    mp = Model(Gurobi.Optimizer)
    set_silent(mp)

    @variable(mp, f[l in L])
    @variable(mp, fAC[l in CL])
    @variable(mp, p[g in G]        >= 0)
    @variable(mp, r[g in G_con]    >= 0)
    @variable(mp, alpha[g in G_con], Bin)
    @variable(mp, s[i in N_ac]     >= 0)
    @variable(mp, x[z in Z])
    @variable(mp, E[z in Z]        >= 0)
    @variable(mp, eta              >= 0)

    # AC zonal balance
    zonal_bal = Dict{String,ConstraintRef}()
    for z in Z
        zonal_bal[z] = @constraint(mp,
            x[z] == sum(
                sum(p[g] for g in G_i[i]) -
                sum(f[(i,j)] for j in N_dc if (i,j) in L; init=0) -
                bard[i] + s[i]
            for i in N_ac_z[z])
        )
    end

    # DC zonal balance
    for z in Z
        @constraint(mp,
            sum(
                sum(f[l] for l in L if l[2] == i; init=zero(AffExpr)) -
                sum(f[l] for l in L if l[1] == i; init=zero(AffExpr))
            for i in N_dc_z[z]) == 0
        )
    end

    # Critical AC line flows via ZPTDF
    for l in CL
        @constraint(mp, fAC[l] == sum(ZPTDF[(l,z)] * x[z] for z in Z))
    end

    # Zonal injection sum = 0 
    @constraint(mp, sum(x[z] for z in Z) == 0)

    # Modify build_master_problem 
    
    # Force x[z] = 0 for offshore-only zones (OBZ design) 
    for z in Z
        if z in offshore_only_zones
            @constraint(mp, x[z] == 0)
        end
    end

    # Generation limits
    for g in G_con; @constraint(mp, p[g] + r[g] <= P_max[g] * alpha[g]) end
    for g in G_res; @constraint(mp, p[g] <= barP[g]) end

    # Load shedding limit
    for i in N_ac;  @constraint(mp, s[i] <= bard[i]) end

    # DC / AC-DC line limits 
    for l in L;     @constraint(mp, -barF[l] <= f[l] <= barF[l]) end

    # OWF converters are export-only (OWF → hub, never reverse)
    owf_converters = [(30001,20001), (30002,20002), (30003,20003),
                      (30004,20004), (30005,20005)]
    for conv in owf_converters
        if conv in L
            @constraint(mp, f[conv] >= 0)
        end
    end

    # Critical AC line limits 
    for l in CL;    @constraint(mp, -F_ac_zonal[l] <= fAC[l] <= F_ac_zonal[l]) end

    # Inertia 
    for z in Z
        @constraint(mp,
            E[z] == sum(
                sum(alpha[g]*H[g] for g in G_i[i] if g in G_con; init=0)
            for i in N_ac_z[z])
        )
    end

    @objective(mp, Min,
        sum(O[g]*alpha[g] + c[g]*p[g]  for g in G_con) +
        sum(c[g]*p[g]                  for g in G_res) +
        sum(0.2*c[g]*r[g]              for g in G_con) +
        sum(VOLL*s[i]                  for i in N_ac)  +
        eta
    )

    return mp, (f=f, fAC=fAC, E=E, x=x, p=p, r=r, alpha=alpha, s=s, eta=eta, zonal_bal=zonal_bal)
end


function solve_oracle_lin(p_K, r_K, s_K, alpha_K, E_K, f_K; prev_gamma=nothing)

    sp = Model(Gurobi.Optimizer)
    set_silent(sp)
    set_optimizer_attribute(sp, "MIPGap",    1e-4)
    set_optimizer_attribute(sp, "TimeLimit", 180)
    set_optimizer_attribute(sp, "Threads",   4)
    set_optimizer_attribute(sp, "Presolve",  2)
    set_optimizer_attribute(sp, "Cuts",      2)
    set_optimizer_attribute(sp, "MIPFocus",  1)

    bigM=1000
    VOFF = 10 * VOLL

    @variable(sp, beta_ac[z in Z] )
    @variable(sp, beta_dc[z in Z] )
    @variable(sp, beta_l[l in CL] )
    @variable(sp, theta )
    @variable(sp, 0 <= m_con[g in G_con] )
    @variable(sp, 0 <= m_res[g in G_res] )
    @variable(sp, 0 <= m[i in N_ac]      )
    @variable(sp, 0 <= n[l in L]         )
    @variable(sp, 0 <= nu[l in L]        )
    @variable(sp, 0 <= n_ac[l in CL]     )
    @variable(sp, 0 <= nu_ac[l in CL]    )

    # Dual variables - FFR 
    @variable(sp, 0 <= pi_plus[l in L]   )    # dual of δ⁺ ≤ F - f^b
    @variable(sp, 0 <= pi_minus[l in L]  )    # dual of δ⁻ ≤ F + f^b
    @variable(sp, 0 <= mu_plus[s in keys(S)]  )   # dual of under-freq
    @variable(sp, 0<= mu_minus[s in keys(S)] )   # dual of over-freq

    @variable(sp, bigM>= l_beta_d[i in N_ac] >= -bigM)
    @variable(sp, bigM>= l_mres_P[g in G_res]>= 0)
    @variable(sp, bigM>= l_m_d[i in N_ac]>= 0)
    @variable(sp, bigM>= l_n_F[l in L]>= 0)
    @variable(sp, bigM>= l_nu_F[l in L]>= 0)

    # NEW: McCormick for π⁺·γ^F and π⁻·γ^F
    @variable(sp, bigM>= l_pi_plus_F[l in L]    >= 0)
    @variable(sp, bigM>= l_pi_minus_F[l in L]   >= 0)
    @variable(sp, bigM>= l_mu_plus_s2[l in L_freq]  >= 0)
    @variable(sp, bigM>= l_mu_plus_s1[l in L_freq]  >= 0)
    @variable(sp, bigM>= l_mu_minus_s2[l in L_freq] >= 0)
    @variable(sp, bigM>= l_mu_minus_s1[l in L_freq] >= 0)


    # Binary uncertainty variables 
    @variable(sp, gammaF[l in L],     Bin)
    @variable(sp, gammad[i in N_ac],  Bin)
    @variable(sp, gammaP[g in G_res], Bin)
    @variable(sp, gammaC[conv in L_acdc], Bin)

    @constraint(sp, sum(gammad[i]    for i in N_ac)  <= bigGammad)
    @constraint(sp, sum(gammaP[g]    for g in G_res) <= bigGammaP)
    @constraint(sp, sum(gammaC[conv]  for conv in L_acdc) <= bigGammaC)

    # Fix zero-demand nodes
    for i in N_ac
        if bard[i] < 1e-6
            @constraint(sp, gammad[i] == 0)
        end
    end

    # Fix zero-deviation RES generators
    if bigGammaP == length(G_res)
        for g in G_res
            @constraint(sp, gammaP[g] == 1)
        end
    else
        for g in G_res
            if hatP[g] < 1e-6
                @constraint(sp, gammaP[g] == 0)
            end
        end
    end
    
    for l in L_acdc
        for affected_l in affected_dc_lines[l]
            @constraint(sp, gammaF[affected_l] >= gammaC[l])
        end
    end

    # Lines can only fail through converter trips (no standalone failures)
    for l in L
        affecting_convs = [conv for conv in L_acdc 
                        if l in affected_dc_lines[conv] || l == conv]
        if isempty(affecting_convs)
            # This line is not connected to any monitored converter
            @constraint(sp, gammaF[l] == 0)
        else
            # Line can fail only if at least one affecting converter trips
            @constraint(sp, gammaF[l] <= sum(gammaC[conv] 
                                            for conv in affecting_convs))
        end
    end

    # Warm-start from previous iteration ─
    if prev_gamma !== nothing
        for i in N_ac;  set_start_value(gammad[i], prev_gamma[:d][i]) end
        for g in G_res; set_start_value(gammaP[g], prev_gamma[:P][g]) end
        for l in L;     set_start_value(gammaF[l], prev_gamma[:F][l]) end
        if haskey(prev_gamma, :C)
            for conv in L_acdc
                set_start_value(gammaC[conv], get(prev_gamma[:C], conv, 0.0))
            end
        end
    end

    # Realised uncertainty 
    @variable(sp, F[l in L])
    @variable(sp, d[i in N_ac])
    @variable(sp, P[g in G_res])

    for l in L;     @constraint(sp, F[l] == barF[l]  - hatF[l]*gammaF[l])  end
    for i in N_ac;  @constraint(sp, d[i] == bard[i]  + hatd[i]*gammad[i])  end
    for g in G_res; @constraint(sp, P[g] == barP[g]  - hatP[g]*gammaP[g])  end

    # Dual feasibility constraints
    # (r^act_g)  g in G_con
    for g in G_con
        @constraint(sp, -beta_ac[z_g[g]] - m_con[g] <= 0.7*c[g])
    end

    # (p^up_g)  g in G_res
    for g in G_res
        @constraint(sp, -beta_ac[z_g[g]] - m_res[g] <= 1.1*c[g])
    end

    # (p^down_g)  g in G_res
    for g in G_res
        @constraint(sp,  beta_ac[z_g[g]] + m_res[g] <= 0.1*c[g])
    end

    # (s^b_i)  i in N_ac
    for i in N_ac
        @constraint(sp, -beta_ac[z_ac_i[i]] - m[i] <= VOLL)
    end

    # (f^b_l)  updated: add -π⁺ + π⁻ terms
    for (i,j) in L
        if i in N_ac_set
            @constraint(sp,
                beta_ac[z_ac_i[i]] + beta_dc[z_dc_i[j]]
                + n[(i,j)] - nu[(i,j)]
                - pi_plus[(i,j)] + pi_minus[(i,j)]    # NEW
                == 0)
        else
            @constraint(sp,
                - beta_dc[z_dc_i[i]] + beta_dc[z_dc_i[j]]
                + n[(i,j)] - nu[(i,j)]
                - pi_plus[(i,j)] + pi_minus[(i,j)]    # NEW
                == 0)
        end
    end

    # (f^{b,ac}_l)  l in CL  — free variable → equality constraint
    for l in CL
        @constraint(sp, beta_l[l] + n_ac[l] - nu_ac[l] == 0)
    end
 
    # (x^b_z)  z in Z  — free variable → equality constraint
    for z in Z
        if z in offshore_only_zones
            # x[z] fixed to 0 → no dual constraint on beta_ac[z]
            # beta_ac[z] is determined by other constraints (converter duals)
        else
            @constraint(sp,
                beta_ac[z] - sum(ZPTDF[(l,z)]*beta_l[l]
                                 for l in CL; init=0.0) + theta == 0)
        end
    end
 
 
    for l in L
        freq_terms = zero(AffExpr)
        for s in keys(S)
            if l in L_in[s]
                add_to_expression!(freq_terms, T_ffr_dc, mu_plus[s])
            end
            if l in L_out[s]
                add_to_expression!(freq_terms, T_ffr_dc, mu_minus[s])
            end
        end
        @constraint(sp, -pi_plus[l] + freq_terms <= 0)
    end
 
 
    for l in L
        freq_terms = zero(AffExpr)
        for s in keys(S)
            if l in L_out[s]
                add_to_expression!(freq_terms, T_ffr_dc, mu_plus[s])
            end
            if l in L_in[s]
                add_to_expression!(freq_terms, T_ffr_dc, mu_minus[s])
            end
        end
        @constraint(sp, -pi_minus[l] + freq_terms <= 0)
    end


    function add_bin_cont!(model, w, x, gamma, xL, xU)
        @constraint(model, w <= xU * gamma)
        @constraint(model, w >= xL * gamma)
        @constraint(model, w <= x - xL*(1 - gamma))
        @constraint(model, w >= x - xU*(1 - gamma))
    end

    for i in N_ac
        add_bin_cont!(sp, l_beta_d[i], beta_ac[z_ac_i[i]], gammad[i], -bigM, bigM)
        add_bin_cont!(sp, l_m_d[i],    m[i],                gammad[i], 0.0,   bigM)
    end
    for g in G_res
        add_bin_cont!(sp, l_mres_P[g], m_res[g], gammaP[g], 0.0, bigM)
    end
    for l in L
        add_bin_cont!(sp, l_n_F[l],  n[l],  gammaF[l], 0.0, bigM)
        add_bin_cont!(sp, l_nu_F[l], nu[l], gammaF[l], 0.0, bigM)
    end

    # NEW: McCormick for FFR headroom duals × γ^F
    for l in L
        add_bin_cont!(sp, l_pi_plus_F[l],  pi_plus[l],  gammaF[l], 0.0, bigM)
        add_bin_cont!(sp, l_pi_minus_F[l], pi_minus[l], gammaF[l], 0.0, bigM)
    end
 
    # McCormick for frequency duals × γ^F (only cross-sync-area lines)
    for l in L_freq
        s1 = s_bus[l[1]]    # sending sync area
        s2 = s_bus[l[2]]     # receiving sync area
 
        add_bin_cont!(sp, l_mu_plus_s2[l],  mu_plus[s2],  gammaF[l], 0.0, bigM)
        add_bin_cont!(sp, l_mu_plus_s1[l],  mu_plus[s1],  gammaF[l], 0.0, bigM)
        add_bin_cont!(sp, l_mu_minus_s2[l], mu_minus[s2], gammaF[l], 0.0, bigM)
        add_bin_cont!(sp, l_mu_minus_s1[l], mu_minus[s1], gammaF[l], 0.0, bigM)
    end
    

    @objective(sp, Max,
        # β^ac · RHS_z (constant part)
        sum(beta_ac[z] * sum(
                sum(p_K[g] for g in G_i[i]; init=0.0) - bard[i] + s_K[i]
            for i in N_ac_z[z]; init=0.0) for z in Z; init=0.0)
        # β^ac · (-d̂_i γ^d) → McCormick
        - sum(hatd[i] * l_beta_d[i]                for i in N_ac;  init=0.0)
        # m^con · (-r_g) 
        + sum(m_con[g] * (-r_K[g])                 for g in G_con; init=0.0)
        # m^res · (p_g - P̄_g) + P̂_g · McCormick 
        + sum(m_res[g] * (-barP[g] + p_K[g])       for g in G_res; init=0.0)
        + sum(hatP[g]  * l_mres_P[g]               for g in G_res; init=0.0)
        # m_i · (s_i - d̄_i) - d̂_i · McCormick 
        + sum(m[i]     * (-bard[i] + s_K[i])       for i in N_ac;  init=0.0)
        - sum(hatd[i]  * l_m_d[i]                  for i in N_ac;  init=0.0)
        # (-n - ν) · F̄_l + F̂_l · McCormick 
        + sum((-n[l]   - nu[l])  * barF[l]         for l in L;     init=0.0)
        + sum(hatF[l]  * (l_n_F[l] + l_nu_F[l])   for l in L;     init=0.0)
        # (-n^ac - ν^ac) · F^ac_l
        + sum((-n_ac[l] - nu_ac[l]) * F_ac_zonal[l]     for l in CL;    init=0.0)
        # (-π⁺ - π⁻) · F̄_l + F̂_l · McCormick 
        + sum((-pi_plus[l] - pi_minus[l]) * barF[l]               for l in L;     init=0.0)
        + sum(hatF[l] * (l_pi_plus_F[l] + l_pi_minus_F[l])       for l in L;     init=0.0)
        # -2K·E_s·(μ⁺ + μ⁻) 
        - sum(2.0 * K_freq * sum(E_K[z] for z in S[s]) * (mu_plus[s] + mu_minus[s])
                                                   for s in keys(S); init=0.0)
        # f_l · (w_μ⁺_s2 - w_μ⁺_s1 - w_μ⁻_s2 + w_μ⁻_s1) 
        + sum(f_K[l] * ( l_mu_plus_s2[l]  - l_mu_plus_s1[l]
                        - l_mu_minus_s2[l] + l_mu_minus_s1[l])
                                                   for l in L_freq; init=0.0)
    )

    optimize!(sp)

    status = termination_status(sp)

    if status == MOI.OPTIMAL || (status == MOI.TIME_LIMIT && has_values(sp))
        if status == MOI.TIME_LIMIT
            @warn "Oracle hit time limit — using best incumbent with gap"
        end
    

        return (
            obj     = objective_value(sp),
            d       = Dict(i => value(d[i])       for i in N_ac),
            P       = Dict(g => value(P[g])       for g in G_res),
            F       = Dict(l => value(F[l])       for l in L),
            # Store binary decisions for warm-starting next iteration
            gamma    = Dict(
                :d => Dict(i => round(value(gammad[i])) for i in N_ac),
                :P => Dict(g => round(value(gammaP[g])) for g in G_res),
                :F => Dict(l => round(value(gammaF[l])) for l in L),
                :C => Dict(conv => round(value(gammaC[conv])) for conv in L_acdc),
            ),
            beta_ac = Dict(z => value(beta_ac[z]) for z in Z),
            m_con   = Dict(g => value(m_con[g])   for g in G_con),
            m_res   = Dict(g => value(m_res[g])   for g in G_res),
            m       = Dict(i => value(m[i])       for i in N_ac),
            n       = Dict(l => value(n[l])       for l in L),
            nu      = Dict(l => value(nu[l])      for l in L),
            n_ac    = Dict(l => value(n_ac[l])    for l in CL),
            nu_ac   = Dict(l => value(nu_ac[l])   for l in CL),
            # NEW
            pi_plus  = Dict(l => value(pi_plus[l])  for l in L),
            pi_minus = Dict(l => value(pi_minus[l]) for l in L),
            mu_plus  = Dict(s => value(mu_plus[s])  for s in keys(S)),
            mu_minus = Dict(s => value(mu_minus[s]) for s in keys(S)),
        )
    else
        # No solution found — generate a random feasible scenario
        @warn "Oracle found no incumbent solution"
    end
end

# =============================================================================
#  ADD SCENARIO k TO MASTER
# =============================================================================
function add_scenario_to_master!(mp, k, d_k::Dict, P_k::Dict, F_k::Dict)

    p   = mp[:p]
    r   = mp[:r]
    s   = mp[:s]
    f   = mp[:f]
    alpha = mp[:alpha]
    E = mp[:E]
    eta = mp[:eta]

    r_act_k  = @variable(mp, [g in G_con], lower_bound=0, base_name="r_act_$k")
    p_up_k   = @variable(mp, [g in G_res], lower_bound=0, base_name="p_up_$k")
    p_down_k = @variable(mp, [g in G_res], lower_bound=0, base_name="p_down_$k")
    s_b_k    = @variable(mp, [i in N_ac],  lower_bound=0, base_name="s_b_$k")
    f_b_k    = @variable(mp, [l in L],                    base_name="f_b_$k")
    f_b_ac_k = @variable(mp, [l in CL],                   base_name="f_b_ac_$k")
    x_b_k    = @variable(mp, [z in Z],                    base_name="x_b_$k")

    # FFR headroom variables for this scenario
    delta_plus_k  = @variable(mp, [l in L], lower_bound=0, base_name="delta_plus_$k")
    delta_minus_k = @variable(mp, [l in L], lower_bound=0, base_name="delta_minus_$k")

    freq_slack_plus_k  = @variable(mp, [s in keys(S)], lower_bound=0, base_name="freq_slack_plus_$k")
    freq_slack_minus_k = @variable(mp, [s in keys(S)], lower_bound=0, base_name="freq_slack_minus_$k")


    # AC zonal balance
    for z in Z
        # RHS: fixed first-stage terms
        rhs_z = sum(
            sum(p[g] for g in G_i[i]; init=zero(AffExpr)) - d_k[i] + s[i]
        for i in N_ac_z[z]; init=zero(AffExpr))

        # LHS: second-stage recourse terms
        con_redispatch = sum(
            sum(r_act_k[g] for g in intersect(G_i[i], G_con); init=zero(AffExpr))
        for i in N_ac_z[z]; init=zero(AffExpr))

        res_redispatch = sum(
            sum(p_up_k[g] - p_down_k[g] for g in intersect(G_i[i], G_res); init=zero(AffExpr))
        for i in N_ac_z[z]; init=zero(AffExpr))

        flow_balance = sum(
            sum(f_b_k[(i,j)] for j in N_dc if (i,j) in L; init=zero(AffExpr)) 
        for i in N_ac_z[z]; init=zero(AffExpr))

        shed = sum(s_b_k[i] for i in N_ac_z[z]; init=zero(AffExpr))

        @constraint(mp,
            x_b_k[z] - con_redispatch - res_redispatch + flow_balance - shed == rhs_z
        )
    end

    # DC zonal balance
    for z in Z
        @constraint(mp,
            sum(
                sum(f_b_k[l] for l in L if l[2] == i; init=zero(AffExpr)) -
                sum(f_b_k[l] for l in L if l[1] == i; init=zero(AffExpr))
            for i in N_dc_z[z]; init=zero(AffExpr)) == 0
        )
    end

    # ZPTDF
    for l in CL
        @constraint(mp,
            f_b_ac_k[l] == sum(ZPTDF[(l,z)] * x_b_k[z] for z in Z; init=zero(AffExpr))
        )
    end

    @constraint(mp, sum(x_b_k[z] for z in Z) == 0)
 
    # Force x_b[z] = 0 for offshore-only zones 
    for z in Z
        if z in offshore_only_zones
            @constraint(mp, x_b_k[z] == 0)
        end
    end

    for g in G_con; @constraint(mp, r_act_k[g] <= r[g])                          end
    for g in G_res; @constraint(mp, p_up_k[g] - p_down_k[g] <= P_k[g] - p[g])   end
    for i in N_ac;  @constraint(mp, s_b_k[i] <= d_k[i] - s[i])                   end
    for l in L;     @constraint(mp, -F_k[l] <= f_b_k[l] <= F_k[l])               end
    # OWF converters are export-only in second stage too 
    owf_converters = [(30001,20001), (30002,20002), (30003,20003),
                      (30004,20004), (30005,20005)]
    for conv in owf_converters
        if conv in L
            @constraint(mp, f_b_k[conv] >= 0)
        end
    end
    for l in CL;    @constraint(mp, -F_ac_zonal[l] <= f_b_ac_k[l] <= F_ac_zonal[l])           end

    # FFR headroom constraints 
    # δ⁺_l ≤ F_k[l] - f^b_l
    # δ⁻_l ≤ F_k[l] + f^b_l
    for l in L
        @constraint(mp, delta_plus_k[l]  <= F_k[l] - f_b_k[l])
        @constraint(mp, delta_minus_k[l] <= F_k[l] + f_b_k[l])
        @constraint(mp, delta_plus_k[l]  <= 2F_k[l])
        @constraint(mp, delta_minus_k[l] <= 2F_k[l])
    end

    #FFR frequency constraints
    for s in keys(S)
        # RHS: inertia energy budget
        Etot=sum(E[z] for z in S[s])
        rhs_inertia = 2.0 * K_freq * Etot
        # Detect tripped lines: those where F_k[l] = 0 (hatF[l] = barF[l])
        tripped_in  = [l for l in L_in[s]  if F_k[l] < 0.1]
        tripped_out = [l for l in L_out[s] if F_k[l] < 0.1]
        # ΔP_trip = Σ_{tripped importing} f_l - Σ_{tripped exporting} f_l
        # f[l] is the first-stage master variable
        delta_P_trip = sum(f[l] for l in tripped_in;  init=zero(AffExpr)) -
                       sum(f[l] for l in tripped_out; init=zero(AffExpr))

        # FFR for under-frequency (deficit):
        # importing lines increase flow (δ⁺), exporting lines decrease flow (δ⁻)
        ffr_deficit = sum(delta_plus_k[l]  for l in L_in[s];  init=zero(AffExpr)) +
                      sum(delta_minus_k[l] for l in L_out[s]; init=zero(AffExpr))

        # FFR for over-frequency (surplus):
        # importing lines decrease flow (δ⁻), exporting lines increase flow (δ⁺)
        ffr_surplus = sum(delta_minus_k[l] for l in L_in[s];  init=zero(AffExpr)) +
                      sum(delta_plus_k[l]  for l in L_out[s]; init=zero(AffExpr))


        # Under-frequency constraint 
        @constraint(mp,
            delta_P_trip * 1.0 <= rhs_inertia + T_ffr_dc * ffr_deficit+ freq_slack_plus_k[s]
        )

        # Over-frequency constraint
        @constraint(mp,
            -delta_P_trip * 1.0 <= rhs_inertia + T_ffr_dc * ffr_surplus+ freq_slack_minus_k[s]
        )
    end

    # Add heavy penalty to objective:
    VOFF = 10 * VOLL  # penalty for frequency violation — must be large
    @constraint(mp, eta >=
        sum(0.7*c[g]*r_act_k[g]                        for g in G_con; init=zero(AffExpr)) +
        sum(1.1*c[g]*p_up_k[g] + 0.1*c[g]*p_down_k[g] for g in G_res; init=zero(AffExpr)) +
        sum(VOLL*s_b_k[i]                              for i in N_ac;  init=zero(AffExpr))+
        sum(VOFF * (freq_slack_plus_k[s] + freq_slack_minus_k[s]) for s in keys(S))
    )
end


function solve_ccg(; max_iter=30, tol=1e-4)

    println("="^65)
    println("  Column-and-Constraint Generation")
    println("="^65)
    @printf("%-6s %-14s %-14s %-10s %-10s\n", "Iter","LB","UB","Gap(%)","eta_K")
    println("-"^65)

    LB = -Inf
    UB =  Inf
    start_time = time()

    mp, vars = build_master_problem()
    eta   = vars.eta
    p     = vars.p
    r     = vars.r
    s     = vars.s
    f     = vars.f
    E     = vars.E
    alpha = vars.alpha

    prev_d = nothing
    prev_P = nothing
    prev_F = nothing

    prev_gamma = nothing   
    for k in 1:max_iter

        optimize!(mp)
        status_mp = termination_status(mp)
        if status_mp != MOI.OPTIMAL
            println("Master non-optimal at iter $k: $status_mp — stopping.")
            break
        end

        LB    = objective_value(mp)
        eta_K = value(eta)

        p_K     = Dict(g => value(p[g])     for g in G)
        r_K     = Dict(g => value(r[g])     for g in G_con)
        s_K     = Dict(i => value(s[i])     for i in N_ac)
        f_K     = Dict(l => value(f[l])     for l in L)
        E_K     = Dict(z => value(E[z])     for z in Z)
        alpha_K = Dict(g => value(alpha[g]) for g in G_con)

        # Oracle finds worst-case scenario 

        result = solve_oracle_lin(p_K, r_K, s_K, alpha_K, E_K, f_K;prev_gamma=prev_gamma)

        prev_gamma = result.gamma 


        if prev_d !== nothing
            d_diff = sum(abs(result.d[i] - prev_d[i]) for i in N_ac)
            P_diff = sum(abs(result.P[g] - prev_P[g]) for g in G_res)
            F_diff = sum(abs(result.F[l] - prev_F[l]) for l in L)
            @printf("  Scenario change: Δd=%.2f  ΔP=%.2f  ΔF=%.2f\n",
                    d_diff, P_diff, F_diff)
        end
        prev_d = copy(result.d)
        prev_P = copy(result.P)
        prev_F = copy(result.F)

        
        x_K     = Dict(z => value(vars.x[z])  for z in Z)
        fs_K    = Dict(:p => p_K, :r => r_K, :s => s_K,
                    :f => f_K, :E => E_K, :x => x_K)
        scen_K = Dict(:d => result.d, :P => result.P, :F => result.F)
        ss_K   = solve_second_stage(fs_K, scen_K; label="UB eval iter $k")
        

        # Update upper bound with TRUE recourse cost
        first_stage = (
            sum(O[g]*alpha_K[g] + c[g]*p_K[g]  for g in G_con) +
            sum(c[g]*p_K[g]                     for g in G_res) +
            sum(0.2*c[g]*r_K[g]                 for g in G_con) +
            sum(VOLL*s_K[i]                     for i in N_ac)
        )
        UB = min(UB, first_stage + ss_K[:obj])

        gap = abs(UB - LB) / (1 + abs(UB))
        @printf("%-6d %-14.4f %-14.4f %-10.4f %-10.4f\n", k, LB, UB, 100*gap, eta_K)

        if gap <= tol
            println("-"^65)
            println("Converged at iteration $k")
            break
        end

        # Add CCG scenario columns + constraints 
        add_scenario_to_master!(mp, k, result.d, result.P, result.F)
    end

    elapsed = time() - start_time
    println("="^65)
    println("  Final LB = $(round(LB, digits=6))")
    println("  Final UB = $(round(UB, digits=6))")
    println("  Gap      = $(round(100*(UB-LB)/(1+abs(UB)), digits=4))%")
    println("  Time     = $(round(elapsed, digits=2))s")
    println("="^65)

    optimize!(mp)

    # Extract final first-stage flows
    f_final = Dict(l => value(f[l]) for l in L)
    E_final = Dict(z => value(E[z]) for z in Z)

    # Frequency feasibility of the MAIN problem 
    freq_slack_total  = 0.0
    freq_slack_detail = Tuple{String,Float64}[]
    for v in all_variables(mp)
        if startswith(name(v), "freq_slack")
            val = value(v)
            freq_slack_total += val
            val > 1e-6 && push!(freq_slack_detail, (name(v), val))
        end
    end
    @printf("\n── Frequency feasibility of MAIN problem ──\n")
    @printf("  Total master frequency slack: %.6f\n", freq_slack_total)
    if freq_slack_total > 1e-4
        println(" VIOLATED — robust solution only softly frequency-secure")
        for (nm, val) in freq_slack_detail
            @printf("    %-30s = %.4f\n", nm, val)
        end
    else
        println("  ✓ Satisfied — master frequency slack ≈ 0")
    end
    

    return Dict(
        :obj   => UB,
        :alpha => Dict(g => value(alpha[g]) for g in G_con),
        :p     => Dict(g => value(p[g])     for g in G),
        :r     => Dict(g => value(r[g])     for g in G_con),
        :s     => Dict(i => value(s[i])     for i in N_ac),
        :f     => f_final,          
        :E     => E_final,          
        :x     => Dict(z => value(vars.x[z]) for z in Z),   
        :last_d => prev_d,          # Worst-case demand
        :last_P => prev_P,          # Worst-case RES capacity
        :last_F => prev_F,          # Worst-case line capacity
        :mp    => mp,                                         
        :vars  => vars,                                       
        :freq_slack_total  => freq_slack_total,
        :freq_slack_detail => freq_slack_detail,
    )
end


function solve_second_stage(first_stage_sol, scenario;
                             K_freq=0.016,          # (Δf_max - f_db) / f_0
                             T_ffr_dc=0.75,         # ΔT^ffr - ΔT^dc/2
                             label="")

    p_val     = first_stage_sol[:p]
    r_val     = first_stage_sol[:r]
    s_val     = first_stage_sol[:s]
    x_val     = first_stage_sol[:x]
    E_val     = first_stage_sol[:E]
    f_val     = first_stage_sol[:f]

    d_wc      = scenario[:d]
    P_wc      = scenario[:P]
    F_wc      = scenario[:F]

    ss = Model(Gurobi.Optimizer)
    set_silent(ss)
    set_optimizer_attribute(ss, "TimeLimit", 120)

    # Variables
    @variable(ss, r_act[g in G_con]  >= 0)
    @variable(ss, p_up[g in G_res]   >= 0)
    @variable(ss, p_down[g in G_res] >= 0)
    @variable(ss, s_b[i in N_ac]     >= 0)
    @variable(ss, f_b[l in L])                 # free
    @variable(ss, f_b_ac[l in CL])             # free
    @variable(ss, x_b[z in Z])                 # free

    @variable(ss, delta_plus[l in L]   >= 0)
    @variable(ss, delta_minus[l in L]   >= 0)

    @variable(ss, freq_slack_plus[s in keys(S)]  >= 0)
    @variable(ss, freq_slack_minus[s in keys(S)] >= 0)

    # AC zonal balance 
    # x^b_z - [sum r^act + sum(p^up - p^down) - sum f^b + s^b]
    #       = sum_i (sum_g p_g - d_i + s_i)
    for z in Z
        rhs_z = sum(
            sum(p_val[g] for g in G_i[i]; init=0.0) - d_wc[i] + s_val[i]
        for i in N_ac_z[z]; init=0.0)

        @constraint(ss,
            x_b[z]
            - sum(r_act[g]
                  for i in N_ac_z[z]
                  for g in intersect(G_i[i], G_con); init=zero(AffExpr))
            - sum(p_up[g] - p_down[g]
                  for i in N_ac_z[z]
                  for g in intersect(G_i[i], G_res); init=zero(AffExpr))
            + sum(
                sum(f_b[(i,j)] for j in N_dc if (i,j) in L; init=zero(AffExpr)) -
                sum(f_b[(j,i)] for j in N_dc if (j,i) in L; init=zero(AffExpr))
              for i in N_ac_z[z]; init=zero(AffExpr))
            - sum(s_b[i] for i in N_ac_z[z]; init=zero(AffExpr))
            == rhs_z
        )
    end

    # DC zonal balance 
    for z in Z
        @constraint(ss,
            sum(
                sum(f_b[l] for l in L if l[2] == i; init=zero(AffExpr)) -
                sum(f_b[l] for l in L if l[1] == i; init=zero(AffExpr))
            for i in N_dc_z[z]; init=zero(AffExpr)) == 0
        )
    end

    # OWF converters are export-only 
    owf_converters = [(30001,20001), (30002,20002), (30003,20003),
                      (30004,20004), (30005,20005)]
    for conv in owf_converters
        if conv in L
            @constraint(ss, f_b[conv] >= 0)
        end
    end

    # Critical AC line flows via ZPTDF 
    # f^{b,ac}_l = sum_z ZPTDF_{lz} * x^b_z
    for l in CL
        @constraint(ss,
            f_b_ac[l] == sum(ZPTDF[(l,z)] * x_b[z] for z in Z; init=0.0)
        )
    end

    # Zonal injection sum = 0 
    @constraint(ss, sum(x_b[z] for z in Z) == 0)

 
    # Force x_b[z] = 0 for offshore-only zones 
    for z in Z
        if z in offshore_only_zones
            @constraint(ss, x_b[z] == 0)
        end
    end

    # Reserve activation limits 
    for g in G_con
        @constraint(ss, r_act[g] <= r_val[g])
    end

    # RES redispatch limits
    for g in G_res
        @constraint(ss, p_up[g] - p_down[g] <= P_wc[g] - p_val[g])
    end

    # Balancing load shedding limit 
    for i in N_ac
        @constraint(ss, s_b[i] <= d_wc[i] - s_val[i])
    end

    # DC / AC-DC line limits 
    for l in L
        @constraint(ss, -F_wc[l] <= f_b[l] <= F_wc[l])
        @constraint(ss, 0 <= delta_plus[l] <= 2F_wc[l])
        @constraint(ss, 0 <= delta_minus[l] <= 2F_wc[l])
        @constraint(ss, delta_plus[l]  <= F_wc[l] - f_b[l])
        @constraint(ss, delta_minus[l] <= F_wc[l] + f_b[l])
    end

    # Critical AC line limits 
    for l in CL
        @constraint(ss, -F_ac_zonal[l] <= f_b_ac[l] <= F_ac_zonal[l])
    end

    #FFR frequency constraints
    for s in keys(S)
        # RHS: inertia energy budget
        Etot=sum(E_val[z] for z in S[s])
        rhs_inertia = 2.0 * K_freq * Etot
        trip_deficit = sum(
            (barF[l] - F_wc[l] > 0.1 ? 1.0 : 0.0) * f_val[l] for l in L_in[s]; init=0.0)
        trip_surplus = sum(
            (barF[l] - F_wc[l] > 0.1 ? 1.0 : 0.0) * f_val[l] for l in L_out[s]; init=0.0)

        # FFR for under-frequency (deficit):
        # importing lines increase flow (δ⁺), exporting lines decrease flow (δ⁻)
        ffr_deficit = sum(delta_plus[l]  for l in L_in[s];  init=zero(AffExpr)) +
                      sum(delta_minus[l] for l in L_out[s]; init=zero(AffExpr))

        # FFR for over-frequency (surplus):
        # importing lines decrease flow (δ⁻), exporting lines increase flow (δ⁺)
        ffr_surplus = sum(delta_minus[l] for l in L_in[s];  init=zero(AffExpr)) +
                      sum(delta_plus[l]  for l in L_out[s]; init=zero(AffExpr))


        @constraint(ss,
            (trip_deficit - trip_surplus) * 1.0 <= 
            rhs_inertia + T_ffr_dc * ffr_deficit + freq_slack_plus[s]
        )

        @constraint(ss,
            (-trip_deficit + trip_surplus) * 1.0 <= 
            rhs_inertia + T_ffr_dc * ffr_surplus + freq_slack_minus[s]
        )
    end

    # Add heavy penalty to objective:
    VOFF = 10 * VOLL  # penalty for frequency violation — must be large
    @objective(ss, Min,
        sum(0.7*c[g]*r_act[g] for g in G_con; init=0.0) +
        sum(1.1*c[g]*p_up[g] + 0.1*c[g]*p_down[g] for g in G_res; init=0.0) +
        sum(VOLL*s_b[i] for i in N_ac; init=0.0) +
        sum(VOFF * (freq_slack_plus[s] + freq_slack_minus[s]) for s in keys(S))
    )

    optimize!(ss)

    status = termination_status(ss)

    if status == MOI.INFEASIBLE
        println("  [$label] Second-stage INFEASIBLE")
        return Dict(:obj => Inf, :status => status)
    elseif status != MOI.OPTIMAL && status != MOI.TIME_LIMIT
        error("  [$label] Second-stage failed: $status")
    end

    obj = objective_value(ss)
    println("  [$label] Second-stage obj = $(round(obj, digits=2))"*
            "  status = $status")

    return Dict(
        :obj    => obj,
        :status => status,
        :r_act  => Dict(g => value(r_act[g])  for g in G_con),
        :p_up   => Dict(g => value(p_up[g])   for g in G_res),
        :p_down => Dict(g => value(p_down[g]) for g in G_res),
        :s_b    => Dict(i => value(s_b[i])    for i in N_ac),
        :f_b    => Dict(l => value(f_b[l])    for l in L),
        :x_b    => Dict(z => value(x_b[z])    for z in Z),
        :delta_plus  => Dict(l => value(delta_plus[l])  for l in L),
        :delta_minus => Dict(l => value(delta_minus[l]) for l in L),
    )
end


function solve_second_stageNodal(result;
                             override_scenario=nothing,   
                             label="")

    p_val     = result[:p]
    r_val     = result[:r]
    s_val     = result[:s]
    alpha_val = result[:alpha]
    E_val     = result[:E]
    f_val     = result[:f]

    # Use override scenario if provided, else fall back to result's own 
    if override_scenario !== nothing
        d_wc = override_scenario[:d]
        P_wc = override_scenario[:P]
        F_wc = override_scenario[:F]
    else
        d_wc = result[:last_d]
        P_wc = result[:last_P]
        F_wc = result[:last_F]
    end
    
    # Gas units NOT committed in the day-ahead: the only units allowed to
    # emergency-start in nodal redispatch. (Fast-start OCGT is the realistic plant type for post-contingency balancing.)
    G_start = [g for g in G_con if gen_info[g]["type"] == "Gas" && alpha_val[g] < 0.5]
    
    ss = Model(Gurobi.Optimizer)
    set_silent(ss)
    set_optimizer_attribute(ss, "TimeLimit", 120)

    #  Variables
    @variable(ss, r_act[g in G_con]  >= 0)
    @variable(ss, p_up[g in G_res]   >= 0)
    @variable(ss, p_down[g in G_res] >= 0)
    @variable(ss, s_b[i in N_ac]     >= 0)
    @variable(ss, f_b[l in L])                 # free
    @variable(ss, f_b_ac[l in L_ac])             # free
    @variable(ss, x_b[i in N_ac])                 # free

    @variable(ss, delta_plus[l in L]   >= 0)
    @variable(ss, delta_minus[l in L]   >= 0)

    @variable(ss, freq_slack_plus[s in keys(S)]  >= 0)
    @variable(ss, freq_slack_minus[s in keys(S)] >= 0)

   
    # Emergency generation from units NOT committed in the day-ahead.
    # Priced at a premium; only uncommitted conventional units may start.

    @variable(ss, g_emer[g in G_start] >= 0)      # emergency energy
    @variable(ss, u_start[g in G_start], Bin)      # 1 if the unit is started
    for g in G_start
        @constraint(ss, g_emer[g] <= P_max[g] * u_start[g])   # no output unless started
    end
    
    # AC zonal balance 
    for i in N_ac
        rhs_i =  sum(p_val[g] for g in G_i[i]; init=0.0) - d_wc[i] + s_val[i]
       
        @constraint(ss,
            x_b[i]
            - sum(r_act[g] for g in intersect(G_i[i], G_con); init=zero(AffExpr))
            - sum(g_emer[g] for g in intersect(G_i[i], G_start); init=zero(AffExpr))  # NEW NEWLY 
            - sum(p_up[g] - p_down[g] for g in intersect(G_i[i], G_res); init=zero(AffExpr))
            + sum(f_b[(i,j)] for j in N_dc if (i,j) in L; init=zero(AffExpr))
            - s_b[i]
            == rhs_i
        )
        
    end

    # DC zonal balance 
    for i in N_dc
        @constraint(ss,
                sum(f_b[l] for l in L if l[2] == i; init=zero(AffExpr)) -
                sum(f_b[l] for l in L if l[1] == i; init=zero(AffExpr))== 0
        )
    end

    # AC line flows 
    for l in L_ac
        @constraint(ss,
            f_b_ac[l] == sum(NPTDF[(l,i)] * x_b[i] for i in N_ac; init=0.0)
        )
    end

    # Zonal injection sum = 0 
    @constraint(ss, sum(x_b[i] for i in N_ac) == 0)

 
    # Force x_b[i] = 0 for offshore AC buses 
    for i in N_ac
        if i in offshore_only_buses
            @constraint(ss, x_b[i] == 0)
        end
    end

    # Reserve activation limits 
    for g in G_con
        @constraint(ss, r_act[g] <= r_val[g])
    end

    # RES redispatch limits 
    for g in G_res
        @constraint(ss, p_up[g] - p_down[g] <= P_wc[g] - p_val[g])
    end

    # Balancing load shedding limit 
    for i in N_ac
        @constraint(ss, s_b[i] <= d_wc[i] - s_val[i])
    end

    # DC / AC-DC line limits 
    for l in L
        @constraint(ss, -F_wc[l] <= f_b[l] <= F_wc[l])
        @constraint(ss, 0 <= delta_plus[l] <= 2F_wc[l])
        @constraint(ss, 0 <= delta_minus[l] <= 2F_wc[l])
        @constraint(ss, delta_plus[l]  <= F_wc[l] - f_b[l])
        @constraint(ss, delta_minus[l] <= F_wc[l] + f_b[l])
    end

    # OWF converters are export-only 
    owf_converters = [(30001,20001), (30002,20002), (30003,20003),
                      (30004,20004), (30005,20005)]
    for conv in owf_converters
        if conv in L
            @constraint(ss, f_b[conv] >= 0)
        end
    end

    # Critical AC line limits 
    for l in CL
        @constraint(ss, -F_ac_zonal[l] <= f_b_ac[l] <= F_ac_zonal[l])
    end

    #FFR frequency constraints
    for s in keys(S)
        # RHS: inertia energy budget
        Etot=sum(E_val[z] for z in S[s])
        rhs_inertia = 2.0 * K_freq * Etot
        trip_deficit = sum(
            (barF[l] - F_wc[l] > 0.1 ? 1.0 : 0.0) * f_val[l] for l in L_in[s]; init=0.0)
        trip_surplus = sum(
            (barF[l] - F_wc[l] > 0.1 ? 1.0 : 0.0) * f_val[l] for l in L_out[s]; init=0.0)

        # FFR for under-frequency (deficit):
        # importing lines increase flow (δ⁺), exporting lines decrease flow (δ⁻)
        ffr_deficit = sum(delta_plus[l]  for l in L_in[s];  init=zero(AffExpr)) +
                      sum(delta_minus[l] for l in L_out[s]; init=zero(AffExpr))

        # FFR for over-frequency (surplus):
        # importing lines decrease flow (δ⁻), exporting lines increase flow (δ⁺)
        ffr_surplus = sum(delta_minus[l] for l in L_in[s];  init=zero(AffExpr)) +
                      sum(delta_plus[l]  for l in L_out[s]; init=zero(AffExpr))

        @constraint(ss,
            (trip_deficit - trip_surplus) * 1.0 <= 
            rhs_inertia + T_ffr_dc * ffr_deficit + freq_slack_plus[s]
        )

        @constraint(ss,
            (-trip_deficit + trip_surplus) * 1.0 <= 
            rhs_inertia + T_ffr_dc * ffr_surplus + freq_slack_minus[s]
        )
        
    end

    # Add heavy penalty to objective:
    VOFF = 10 * VOLL  # penalty for frequency violation — must be large
   
    kappaEmer = 3.0   # premium on marginal cost for an emergency start
    @objective(ss, Min,
        sum(0.7*c[g]*r_act[g] for g in G_con; init=0.0) +
        sum(O[g]*u_start[g] + kappaEmer*c[g]*g_emer[g] for g in G_start; init=0.0) +          
        sum(1.1*c[g]*p_up[g] + 0.1*c[g]*p_down[g] for g in G_res; init=0.0) +
        sum(VOLL*s_b[i] for i in N_ac; init=0.0) +
        sum(VOFF*(freq_slack_plus[s] + freq_slack_minus[s]) for s in keys(S))
    )
    
    optimize!(ss)

    status = termination_status(ss)

    if status == MOI.INFEASIBLE
        println("  [$label] Second-stage INFEASIBLE")
        return Dict(:obj => Inf, :status => status)
    elseif status != MOI.OPTIMAL && status != MOI.TIME_LIMIT
        error("  [$label] Second-stage failed: $status")
    end

    obj = objective_value(ss)
    println("  [$label] Second-stage obj = $(round(obj, digits=2))"*
            "  status = $status")

    return Dict(
        :obj    => obj,
        :status => status,
        :r_act  => Dict(g => value(r_act[g])  for g in G_con),
        :p_up   => Dict(g => value(p_up[g])   for g in G_res),
        :p_down => Dict(g => value(p_down[g]) for g in G_res),
        :s_b    => Dict(i => value(s_b[i])    for i in N_ac),
        :f_b    => Dict(l => value(f_b[l])    for l in L),
        :x_b    => Dict(i => value(x_b[i])    for i in N_ac),
        :delta_plus  => Dict(l => value(delta_plus[l])  for l in L),
        :delta_minus => Dict(l => value(delta_minus[l]) for l in L),
        :g_emer  => Dict(g => value(g_emer[g])  for g in G_start),
        :u_start => Dict(g => value(u_start[g]) for g in G_start),
        # add to the return Dict of solve_second_stageNodal:
        :freq_slack_plus  => Dict(s => value(freq_slack_plus[s])  for s in keys(S)),
        :freq_slack_minus => Dict(s => value(freq_slack_minus[s]) for s in keys(S)),
    )
end

function extract_zonal_prices(result)
    mp = result[:mp]; vars = result[:vars]
    for g in G_con
        unset_binary(vars.alpha[g])
        fix(vars.alpha[g], round(result[:alpha][g]); force=true)
    end
    optimize!(mp)
    if termination_status(mp) != MOI.OPTIMAL
        @warn "LP relax failed"
        for g in G_con; unfix(vars.alpha[g]); set_binary(vars.alpha[g]) end
        return nothing
    end
    prices = Dict{String,Float64}(z => -dual(vars.zonal_bal[z]) * 1000.0 for z in Z)
    for g in G_con; unfix(vars.alpha[g]); set_binary(vars.alpha[g]) end
    return prices
end

function compute_congestion_revenue(result, prices)
    cong = Dict(); tot = 0.0
    for l in L
        fl = result[:f][l]
        zs = (l[1] in N_ac_set) ? z_ac_i[l[1]] : z_dc_i[l[1]]
        zr = z_dc_i[l[2]]
        ps = get(prices, zs, 0.0); pr = get(prices, zr, 0.0)
        rv = fl * (pr - ps)
        cong[l] = Dict("flow"=>fl, "z_send"=>zs, "z_recv"=>zr,
                        "p_send"=>ps, "p_recv"=>pr, "revenue"=>rv)
        tot += rv
    end
    return cong, tot
end

# Count generators for budget sizing 
n_res       = length(G_res)
n_load_bus  = length([i for i in N_ac if bard[i] > 1e-5])

# Case definitions for the paper
# Run each of these in turn (comment/uncomment) to build the comparison table.
 
# Case A: Deterministic (no uncertainty)
#bigGammaC = 0;  bigGammad = 0;  bigGammaP = 0
 
# Case B: Converter contingency only (N-1 on converters)
#bigGammaC = 1;  bigGammad = 0;  bigGammaP = 0

# Case C: Converter contingency only (N-1 on converters, res)
#bigGammaC = 1;  bigGammad = 0;  bigGammaP = ceil(Int, n_res * 1.0)

# Case D: Converter contingency only (N-1 on converters, res, 5% demand)
#bigGammaC = 1;  bigGammad = ceil(Int, n_load_bus * 0.05);  bigGammaP = ceil(Int, n_res * 1.0)

# Case E: Converter contingency only (N-1 on converters, res, 10% demand)
bigGammaC = 1;  bigGammad = ceil(Int, n_load_bus * 0.10);  bigGammaP = ceil(Int, n_res * 1.0)

# Scenario F: Converter contingency only (N-1 on converters, res, 15% demand)
#bigGammaC = 1;  bigGammad = ceil(Int, n_load_bus * 0.15);  bigGammaP = ceil(Int, n_res * 1.0)


# ═══════════════════════════════════════════════════════════════════════════
#  SOLVE CCG
# ═══════════════════════════════════════════════════════════════════════════
scenario_tag = "C$(bigGammaC)_D$(bigGammad)_P$(bigGammaP)"
println("\n  Scenario tag: $(scenario_tag)")
println("  Design:       $(design_choice)")

using Serialization

result = solve_ccg(; max_iter=10, tol=1e-5)

nodal_result = solve_second_stageNodal(result)

# ═══════════════════════════════════════════════════════════════════════════
#  EXTRACT PRICES
# ═══════════════════════════════════════════════════════════════════════════
prices = extract_zonal_prices(result)

# ═══════════════════════════════════════════════════════════════════════════
#  RESULTS SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
println("\n" * "═"^65)
println("  RESULTS: $design_choice  [$scenario_tag]")
println("═"^65)

# Cost breakdown (tab:main_results, fig:cost_decomp)
commitment = sum(O[g]*result[:alpha][g] for g in G_con)
gen_conv   = sum(c[g]*result[:p][g] for g in G_con)
gen_res    = sum(c[g]*result[:p][g] for g in G_res)
reserve    = sum(0.2*c[g]*result[:r][g] for g in G_con)
shed_da    = sum(VOLL*result[:s][i] for i in N_ac)
first_stg  = commitment + gen_conv + gen_res + reserve + shed_da

@printf("  DA cost (first-stage):   %10.2f k€\n", first_stg)
@printf("  Nodal redispatch cost:   %10.2f k€\n", nodal_result[:obj])
@printf("  TOTAL (DA + nodal):      %10.2f k€\n", first_stg + nodal_result[:obj])
@printf("  Worst-case recourse:   %10.2f k€\n", result[:obj] - first_stg)
@printf("  TOTAL (zonal):          %10.2f k€\n", result[:obj])

# Operational metrics (tab:operational)
total_reserve = sum(result[:r][g] for g in G_con)
total_shed_rt = sum(nodal_result[:s_b][i] for i in N_ac; init=0.0)
E_total       = sum(result[:E][z] for z in Z if haskey(result[:E], z); init=0.0)

# Committed gas capacity
gas_committed_cap = sum(
    result[:alpha][g] > 0.5 ? P_max[g] : 0.0
    for g in G_con if gen_info[g]["type"] == "Gas"; init=0.0)

@printf("  Reserve procured:        %10.1f MW\n", total_reserve)
@printf("  Committed gas capacity:  %10.1f MW\n", gas_committed_cap)
@printf("  RT load shedding:        %10.1f MW\n", total_shed_rt)
@printf("  Total inertia:           %10.1f MWs\n", E_total)
@printf("  Load shedding (DA):    %10.1f MW\n", shed_da)


# Prices and congestion (tab:prices)
if prices !== nothing
    pvals = collect(values(prices))
    price_spread = maximum(pvals) - minimum(pvals)
    _, total_cong_rev = compute_congestion_revenue(result, prices)
    @printf("  Price spread:            %10.2f €/MWh\n", price_spread)
    @printf("  Congestion revenue:      %10.2f €/h\n", total_cong_rev)
end

# Frequency feasibility check
if get(result, :freq_slack_total, 0.0) > 1e-4
    @printf("  Frequency VIOLATED — total slack = %.4f\n", result[:freq_slack_total])
else
    println("  ✓ Frequency satisfied")
end



println("\n" * "═"^75)
println("  DONE — $design_choice [$scenario_tag]")
println("═"^75)
