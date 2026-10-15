# NorthSeaData
North Sea Network Data used in the paper of Adaptive Robust Optimization for Market Clearing Problem

OVERVIEW
--------

We compare two electricity market designs for integrating large-scale
offshore wind into the North Sea grid:

  - Home Market (HM): Offshore wind farms are assigned to the onshore
    bidding zone of the connecting country.

  - Offshore Bidding Zone (OBZ): Each offshore wind farm hub forms its
    own bidding zone, enabling market-based allocation of transmission
    capacity.

The model is a two-stage adaptive robust optimization solved via
Column-and-Constraint Generation (CCG):

  1. First stage 
     Unit commitment, generation dispatch, reserve procurement, and
     cross-zonal energy exchange under a ZPTDF-based flow model with
     frequency security constraints (inertia, RoCoF, nadir, FFR via
     HVDC converters).

  2. Second stage (real-time redispatch):
     Redispatch under worst-case uncertainty realizations,
     including HVDC converter contingencies, RES forecast errors,
     and demand deviations.

Uncertainty is modeled via polyhedral uncertainty sets with three
budget parameters:

  GammaC -- number of simultaneous HVDC converter outages (N-1)
  GammaP -- number of RES generators deviating from forecast
  Gammad -- number of load buses deviating from forecast


REPOSITORY STRUCTURE
--------------------

  README.txt
  HMvsOBZ.jl                         Single-hour model 
  DECvsJUN.jl                         Multi-hour model (24h, DEC21 or JUN21)
  DETvsROBUST.jl                         Single-hour model with det. vs robust comparison
  data
      busAC.txt                AC bus data (node locations, zones)
      branchAC.txt             AC branch data (lines, transformers)
      busDC.txt                DC bus data (converter terminals, OWF hubs)
      branchDC.txt             DC branch data (HVDC cables)
      convdc.txt               HVDC converter station parameters
      gen.txt                  Generator data (type, capacity, costs, inertia)
      load.txt                 Load bus data (demand, zones)
      OWFs.txt                 Offshore wind farm hubs (5 hubs)
      zones.txt                Bidding zone definitions (16 zones)
      interZonal_branchAC.txt  Inter-zonal AC branches (cross-border lines)
  ZPTDF_CL.txt                 Zonal PTDF matrix -- HM configuration
  ZPTDF_OBZ.txt                Zonal PTDF matrix -- OBZ configuration


DATA FILES
----------

All data files are tab-delimited text with a single header row.

busAC.txt (3407 nodes)

  AC bus (node) data for the entire onshore transmission network.
  Each row represents one AC bus with its geographic location and
  zone assignment.

  Key columns:
    bus_i       -- unique bus index
    name        -- bus name
    lat, lon    -- geographic coordinates
    zone        -- bidding zone the bus belongs to (e.g., BE, DE, NO2)
    base_kv     -- base voltage (kV)
    bus_type    -- bus type (PQ, PV, or reference)
    country     -- country code

branchAC.txt (4836 branches)

  AC branch data representing transmission lines and transformers in
  the onshore network. Used for the nodal redispatch (second-stage)
  power flow calculations via the NPTDF matrix.

  Key columns:
    f_bus, t_bus      -- from-bus and to-bus indices (reference busAC.txt)
    br_r, br_x        -- branch resistance and reactance (p.u.)
    rate_a             -- thermal capacity limit (MW)
    interconnector     -- TRUE if the branch crosses a zone boundary
    transformer        -- TRUE if the branch is a transformer
    type               -- branch type classification

busDC.txt (47 buses)

  DC bus data for the HVDC network, including onshore converter
  station terminals and the five offshore wind farm hub buses.

  Key columns:
    busdc_i     -- unique DC bus index
    name        -- bus name
    lat, lon    -- geographic coordinates
    zone        -- zone assignment (zone_no 33 = offshore hub bus)
    basekVdc    -- base DC voltage (kV)
    Vdc         -- DC voltage setpoint

branchDC.txt (41 cables)

  HVDC cable data for all DC connections: existing cross-border
  interconnectors, hub-to-shore cables, and hub-to-hub cables.
  These are the transmission assets whose N-1 contingency is
  modeled via the GammaC uncertainty budget.

  Key columns:
    name                -- cable/link name (e.g., NORNED, Nautilus)
    fbusdc, tbusdc      -- from and to DC bus indices
    fZone, tZone        -- from and to zone names
    rateA               -- cable capacity (MW)
    type                -- cable type classification

convdc.txt (47 converters)

  HVDC converter station parameters linking DC buses to AC buses.
  These converters enable power transfer between the AC and DC
  networks and provide Fast Frequency Response (FFR) headroom in
  the frequency security constraints.

  Key columns:
    busdc_i         -- DC bus index (reference busDC.txt)
    busac_i         -- AC bus index (reference busAC.txt)
    Pacmax, Pacmin  -- maximum and minimum AC-side active power (MW)
    interconnector  -- TRUE if the converter is part of an existing
                       cross-border interconnector
    LossA, LossB    -- converter loss coefficients
    LossCinv, LossCrec -- quadratic loss coefficients (inverter/rectifier)

  Converters 301-305 are the OWF hub converters (Pacmax = 10000 MW
  placeholder, sized by connected cable capacity in the model).

gen.txt (3944 generators)

  All generation units in the system, including conventional
  thermal plants, nuclear, hydro, and renewable energy sources
  (onshore wind, offshore wind, solar PV). Each generator's inertia
  constant (H) is derived from its type for the frequency security
  constraints.

  Key columns:
    gen_bus     -- AC bus where the generator is connected
    zone        -- bidding zone
    country     -- country code
    type        -- technology type: Gas, Nuclear, Hard Coal, Oil,
                   Lignite, Biomass, Hydro Reservoir,
                   Hydro Pumped Storage, Hydro Run-of-River,
                   Offshore, Onshore, Solar PV
    type_tyndp  -- TYNDP subtype (e.g., "Gas CCGT new", "Gas OCGT")
    pmax, pmin  -- maximum and minimum generation capacity (MW)
    unit_cost   -- marginal generation cost (EUR/MWh)
    qmax, qmin  -- reactive power limits (MVAr)

load.txt (1766 load buses)

  Demand data for all load buses in the system. Each row represents
  one load bus with its active power demand and associated zone.

  Key columns:
    load_bus        -- AC bus index where the load is located
    pd              -- active power demand (MW)
    zone            -- bidding zone
    country         -- country code
    country_peak_load -- peak load for the country (MW)
    cost_red        -- cost of demand reduction (EUR/MWh)
    cost_curt       -- cost of demand curtailment (EUR/MWh)
    pmax            -- maximum load at this bus (MW)

OWFs.txt (5 hubs)

  Offshore wind farm hub definitions. Each hub aggregates one or
  more planned offshore wind farms into a single connection point.

  Key columns:
    index       -- hub index (1-5)
    OWF         -- hub identifier
    zone        -- onshore zone the hub is associated with under HM
    name        -- full hub name
    lat, lon    -- geographic coordinates
    capacity    -- total installed capacity (MW)

  Hubs:
    1  Belgian Princess Elisabeth Island          BE    3,500 MW
    2  NL Energy Hubs                             NL   10,000 MW
    3  German Offshore Interconnection Cluster    DE   10,000 MW
    4  Danish Energy Island                       DK1   3,000 MW
    5  Sorlige Nordsjo 2                          NO2   3,000 MW

zones.txt (16 zones)

  Bidding zone definitions with centroid coordinates for the
  16-zone representation of the North Sea region.

  Key columns:
    index       -- zone index (1-16)
    zone        -- zone name (e.g., BE, DE, DK1, NO3, SE2, UK)
    lat, lon    -- zone centroid coordinates

  Under the OBZ design, 5 additional offshore zones are created
  (one per hub), extending this to 21 zones.

interZonal_branchAC.txt (58 branches)

  Cross-border (inter-zonal) AC branches extracted from the full
  branchAC.txt network. These represent the AC interconnections
  between bidding zones and are used in the ZPTDF matrix
  construction for zonal market clearing.

  Key columns:
    f_bus2, t_bus2    -- from-bus and to-bus indices
    f_zone, t_zone    -- from and to zone names
    rate_a             -- thermal capacity (MW)
    br_r, br_x         -- resistance and reactance (p.u.)
    interconnector     -- always TRUE (all rows are cross-border)

  Cross-border corridors include:
    DE-BE, DK1-DE, FR-BE, NL-BE, NL-DE (Continental)
    NO-SE internal Nordic connections
    SE internal connections (SE1-SE2, SE2-SE3, SE3-SE4)
    DK1-SE3, DK2-SE4 (Nordic-Continental)

ZPTDF_CL.txt / ZPTDF_OBZ.txt

  Zonal Power Transfer Distribution Factor (ZPTDF) matrices, used
  for the zonal market clearing (first-stage) power flow model.

  ZPTDF_CL.txt   -- HM (Home Market) configuration: 16 zones,
                    offshore wind assigned to onshore zones.
  ZPTDF_OBZ.txt  -- OBZ (Offshore Bidding Zone) configuration:
                    21 zones (16 onshore + 5 offshore).

  Each row corresponds to a critical branch, each column to a zone.
  The matrix entry gives the sensitivity of power flow on that
  branch to a net injection change in that zone.


SCRIPTS
-------

HMvsOBZ.jl -- Single-Hour Model

  Solves one representative hour (winter peak, DEC21) for a single
  uncertainty case. Set design_choice = "HM" or "OBZ" and uncomment
  one of the cases A-F before running. Outputs include
  DA cost, nodal redispatch cost, reserves, load shedding, inertia,
  zonal prices, and congestion revenue.

  Uncertainty cases:

    Case   GammaC   Gammad          GammaP        Description
    ----   ------   ------          ------        -----------
    A      0        0               0             Deterministic (no uncertainty)
    B      1        0               0             Converter N-1 only
    C      1        0               100% of RES   Converter N-1 + full RES uncertainty
    D      1        5% of loads     100% of RES   + 5% demand uncertainty
    E      1        10% of loads    100% of RES   + 10% demand uncertainty
    F      1        15% of loads    100% of RES   + 15% demand uncertainty

DECvsJUN.jl -- Multi-Hour Model (24h)

  Solves all 24 hours of a representative day.
  Supports both DEC21 (winter) and JUN21 (summer) load/RES profiles.
  Collects hourly results and produces daily aggregates.

DETvsROBUST.jl -- Deterministic vs Robust Comparison

  Runs both a deterministic (Gamma = 0) and a robust (with uncertainty
  budgets) solve for a given design, then evaluates both solutions
  under the worst-case scenario to compute the Value of Robustness
  (VoR), Cost of Uncertainty (CoU), and hedging cost.


TEST SYSTEM
-----------

The model uses a 16-zone representation of the North Sea region
covering 8 countries:

  Country               Zones   Synchronous Area
  -------               -----   ----------------
  Belgium (BE)          1       Continental
  Germany (DE)          1       Continental
  Denmark (DK1, DK2)   2       Continental
  France (FR)           1       Continental
  Netherlands (NL)      1       Continental
  Norway (NO1-NO5)      5       Nordic
  Sweden (SE1-SE4)      4       Nordic
  United Kingdom (UK)   1       UK (island)

Offshore wind farm hubs (5 hubs, total 29.5 GW installed capacity):

  Hub                                       Zone   Capacity (MW)
  ---                                       ----   -------------
  Belgian Princess Elisabeth Island         BE     3,500
  NL Energy Hubs                            NL     10,000
  German Offshore Interconnection Cluster   DE     10,000
  Danish Energy Island                      DK1    3,000
  Sorlige Nordsjo 2                         NO2    3,000

Under the OBZ design, each hub forms its own offshore bidding zone
(5 additional zones), connected to onshore zones and to each other
via HVDC cables.



================================================================================
