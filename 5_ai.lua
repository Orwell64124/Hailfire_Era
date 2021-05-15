#textdomain-Hailfire_Era

#define HAILFIRE_VILLAGES
	[event]
        name=preload
        first_time_only=no
		[lua]
			code = <<
			
local H = wesnoth.require "helper"
local W = H.set_wml_action_metatable {}
local LS = wesnoth.require "location_set"
local F = wesnoth.require "functional"
local M = wesnoth.map

local fred_village_utils = {}

function fred_village_utils.villages_to_protect(zone_cfgs, side_cfgs, move_data)
    local my_start_hex, enemy_start_hex
    for side,cfgs in ipairs(side_cfgs) do
        if (side == wesnoth.current.side) then
            my_start_hex = cfgs.start_hex
        else
            enemy_start_hex = cfgs.start_hex
        end
    end

    -- TODO: this is needed in several places, could be pulled into move_data or something
    local zone_maps = {}
    for zone_id,cfg in pairs(zone_cfgs) do
        zone_maps[zone_id] = {}
        local zone = wesnoth.get_locations(cfg.ops_slf)
        for _,loc in ipairs(zone) do
            FU.set_fgumap_value(zone_maps[zone_id], loc[1], loc[2], 'in_zone', true)
        end
    end

    local villages_to_protect_maps = {}
    for x,y,_ in FU.fgumap_iter(move_data.village_map) do
        local my_distance = wesnoth.map.distance_between(x, y, my_start_hex[1], my_start_hex[2])
        local enemy_distance = wesnoth.map.distance_between(x, y, enemy_start_hex[1], enemy_start_hex[2])

        local village_zone
        for zone_id,_ in pairs(zone_maps) do
            if FU.get_fgumap_value(zone_maps[zone_id], x, y, 'in_zone') then
                village_zone = zone_id
                break
            end
        end
        if (not village_zone) then village_zone = 'other' end

        if (not villages_to_protect_maps[village_zone]) then
            villages_to_protect_maps[village_zone] = {}
        end
        if (my_distance <= enemy_distance) then
            FU.set_fgumap_value(villages_to_protect_maps[village_zone], x, y, 'protect', true)
        else
            FU.set_fgumap_value(villages_to_protect_maps[village_zone], x, y, 'protect', false)
        end
    end

    return villages_to_protect_maps
end


function fred_village_utils.village_goals(villages_to_protect_maps, move_data)
    -- Village goals are those that are:
    --  - on my side of the map
    --  - not owned by me
    -- We set those up as arrays, one for each zone
    --  - if a village is found that is not in a zone, assign it zone 'other'

    local zone_village_goals = {}
    for zone_id, villages in pairs(villages_to_protect_maps) do
        for x,y,village_data in FU.fgumap_iter(villages) do
            local owner = FU.get_fgumap_value(move_data.village_map, x, y, 'owner')

            if (owner ~= wesnoth.current.side) then
                if (not zone_village_goals[zone_id]) then
                    zone_village_goals[zone_id] = {}
                end

                local grab_only = true
                if village_data.protect then
                    grab_only = false
                end

                local threats = FU.get_fgumap_value(move_data.enemy_attack_map[1], x, y, 'ids')

                table.insert(zone_village_goals[zone_id], {
                    x = x, y = y,
                    owner = owner,
                    grab_only = grab_only,
                    threats = threats
                })
            end
        end
    end

    return zone_village_goals
end


function fred_village_utils.protect_locs(villages_to_protect_maps, fred_data)
    -- For now, every village on our side of the map that can be reached
    -- by an enemy needs to be protected

    local protect_locs = {}
    for zone_id,villages in pairs(villages_to_protect_maps) do
        protect_locs[zone_id] = {}
        local max_ld, loc
        for x,y,village_data in FU.fgumap_iter(villages) do
            if village_data.protect then
                local is_protected = true
                for enemy_id,_ in pairs(fred_data.move_data.enemies) do
                    if FU.get_fgumap_value(fred_data.turn_data.enemy_initial_reach_maps[enemy_id], x, y, 'moves_left') then
                        if FU.get_fgumap_value(fred_data.move_data.reach_maps[enemy_id], x, y, 'moves_left') then
                            is_protected = false
                        end

                        local ld = FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, x, y, 'distance')
                        if (not max_ld) or (ld > max_ld) then
                            max_ld = ld
                            loc = { x, y }
                        end
                    end
                end
                if loc then
                    loc.is_protected = is_protected
                end
            end
        end

        if max_ld then
            -- In this case, we want both min and max to be the same
            protect_locs[zone_id].leader_distance = {
                min = max_ld,
                max = max_ld
            }
            protect_locs[zone_id].locs = { loc }
        end
    end

    return protect_locs
end


function fred_village_utils.assign_grabbers(zone_village_goals, villages_to_protect_maps, assigned_units, village_actions, fred_data)
    -- assigned_units and village_actions are modified directly in place

    local value_ratio = fred_data.turn_data.behavior.orders.value_ratio
    local leader_derating = FCFG.get_cfg_parm('leader_derating')

    local move_data = fred_data.move_data
    -- Villages that can be reached are dealt with separately from others
    -- Only go over those found above
    local villages_in_reach = { by_village = {}, by_unit = {} }

    for zone_id,villages in pairs(zone_village_goals) do
        for _,village in ipairs(villages) do
            local x, y = village.x, village.y

            local tmp_in_reach = {
                x = x, y = y,
                owner = village.owner, zone_id = zone_id,
                units = {}
            }
            --std_print(x, y)

            local ids = FU.get_fgumap_value(move_data.my_move_map[1], x, y, 'ids') or {}

            for _,id in pairs(ids) do
                local loc = move_data.my_units[id]
                -- Only include the leader if he's on the keep
                if (not move_data.unit_infos[id].canrecruit)
                    or wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).keep
                then
                    --std_print('  ' .. id, loc[1], loc[2])

                    local max_damage, av_damage = 0, 0
                    if village.threats then
                        for _,enemy_id in ipairs(village.threats) do
                            local att = fred_data.turn_data.unit_attacks[id][enemy_id]
                            local damage_taken = att.damage_counter.base_taken
                            if move_data.unit_infos[enemy_id].canrecruit then
                                damage_taken = damage_taken * leader_derating
                            end

                            -- TODO: this does not take chance_to_hit specials into account
                            local my_hc = 1 - FGUI.get_unit_defense(move_data.unit_copies[id], x, y, move_data.defense_maps)
                            --std_print('    ' .. enemy_id, damage_taken, my_hc)

                            max_damage = max_damage + damage_taken
                            av_damage = av_damage + damage_taken * my_hc
                        end
                    end
                    --std_print('  -> ' .. av_damage, max_damage)

                    -- applicable_damage: if this is smaller than the unit's hitpoints, the grabbing is acceptable
                    -- For villages to be protected, we always grab them (i.e. applicable_damage = 0)
                    -- Otherwise, use the mean between average and maximum damage,
                    -- Except for the leader, for which we are much more conservative in both cases.
                    local applicable_damage = 0
                    if (not FU.get_fgumap_value(villages_to_protect_maps, x, y, 'protect')) then
                        local xp_mult = FU.weight_s(move_data.unit_infos[id].experience / move_data.unit_infos[id].max_experience, 0.5)
                        local level = move_data.unit_infos[id].level
                        hp_max = (max_damage + av_damage) / 2
                        dh = 1.5 * (hp_max - av_damage / 2) * (1 - value_ratio) * (1 - xp_mult) / level^2
                        applicable_damage = max_damage - dh
                    end
                    if move_data.unit_infos[id].canrecruit then
                        applicable_damage = max_damage * 2
                    end
                    --std_print('     ' .. applicable_damage, move_data.unit_infos[id].hitpoints)

                    if (applicable_damage < move_data.unit_infos[id].hitpoints) then
                        table.insert(tmp_in_reach.units, id)

                        -- For this is sufficient to just count how many villages a unit can get to
                        if (not villages_in_reach.by_unit[id]) then
                            villages_in_reach.by_unit[id] = 1
                        else
                            villages_in_reach.by_unit[id] = villages_in_reach.by_unit[id] + 1
                        end
                    end
                end
            end

            if (#tmp_in_reach.units > 0) then
                table.insert(villages_in_reach.by_village, tmp_in_reach)
            end
        end
    end


    -- Now find best villages for those units
    -- This is one where we need to do the full analysis at this layer,
    -- as it determines which units goes into which zone
    local best_captures = {}
    local keep_trying = true
    while keep_trying do
        keep_trying = false

        local max_rating, best_id, best_index
        for i_v,village in ipairs(villages_in_reach.by_village) do
            local base_rating = 1000
            if (village.owner ~= 0) then
                base_rating = base_rating + 1200
            end
            base_rating = base_rating / #village.units

            -- Prefer villages farther back
            local add_rating_village = -2 * FU.get_fgumap_value(fred_data.turn_data.leader_distance_map, village.x, village.y, 'distance')

            for _,id in ipairs(village.units) do
                local unit_rating = base_rating / (villages_in_reach.by_unit[id]^2)

                local ui = move_data.unit_infos[id]

                -- Use most injured unit first (but less important than choice of village)
                -- Don't give an injured bonus for regenerating units
                local add_rating_unit = 0
                if (not ui.abilities.regenerate) then
                    add_rating_unit = add_rating_unit + (ui.max_hitpoints - ui.hitpoints) / ui.max_hitpoints

                    if ui.status.poisoned then
                        local poison_damage = 8
                        if ui.traits.healthy then
                            poison_damage = poison_damage * 0.75
                        end
                        add_rating_unit = add_rating_unit + poison_damage / ui.max_hitpoints
                    end
                end

                if ui.traits.healthy then
                    add_rating_unit = add_rating_unit - 2 / ui.max_hitpoints
                end

                -- And finally, prefer the fastest unit, but at an even lesser level
                add_rating_unit = add_rating_unit + ui.max_moves / 100.

                -- Finally, prefer the leader, if possible, but only in the minor ratings
                if ui.canrecruit then
                    -- Note that add_rating_unit can be negative, but that's okay here
                    add_rating_unit = add_rating_unit * 2
                end

                local total_rating = unit_rating + add_rating_village + add_rating_unit
                --std_print(id, add_rating_unit, total_rating, ui.canrecruit)

                if (not max_rating) or (total_rating > max_rating) then
                    max_rating = total_rating
                    best_id, best_index = id, i_v
                end
            end
        end

        if best_id then
            table.insert(best_captures, {
                id = best_id ,
                x = villages_in_reach.by_village[best_index].x,
                y = villages_in_reach.by_village[best_index].y,
                zone_id = villages_in_reach.by_village[best_index].zone_id
            })

            -- We also need to delete both this village and unit from the list
            -- before considering the next village/unit
            -- 1. Each unit that could reach this village can reach one village less overall
            for _,id in ipairs(villages_in_reach.by_village[best_index].units) do
                villages_in_reach.by_unit[id] = villages_in_reach.by_unit[id] - 1
            end

            -- 2. Remove theis village
            table.remove(villages_in_reach.by_village, best_index)

            -- 3. Remove this unit
            villages_in_reach.by_unit[best_id] = nil

            -- 4. Remove this unit from all other villages
            for _,village in ipairs(villages_in_reach.by_village) do
                for i = #village.units,1,-1 do
                    if (village.units[i] == best_id) then
                        table.remove(village.units, i)
                    end
                end
            end

            keep_trying = true
        end
    end

    for _,capture in ipairs(best_captures) do
        if (not assigned_units[capture.zone_id]) then
            assigned_units[capture.zone_id] = {}
        end
        assigned_units[capture.zone_id][capture.id] = move_data.units[capture.id]

        -- This currently only works for single-unit actions; can be expanded as needed
        local unit = move_data.my_units[capture.id]
        unit.id = capture.id
        table.insert(village_actions, {
            action = {
                zone_id = capture.zone_id,
                action_str = 'grab_village',
                units = { unit },
                dsts = { { capture.x, capture.y } }
            }
        })
    end
end


function fred_village_utils.assign_scouts(zone_village_goals, assigned_units, retreat_utilities, move_data)
    -- Potential TODOs:
    --  - Add threat assessment for scout routes; it might in fact make sense to use
    --    injured units to scout in unthreatened areas
    --  - Actually assigning scouting actions
    -- Find how many units are needed in each zone for moving toward villages ('exploring')
    local units_needed_villages = {}
    local villages_per_unit = FCFG.get_cfg_parm('villages_per_unit')
    for zone_id,villages in pairs(zone_village_goals) do
        local n_villages = 0
        for _,village in pairs(villages) do
            if (not village.grab_only) then
                n_villages = n_villages + 1
            end
        end

        local n_units = math.ceil(n_villages / villages_per_unit)
        units_needed_villages[zone_id] = n_units
    end

    local units_assigned_villages = {}
    local used_ids = {}
    for zone_id,units in pairs(assigned_units) do
        for id,_ in pairs(units) do
            units_assigned_villages[zone_id] = (units_assigned_villages[zone_id] or 0) + 1
            used_ids[id] = true
        end
    end

    -- Check out what other units to send in this direction
    local scouts = {}
    for zone_id,villages in pairs(zone_village_goals) do
        if (units_needed_villages[zone_id] > (units_assigned_villages[zone_id] or 0)) then
            --std_print(zone_id)
            scouts[zone_id] = {}
            for _,village in ipairs(villages) do
                if (not village.grab_only) then
                    --std_print('  ' .. village.x, village.y)
                    for id,loc in pairs(move_data.my_units) do
                        -- The leader is always excluded here, plus any unit that has already been assigned
                        -- TODO: set up an array of unassigned units?
                        if (not move_data.unit_infos[id].canrecruit) and (not used_ids[id]) then
                            local _, cost = wesnoth.find_path(move_data.unit_copies[id], village.x, village.y)
                            cost = cost + move_data.unit_infos[id].max_moves - move_data.unit_infos[id].moves
                            --std_print('    ' .. id, cost)
                            local _, cost_ign = wesnoth.find_path(move_data.unit_copies[id], village.x, village.y, { ignore_units = true })
                            cost_ign = cost_ign + move_data.unit_infos[id].max_moves - move_data.unit_infos[id].moves

                            local unit_rating = - cost / #villages / move_data.unit_infos[id].max_moves

                            -- Scout utility to compare to retreat utility
                            local int_turns = math.ceil(cost / move_data.unit_infos[id].max_moves)
                            local int_turns_ign = math.ceil(cost_ign / move_data.unit_infos[id].max_moves)
                            local scout_utility = math.sqrt(1 / math.max(1, int_turns - 1))
                            scout_utility = scout_utility * int_turns_ign / int_turns

                            if scouts[zone_id][id] then
                                unit_rating = unit_rating + scouts[zone_id][id].rating
                            end
                            scouts[zone_id][id] = { rating = unit_rating }

                            if (not scouts[zone_id][id].utility) or (scout_utiltiy > scouts[zone_id][id].utility) then
                                scouts[zone_id][id].utility = scout_utility
                            end
                        end
                    end
                end
            end
        end
    end

    local sorted_scouts = {}
    for zone_id,units in pairs(scouts) do
        for id,data in pairs(units) do
            if (data.utility > retreat_utilities[id]) then
                if (not sorted_scouts[zone_id]) then
                    sorted_scouts[zone_id] = {}
                end

                table.insert(sorted_scouts[zone_id], {
                    id = id,
                    rating = data.rating,
                    org_rating = data.rating
                })
            else
                --std_print('needs to retreat instead:', id)
            end
        end
        if sorted_scouts[zone_id] then
            table.sort(sorted_scouts[zone_id], function(a, b) return a.rating > b.rating end)
        end
    end

    local keep_trying = true
    local zone_id,units = next(sorted_scouts)
    if (not zone_id) or (#units == 0) then
        keep_trying = false
    end

    while keep_trying do
        keep_trying = false

        -- Set rating relative to the second highest rating in each zone
        -- This is
        --
        -- Notes:
        --  - If only one units is left, we use the original rating
        --  - This is unnecessary when only one zone is left, but it works then too,
        --    so we'll just keep it rather than adding yet another conditional
        for zone_id,units in pairs(sorted_scouts) do
            if (#units > 1) then
                local second_rating = units[2].rating
                for _,scout in pairs(units) do
                    scout.rating = scout.rating - second_rating
                end
            else
                units[1].rating = units[1].org_rating
            end
        end

        local max_rating, best_id, best_zone
        for zone_id,units in pairs(sorted_scouts) do
            local rating = sorted_scouts[zone_id][1].rating

            if (not max_rating) or (rating > max_rating) then
                max_rating = rating
                best_id = sorted_scouts[zone_id][1].id
                best_zone = zone_id
            end
        end
        --std_print('best:', best_zone, best_id)

        for zone_id,units in pairs(sorted_scouts) do
            for i_u,data in ipairs(units) do
                if (data.id == best_id) then
                    table.remove(units, i_u)
                    break
                end
            end
        end
        for zone_id,units in pairs(sorted_scouts) do
            if (#units == 0) then
                sorted_scouts[zone_id] = nil
            end
        end

        if (not assigned_units[best_zone]) then
            assigned_units[best_zone] = {}
        end
        assigned_units[best_zone][best_id] = move_data.units[best_id]

        units_assigned_villages[best_zone] = (units_assigned_villages[best_zone] or 0) + 1

        for zone_id,n_needed in pairs(units_needed_villages) do
            if (n_needed <= (units_assigned_villages[zone_id] or 0)) then
                sorted_scouts[zone_id] = nil
            end
        end

        -- Check whether we are done
        local zone_id,units = next(sorted_scouts)
        if zone_id and (#units > 0) then
            keep_trying = true
        end
    end
end


return fred_village_utils
			

		 >>
		[/lua]
	[/event]
#enddef

#define LUA_RELOAD_MENU
	[event]
        name=preload
        first_time_only=no
		[lua]
			code = << 
			
local H = wesnoth.require "helper"
local W = H.set_wml_action_metatable {}
local LS = wesnoth.require "location_set"
local F = wesnoth.require "functional"
local M = wesnoth.map

local ai_helper = {}

----- Debugging helper functions ------

function ai_helper.get_unit_time_of_day_bonus(alignment, lawful_bonus)
    local multiplier = 1
    if (lawful_bonus ~= 0) then
        if (alignment == 'lawful') then
            multiplier = (1 + lawful_bonus / 100.)
        elseif (alignment == 'chaotic') then
            multiplier = (1 - lawful_bonus / 100.)
        elseif (alignment == 'liminal') then
            multipler = (1 - math.abs(lawful_bonus) / 100.)
        end
    end
    return multiplier
end

return ai_helper


		 >>
		[/lua]
	[/event]
#enddef

#define SECOND_ALIGNMENT_CONFIG
	[event]
        name=preload
        first_time_only=no
		id=second_alignment_config_CA
		[lua]
			code = << 
-- AI configuration parameters

-- Note: Assigning this table is slow compared to accessing values in it. It is
-- thus done outside the functions below, so that it is not done over and over
-- for each function call.
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account


    ----- Do not change values below unless you know exactly what you are doing -----

    -- Unit value parameters
    xp_weight = 1.0,
    leader_weight = 1.5,
    leader_derating = 0.5,

    influence_falloff_floor = 0.5,
    influence_falloff_exp = 2,

    winning_ratio = 1.25,
    losing_ratio = 0.8,

    -- Village grabbing parameters
    villages_per_unit = 2,

    -- Attack rating parameters
    terrain_defense_weight = 0.1,
    distance_leader_weight = 0.002,
    occupied_hex_penalty = 0.001,
    leader_max_die_chance = 0.02,

    -- Hold rating parameters
    vuln_weight = 0.25,
    forward_weight = 0.02,
    hold_counter_weight = 0.1,
    protect_forward_weight = 1,

    -- Retreat rating parameters
    hp_inflection_base = 20
}
		>>
		[/lua]
	[/event]
#enddef

#define SECOND_ALIGNMENT_FACTION
	[event]
        name=preload
        first_time_only=no
		[lua]
			code = << 
			
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local W = H.set_wml_action_metatable {}
local LS = wesnoth.require "location_set"
local F = wesnoth.require "functional"
local M = wesnoth.map

		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Mage_Mystic') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}


		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Drake_Fighter') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Dune_Soldier') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		
		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Farmer_Halfling') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		
		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Dwarvish_Fighter') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		
		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Loyalist_Heavy_Infantryman') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}


		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Orcish_Grunt') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		
		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Drake_Apprentice') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		
		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Elvish_Shaman') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		
		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Saurian_Armorer') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		-- Separate LUA, Faction is checked by seeing if the side can recruit orcs
        local can_recruit_grunts = false
        for i,r in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            if (r == 'HF_Necro_Dark_Adept') then
                can_recruit_grunts = true
                break
            end
        end
		
local cfg = {
    ----- Parameters in this section are meant to be adjustable for faction, scenario, ... -----

    aggression = 1.5,                  -- To first order, base ratio of acceptable damage: own / enemy
    min_aggression = 1.25,
    next_turn_influence_weight = 1,  -- Fraction of ToD influence change of next turn to take into account
}

		 >>
		[/lua]
	[/event]
#enddef

#define SECOND_ALIGNMENT_HELPER
	[event]
        name=preload
        first_time_only=no
		[lua]
			code = << 
			
local AH = wesnoth.require "ai/lua/ai_helper.lua"
local H = wesnoth.require "helper"
local W = H.set_wml_action_metatable {}
local LS = wesnoth.require "location_set"
local F = wesnoth.require "functional"
local M = wesnoth.map
local H = wesnoth.require "helper"

local ai_helper = {}

function ai_helper.get_attackable_enemies(filter, side, cfg)
    -- Attackable enemies are defined as being being
    --   - enemies of the side defined in @side,
    --   - not petrified
    --   - and visible to the side defined in @cfg.viewing_side.
    -- For speed reasons, this is done separately, rather than calling ai_helper.get_visible_units().
    --
    -- Optional parameters:
    -- @filter: Standard unit filter WML table for the enemies
    --   Example 1: { type = 'Orcish Grunt' }
    --   Example 2: { { "filter_location", { x = 10, y = 12, radius = 5 } } }
    -- @side: side number, if side other than current side is to be considered
    -- @cfg: table with optional configuration parameters:
    --   viewing_side: see comments at beginning of this file. Defaults to @side.

    side = side or wesnoth.current.side
    local viewing_side = cfg and cfg.viewing_side or side

    local filter_plus_vision = {}
    if filter then filter_plus_vision = ai_helper.table_copy(filter) end
    if wesnoth.sides[viewing_side] then
        table.insert(filter_plus_vision, { "filter_vision", { side = viewing_side, visible = 'yes' } })
    end

    local enemies = {}
    local all_units = wesnoth.get_units()
    for _,unit in ipairs(all_units) do
        if wesnoth.is_enemy(side, unit.side)
           and (not unit.status.petrified)
           and unit:matches(filter_plus_vision)
        then
            table.insert(enemies, unit)
        end
    end

    return enemies
end

function ai_helper.has_ability(unit, ability)
    -- Returns true/false depending on whether unit has the given ability
    local has_ability = false
    local abilities = wml.get_child(unit.__cfg, "abilities")
    if abilities then
        if wml.get_child(abilities, ability) then has_ability = true end
    end
    return has_ability
end

function ai_helper.has_weapon_special(unit, special)
    -- Returns true/false depending on whether @unit has a weapon with special @special
    -- Also returns the number of the first weapon with this special
    for weapon_number,att in ipairs(unit.attacks) do
        for _,sp in ipairs(att.specials) do
            if (sp[1] == special) then
                return true, weapon_number
            end
        end
    end
    return false
end

function ai_helper.robust_move_and_attack(ai, src, dst, target_loc, cfg)
    -- Perform a move and/or attack with an AI unit in a way that is robust against
    -- unexpected outcomes such as being ambushed or changes caused by WML events.
    -- As much as possible, this function also tries to ensure that the gamestate
    -- is changed in case an action turns out to be impossible due to such an
    -- unexpected outcome.
    --
    -- Required input parameters:
    -- @ai: the Lua ai table
    -- @src: current coordinates of the AI unit to be used
    -- @dst: coordinates to which the unit should move. This does not have to be
    --   different from @src. In fact, the unit does not even need to have moves
    --   left, as long as an attack is specified in the latter case. If another
    --   AI unit is at @dst, it is moved out of the way.
    --
    -- Optional parameters:
    -- @target_loc: coordinates of the enemy unit to be attacked. If not given, no
    --   attack is attempted.
    -- @cfg: table with optional configuration parameters:
    --   partial_move: By default, this function performs full moves. If this
    --     parameter is true, a partial move is done instead.
    --   weapon: The number (starting at 1) of the attack weapon to be used.
    --     If omitted, the best weapon is automatically selected.
    --   all optional parameters for ai_helper.move_unit_out_of_way()

    -- Notes:
    -- - @src, @dst and @target_loc can be any table (including proxy units) that contains
    --   the coordinates of the respective locations using either indices .x/.y or [1]/[2].
    --   If both are given, .x/.y takes precedence over [1]/[2].
    -- - This function only safeguards AI moves against outcomes that the AI cannot know
    --   about, such as hidden units and WML events. It is assumed that the potential
    --   move was tested for general feasibility (units are on AI side and have moves
    --   left, terrain is passable, etc.) beforehand. If that is not done, it might
    --   lead to very undesirable behavior, incl. the CA being blacklisted or even the
    --   entire AI turn being ended.

    local src_x, src_y = src.x or src[1], src.y or src[2] -- this works with units or locations
    local dst_x, dst_y = dst.x or dst[1], dst.y or dst[2]

    local unit = wesnoth.get_unit(src_x, src_y)
    if (not unit) then
        return ai_helper.dummy_check_action(false, false, 'robust_move_and_attack::NO_UNIT')
    end

    -- Getting target at beginning also, in case events mess up things along the way
    local target, target_x, target_y
    if target_loc then
        target_x, target_y = target_loc.x or target_loc[1], target_loc.y or target_loc[2]
        target = wesnoth.get_unit(target_x, target_y)

        if (not target) then
            return ai_helper.dummy_check_action(false, false, 'robust_move_and_attack::NO_TARGET')
        end
    end

    local gamestate_changed = false
    local move_result = ai_helper.dummy_check_action(false, false, 'robust_move_and_attack::NO_ACTION')
    if (unit.moves > 0) then
        if (src_x == dst_x) and (src_y == dst_y) then
            move_result = ai.stopunit_moves(unit)

            -- The only possible failure modes are non-recoverable (such as E_NOT_OWN_UNIT)
            if (not move_result.ok) then return move_result end

            if (not unit) or (not unit.valid) then
                return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNIT_DISAPPEARED')
            end

            gamestate_changed = true
        else
            local unit_old_moves = unit.moves

            local unit_in_way = wesnoth.get_unit(dst_x, dst_y)
            if unit_in_way and (unit_in_way.side == wesnoth.current.side) and (unit_in_way.moves > 0) then
                local uiw_old_moves = unit_in_way.moves
                ai_helper.move_unit_out_of_way(ai, unit_in_way, cfg)

                if (not unit_in_way) or (not unit_in_way.valid) then
                    return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNIT_IN_WAY_DISAPPEARED')
                end

                -- Failed move out of way: abandon remaining actions
                if (unit_in_way.x == dst_x) and (unit_in_way.y == dst_y) then
                    if (unit_in_way.moves == uiw_old_moves) then
                        -- Forcing a gamestate change, if necessary
                        ai.stopunit_moves(unit_in_way)
                    end
                    return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNIT_IN_WAY_EMPTY_MOVE')
                end

                -- Check whether dst hex is free now (an event could have done something funny)
                local unit_in_way = wesnoth.get_unit(dst_x, dst_y)
                if unit_in_way then
                    return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::ANOTHER_UNIT_IN_WAY')
                end

                gamestate_changed = true
            end

            if (not unit) or (not unit.valid) or (unit.x ~= src_x) or (unit.y ~= src_y) then
                return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNIT_DISAPPEARED')
            end

            local check_result = ai.check_move(unit, dst_x, dst_y)
            if (not check_result.ok) then
                if (not ai_helper.is_incomplete_or_empty_move(check_result)) then
                    if (not gamestate_changed) then
                        ai.stopunit_moves(unit)
                    end
                    return check_result
                end
            end

            if cfg and cfg.partial_move then
                move_result = ai.move(unit, dst_x, dst_y)
            else
                move_result = ai.move_full(unit, dst_x, dst_y)
            end
            if (not move_result.ok) then return move_result end

            if (not unit) or (not unit.valid) then
                return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNIT_DISAPPEARED')
            end

            -- Failed move: abandon rest of actions
            if (unit.x == src_x) and (unit.y == src_y) then
                if (not gamestate_changed) and (unit.moves == unit_old_moves) then
                    -- Forcing a gamestate change, if necessary
                    ai.stopunit_moves(unit)
                end
                return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNPLANNED_EMPTY_MOVE')
            end

            gamestate_changed = true
        end
    end

    -- Tests after the move, before continuing to attack, to ensure WML events
    -- did not do something funny
    if (not unit) or (not unit.valid) then
        return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNIT_DISAPPEARED')
    end
    if (unit.x ~= dst_x) or (unit.y ~= dst_y) then
        return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNIT_NOT_AT_DESTINATION')
    end

    -- In case all went well and there's no attack to be done
    if (not target_x) then return move_result end

    if (not target) or (not target.valid) then
        return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::TARGET_DISAPPEARED')
    end
    if (target.x ~= target_x) or (target.y ~= target_y) then
        return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::TARGET_MOVED')
    end

    local weapon = cfg and cfg.weapon
    local old_attacks_left = unit.attacks_left

    local check_result = ai.check_attack(unit, target, weapon)
    if (not check_result.ok) then
        if (not gamestate_changed) then
            ai.stopunit_all(unit)
        end
        return check_result
    end

    move_result = ai.attack(unit, target, weapon)
    -- This should not happen, given that we just checked, but just in case
    if (not move_result.ok) then return move_result end

    if (not unit) or (not unit.valid) then
        return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::UNIT_DISAPPEARED')
    end

    if (unit.attacks_left == old_attacks_left) and (not gamestate_changed) then
        ai.stopunit_all(unit)
        return ai_helper.dummy_check_action(true, false, 'robust_move_and_attack::NO_ATTACK')
    end

    return move_result
end

return ai_helper
		 >>
		[/lua]
	[/event]
#enddef
			
#define SECOND_ALIGNMENT_RECRUIT
	[event]
        name=preload
        first_time_only=no
		id=second_alignment_recruit_CA
		[lua]
			code = << 
return {
    -- init parameters:
    -- ai: a reference to the ai engine so recruit has access to ai functions
    --   It is also possible to pass an ai table directly to the execution function, which will then override the value passed here
    -- ai_cas: an object reference to store the CAs and associated data
    --   the CA will use the function names ai_cas:recruit_rushers_eval/exec, so should be referenced by the object name used by the calling AI
    --   ai_cas also has the functions find_best_recruit, find_best_recruit_hex, prerecruit_units and analyze_enemy_unit added to it
    --     find_best_recruit, find_best_recruit_hex may be useful for writing recruitment code separately from the engine
    -- params: parameters to configure recruitment
    --      score_function: function that returns the CA score when recruit_rushers_eval wants to recruit
    --          (default returns the Default AI recruitment score)
    --      randomness: a measure of randomness in recruitment
    --          higher absolute values increase randomness, with values above about 3 being close to completely random
    --          (default = 0.1)
    --      min_turn_1_recruit: function that returns true if only enough units to grab nearby villages should be recruited turn 1, false otherwise
    --          (default always returns false)
    --      leader_takes_village: function that returns true if and only if the leader is going to move to capture a village this turn
    --          (default always returns true)
    -- params to eval/exec functions:
    --      avoid_map: location set listing hexes on which we should
    --          not recruit, unless no other hexes are available
    --      outofway_units: a table of type { id = true } listing units that
    --          can move out of the way to make place for recruiting. It
    --          must be checked beforehand that these units are able to move,
    --          away. This is not done here.

    init = function(ai, ai_cas, params)
        if not params then
            params = {}
        end
        math.randomseed(os.time())

        local AH = wesnoth.require "ai/lua/ai_helper.lua"
        local DBG = wesnoth.require "ai/lua/debug.lua"
        local LS = wesnoth.require "location_set"

        local function print_time(...)
            if turn_start_time then
                AH.print_ts_delta(turn_start_time, ...)
            else
                AH.print_ts(...)
            end
        end

        local recruit_data = {}

        local no_village_cost = function(recruit_id)
            return wesnoth.unit_types[recruit_id].cost+wesnoth.unit_types[recruit_id].level+wesnoth.sides[wesnoth.current.side].village_gold
        end

        local get_hp_efficiency = function (table, recruit_id)
            -- raw durability is a function of hp and the regenerates ability
            -- efficiency decreases faster than cost increases to avoid recruiting many expensive units
            -- there is a requirement for bodies in order to block movement

            -- There is currently an assumption that opponents will average about 15 damage per strike
            -- and that two units will attack per turn until the unit dies to estimate the number of hp
            -- gained from regeneration
            local effective_hp = wesnoth.unit_types[recruit_id].max_hitpoints

            local unit = wesnoth.create_unit {
                type = recruit_id,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            -- Find the best regeneration ability and use it to estimate hp regained by regeneration
            local abilities = wml.get_child(unit.__cfg, "abilities")
            local regen_amount = 0
            if abilities then
                for regen in wml.child_range(abilities, "regenerate") do
                    if regen.value > regen_amount then
                        regen_amount = regen.value
                    end
                end
                effective_hp = effective_hp + (regen_amount * effective_hp/30)
            end
            local hp_score = math.max(math.log(effective_hp/20),0.01)
            local efficiency = hp_score/(wesnoth.unit_types[recruit_id].cost^2)
            local no_village_efficiency = hp_score/(no_village_cost(recruit_id)^2)

            table[recruit_id] = {efficiency, no_village_efficiency}
            return {efficiency, no_village_efficiency}
        end
        local efficiency = {}
        setmetatable(efficiency, { __index = get_hp_efficiency })

        function poisonable(unit)
            return not unit.status.unpoisonable
        end

        function drainable(unit)
            return not unit.status.undrainable
        end

        function get_best_defense(unit)
            local terrain_archetypes = { "Wo", "Ww", "Wwr", "Ss", "Gt", "Ds", "Ft", "Hh", "Mm", "Vi", "Ch", "Uu", "At", "Qt", "^Uf", "Xt" }
            local best_defense = 100

            for i, terrain in ipairs(terrain_archetypes) do
                local defense = wesnoth.unit_defense(unit, terrain)
                if defense < best_defense then
                    best_defense = defense
                end
            end

            return best_defense
        end

        function analyze_enemy_unit(enemy_type, ally_type)
            local function get_best_attack(attacker, defender, defender_defense, attacker_defense, can_poison)
                -- Try to find the average damage for each possible attack and return the one that deals the most damage.
                -- Would be preferable to call simulate combat, but that requires the defender to be on the map according
                -- to documentation and we are looking for hypothetical situations so would have to search for available
                -- locations for the defender that would have the desired defense. We would also need to remove nearby units
                -- in order to ensure that adjacent units are not modifying the result. In addition, the time of day is
                -- assumed to be neutral here, which is not assured in the simulation.
                -- Ideally, this function would be a clone of simulate combat, but run for each time of day in the scenario and on arbitrary terrain.
                -- In several cases this function only approximates the correct value (eg Thunderguard vs Goblin Spearman has damage capped by target health)
                -- In some cases (like poison), this approximation is preferred to the actual value.
                local best_damage = 0
                local best_attack = nil
                local best_poison_damage = 0
                -- Steadfast is currently disabled because it biases the AI too much in favour of Guardsmen
                -- Basically it sees the defender stats for damage and wrongfully concludes that the unit is amazing
                -- This may be rectifiable by looking at retaliation damage as well.
                local steadfast = false

                for attack in wml.child_range(wesnoth.unit_types[attacker.type].__cfg, "attack") do
                    local defense = defender_defense
                    local poison = false
                    local damage_multiplier = 1
                    local damage_bonus = 0
                    local weapon_damage = attack.damage

                    for special in wml.child_range(attack, 'specials') do
                        local mod
                        if wml.get_child(special, 'poison') and can_poison then
                            poison = true
                        end

                        -- Handle marksman and magical
                        mod = wml.get_child(special, 'chance_to_hit')
                        if mod then
                            if mod.value then
                                if mod.cumulative then
                                    if mod.value > defense then
                                        defense = mod.value
                                    end
                                else
                                    defense = mod.value
                                end
                            elseif mod.add then
                                defense = defense + mod.add
                            elseif mod.sub then
                                defense = defense - mod.sub
                            elseif mod.multiply then
                                defense = defense * mod.multiply
                            elseif mod.divide then
                                defense = defense / mod.divide
                            end
                        end
						
                       -- Handle magical clear
                        mod = wml.get_child(special, 'HF_magical_clear')
                        if mod then
                            if mod.value then
                                if mod.cumulative then
                                    if mod.value > defense then
                                        defense = mod.value
                                    end
                                else
                                    defense = mod.value
                                end
                            elseif mod.add then
                                defense = defense + mod.add
                            elseif mod.sub then
                                defense = defense - mod.sub
                            elseif mod.multiply then
                                defense = defense * mod.multiply
                            elseif mod.divide then
                                defense = defense / mod.divide
                            end
                        end
						
                       -- Handle magical ice
                        mod = wml.get_child(special, 'HF_magical_ice')
                        if mod then
                            if mod.value then
                                if mod.cumulative then
                                    if mod.value > defense then
                                        defense = mod.value
                                    end
                                else
                                    defense = mod.value
                                end
                            elseif mod.add then
                                defense = defense + mod.add
                            elseif mod.sub then
                                defense = defense - mod.sub
                            elseif mod.multiply then
                                defense = defense * mod.multiply
                            elseif mod.divide then
                                defense = defense / mod.divide
                            end
                        end	
						
                        -- Handle magical fire
                        mod = wml.get_child(special, 'HF_magical_fire')
                        if mod then
                            if mod.value then
                                if mod.cumulative then
                                    if mod.value > defense then
                                        defense = mod.value
                                    end
                                else
                                    defense = mod.value
                                end
                            elseif mod.add then
                                defense = defense + mod.add
                            elseif mod.sub then
                                defense = defense - mod.sub
                            elseif mod.multiply then
                                defense = defense * mod.multiply
                            elseif mod.divide then
                                defense = defense / mod.divide
                            end
                        end		
						
                        -- Handle most damage specials (assumes all are cumulative)
                        mod = wml.get_child(special, 'damage')
                        if mod and mod.active_on ~= "defense" then
                            local special_multiplier = 1
                            local special_bonus = 0

                            if mod.multiply then
                                special_multiplier = special_multiplier*mod.multiply
                            end
                            if mod.divide then
                                special_multiplier = special_multiplier/mod.divide
                            end
                            if mod.add then
                                special_bonus = special_bonus+mod.add
                            end
                            if mod.subtract then
                                special_bonus = special_bonus-mod.subtract
                            end

                            if mod.backstab then
                                -- Assume backstab happens on only 1/2 of attacks
                                -- TODO: find out what actual probability of getting to backstab is
                                damage_multiplier = damage_multiplier*(special_multiplier*0.5 + 0.5)
                                damage_bonus = damage_bonus+(special_bonus*0.5)
                                if mod.value ~= nil then
                                    weapon_damage = (weapon_damage+mod.value)/2
                                end
                            else
                                damage_multiplier = damage_multiplier*special_multiplier
                                damage_bonus = damage_bonus+special_bonus
                                if mod.value ~= nil then
                                    weapon_damage = mod.value
                                end
                            end
                        end
                    end

                    -- Handle drain for defender
                    local drain_recovery = 0
                    for defender_attack in wml.child_range(defender.__cfg, 'attack') do
                        if (defender_attack.range == attack.range) then
                            for special in wml.child_range(defender_attack, 'specials') do
                                if wml.get_child(special, 'drains') and drainable(attacker) then
                                    -- TODO: calculate chance to hit
                                    -- currently assumes 50% chance to hit using supplied constant
                                    local attacker_resistance = wesnoth.unit_resistance(attacker, defender_attack.type)
                                    drain_recovery = (defender_attack.damage*defender_attack.number*attacker_resistance*attacker_defense/2)/10000
                                end
                            end
                        end
                    end

                    defense = defense/100.0
                    local resistance = wesnoth.unit_resistance(defender, attack.type)
                    if steadfast and (resistance < 100) then
                        resistance = 100 - ((100 - resistance) * 2)
                        if (resistance < 50) then
                            resistance = 50
                        end
                    end
                    local base_damage = (weapon_damage+damage_bonus)*resistance*damage_multiplier
                    if (resistance > 100) then
                        base_damage = base_damage-1
                    end
                    base_damage = math.floor(base_damage/100 + 0.5)
                    if (base_damage < 1) and (attack.damage > 0) then
                        -- Damage is always at least 1
                        base_damage = 1
                    end
                    local attack_damage = base_damage*attack.number*defense-drain_recovery

                    local poison_damage = 0
                    if poison then
                        -- Add poison damage * probability of poisoning
                        poison_damage = 8*(1-((1-defense)^attack.number))
                    end

                    if (not best_attack) or (attack_damage+poison_damage > best_damage+best_poison_damage) then
                        best_damage = attack_damage
                        best_poison_damage = poison_damage
                        best_attack = attack
                    end
                end

                return best_attack, best_damage, best_poison_damage
            end

            -- Use cached information when possible: this is expensive
            local analysis = {}
            if not recruit_data.analyses then
                recruit_data.analyses = {}
            else
                if recruit_data.analyses[enemy_type] then
                    analysis = recruit_data.analyses[enemy_type] or {}
                end
            end
            if analysis[ally_type] then
                return analysis[ally_type]
            end

            local unit = wesnoth.create_unit {
                type = enemy_type,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            local can_poison = poisonable(unit) and (not wesnoth.unit_ability(unit, 'regenerate'))
            local flat_defense = wesnoth.unit_defense(unit, "Gt")
            local best_defense = get_best_defense(unit)

            local recruit = wesnoth.create_unit {
                type = ally_type,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            local recruit_flat_defense = wesnoth.unit_defense(recruit, "Gt")
            local recruit_best_defense = get_best_defense(recruit)

            local can_poison_retaliation = poisonable(recruit) and (not wesnoth.unit_ability(recruit, 'regenerate'))
            best_flat_attack, best_flat_damage, flat_poison = get_best_attack(recruit, unit, flat_defense, recruit_best_defense, can_poison)
            best_high_defense_attack, best_high_defense_damage, high_defense_poison = get_best_attack(recruit, unit, best_defense, recruit_flat_defense, can_poison)
            best_retaliation, best_retaliation_damage, retaliation_poison = get_best_attack(unit, recruit, recruit_flat_defense, best_defense, can_poison_retaliation)

            local result = {
                offense = { attack = best_flat_attack, damage = best_flat_damage, poison_damage = flat_poison },
                defense = { attack = best_high_defense_attack, damage = best_high_defense_damage, poison_damage = high_defense_poison },
                retaliation = { attack = best_retaliation, damage = best_retaliation_damage, poison_damage = retaliation_poison }
            }
            analysis[ally_type] = result

            -- Cache result before returning
            recruit_data.analyses[enemy_type] = analysis
            return analysis[ally_type]
        end

        function can_slow(unit)
            for defender_attack in wml.child_range(unit.__cfg, 'attack') do
                for special in wml.child_range(defender_attack, 'specials') do
                    if wml.get_child(special, 'slow') then
                        return true
                    end
                end
            end
            return false
        end

        function get_hp_ratio_with_gold()
            function sum_gold_for_sides(side_filter)
                -- sum positive amounts of gold for a set of sides
                -- positive only because it is used to estimate the number of enemy units that could appear
                -- and negative numbers shouldn't subtract from the number of units on the map
                local gold = 0
                local sides = wesnoth.get_sides(side_filter)
                for i,s in ipairs(sides) do
                    if s.gold > 0 then
                        gold = gold + s.gold
                    end
                end

                return gold
            end

            -- Hitpoint ratio of own units / enemy units
            -- Also convert available gold to a hp estimate
            my_units = AH.get_live_units {
                { "filter_side", {{"allied_with", {side = wesnoth.current.side} }} }
            }
            enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            local my_hp, enemy_hp = 0, 0
            for i,u in ipairs(my_units) do my_hp = my_hp + u.hitpoints end
            for i,u in ipairs(enemies) do enemy_hp = enemy_hp + u.hitpoints end

            my_hp = my_hp + sum_gold_for_sides({{"allied_with", {side = wesnoth.current.side} }})*2.3
            enemy_hp = enemy_hp+sum_gold_for_sides({{"enemy_of", {side = wesnoth.current.side} }})*2.3
            hp_ratio = my_hp/(enemy_hp + 1e-6)

            return hp_ratio
        end

        function do_recruit_eval(data, outofway_units)
            outofway_units = outofway_units or {}

            -- Check if leader exists
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            if not leader then
                return 0
            end

            -- Check if there is enough gold to recruit a unit
            local cheapest_unit_cost = AH.get_cheapest_recruit_cost()
            local current_gold = wesnoth.sides[wesnoth.current.side].gold
            if cheapest_unit_cost > current_gold then
                return 0
            end

            -- Minimum requirements satisfied, init recruit data if needed for more complex evaluations
            if data.recruit == nil then
                data.recruit = init_data()
            end
            get_current_castle(leader, data)

            -- Do not recruit now if we want to recruit elsewhere unless
            -- a) there is a nearby village recruiting would let us capture, or
            -- b) we have enough gold to recruit at both locations
            -- c) we are now at the other location
            local village_target_available = get_village_target(leader, data)[1]
            if (not village_target_available) and
               (cheapest_unit_cost > current_gold - data.recruit.prerecruit.total_cost) and
               (leader.x ~= data.recruit.prerecruit.loc[1] or leader.y ~= data.recruit.prerecruit.loc[2]) then
                return 1
            end

            local cant_recruit_at_location_score = 0
            if data.recruit.prerecruit.total_cost > 0 then
                cant_recruit_at_location_score = 1
            end

            if not wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep then
                return cant_recruit_at_location_score
            end

            -- Check for space to recruit a unit
            local no_space = true
            for i,c in ipairs(data.castle.locs) do
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) or (outofway_units[unit.id] and (not unit.canrecruit)) then
                    no_space = false
                    break
                end
            end
            if no_space then
                return cant_recruit_at_location_score
            end

            -- Check for minimal recruit option
            if wesnoth.current.turn == 1 and params.min_turn_1_recruit and params.min_turn_1_recruit() then
                if not village_target_available then
                    return cant_recruit_at_location_score
                end
            end

            local score = 180000 -- default score if one not provided. Same as Default AI
            if params.score_function then
                score = params.score_function()
            end
            return score
        end

        function init_data()
            local data = {}

            -- Count enemies of each type
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }}}
            }
            local enemy_counts = {}
            local enemy_types = {}
            local possible_enemy_recruit_count = 0

            local function add_unit_type(unit_type)
                if enemy_counts[unit_type] == nil then
                    table.insert(enemy_types, unit_type)
                    enemy_counts[unit_type] = 1
                else
                    enemy_counts[unit_type] = enemy_counts[unit_type] + 1
                end
            end

            -- Collect all enemies on map
            for i, unit in ipairs(enemies) do
                add_unit_type(unit.type)
            end
            -- Collect all possible enemy recruits and count them as virtual enemies
            local enemy_sides = wesnoth.get_sides({
                { "enemy_of", {side = wesnoth.current.side} },
                { "has_unit", { canrecruit = true }} })
            for i, side in ipairs(enemy_sides) do
                possible_enemy_recruit_count = possible_enemy_recruit_count + #(wesnoth.sides[side.side].recruit)
                for j, unit_type in ipairs(wesnoth.sides[side.side].recruit) do
                    add_unit_type(unit_type)
                end
            end
            data.enemy_counts = enemy_counts
            data.enemy_types = enemy_types
            data.num_enemies = #enemies
            data.possible_enemy_recruit_count = possible_enemy_recruit_count
            data.cheapest_unit_cost = AH.get_cheapest_recruit_cost()

            data.prerecruit = {
                total_cost = 0,
                units = {}
            }

            return data
        end

        function ai_cas:recruit_rushers_eval(outofway_units)
            local start_time, ca_name = wesnoth.get_time_stamp() / 1000., 'recruit_rushers'
            if AH.print_eval() then print_time('     - Evaluating recruit_rushers CA:') end

            local score = do_recruit_eval(recruit_data, outofway_units)
            if score == 0 then
                -- We're done for the turn, discard data
                recruit_data.recruit = nil
            end

            if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
            return score
        end

        -- Select a unit and hex to recruit to.
        function select_recruit(leader, avoid_map, outofway_units)
            local enemy_counts = recruit_data.recruit.enemy_counts
            local enemy_types = recruit_data.recruit.enemy_types
            local num_enemies =  recruit_data.recruit.num_enemies
            local hp_ratio = get_hp_ratio_with_gold()

            -- Determine effectiveness of recruitable units against each enemy unit type
            local recruit_effectiveness = {}
            local recruit_vulnerability = {}
            local attack_type_count = {} -- The number of units who will likely use a given attack type
            local attack_range_count = {} -- The number of units who will likely use a given attack range
            local unit_attack_type_count = {} -- The attack types a unit will use
            local unit_attack_range_count = {} -- The ranges a unit will use
            local enemy_type_count = 0
            local poisoner_count = 0.1 -- Number of units with a poison attack (set to slightly > 0 because we divide by it later)
            local poisonable_count = 0 -- Number of units that the opponents control that are hurt by poison
            local recruit_count = {}
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                recruit_count[recruit_id] = #(AH.get_live_units { side = wesnoth.current.side, type = recruit_id, canrecruit = 'no' })
            end
            -- Count prerecruited units as recruited
            for i, prerecruited in ipairs(recruit_data.recruit.prerecruit.units) do
                recruit_count[prerecruited.recruit_type] = recruit_count[prerecruited.recruit_type] + 1
            end

            for i, unit_type in ipairs(enemy_types) do
                enemy_type_count = enemy_type_count + 1
                local poison_vulnerable = false
                for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                    local analysis = analyze_enemy_unit(unit_type, recruit_id)

                    if recruit_effectiveness[recruit_id] == nil then
                        recruit_effectiveness[recruit_id] = {damage = 0, poison_damage = 0}
                        recruit_vulnerability[recruit_id] = 0
                    end

                    recruit_effectiveness[recruit_id].damage = recruit_effectiveness[recruit_id].damage + analysis.defense.damage * enemy_counts[unit_type]^2
                    if analysis.defense.poison_damage and analysis.defense.poison_damage > 0 then
                        poison_vulnerable = true
                        recruit_effectiveness[recruit_id].poison_damage = recruit_effectiveness[recruit_id].poison_damage +
                            analysis.defense.poison_damage * enemy_counts[unit_type]^2
                    end
                    recruit_vulnerability[recruit_id] = recruit_vulnerability[recruit_id] + (analysis.retaliation.damage * enemy_counts[unit_type])^3

                    local attack_type = analysis.defense.attack.type
                    if attack_type_count[attack_type] == nil then
                        attack_type_count[attack_type] = 0
                    end
                    attack_type_count[attack_type] = attack_type_count[attack_type] + recruit_count[recruit_id]

                    local attack_range = analysis.defense.attack.range
                    if attack_range_count[attack_range] == nil then
                        attack_range_count[attack_range] = 0
                    end
                    attack_range_count[attack_range] = attack_range_count[attack_range] + recruit_count[recruit_id]

                    if unit_attack_type_count[recruit_id] == nil then
                        unit_attack_type_count[recruit_id] = {}
                    end
                    unit_attack_type_count[recruit_id][attack_type] = true

                    if unit_attack_range_count[recruit_id] == nil then
                        unit_attack_range_count[recruit_id] = {}
                    end
                    unit_attack_range_count[recruit_id][attack_range] = true
                end
                if poison_vulnerable then
                    poisonable_count = poisonable_count + enemy_counts[unit_type]
                end
            end
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                -- Count the number of units with the poison ability
                -- This could be wrong if all the units on the enemy side are immune to poison, but since poison has no effect then anyway it doesn't matter
                if recruit_effectiveness[recruit_id].poison_damage > 0 then
                    poisoner_count = poisoner_count + recruit_count[recruit_id]
                end
            end
            -- Subtract the number of possible recruits for the enemy from the list of poisonable units
            -- This works perfectly unless some of the enemy recruits cannot be poisoned.
            -- However, there is no problem with this since poison is generally less useful in such situations and subtracting them too discourages such recruiting
            local poison_modifier = math.max(0, math.min(((poisonable_count-recruit_data.recruit.possible_enemy_recruit_count) / (poisoner_count*5)), 1))^2
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                -- Ensure effectiveness and vulnerability are positive.
                -- Negative values imply that drain is involved and the amount drained is very high
                if recruit_effectiveness[recruit_id].damage <= 0 then
                    recruit_effectiveness[recruit_id].damage = 0.01
                else
                    recruit_effectiveness[recruit_id].damage = (recruit_effectiveness[recruit_id].damage / (num_enemies)^2)^0.5
                end
                recruit_effectiveness[recruit_id].poison_damage = (recruit_effectiveness[recruit_id].poison_damage / (num_enemies)^2)^0.5 * poison_modifier
                if recruit_vulnerability[recruit_id] <= 0 then
                    recruit_vulnerability[recruit_id] = 0.01
                else
                    recruit_vulnerability[recruit_id] = (recruit_vulnerability[recruit_id] / ((num_enemies)^2))^0.5
                end
            end
            -- Correct count of units for each range
            local most_common_range = nil
            local most_common_range_count = 0
            for range, count in pairs(attack_range_count) do
                attack_range_count[range] = count/enemy_type_count
                if attack_range_count[range] > most_common_range_count then
                    most_common_range = range
                    most_common_range_count = attack_range_count[range]
                end
            end
            -- Correct count of units for each attack type
            for attack_type, count in pairs(attack_type_count) do
                attack_type_count[attack_type] = count/enemy_type_count
            end

            local recruit_type = nil

            repeat
                recruit_data.recruit.best_hex, recruit_data.recruit.target_hex = ai_cas:find_best_recruit_hex(leader, recruit_data, avoid_map, outofway_units)
                if recruit_data.recruit.best_hex == nil or recruit_data.recruit.best_hex[1] == nil then
                    return nil
                end
                recruit_type = ai_cas:find_best_recruit(attack_type_count, unit_attack_type_count, recruit_effectiveness, recruit_vulnerability, attack_range_count, unit_attack_range_count, most_common_range_count)
            until recruit_type ~= nil

            return recruit_type
        end

        -- Consider recruiting as many units as possible at a location where the leader currently isn't
        -- These units will eventually be considered already recruited when trying to recruit at the current location
        -- Recruit will also recruit these units first once the leader moves to that location
        function ai_cas:prerecruit_units(from_loc, outofway_units)
            if recruit_data.recruit == nil then
                recruit_data.recruit = init_data()
            end

            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            if leader == nil then
                return nil
            end
            leader = wesnoth.copy_unit(leader)
            leader.x, leader.y = from_loc[1], from_loc[2]

            -- only track one prerecruit location at a time
            if recruit_data.recruit.prerecruit.loc == nil
            or from_loc[1] ~= recruit_data.recruit.prerecruit.loc[1]
            or from_loc[2] ~= recruit_data.recruit.prerecruit.loc[2] then
                recruit_data.recruit.prerecruit = {
                    loc = from_loc,
                    total_cost = 0,
                    units = {}
                }
            end

            get_current_castle(leader, recruit_data)

            -- recruit as many units as possible at that location
            while #recruit_data.castle.locs > 0 do
                local recruit_type = select_recruit(leader, nil, outofway_units)
                if recruit_type == nil then
                    break
                end
                local unit_cost = wesnoth.unit_types[recruit_type].cost
                if unit_cost > wesnoth.sides[wesnoth.current.side].gold - recruit_data.recruit.prerecruit.total_cost then
                    break
                end
                local queued_recruit = {
                    recruit_type = recruit_type,
                    recruit_hex = recruit_data.recruit.best_hex,
                    target_hex = recruit_data.recruit.target_hex
                }
                table.insert(recruit_data.recruit.prerecruit.units, queued_recruit)
                remove_hex_from_castle(recruit_data.castle, queued_recruit.recruit_hex)
                recruit_data.recruit.prerecruit.total_cost = recruit_data.recruit.prerecruit.total_cost + unit_cost
            end

            -- Provide the prerecruit data to the caller
            return recruit_data.recruit.prerecruit
        end

        function ai_cas:clear_prerecruit()
                recruit_data = {}
                recruit_data.recruit = init_data()
        end

        -- recruit a unit
        function ai_cas:recruit_rushers_exec(ai_local, avoid_map, outofway_units, no_exec)
            -- Optional input:
            --  @no_exec: if set, only go through the calculation and return true,
            --    but don't actually do anything. This is just a hack for now until
            --    we know if this works as desired.
            --    TODO: implement in a less awkward way later

            if ai_local then ai = ai_local end

            if AH.show_messages() then wesnoth.wml_actions.message { speaker = 'narrator', message = 'Recruiting' } end

            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            -- If leader location == prerecruit location, recruit units from prerecruit list instead of trying locally
            local recruit_type
            local max_cost = wesnoth.sides[wesnoth.current.side].gold
            if recruit_data.recruit.prerecruit.loc ~= nil
            and leader.x == recruit_data.recruit.prerecruit.loc[1] and leader.y == recruit_data.recruit.prerecruit.loc[2]
            and #recruit_data.recruit.prerecruit.units > 0 then
                local recruit_unit_data = table.remove(recruit_data.recruit.prerecruit.units, 1)
                recruit_hex = recruit_unit_data.recruit_hex
                target_hex = recruit_unit_data.target_hex
                recruit_type = recruit_unit_data.recruit_type
                if target_hex ~= nil and target_hex[1] ~= nil then
                    table.insert(recruit_data.castle.assigned_villages_x, target_hex[1])
                    table.insert(recruit_data.castle.assigned_villages_y, target_hex[2])
                end
                recruit_data.recruit.prerecruit.total_cost = recruit_data.recruit.prerecruit.total_cost - wesnoth.unit_types[recruit_type].cost
            else
                recruit_type = select_recruit(leader, avoid_map, outofway_units)
                if recruit_type == nil then
                    return false
                end
                recruit_hex = recruit_data.recruit.best_hex
                target_hex = recruit_data.recruit.target_hex

                -- Consider prerecruited units to already be recruited if there is no target hex
                -- Targeted hexes won't be available at the prerecruit location and we don't want to miss getting the associated villages
                if recruit_data.recruit.target_hex == nil or recruit_data.recruit.target_hex[1] == nil then
                    max_cost = max_cost - recruit_data.recruit.prerecruit.total_cost
                end
            end

            if wesnoth.unit_types[recruit_type].cost <= max_cost then
                -- It is possible that there's a unit on the recruit hex if a
                -- outofway_units table is passed.

                -- Placeholder: TODO: implement better way of doing this
                if no_exec then return true end

                local unit_in_way = wesnoth.get_unit(recruit_hex[1], recruit_hex[2])
                if unit_in_way then
                    AH.move_unit_out_of_way(ai, unit_in_way)
                end


                AH.checked_recruit(ai, recruit_type, recruit_hex[1], recruit_hex[2])

                local unit = wesnoth.get_unit(recruit_hex[1], recruit_hex[2])

                -- If the recruited unit cannot reach the target hex, return it to the pool of targets
                if target_hex ~= nil and target_hex[1] ~= nil then
                    local path, cost = wesnoth.find_path(unit, target_hex[1], target_hex[2], {viewing_side=0, max_cost=unit.max_moves+1})
                    if cost > unit.max_moves then
                        -- The last village added to the list should be the one we tried to aim for, check anyway
                        local last = #recruit_data.castle.assigned_villages_x
                        if (recruit_data.castle.assigned_villages_x[last] == target_hex[1]) and (recruit_data.castle.assigned_villages_y[last] == target_hex[2]) then
                            table.remove(recruit_data.castle.assigned_villages_x)
                            table.remove(recruit_data.castle.assigned_villages_y)
                        end
                    end
                end

                return true, unit
            else
                return false
            end
        end

        function get_current_castle(leader, data)
            if (not data.castle) or (data.castle.x ~= leader.x) or (data.castle.y ~= leader.y) then
                data.castle = {}
                local width,height,border = wesnoth.get_map_size()

                data.castle = {
                    locs = wesnoth.get_locations {
                        x = "1-"..width, y = "1-"..height,
                        { "and", {
                            x = leader.x, y = leader.y, radius = 200,
                            { "filter_radius", { terrain = 'C*,K*,C*^*,K*^*,*^K*,*^C*' } }
                        } },
                        { "not", { -- exclude hex leader is on
                            x = leader.x, y = leader.y
                        } }
                    },
                    x = leader.x,
                    y = leader.y
                }
            end
        end

        function remove_hex_from_castle(castle, hex)
            for i,c in ipairs(castle.locs) do
                if c[1] == hex[1] and c[2] == hex[2] then
                    table.remove(castle.locs, i)
                    break
                end
            end
        end

        function ai_cas:find_best_recruit_hex(leader, data, avoid_map, outofway_units)
            -- Find the best recruit hex
            -- First choice: a hex that can reach an unowned village
            -- Second choice: a hex close to the enemy
            --
            -- Optional inputs:
            --  @avoid_map: location set listing hexes on which we should
            --    not recruit, unless no other hexes are available
            --  @outofway_units: a table of type { id = true } listing units that
            --    can move out of the way to make place for recruiting

            outofway_units = outofway_units or {}

            get_current_castle(leader, data)

            local best_hex, village = get_village_target(leader, data)
            if village[1] then
                table.insert(data.castle.assigned_villages_x, village[1])
                table.insert(data.castle.assigned_villages_y, village[2])
            else
                -- no available village, look for hex closest to enemy leader
                -- and also the closest enemy
                local max_rating = -9e99

                local enemy_leaders = AH.get_live_units { canrecruit = 'yes',
                    { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
                }
                local closest_enemy_distance, closest_enemy_location = AH.get_closest_enemy()

                for i,c in ipairs(data.castle.locs) do
                    local rating = 0
                    local unit = wesnoth.get_unit(c[1], c[2])
                    if (not unit) or outofway_units[unit.id] then
                        for j,e in ipairs(enemy_leaders) do
                            rating = rating + 1 / wesnoth.map.distance_between(c[1], c[2], e.x, e.y) ^ 2.
                        end
                        rating = rating + 1 / wesnoth.map.distance_between(c[1], c[2], closest_enemy_location.x, closest_enemy_location.y) ^ 2.

                        -- If there's a unit on the hex (that is marked as being able
                        -- to move out of the way, otherwise we don't get here), give
                        -- a pretty stiff penalty, but make it possible to recruit here
                        if unit then
                            --std_print('Out of way penalty', c[1], c[2], unit.id)
                            rating = rating - 100.
                        end

                        if avoid_map and avoid_map:get(c[1], c[2]) then
                            --std_print('Avoid hex for recruiting:', c[1], c[2])
                            rating = rating - 1000.
                        end
                        if (rating > max_rating) then
                            max_rating, best_hex = rating, { c[1], c[2] }
                        end
                    end
                end
            end

            if AH.print_eval() then
                if village[1] then
                    std_print("Recruit at: " .. best_hex[1] .. "," .. best_hex[2] .. " -> " .. village[1] .. "," .. village[2])
                else
                    std_print("Recruit at: " .. best_hex[1] .. "," .. best_hex[2])
                end
            end
            return best_hex, village
        end

        function ai_cas:find_best_recruit(attack_type_count, unit_attack_type_count, recruit_effectiveness, recruit_vulnerability, attack_range_count, unit_attack_range_count, most_common_range_count)
            -- Find best recruit based on damage done to enemies present, speed, and hp/gold ratio
            local recruit_scores = {}
            local best_scores = {offense = 0, defense = 0, move = 0}
            local best_hex = recruit_data.recruit.best_hex
            local target_hex = recruit_data.recruit.target_hex
            local distance_to_enemy, enemy_location
            if target_hex[1] then
                distance_to_enemy, enemy_location = AH.get_closest_enemy(target_hex)
            else
                distance_to_enemy, enemy_location = AH.get_closest_enemy(best_hex)
            end

            local gold_limit = 9e99
            if recruit_data.castle.loose_gold_limit >= recruit_data.recruit.cheapest_unit_cost then
                gold_limit = recruit_data.castle.loose_gold_limit
            end
            --std_print (recruit_data.castle.loose_gold_limit .. " " .. recruit_data.recruit.cheapest_unit_cost .. " " .. gold_limit)

            local recruitable_units = {}

            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                -- Count number of units with the same attack type. Used to avoid recruiting too many of the same unit
                local attack_types = 0
                local recruit_count = 0
                for attack_type, count in pairs(unit_attack_type_count[recruit_id]) do
                    attack_types = attack_types + 1
                    recruit_count = recruit_count + attack_type_count[attack_type]
                end
                recruit_count = recruit_count / attack_types
                local recruit_modifier = 1+recruit_count/50
                local efficiency_index = 1
                local unit_cost = wesnoth.unit_types[recruit_id].cost

                -- Use time to enemy to encourage recruiting fast units when the opponent is far away (game is beginning or we're winning)
                -- Base distance on
                local recruit_unit = wesnoth.create_unit {
                    type = recruit_id,
                    x = best_hex[1],
                    y = best_hex[2],
                    random_traits = false,
                    name = "X",
                    random_gender = false
                }
                if target_hex[1] then
                    local path, cost = wesnoth.find_path(recruit_unit, target_hex[1], target_hex[2], {viewing_side=0, max_cost=wesnoth.unit_types[recruit_id].max_moves+1})
                    if cost > wesnoth.unit_types[recruit_id].max_moves then
                        -- Unit cost is effectively higher if cannot reach the village
                        efficiency_index = 2
                        unit_cost = no_village_cost(recruit_id)
                    end

                    -- Later calculations are based on where the unit will be after initial move
                    recruit_unit.x = target_hex[1]
                    recruit_unit.y = target_hex[2]
                end

                local path, cost = wesnoth.find_path(recruit_unit, enemy_location.x, enemy_location.y, {ignore_units = true})
                local time_to_enemy = cost / wesnoth.unit_types[recruit_id].max_moves
                local move_score = 1 / (time_to_enemy * unit_cost^0.5)

                local eta = math.ceil(time_to_enemy)
                if target_hex[1] then
                    -- expect a 1 turn delay to reach village
                    eta = eta + 1
                end
                -- divide the lawful bonus by eta before running it through the function because the function converts from 0 centered to 1 centered

                local lawful_bonus = 0
                local eta_turn = wesnoth.current.turn + eta
                if eta_turn <= wesnoth.game_config.last_turn then
                    lawful_bonus = wesnoth.get_time_of_day(wesnoth.current.turn + eta).lawful_bonus / eta^2
                end
                local damage_bonus = AH.get_unit_time_of_day_bonus(recruit_unit.__cfg.alignment, lawful_bonus)
                -- Estimate effectiveness on offense and defense
                local offense_score =
                    (recruit_effectiveness[recruit_id].damage*damage_bonus+recruit_effectiveness[recruit_id].poison_damage)
                    /(wesnoth.unit_types[recruit_id].cost^0.3*recruit_modifier^4)
                local defense_score = efficiency[recruit_id][efficiency_index]/recruit_vulnerability[recruit_id]
				-- Hailfire alterations start here 
                local unit_score = {offense = offense_score, defense = defense_score, move = move_score}
                recruit_scores[recruit_id] = unit_score
                for key, score in pairs(unit_score) do
                    if score > best_scores[key] then
                        best_scores[key] = score
                    end
                end

                if can_slow(recruit_unit) then
                    unit_score["slows"] = true
                end
				if wesnoth.match_unit(recruit_unit, { ability = "trapper" }) then
                    unit_score["slows"] = true
                end
				if wesnoth.match_unit(recruit_unit, { ability = "healing" }) then
                    unit_score["heals"] = true
                end
                if wesnoth.match_unit(recruit_unit, { ability = "skirmisher" }) then
                    unit_score["skirmisher"] = true
                end
                if wesnoth.match_unit(recruit_unit, { ability = "rustic" }) then
                    unit_score["rustic"] = true
                end
                if wesnoth.match_unit(recruit_unit, { ability = "arctic" }) then
                    unit_score["arctic"] = true
                end
                if wesnoth.match_unit(recruit_unit, { ability = "tropic" }) then
                    unit_score["tropic"] = true
                end
				if wesnoth.match_unit(recruit_unit, { ability = "HF_magical_clear" }) then
                    unit_score["HF_magical_clear"] = true
                end
                if wesnoth.match_unit(recruit_unit, { ability = "HF_magical_ice" }) then
                    unit_score["HF_magical_ice"] = true
                end
                if wesnoth.match_unit(recruit_unit, { ability = "HF_magical_fire" }) then
                    unit_score["HF_magical_fire"] = true
                end
                recruitable_units[recruit_id] = recruit_unit
            end
            local healer_count, healable_count = get_unit_counts_for_healing()
            local best_score = 0
            local recruit_type = nil
            local offense_weight = 2.5
            local defense_weight = 1/hp_ratio^0.5
            local move_weight = math.max((distance_to_enemy/20)^2, 0.25)
            local randomness = params.randomness or 0.1
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local scores = recruit_scores[recruit_id]
                local offense_score = (scores["offense"]/best_scores["offense"])^0.5
                local defense_score = (scores["defense"]/best_scores["defense"])^0.5
                local move_score = (scores["move"]/best_scores["move"])--^0.5

                local bonus = math.random()*randomness
                if scores["slows"] then
                    bonus = bonus + 0.4
                end
                if scores["heals"] then
                    bonus = bonus + (healable_count/(healer_count+1))/20
                end
                if scores["skirmisher"] then
                    bonus = bonus + 0.1
                end
                if scores["HF_magical_ice"] then
                    bonus = bonus + 0.6
                end
                if scores["HF_magical_fire"] then
                    bonus = bonus + 0.6
                end
                if scores["HF_magical_clear"] then
                    bonus = bonus + 0.6
                end
                if scores["arctic"] then
                    bonus = bonus + 0.05
                end
                if scores["tropic"] then
                    bonus = bonus + 0.05
                end		
                for attack_range, count in pairs(unit_attack_range_count[recruit_id]) do
                    bonus = bonus + 0.02 * most_common_range_count / (attack_range_count[attack_range]+1)
                end
                bonus = bonus + 0.03 * wesnoth.races[wesnoth.unit_types[recruit_id].__cfg.race].num_traits^2
                if target_hex[1] then
                    recruitable_units[recruit_id].x = best_hex[1]
                    recruitable_units[recruit_id].y = best_hex[2]
                    local path, cost = wesnoth.find_path(recruitable_units[recruit_id], target_hex[1], target_hex[2], {viewing_side=0, max_cost=wesnoth.unit_types[recruit_id].max_moves+1})
                    if cost > wesnoth.unit_types[recruit_id].max_moves then
                        -- penalty if the unit can't reach the target village
                        bonus = bonus - 0.2
                    end
                end
				-- Hailfire alterations end here, may change some stuff directly after this later on 
                local score = offense_score*offense_weight + defense_score*defense_weight + move_score*move_weight + bonus
                --std_print(recruit_id)
                --std_print('  ' .. offense_score .. ' * ' .. offense_weight .. ' + ' .. defense_score .. ' * ' .. defense_weight .. ' + ' .. move_score .. ' * ' .. move_weight .. ' + ' .. bonus)
                --std_print('  --> ' .. score)
                if AH.print_eval() then
                    std_print(recruit_id .. " score: " .. offense_score*offense_weight .. " + " .. defense_score*defense_weight .. " + " .. move_score*move_weight  .. " + " .. bonus  .. " = " .. score)
                end
                if score > best_score and wesnoth.unit_types[recruit_id].cost <= gold_limit then
                    best_score = score
                    recruit_type = recruit_id
                end
            end

            return recruit_type
        end

        function get_unit_counts_for_healing()
            local healers = #AH.get_live_units {
                side = wesnoth.current.side,
                ability = "healing",
                { "not", { canrecruit = "yes" }}
            }
            local healable = #AH.get_live_units {
                side = wesnoth.current.side,
                { "not", { ability = "regenerates" }}
            }
            return healers, healable
        end

        function get_village_target(leader, data)
            -- Only consider villages reachable by our fastest unit
            local fastest_unit_speed = 0
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                if wesnoth.unit_types[recruit_id].max_moves > fastest_unit_speed then
                    fastest_unit_speed = wesnoth.unit_types[recruit_id].max_moves
                end
            end

            local locsx, locsy = AH.split_location_list_to_strings(data.castle.locs)

            -- get a list of all unowned villages within fastest_unit_speed
            -- TODO get list of villages not owned by allies instead
            -- this may have false positives (villages that can't be reached due to difficult/impassible terrain)
            local exclude_x, exclude_y = "0", "0"
            if data.castle.assigned_villages_x ~= nil and data.castle.assigned_villages_x[1] then
                exclude_x = table.concat(data.castle.assigned_villages_x, ",")
                exclude_y = table.concat(data.castle.assigned_villages_y, ",")
            end
            local villages = wesnoth.get_villages {
                owner_side = 0,
                { "and", {
                    radius = fastest_unit_speed,
                    x = locsx, y = locsy
                }},
                { "not", {
                    x = exclude_x,
                    y = exclude_y
                }}
            }

            local hex, target, shortest_distance = {}, {}, AH.no_path

            if not data.castle.assigned_villages_x then
                data.castle.assigned_villages_x = {}
                data.castle.assigned_villages_y = {}

                if not params.leader_takes_village or params.leader_takes_village() then
                    -- skip one village for the leader
                    for i,v in ipairs(villages) do
                        local path, cost = wesnoth.find_path(leader, v[1], v[2], {max_cost = leader.max_moves+1})
                        if cost <= leader.max_moves then
                            table.insert(data.castle.assigned_villages_x, v[1])
                            table.insert(data.castle.assigned_villages_y, v[2])
                            table.remove(villages, i)
                            break
                        end
                    end
                end
            end

            local village_count = #villages
            local test_units = get_test_units()
            local num_recruits = #test_units
            local total_village_distance = {}
            for j,c in ipairs(data.castle.locs) do
                c_index = c[1] + c[2]*1000
                total_village_distance[c_index] = 0
                for i,v in ipairs(villages) do
                    total_village_distance[c_index] = total_village_distance[c_index] + wesnoth.map.distance_between(c[1], c[2], v[1], v[2])
                end
            end

            local width,height,border = wesnoth.get_map_size()
            for i,v in ipairs(villages) do
                local close_castle_hexes = wesnoth.get_locations {
                    x = locsx, y = locsy,
                    { "and", {
                      x = v[1], y = v[2],
                      radius = fastest_unit_speed
                    }},
                    { "not", { { "filter", {} } } }
                }
                for u,unit in ipairs(test_units) do
                    test_units[u].x = v[1]
                    test_units[u].y = v[2]
                end

                local viable_village = false
                local village_best_hex, village_shortest_distance = {}, AH.no_path
                for j,c in ipairs(close_castle_hexes) do
                    if c[1] > 0 and c[2] > 0 and c[1] <= width and c[2] <= height then
                        local distance = 0
                        for x,unit in ipairs(test_units) do
                            local path, unit_distance = wesnoth.find_path(unit, c[1], c[2], {viewing_side=0, max_cost=fastest_unit_speed+1})
                            distance = distance + unit_distance

                            -- Village is only viable if at least one unit can reach it
                            if unit_distance <= unit.max_moves then
                                viable_village = true
                            end
                        end
                        distance = distance / num_recruits

                        if distance < village_shortest_distance
                        or (distance == village_shortest_distance and distance < AH.no_path
                            and total_village_distance[c[1] + c[2]*1000] > total_village_distance[village_best_hex[1]+village_best_hex[2]*1000])
                        then
                            village_best_hex = c
                            village_shortest_distance = distance
                        end
                    end
                end
                if village_shortest_distance < shortest_distance then
                    hex = village_best_hex
                    target = v
                    shortest_distance = village_shortest_distance
                end

                if not viable_village then
                    -- this village could not be reached by any unit
                    -- eliminate it from consideration
                    table.insert(data.castle.assigned_villages_x, v[1])
                    table.insert(data.castle.assigned_villages_y, v[2])
                    village_count = village_count - 1
                end
            end

            data.castle.loose_gold_limit = math.floor(wesnoth.sides[wesnoth.current.side].gold/village_count + 0.5)

            return hex, target
        end

        function get_test_units()
            local test_units, num_recruits = {}, 0
            local movetypes = {}
            for x,id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local custom_movement = wml.get_child(wesnoth.unit_types[id].__cfg, "movement_costs")
                local movetype = wesnoth.unit_types[id].__cfg.movement_type
                if custom_movement
                or (not movetypes[movetype])
                or (movetypes[movetype] < wesnoth.unit_types[id].max_moves)
                then
                    if not custom_movement then
                        movetypes[movetype] = wesnoth.unit_types[id].max_moves
                    end
                    num_recruits = num_recruits + 1
                    test_units[num_recruits] =  wesnoth.create_unit({
                        type = id,
                        side = wesnoth.current.side,
                        random_traits = false,
                        name = "X",
                        random_gender = false
                    })
                end
            end

            return test_units
        end
    end -- init()
}

		 >>
		[/lua]
	[/event]
#enddef

#define SECOND_ALIGNMENT_RETREAT
	[event]
        name=preload
        first_time_only=no
		id=second_alignment_retreat_CA
		[lua]
			code = << 
--[=[
Functions to support the retreat of injured units and Hailfire Era units in hostile time_of_day areas
]=]

		local H = wesnoth.require "helper"
		local AH = wesnoth.require "ai/lua/ai_helper.lua"
		local BC = wesnoth.require "ai/lua/battle_calcs.lua"
		local LS = wesnoth.require "location_set"

local retreat_functions = {}

function retreat_functions.get_retreat_injured_units(healees, regenerates, enemy_count_weight)
    -- Only retreat to safe locations
    local enemies = AH.get_live_units {
        { "filter_side", {{ "enemy_of", { side = wesnoth.current.side } }} }
    }
    local enemy_attack_map = BC.get_attack_map(enemies)

    local enemy_count_weight = enemy_count_weight or 100000

    local healing_locs = retreat_functions.get_healing_locations()

    local max_rating, best_loc, best_unit = -9e99, nil, nil
    for i,u in ipairs(healees) do
        local possible_locations = wesnoth.find_reach(u)
        -- TODO: avoid ally's villages (may be preferable to lower rating so they will
        -- be used if unit is very injured)
        if not regenerates then
            -- Unit cannot self heal, make the terrain do it for us if possible
            local location_subset = {}
            for j,loc in ipairs(possible_locations) do
                local heal_amount = wesnoth.get_terrain_info(wesnoth.get_terrain(loc[1], loc[2])).healing or 0
                if heal_amount == true then
                    -- handle deprecated syntax
                    -- TODO: remove this when removed from game
                    heal_amount = 8
                end
                local curing = 0
                if heal_amount > 0 then
                    curing = 2
                end
                local healer_values = healing_locs:get(loc[1], loc[2]) or { 0, 0 }
                heal_amount = math.max(heal_amount, healer_values[1])
                curing = math.max(curing, healer_values[2])
                table.insert(location_subset, { loc[1], loc[2], heal_amount, curing })
            end

            possible_locations = location_subset
        end
            -- Hailfire alterations are here
        local base_rating = - u.hitpoints + u.max_hitpoints / 2.
        if u.status.poisoned then base_rating = base_rating + 8 end
		if u.status.slowed then base_rating = base_rating + 4 end
		if u.status.petrified then base_rating = base_rating + 4 end
		if u.status.burnt then base_rating = base_rating + 4 end
		if u.status.frostbitten then base_rating = base_rating + 4 end
		if u.status.paralyzed then base_rating = base_rating + 4 end
		if u.status.bleeding then base_rating = base_rating + 4 end
		if u.status.dizzied then base_rating = base_rating + 4 end
		if u.status.arctic and u.status.sweltry then base_rating = base_rating + 12 end
        if u.status.tropic and u.status.frigid then base_rating = base_rating + 12 end
        base_rating = base_rating * 1000
			-- Hailfire alterations end here
        for j,loc in ipairs(possible_locations) do
            local unit_in_way = wesnoth.get_unit(loc[1], loc[2])
            if (not unit_in_way) or ((unit_in_way.moves > 0) and (unit_in_way.side == wesnoth.current.side)) then
                local rating = base_rating
                local heal_score = 0
                if regenerates then
                    heal_score = math.min(8, u.max_hitpoints - u.hitpoints)
                else
                    if u.status.poisoned then
                        if loc[4] > 0 then
                            heal_score = math.min(8, u.hitpoints - 1)
                            if loc[4] == 2 then
                                -- This value is arbitrary, it just represents the ability to heal on the turn after
                                heal_score = heal_score + 1
                            end
                        end
                    else
                        heal_score = math.min(loc[3], u.max_hitpoints - u.hitpoints)
                    end
                end

                -- Huge penalty for each enemy that can reach location,
                -- this is the single most important point (and non-linear)
                local enemy_count = enemy_attack_map.units:get(loc[1], loc[2]) or 0
                rating = rating - enemy_count * enemy_count_weight

                -- Penalty based on terrain defense for unit
                rating = rating - wesnoth.unit_defense(u, wesnoth.get_terrain(loc[1], loc[2]))/100.

                if (loc[1] == u.x) and (loc[2] == u.y) and (not u.status.poisoned) then
                    if enemy_count == 0 then
                        -- Bonus if we can rest heal
                        -- TODO: Always apply bonus if unit has healthy trait
                        heal_score = heal_score + 2
                    end
                elseif unit_in_way then
                    -- Penalty if a unit has to move out of the way
                    -- (based on hp of moving unit)
                    rating = rating + unit_in_way.hitpoints - unit_in_way.max_hitpoints
                end

                rating = rating + heal_score^2

                if (rating > max_rating) then
                    max_rating, best_loc, best_unit = rating, loc, u
                end
            end
        end
    end

    return best_unit, best_loc, enemy_attack_map.units:get(best_loc[1], best_loc[2]) or 0
end

return retreat_functions
		 >>
		[/lua]
	[/event]
#enddef

#define SECOND_ALIGNMENT_RUSH
	[event]
        name=preload
        first_time_only=no
		id=second_alignment_rush_CA
		[lua]
			code = << 
return {
    init = function(ai)

        -- Grab CA as starting point for rush engine 
        local generic_rush = wesnoth.require("ai/lua/generic_rush_engine.lua").init(ai)

        local AH = wesnoth.require "ai/lua/ai_helper.lua"
        local BC = wesnoth.require "ai/lua/battle_calcs.lua"
        local LS = wesnoth.require "location_set"
        local DBG = wesnoth.require "ai/lua/debug.lua"
        local HS = wesnoth.require "ai/micro_ais/cas/ca_healer_move.lua"
        local R = wesnoth.require "ai/lua/retreat.lua"

        local function print_time(...)
            if generic_rush.data.turn_start_time then
                AH.print_ts_delta(generic_rush.data.turn_start_time, ...)
            else
                AH.print_ts(...)
            end
        end
		
		 ------- Spread Clear CA --------------

        function generic_rush:spread_clear_eval()
            local start_time, ca_name = wesnoth.get_time_stamp() / 1499., 'spread_clear'
            if AH.print_eval() then print_time('     - Evaluating spread_clear CA:') end

            -- If a unit with a HF_magical_clear weapon special can make an attack, we'll do that preferentially
            -- (with some exceptions)
            local basics = AH.get_live_units { side = wesnoth.current.side,
                formula = 'attacks_left > 0',
                { "filter_wml", {
                    { "attack", {
                        { "specials", {
                            { "HF_magical_clear", { } }
                        } }
                    } }
                } },
                canrecruit = 'no'
            }
            --print('#basics', #basics)
            if (not basics[1]) then
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 0
            end

            local attacks = AH.get_attacks(basics)
            --print('#attacks', #attacks)
            if (not attacks[1]) then
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 0
            end

            -- Go through all possible attacks with basics
            local max_rating, best_attack = -9e99, {}
            for i,a in ipairs(attacks) do
                local attacker = wesnoth.get_unit(a.src.x, a.src.y)
                local defender = wesnoth.get_unit(a.target.x, a.target.y)

                -- Don't try to remove weather from a rustic unit
                local cant_clear = defender.status.rustic

                -- Also, rustic units that would level up through the attack or could level on their turn as a result is very bad
                local about_to_level = defender.max_experience - defender.experience <= (wesnoth.unit_types[attacker.type].level * 2)

                if (not cant_basic) and (not on_village) and (not about_to_level) then
                    -- Strongest enemy gets weather removed first
                    local rating = defender.hitpoints

                    -- Always attack enemy leader, if possible
                    if defender.canrecruit then rating = rating + 1000 end

                    -- Enemies that can regenerate are not good targets
                    if wesnoth.unit_ability(defender, 'regenerate') then rating = rating - 1000 end
					
					-- Rustic enemies are not good targets
                    if wesnoth.unit_ability(defender, 'rustic') then rating = rating - 1000 end
					
					-- Enemies in weather-themed areas are good targets
			if wesnoth.unit_tod(defender, 'Cdawn, Cmorning, Cafternoon, Cdusk, Cfirst_watch, Csecond_watch, Hdawn, Hmorning, Hafternoon, Hdusk, Hfirst_watch, Hsecond_watch') then rating = rating + 1200 end
					
                    -- More priority to enemies on strong terrain
                    local defender_defense = 100 - wesnoth.unit_defense(defender, wesnoth.get_terrain(defender.x, defender.y))
                    rating = rating + defender_defense / 4.

                    -- For the same attacker/defender pair, go to strongest terrain
                    local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.dst.x, a.dst.y))
                    rating = rating + attack_defense / 2.
                    --print('rating', rating)

                    -- And from village everything else being equal
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(a.dst.x, a.dst.y)).village
                    if is_village then rating = rating + 0.5 end

                    if rating > max_rating then
                        max_rating, best_attack = rating, a
                    end
                end
            end

            if (max_rating > -9e99) then
                self.data.attack = best_attack
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 190000
            end
            if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
            return 0
        end

        function generic_rush:spread_clear_exec()
            local attacker = wesnoth.get_unit(self.data.attack.src.x, self.data.attack.src.y)
            -- If several attacks have the HF_magical_fire weapon special, this will always find the last one
            local is_jackbasic, basic_weapon = AH.has_weapon_special(attacker, "HF_magical_clear")

            if AH.print_exec() then print_time('   Executing spread_clear CA') end
            if AH.show_messages() then wesnoth.wml_actions.message { speaker = attacker.id, message = 'magical clear attack' } end

            AH.robust_move_and_attack(ai, attacker, self.data.attack.dst, self.data.attack.target, { weapon = clear_weapon })

            self.data.attack = nil
        end 

	 ------- Spread Frigid CA --------------

        function generic_rush:spread_frigid_eval()
            local start_time, ca_name = wesnoth.get_time_stamp() / 1500., 'spread_frigid'
            if AH.print_eval() then print_time('     - Evaluating spread_frigid CA:') end

            -- If a unit with a HF_magical_ice weapon special can make an attack, we'll do that preferentially
            -- (with some exceptions)
            local jackfrosts = AH.get_live_units { side = wesnoth.current.side,
                formula = 'attacks_left > 0',
                { "filter_wml", {
                    { "attack", {
                        { "specials", {
                            { "HF_magical_ice", { } }
                        } }
                    } }
                } },
                canrecruit = 'no'
            }
            --print('#jackfrosts', #jackfrosts)
            if (not jackfrosts[1]) then
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 0
            end

            local attacks = AH.get_attacks(jackfrosts)
            --print('#attacks', #attacks)
            if (not attacks[1]) then
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 0
            end

            -- Go through all possible attacks with jackfrosts
            local max_rating, best_attack = -9e99, {}
            for i,a in ipairs(attacks) do
                local attacker = wesnoth.get_unit(a.src.x, a.src.y)
                local defender = wesnoth.get_unit(a.target.x, a.target.y)

                -- Don't try to chill a unit that cannot be made frigid
                local cant_frigid = defender.status.frigid or defender.status.arctic

                -- Also, chilling units that would level up through the attack or could level on their turn as a result is very bad
                local about_to_level = defender.max_experience - defender.experience <= (wesnoth.unit_types[attacker.type].level * 2)

                if (not cant_frigid) and (not on_village) and (not about_to_level) then
                    -- Strongest enemy gets made frigid first
                    local rating = defender.hitpoints

                    -- Always attack enemy leader, if possible
                    if defender.canrecruit then rating = rating + 1000 end

                    -- Enemies that can regenerate are not good targets
                    if wesnoth.unit_ability(defender, 'regenerate') then rating = rating - 1000 end
					
					-- Arctic enemies are not good targets
                    if wesnoth.unit_ability(defender, 'arctic') then rating = rating - 1000 end
					
					-- Enemies in heat-themed areas are good targets
			if wesnoth.unit_tod(defender, 'Hdawn, Hmorning, Hafternoon, Hdusk, Hfirst_watch, Hsecond_watch') then rating = rating + 1200 end
					
                    -- More priority to enemies on strong terrain
                    local defender_defense = 100 - wesnoth.unit_defense(defender, wesnoth.get_terrain(defender.x, defender.y))
                    rating = rating + defender_defense / 4.

                    -- For the same attacker/defender pair, go to strongest terrain
                    local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.dst.x, a.dst.y))
                    rating = rating + attack_defense / 2.
                    --print('rating', rating)

                    -- And from village everything else being equal
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(a.dst.x, a.dst.y)).village
                    if is_village then rating = rating + 0.5 end

                    if rating > max_rating then
                        max_rating, best_attack = rating, a
                    end
                end
            end

            if (max_rating > -9e99) then
                self.data.attack = best_attack
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 190000
            end
            if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
            return 0
        end

        function generic_rush:spread_frigid_exec()
            local attacker = wesnoth.get_unit(self.data.attack.src.x, self.data.attack.src.y)
            -- If several attacks have HF_magical_ice", this will always find the last one
            local is_jackfroster, frigid_weapon = AH.has_weapon_special(attacker, "HF_magical_ice")

            if AH.print_exec() then print_time('   Executing spread_frigid CA') end
            if AH.show_messages() then wesnoth.wml_actions.message { speaker = attacker.id, message = 'HF_magical_ice" attack' } end

            AH.robust_move_and_attack(ai, attacker, self.data.attack.dst, self.data.attack.target, { weapon = frigid_weapon })

            self.data.attack = nil
        end
		
	 ------- Spread Sweltry CA --------------

        function generic_rush:spread_sweltry_eval()
            local start_time, ca_name = wesnoth.get_time_stamp() / 1499., 'spread_sweltry'
            if AH.print_eval() then print_time('     - Evaluating spread_sweltry CA:') end

            -- If a unit with a HF_magical_fire weapon special can make an attack, we'll do that preferentially
            -- (with some exceptions)
            local broilers = AH.get_live_units { side = wesnoth.current.side,
                formula = 'attacks_left > 0',
                { "filter_wml", {
                    { "attack", {
                        { "specials", {
                            { "HF_magical_fire", { } }
                        } }
                    } }
                } },
                canrecruit = 'no'
            }
            --print('#broilers', #broilers)
            if (not broilers[1]) then
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 0
            end

            local attacks = AH.get_attacks(broilers)
            --print('#attacks', #attacks)
            if (not attacks[1]) then
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 0
            end

            -- Go through all possible attacks with broilers
            local max_rating, best_attack = -9e99, {}
            for i,a in ipairs(attacks) do
                local attacker = wesnoth.get_unit(a.src.x, a.src.y)
                local defender = wesnoth.get_unit(a.target.x, a.target.y)

                -- Don't try to heat a unit that cannot be made sweltry
                local cant_sweltry = defender.status.sweltry or defender.status.tropic

                -- Also, broiling units that would level up through the attack or could level on their turn as a result is very bad
                local about_to_level = defender.max_experience - defender.experience <= (wesnoth.unit_types[attacker.type].level * 2)

                if (not cant_sweltry) and (not on_village) and (not about_to_level) then
                    -- Strongest enemy gets made sweltry first
                    local rating = defender.hitpoints

                    -- Always attack enemy leader, if possible
                    if defender.canrecruit then rating = rating + 1000 end

                    -- Enemies that can regenerate are not good targets
                    if wesnoth.unit_ability(defender, 'regenerate') then rating = rating - 1000 end
					
					-- Tropic enemies are not good targets
                    if wesnoth.unit_ability(defender, 'tropic') then rating = rating - 1000 end
					
					-- Enemies in cold-themed areas are good targets
			if wesnoth.unit_tod(defender, 'Cdawn, Cmorning, Cafternoon, Cdusk, Cfirst_watch, Csecond_watch') then rating = rating + 1200 end
					
                    -- More priority to enemies on strong terrain
                    local defender_defense = 100 - wesnoth.unit_defense(defender, wesnoth.get_terrain(defender.x, defender.y))
                    rating = rating + defender_defense / 4.

                    -- For the same attacker/defender pair, go to strongest terrain
                    local attack_defense = 100 - wesnoth.unit_defense(attacker, wesnoth.get_terrain(a.dst.x, a.dst.y))
                    rating = rating + attack_defense / 2.
                    --print('rating', rating)

                    -- And from village everything else being equal
                    local is_village = wesnoth.get_terrain_info(wesnoth.get_terrain(a.dst.x, a.dst.y)).village
                    if is_village then rating = rating + 0.5 end

                    if rating > max_rating then
                        max_rating, best_attack = rating, a
                    end
                end
            end

            if (max_rating > -9e99) then
                self.data.attack = best_attack
                if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
                return 190000
            end
            if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
            return 0
        end

        function generic_rush:spread_sweltry_exec()
            local attacker = wesnoth.get_unit(self.data.attack.src.x, self.data.attack.src.y)
            -- If several attacks have the HF_magical_fire weapon special, this will always find the last one
            local is_jackbroiler, sweltry_weapon = AH.has_weapon_special(attacker, "HF_magical_fire")

            if AH.print_exec() then print_time('   Executing spread_sweltry CA') end
            if AH.show_messages() then wesnoth.wml_actions.message { speaker = attacker.id, message = 'magical fire attack' } end

            AH.robust_move_and_attack(ai, attacker, self.data.attack.dst, self.data.attack.target, { weapon = sweltry_weapon })

            self.data.attack = nil
        end 
		
		return generic_rush
    end
}
		 >>
		[/lua]
	[/event]
#enddef
