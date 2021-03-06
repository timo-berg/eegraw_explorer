using Base: func_for_method_checked, structdiff, Const
using GLMakie
using Statistics
using Colors
using Distributions
include("load_eeglab.jl")

##

# Ticks
"""
Create 10 x-ticks from 10% to 90% of the x-axis as time in seconds.
time_idx should be the lower bound of the plotted data.
"""
function set_time_ticks(axis, time_idx, plot_range)
    xtick_pos = LinRange(round(plot_range*0.1),round_int(plot_range*0.9), 10)
    # Convert x_pos to time
    xtick_pos_label = map(x->round((time_idx + x)/srate, digits=2), xtick_pos)
    axis.xticks = (xtick_pos, ["$(x)s" for x in xtick_pos_label])
end


# Events
"""
Check what events lines are in the current plot range and make them visible.
Make events outside of this range invisible.
"""
function redraw_event_markers(lines, lower_bound, upper_bound)
    # Check for visibility
    vis_events = lower_bound .< event_df[:,:latency] .< upper_bound
    
    for (event_idx, event) in enumerate(lines[vis_events])
        event.visible = true
    end
    for (event_idx, event) in enumerate(lines[.!vis_events])
        event.visible = false
    end
end

"""
Check what events tags are in the current plot range and make them visible.
Make events outside of this range invisible.
"""
function redraw_event_text(tags, event_df, lower_bound, upper_bound, tag_height)
    # Check for visibility
    vis_events = lower_bound .< event_df[:,:latency] .< upper_bound
    for tag in tags[vis_events]
        # Index of tag in unfiltered array
        idx_unfiltered = findfirst((x)-> x==tag, tags)
        # Observable position doesn't work for text -> manually update position
        corrected_lat = event_df[idx_unfiltered,:latency] - lower_bound
        tag.attributes.attributes[:position][] = (corrected_lat, tag_height)
        tag.visible = true
    end
    for tag in tags[.!vis_events]
        tag.visible = false
    end
end


# Reject regions mark time regions for rejection
"""
Create a new reject region at the passed region if it does not overlap with an exisiting one.
Stores the plot in the reject_plots array and its limits in reject_limits array.
"""
function create_new_reject_region!(axis, new_rect, reject_limits, reject_plots, slider_time, nsample_to_show_obs, lower_bound, upper_bound)
    start_idx = deepcopy(new_rect.origin[1]+max(1, slider_time-nsample_to_show_obs/2))
    end_idx = deepcopy(start_idx + new_rect.widths[1])
    overlaps = false
    for limit in reject_limits
        if limit[1] < start_idx < limit[2] || limit[1] < end_idx < limit[2]
            overlaps = true
        end
    end
    if !overlaps
        append!(reject_limits, [[start_idx, end_idx]])
        
        plot_start = @lift(max(0, start_idx-$lower_bound))
        plot_end = @lift(min(end_idx - $lower_bound, $upper_bound))
        y_lim = @lift([$(axis.finallimits).origin[2], $(axis.finallimits).widths[2]])
        y_height = @lift(abs($y_lim[1]-$y_lim[2]))
        draw_rect = @lift(FRect($plot_start, $y_lim[1], abs($plot_end-$plot_start), $y_height))
        append!(reject_plots, [draw_reject_region(axis, draw_rect)])
    end
end

"""
Check if reject region is under passed x-position.
Delete region from axis, plot_array, and region limits.
"""
function delete_reject_region(axis, position, reject_limits, reject_plots, slider_time, nsample_to_show_obs)
    for (region_idx, limit) in enumerate(reject_limits)
        if limit[1] < position+max(1, slider_time-nsample_to_show_obs/2) < limit[2]
            deleteat!(reject_limits, region_idx)
            delete!(axis, reject_plots[region_idx])
            deleteat!(reject_plots, region_idx)
        end
    end
end

"""
Draw a transparent rectangle that represents a region to be rejected
"""
function draw_reject_region(axis, rect)
    poly!(axis, rect, raw = true, visible = true, color = RGBAf0(1.0, 0.08, 0.58, 0.3), strokewidth = 0)
end

"""
Check what reject regions are in the current plot range and make them visible.
Make reject regions outside of this range invisible.
"""
function redraw_reject_regions(limits, plots, lower_bound, upper_bound)
    # Create dataframe with lower and upper bounds of the regions
    limits_df = DataFrame( lower=[], upper=[])
    for region in limits
        push!(limits_df, region)
    end
    # Check what regions are visible
    vis_regions = ((lower_bound .< limits_df[:,:lower] .< upper_bound)
                .| (lower_bound .< limits_df[:,:upper] .< upper_bound))

    for region in plots[vis_regions]
        region.visible = true
    end
    for region in plots[.!vis_regions]
        region.visible = false
    end
end

# Channel rejection
"""
Find channel that is closest to mouseposition at click and color it red.
If channel is marked already, unmark it.
"""
function mark_channel(axis, mouse_pos, channel_plots)
    mark_plot = Makie.pick(axis.scene, mouse_pos, 500)[1]
    # Lineplot is an actual EEG plot

    if mark_plot in channel_plots
        # If marked, unmark it
        if mark_plot.attributes.color[] == :red
            mark_plot.attributes.color = :grey0
        else
            mark_plot.attributes.color = :red
        end
    end

    findall(x -> x==mark_plot, channel_plots)
end


# Helper functions
"""
Check if mouse is inside scene.
"""
function is_mouseinside(scene)
    return Vec(scene.events.mouseposition[]) in pixelarea(scene)[]
end

"""
Take a rectangle with origin and widths and return the same rectangle but with
the origin in the lower left corner.
This ensures that widths are positive.
"""
function absrect(rectangle)
    origin = rectangle.origin
    widths = rectangle.widths
    opposite_corner = origin + widths
    new_origin = min.(origin, opposite_corner)
    new_widths = abs.(widths)
    new_rectangle = FRect(new_origin[1], new_origin[2], new_widths[1], new_widths[2])
end

"""
Select a time region in the plot when Left-Shift is hold.
Return the selected region.
"""
function select_rectangle(axis; blocking = false, priority = 2, strokewidth = 3.0, kwargs...)
    scene = axis.scene
    key = Keyboard.left_shift
    waspressed = Node(false)
    rect = Node(FRect(0, 0, 1, 1)) # plotted rectangle
    rect_ret = Node(FRect(0, 0, 1, 1)) # returned rectangle
    y_lim = @lift([$(axis.finallimits).origin[2], $(axis.finallimits).widths[2]])
    y_height = @lift(abs($y_lim[1]-$y_lim[2]))
    # Create an initially hidden rectangle
    plotted_rect = poly!(
        scene, rect, raw = true, visible = false, color = RGBAf0(1.0, 0.08, 0.58, 0.3), strokewidth = 0, transparency = false, kwargs...,
    )

    # Control key press and hold
    on(events(scene).keyboardbutton , priority=priority) do event
        # Start tracking on key press
        if event.key == key
            if event.action == Keyboard.press && is_mouseinside(scene)
                mp = mouseposition(scene)
                waspressed[] = true
                plotted_rect[:visible] = true # start displaying
                rect[] = FRect(mp[1], y_lim[][1], 0.0, y_height[])
                return Consume(blocking)
            end
        end
        # End if key is released
        if !(event.key == key && event.action == Keyboard.repeat)
            if waspressed[] # User has selected the rectangle
                waspressed[] = false
                r = absrect(rect[])
                w, h = widths(r)
                if w > 0.0 && h > 0.0 # Ensure that the rectangle has non0 size.
                    rect_ret[] = r
                end
            end
            # always hide if not the right key is pressed
            plotted_rect[:visible] = false # make the plotted rectangle invisible
            return Consume(blocking)
        end

        return Consume(false)
    end
    # Adapt rectangle depending on mouse position; only if currently tracking.
    on(events(scene).mouseposition, priority=priority) do event
        if waspressed[]
            mp = mouseposition(scene)
            mini = minimum(rect[])
            rect[] = FRect(mini[1], y_lim[][1], mp[1] - mini[1], y_height[])
            return Consume(blocking)
        end
        return Consume(false)
    end

    return rect_ret
end

"""
Disable Makie-native scroll zoom, pan scroll and rectangle zoom.
"""
function disable_native_zoom(axis)
    axis.yzoomlock = true
    axis.xzoomlock = true
    axis.xpanlock = true
    axis.ypanlock = true
    axis.xrectzoom = false
    axis.yrectzoom = false
end





"""
Make channels in mask visible and channels not in it invisible.
"""
function toggle_channel_visibility(channel_plots, mask)
    for (plot_idx, plot) in enumerate(channel_plots)
        if plot_idx in mask
            plot.visible = true
        else
            plot.visible = false
        end 
    end
end

"""
Find index of element in array. If element is not in array, return 0.
"""
function findfirst_zero(element, array)
    idx = findfirst(x-> x==element, array)
    if isnothing(idx)
        idx = 0
    end
    idx
end

"""
Round number to neares Integer.
"""
function round_int(x)
    round(Int, x)
end

"""
Check what event regions are in the current plot range and make them visible.
Make event regions outside of this range invisible.
"""
function redraw_event_regions(events, plots, lower_bound, upper_bound)
    # Create dataframe with lower and upper bounds of the regions
    # limits_df = DataFrame( lower=[], upper=[])
    # for event in events
    #     push!(limits_df, region)
    # end
    # Check what regions are visible
    vis_regions = ((lower_bound .< events[:,:latency] .< upper_bound)
                .| (lower_bound .< events[:,:latency] + events[:,:duration] .< upper_bound))

    for region in plots[vis_regions]
        region.visible = true
    end
    for region in plots[.!vis_regions]
        region.visible = false
    end
end

"""
Control a reasonable scale bar size.
"""
function get_scale_factor(scale)
    1/round(scale; digits=1)
end


"""
Plot the data and set up the various interactions.
"""
function data_plot(data,srate,event_df,chanlabels,title, path_to_output, output_file_name)
        
    # Output file
    io = open(path_to_output * output_file_name, "w")
    reject_chans = []

    # Data size
    nchan = size(data,1)
    nsamples = size(data,2)

    # Parameters to set
    offset = 5.0
    y_estate = offset*nchan
    nsample_to_show = 1000 # only for initial plotting

    tag_height = (nchan+5)*offset
    plot_high = (nchan+10)*offset
    plot_low = -offset
    event_upper_lim = tag_height/plot_high-0.01

    # Set up figure
    fig = Figure(resolution = (2560, 1440))
    axis = fig[1, 1] = Axis(fig, title = title)

    # disable native zoom
    disable_native_zoom(axis)

    # Set up time slider
    time_slider = Slider(fig[2, 1], range = 1:1:nsamples-nsample_to_show, startvalue = 1)
    slider_time = time_slider.value

    # Channel scroll
    channel_slider = IntervalSlider(fig[1, 2], range = 1:1:nchan, startvalues = (1,nchan), horizontal = false)
    channel_interval = channel_slider.interval

    # Time range to plot
    nsample_to_show_obs = Node(nsample_to_show)
    lower_bound = @lift(max(1, round_int($slider_time)-round_int($nsample_to_show_obs/2)))
    upper_bound = @lift(min(nsamples, $lower_bound+round_int($nsample_to_show_obs)))
    range = @lift([$lower_bound,$upper_bound])

    # Scale Observables
    scale_obs = Node(0.4)
    amp_scalable = Node(false)

    # Channel Observables
    offset_obs = Node(offset)

    # Plot EEG
    channel_plots = []
    for chan in 1:nchan
        # Get data chunk currently to be plottet
        data_chunk = @lift(data[chan,$range[1]:$range[2]])
        chunk_mean = @lift(mean($data_chunk))
        chan_pos = @lift(findfirst_zero(chan, ($channel_interval[1]:$channel_interval[2])))
        # Mean center, scale and shift to plot all channels above each other in y-direction
        data_chunk_plot = @lift((($data_chunk .-$chunk_mean)  .* $scale_obs) .+ $chan_pos*$offset_obs)
        append!(channel_plots, [lines!(axis, data_chunk_plot, color = :grey0)])
    end

    # Plot events as vertical lines
    event_lines = map(eachrow(event_df)) do event
        plot_pos = @lift(event.latency-$lower_bound)
        vlines!(axis, plot_pos, ymax=event_upper_lim, visible = false, color = :steelblue1)
    end

    # event_regions = map(eachrow(event_df)) do event
    #     plot_start = @lift(event.latency-$lower_bound)
    #     plot_end = @lift(min(event.latency + event.duration - $lower_bound, $upper_bound))
    #     y_lim = @lift([$(axis.finallimits).origin[2], $(axis.finallimits).widths[2]])
    #     y_height = @lift(abs($y_lim[1]-$y_lim[2]))
    #     draw_rect = @lift(FRect($plot_start, $y_lim[1], abs($plot_end-$plot_start), $y_height))

    #     poly!(axis, draw_rect, raw = true, visible = false, color = :steelblue1, strokewidth = 0)
    # end

    #TW SPECIFIC
    level_1 = ["experimentStart", "longBaselineStart",   "longBaselineWaypoint", "longBaselineTargetpoint", "intertrialBaselineStart", "intertrialBaselineTransitpoint", "intertrialBaselineTargetpoint", "intertrialBaselineStop", "triangleStart", "triangleTaskFirstpoint", "triangleTaskSecondpoint", "triangleTaskHomingtaskStart", "triangleTaskHomingtaskLocationConfirmed", "triangleTaskHomingtaskDistanceerror", "triangleStop", "longBaselineStop", "experimentStop"]
    level_2 = ["rotationStart", "rotationStop", "translationStart", "translationStop","triangleTaskPoleVisible", "triangleTaskPoleSpotted", "longBaselineSphereSpotted", "intertrialBaselineSphereSpotted"]
    level_3 = ["miniBaselineStart", "miniBaselineStop", "subtaskFinished"]
    # TW SPECIFIC

    # Plot event tag above event line
    event_tags = map(eachrow(event_df)) do event
        plot_pos = @lift(event.latency-$lower_bound)
        # TW SPECIFIC
        if event.event ??? level_1
            text!(axis.scene, event.event, position=(plot_pos,tag_height), offset=(0,30), align=(:center, :center), visible=false, color = :green)
        elseif event.event ??? level_2
            text!(axis.scene, event.event, position=(plot_pos,tag_height), offset=(0,10), align=(:center, :center), visible=false, color = :orange)
        else
            text!(axis.scene, event.event, position=(plot_pos,tag_height), offset=(0,-10), align=(:center, :center), visible=false, color = :red)
        end
        # TW SPECIFIC
        #text!(axis.scene, event.event, position=(plot_pos,tag_height), align=(:center, :center), visible=false, color = :black)
    end

    # Plot range changes (i.e. zoom or scroll)
    on(range) do value
        redraw_event_markers(event_lines, lower_bound[], upper_bound[])
        redraw_event_text(event_tags, event_df, lower_bound[], upper_bound[], tag_height)
        redraw_reject_regions(reject_limits, reject_plots, lower_bound[], upper_bound[])
        # redraw_event_regions(event_df, event_regions)
        set_time_ticks(axis, lower_bound[], nsample_to_show_obs[])
    end

    # Set initial ticks
    axis.yticks = (offset:offset:(nchan)*offset, chanlabels)
    axis.yticklabelsize = 10.0
    set_time_ticks(axis, 0, nsample_to_show_obs[])

    # Scrolling time/amplitude-zoom
    on(events(fig).scroll, priority = 100) do scroll
        if amp_scalable[]
            scale_obs[] = max(0, scale_obs[] + 0.01*scroll[2])
        else
            nsample_to_show_obs[] = clamp(nsample_to_show_obs[]-floor(scroll[2]*30), 150, nsamples)
        end
    end

    # Enable amplitude-zoom on left-ctrl hold
    on(events(fig).keyboardbutton) do event
        if event.key == Keyboard.left_control && event.action in (Keyboard.repeat, Keyboard.press)
            amp_scalable[] = true
        else
            amp_scalable[] = false
        end
    end

    # Color channel on click
    on(events(fig).mousebutton) do event
        if event.action == Mouse.press && event.button == Mouse.left
            mouse_pos = events(fig).mouseposition[]
            channel_id = mark_channel(axis, mouse_pos, channel_plots)
            if !isempty(channel_id) 
                if !(channel_id[1] in reject_chans)
                    append!(reject_chans, channel_id[1])
                else
                    deleteat!(reject_chans, findall(x->x==channel_id[1], reject_chans))
                end
            end
        end
        return Consume(false)
    end

    # Keyboard input
    on(events(fig).keyboardbutton) do event
        if event.action in (Keyboard.press, Keyboard.repeat)
            # Time-scroll on left/right arrow key
            if event.key == Keyboard.left
                set_close_to!(time_slider, max(1, slider_time[]-100))
            end
            if event.key == Keyboard.right
                set_close_to!(time_slider, min(slider_time[]+100, nsamples-nsample_to_show))
            end

            # Close file
            if event.key == Keyboard.p
                for chan_id in reject_chans
                    println(io, chan_id)
                end
                close(io)
            end
        end
        return Consume(false)
    end

    # Mark time windows
    rect = select_rectangle(axis)
    reject_limits = Array{Float32}[]
    reject_plots = []
    on(rect) do new_rect
        create_new_reject_region!(axis, new_rect, reject_limits, reject_plots, slider_time[], nsample_to_show_obs[], lower_bound, upper_bound)
    end

    # Delete time window on right click
    on(events(fig).mousebutton) do event
        if event.button == Mouse.right && event.action == Mouse.press
            mp_x = mouseposition(axis.scene)[1]
            delete_reject_region(axis, mp_x, reject_limits, reject_plots, slider_time[], nsample_to_show_obs[])
        end
    end


    # Time input
    time_input = Textbox(fig[2, 2], width = 100, validator = Float64, placeholder=string(nsample_to_show_obs[]/srate))
    time_value = time_input.stored_string


    on(time_value) do time_range
        new_range = min(parse(Float64, time_range), nsamples/srate)
        nsample_to_show_obs[] = round_int(new_range * srate)
    end

    # Update time zoom variables
    on(nsample_to_show_obs) do nsample
        xlims!(0,nsample)
        time_input.displayed_string = string(nsample/srate)
    end

    # Channel scroll
    on(channel_interval) do interval
        toggle_channel_visibility(channel_plots, (interval[1]:interval[2]))
        offset_obs[] = y_estate/(interval[2]-interval[1]+1)
        new_nchan = interval[2]-interval[1]+1
        new_chanlabels = chanlabels[interval[1]:interval[2]]
        axis.yticks = (offset_obs[]:offset_obs[]:(new_nchan)*offset_obs[], new_chanlabels)
    end

    # Inital event rendering
    redraw_event_markers(event_lines, lower_bound[], upper_bound[])
    redraw_event_text(event_tags, event_df, lower_bound[], upper_bound[], tag_height)

    # Set visible limits (doesn't affect plotted data)
    tightlimits!(axis, Left(), Right()) # No left/right margin
    ylims!(plot_low, plot_high)

    # Scalebar
    scale_x_pos = @lift([round_int($nsample_to_show_obs*0.98)])
    scale_y_pos = [round_int((plot_low + plot_high)/2)]
    scale_size = @lift($scale_obs*100/2) # Divide by 2 because it extends in both directions
    errorbars!(scale_x_pos, scale_y_pos, scale_size, color = :red, linewidth = 3, whiskerwidth = 10)

    # Scalelabel
    label_pos = @lift(($scale_x_pos[1], scale_y_pos[1]))
    label_offset = @lift((-round_int($nsample_to_show_obs*0.02), 0))
    label_text = string(100) * " ??V"

    text!(axis.scene, label_text, position = label_pos, color = :red, align=(:right, :center), offset = (-30, 0))


    fig
end
##


subject = 21

path = "/Users/timotheusberg/Documents/Work/BPN/triangle_walking/04_data/3_EEG-preprocessing/s$subject/"

input_file = "s$(subject)_preprocessed.set"

output_file = "s$(subject)_reject.txt"

data,srate,event_df,chanlocs_df,EEG = import_eeglab(path * input_file)

# Test data
time = 1:5000
sin_time = sin.(time./10).*50
test_data = repeat(transpose(sin_time), 128, 1)

chanlabels = chanlocs_df[:, :labels]

##

fig = data_plot(data,srate,event_df,chanlabels,input_file,path, output_file)

##
# PROBLEMS
# - make sure that nsample to display 
#   doesn't exceed data bounds and scroll when end is reached


# TODO
# - show amplitude scale
# - read in reject stuff
# - export reject regions

#
# OPTIONAL
# - show mini plot under time-scroll that visualizes position and zoom level
