using Base: func_for_method_checked, structdiff, Const
using GLMakie
using Statistics
using Colors
include("load_eeglab.jl")
##

data,srate,evts_df,chanlocs_df,EEG = import_eeglab("sub35_preprocessed.set")


##

nchan = size(data,1)
nsamples = size(data,2)

chanlabels = chanlocs_df[:, :labels]

# Parameters to set
scale = 1
offset = 100
nsample_to_show = 1000


##

function update_time_ticks(axis, value)
    # xtick_pos = 1:100:nsample_to_show_obs[]
    xtick_pos = LinRange(Int(nsample_to_show_obs[]*0.1),Int(nsample_to_show_obs[]*0.9), 10)
    xtick_pos_label = map(x->round((value + x)/srate, digits=2), xtick_pos)
    axis.xticks = (xtick_pos, ["$(x)s" for x in xtick_pos_label])
end

function redraw_events(plots)
    # Draw new events and store them in event array
    vis_events = lower_bound[] .< evts_df[:,:latency] .< upper_bound[]
    for event in plots[vis_events]
        event.visible = true
    end
    for event in plots[.!vis_events]
        event.visible = false
    end
end

function redraw_reject_regions(limits, plots)
    limits_df = DataFrame( lower=[], upper=[])
    for region in limits
        push!(limits_df, region)
    end
    vis_regions = ((lower_bound[] .< limits_df[:,:lower] .< upper_bound[])
                .| (lower_bound[] .< limits_df[:,:upper] .< upper_bound[]))
    for region in plots[vis_regions]
        region.visible = true
    end
    for region in plots[.!vis_regions]
        region.visible = false
    end
end

function draw_reject_region(rect)
    poly!(axis, rect, raw = true, visible = true, color = RGBAf0(1.0, 0.08, 0.58, 0.3), strokewidth = 0)
end

function is_mouseinside(scene)
    return Vec(scene.events.mouseposition[]) in pixelarea(scene)[]
    # Check that mouse is not inside any other screen
    # for child in scene.children
    #     is_mouseinside(child) && return false
    # end
end

function absrect(rectangle)
    origin = rectangle.origin
    widths = rectangle.widths
    opposite_corner = origin + widths
    new_origin = min.(origin, opposite_corner)
    new_widths = abs.(widths)
    new_rectangle = FRect(new_origin[1], new_origin[2], new_widths[1], new_widths[2])
end

function select_rectangle(scene; blocking = false, priority = 2, strokewidth = 3.0, kwargs...)
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

    on(events(scene).keyboardbutton , priority=priority) do event
        if event.key == key
            if event.action == Keyboard.press && is_mouseinside(scene)
                mp = mouseposition(scene)
                waspressed[] = true
                plotted_rect[:visible] = true # start displaying
                rect[] = FRect(mp[1], y_lim[][1], 0.0, y_height[])
                return Consume(blocking)
            end
        end
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

##

# Set up figure
fig = Figure(resolution = (2560, 1440))
axis = fig[1, 1] = Axis(fig, title = "EEG")

# native zoom
axis.yzoomlock = true
axis.xzoomlock = true
axis.xpanlock = true
axis.ypanlock = true
axis.xrectzoom = false
axis.yrectzoom = false

# Set up slider
slider = Slider(fig[2, 1], range = 1:1:nsamples-nsample_to_show, startvalue = 1)
slider_time = slider.value

# Time range to plot
nsample_to_show_obs = Node(nsample_to_show)
lower_bound = @lift(max(1, Int($slider_time)-Int($nsample_to_show_obs/2)))
upper_bound = @lift(min(nsamples, $lower_bound+Int($nsample_to_show_obs)))
range = @lift([$lower_bound,$upper_bound])

# Plot EEG
for chan in 1:nchan
    data_chunk = @lift(data[chan,$range[1]:$range[2]])
    chunk_mean = @lift(mean($data_chunk))
    data_chunk_plot = @lift($data_chunk .+ (-$chunk_mean + chan*offset) .* scale)
    lines!(axis, data_chunk_plot, color = :grey0)
end

# Plot events
event_plots = map(evts_df.latency) do latency
    plot_pos = @lift(latency-$lower_bound)
    vlines!(axis, plot_pos, visible = false)
end
on(range) do value
    redraw_events(event_plots)
    redraw_reject_regions(reject_limits, reject_plots)
end

# Set ticks
axis.yticks = (offset:offset:(nchan)*offset, chanlabels)
update_time_ticks(axis, 0)
# dynamic time tick update
on(slider.value) do value
    update_time_ticks(axis, value)
end

# Scrolling zoom
on(events(fig).scroll, priority = 100) do scroll
    nsample_to_show_obs[] = clamp(nsample_to_show_obs[]+scroll[2]*30, 150, nsamples)
    xlims!(0,nsample_to_show_obs[])
    update_time_ticks(axis, slider.value[])
end

# Color channel on click
on(events(fig).mousebutton) do event
    if event.action == Mouse.press
        mouse_pos = events(fig).mouseposition[]
        mark_plot = Makie.pick(axis.scene, mouse_pos, 500)[1]
        if typeof(mark_plot) == Lines{Tuple{Vector{Point{2, Float32}}}}
            if mark_plot.attributes.color[] == :red
                mark_plot.attributes.color = :grey0
            else
                mark_plot.attributes.color = :red
            end
        end
    end
    return Consume(false)
end


# Mark time windows
rect = select_rectangle(axis.scene)
reject_limits = Array{Float32}[]
reject_plots = []
on(rect) do new_rect
    start_idx = deepcopy(new_rect.origin[1]+max(1, slider_time[]-nsample_to_show_obs[]/2))
    end_idx = deepcopy(start_idx + new_rect.widths[1])
    append!(reject_limits, [[start_idx, end_idx]])
    
    plot_start = @lift(max(0, start_idx-$lower_bound))
    plot_end = @lift(min(end_idx - $lower_bound, $upper_bound))
    y_lim = @lift([$(axis.finallimits).origin[2], $(axis.finallimits).widths[2]])
    y_height = @lift(abs($y_lim[1]-$y_lim[2]))
    draw_rect = @lift(FRect($plot_start, $y_lim[1], abs($plot_end-$plot_start), $y_height))
    append!(reject_plots, [draw_reject_region(draw_rect)])
    println(plot_start[])
    println(draw_rect[])
end

# No left/right margin
tightlimits!(axis, Left(), Right())
ylims!(-offset*scale, (1+nchan)*offset*scale)

set_window_config!(focus_on_show = true)
fig
##

# TODO
# - delete reject region on right click
# - prevent creation of overlapping reject vis_regions
# - add event tags http://makie.juliaplots.org/stable/plotting_functions/text.html#text
# - add scroll via arrow keys
#
# OPTIONAL
# - add channel scroll
