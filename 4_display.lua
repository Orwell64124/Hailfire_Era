#textdomain-Hailfire_Era

#define SECOND_ALIGNMENT_TEXT
	
	[event]
        name=preload
        first_time_only=no
		[lua]
			code = << 
			
	local old_unit_alignment = wesnoth.theme_items.unit_alignment
	function wesnoth.theme_items.unit_alignment()
	   local u = wesnoth.get_displayed_unit()
	   if not u then return {} end
	   local s = old_unit_alignment()
	   if u.status.arctic or u.status.tropic then
		  if u.status.arctic and u.status.sweltry then
			 table.insert(s, { "element", {                           
				text = ",<span color='#9FEFFF'>A</span><span color='#FF9933' size='small'>(0.5x)</span>",
				tooltip = "<span color='#9FEFFF'>Arctic:</span> Units with this ability will inflict double damage in cold and frigid areas, but only half damage in hot and sweltry areas."
			 } })
		  elseif u.status.arctic and u.status.frigid then
			 table.insert(s, { "element", {                           
				text = ",<span color='#9FEFFF'>A</span><span color='#00ff00' size='small'>(2.0x)</span>",
				tooltip = "<span color='#9FEFFF'>Arctic:</span> Units with this ability will inflict double damage in cold and frigid areas, but only half damage in hot and sweltry areas."
			 } })
		  elseif u.status.arctic then
			 table.insert(s, { "element", {                           
				text = ",<span color='#9FEFFF'>A</span><span size='small'>(1.0x)</span>",
				tooltip = "<span color='#9FEFFF'>Arctic:</span> Units with this ability will inflict double damage in cold and frigid areas, but only half damage in hot and sweltry areas."
			 } })
		  end
	    end
		return s
	end 
		 >>
		[/lua]
	[/event]
	
	[event]
        name=preload
        first_time_only=no
		[lua]
			code = << 
			local old_unit_alignment = wesnoth.theme_items.unit_alignment
			function wesnoth.theme_items.unit_alignment()
			   local u = wesnoth.get_displayed_unit()
			   if not u then return {} end
			   local s = old_unit_alignment()
			   if u.status.tropic or u.status.frigid then
				  if u.status.tropic and u.status.sweltry then
					 table.insert(s, { "element", {                           
						text = ",<span color='#ffd505'>T</span><span color='#00ff00' size='small'>(2.0x)</span>",
						tooltip = "<span color='#ffd505'>Tropic:</span> Units with this ability will inflict double damage in hot and sweltry areas, and only half damage in cold and frigid areas."
					 } })
				  elseif u.status.tropic and u.status.frigid then
					 table.insert(s, { "element", {                           
						text = ",<span color='#ffd505'>T</span><span color='#FF9933' size='small'>(0.5x)</span>",
						tooltip = "<span color='#ffd505'>Tropic:</span> Units with this ability will inflict double damage in hot and sweltry areas, and only half damage in cold and frigid areas."
					 } })
				  elseif u.status.tropic then
					 table.insert(s, { "element", {                           
						text = ",<span color='#ffd505'>T</span><span size='small'>(1.0x)</span>",
						tooltip = "<span color='#ffd505'>Tropic:</span> Units with this ability will inflict double damage in hot and sweltry areas, and only half damage in cold and frigid areas."
					 } })
				  end
			    end
				return s
			end 
		 >>
		[/lua]
	[/event]

	[event]
        name=preload
        first_time_only=no
		[lua]
			code = << 
			local old_unit_alignment = wesnoth.theme_items.unit_alignment
			function wesnoth.theme_items.unit_alignment()
			   local u = wesnoth.get_displayed_unit()
			   if not u then return {} end
			   local s = old_unit_alignment()
			   if u.status.rustic then
				  if u.status.rustic and u.status.sweltry then
					 table.insert(s, { "element", {                           
						text = ",<span color='#E1E1E1'>R</span><span size='small'>(1.0x)</span>",
						tooltip = "<span color='#E1E1E1'>Rustic:</span> Most units with this ability inflict the same damage in all types of weather."
					 } })
				  elseif u.status.rustic and u.status.frigid then
					 table.insert(s, { "element", {                           
						text = ",<span color='#E1E1E1'>R</span><span size='small'>(1.0x)</span>",
						tooltip = "<span color='#E1E1E1'>Rustic:</span> Most units with this ability inflict the same damage in all types of weather."
					 } })
				  elseif u.status.rustic then
					 table.insert(s, { "element", {                           
						text = ",<span color='#E1E1E1'>R</span><span size='small'>(1.0x)</span>",
						tooltip = "<span color='#E1E1E1'>Rustic:</span> Most units with this ability inflict the same damage in all types of weather."
					 } })
				  end
			    end
				return s
			end 
		 >>
		[/lua]
	[/event]

#enddef



#define SECOND_ALIGNMENT_IMAGES

	[event]
        name=preload
        first_time_only=no
        [lua]
            code=<<
                local old_unit_alignment = wesnoth.theme_items.unit_alignment
                function wesnoth.theme_items.unit_alignment()
                    local u = wesnoth.get_displayed_unit()
                    if not u then return {} end
                    local s = old_unit_alignment()
                    if u.status.sweltry then
                        table.insert(s, { "element", {
                            image = "misc/sweltry.png",
                            tooltip = "sweltry: Tropic units in this area have a large damage increase. Arctic units have a large damage decrease."
                        } })
                    end
                    return s
                end
            >>
        [/lua]
    [/event]
	
	[event]
        name=preload
        first_time_only=no
        [lua]
            code=<<
                local old_unit_alignment = wesnoth.theme_items.unit_alignment
                function wesnoth.theme_items.unit_alignment()
                    local u = wesnoth.get_displayed_unit()
                    if not u then return {} end
                    local s = old_unit_alignment()
                    if u.status.frigid then
                        table.insert(s, { "element", {
                            image = "misc/frigid.png",
                            tooltip = "frigid: Arctic units in this area have a large damage decrease. Tropic units have a large damage increase."
                        } })
                    end
                    return s
                end
            >>
        [/lua]
    [/event]
#enddef

#define FLAG_VARIANT NAME
    # Enable the specified flag variant: centaur(fix), halfing(fix), knalgan, loyalist,
    # pagan(fix), ragged, saurian(fix), long, undead, or wood-elvish. 
    # Use within a [side] block; only affects that side.
    # Since the ragged variant has six frames instead of the usual four,
    # for that flag it's better to use FLAG_VARIANT6 below instead.
    # wmlscope: start ignoring
    flag=flags/{NAME}-flag-[1~4].png:150
    flag_icon=flags/{NAME}-flag-icon.png
    # wmlscope: stop ignoring
#enddef

#define FLAG_VARIANT6 NAME
    # Like FLAG_VARIANT, but this supports flags with six frames.
    # Currently only the ragged flag has six frames.
    # wmlscope: start ignoring
    flag=flags/{NAME}-flag-[1~6].png:150
    flag_icon=flags/{NAME}-flag-icon.png
    # wmlscope: stop ignoring
#enddef

#following macros from Uber Default#

#define MOVING_ANIM_DIRECTIONAL_6_FRAME BASE_IMAGE_NAME
	[movement_anim]
		start_time=0
		[if]
			direction=s,se,sw
			[frame]
				image={BASE_IMAGE_NAME}-se-run[1~6].png:100
			[/frame]
		[/if]
		[else]
			direction=n,ne,nw
			[frame]
				image={BASE_IMAGE_NAME}-ne-run[1~6].png:100
			[/frame]
		[/else]
	[/movement_anim]
#enddef