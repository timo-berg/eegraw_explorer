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

function draw_events(event_array)
    # Delete old events
    if !isempty(event_array)
        for i in 1:size(event_array)[1]
            delete!(axis, event_array[i])
        end
    end

    # Draw new events and store them in event array
    vis_events = evts_df[ lower_bound[] .< evts_df[:,:latency] .< upper_bound[],:]
    append!(event_array,[vlines!(axis, event.latency/srate, color = :red) for event in eachrow(vis_events)])
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
    key = Mouse.left
    waspressed = Node(false)
    rect = Node(FRect(0, 0, 1, 1)) # plotted rectangle
    rect_ret = Node(FRect(0, 0, 1, 1)) # returned rectangle
    y_lim = @lift([$(axis.finallimits).origin[2], $(axis.finallimits).widths[2]])
    y_height = @lift(abs($y_lim[1]-$y_lim[2]))
    # Create an initially hidden rectangle
    plotted_rect = poly!(
        scene, rect, raw = true, visible = false, color = RGBAf0(1.0, 0.08, 0.58, 0.3), strokewidth = 0, transparency = false, kwargs...,
    )

    on(events(scene).mousebutton, priority=priority) do event
        if event.button == key
            if event.action == Mouse.press && is_mouseinside(scene)
                mp = mouseposition(scene)
                waspressed[] = true
                plotted_rect[:visible] = true # start displaying
                rect[] = FRect(mp[1], y_lim[][1], 0.0, y_height[])
                return Consume(blocking)
            end
        end
        if !(event.button == key && event.action == Mouse.press)
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

# Set ticks
axis.yticks = (offset:offset:(nchan)*offset, chanlabels)
update_time_ticks(axis, 0)
# dynamic time tick update
on(slider.value) do value
    update_time_ticks(axis, value)
end

# Event plotting
event_array = []
on(range) do value
    # draw_events(event_array)
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

start_time = Node(0)
end_time = Node(1)
time_range = @lift($start_time+1:$end_time)
time_diff = @lift($end_time - $start_time)
lower_band = @lift(repeat([0], $time_diff))
upper_band = @lift(repeat([1000], $time_diff))
band!(time_range, lower_band, upper_band, color = :red)

on(events(fig).keyboardbutton) do event
    if event.action == Keyboard.press && event.key == Keyboard.left_shift
        start_time[] = events(fig).mouseposition[][1]
    end
    
    if event.action == Keyboard.release && event.key == Keyboard.left_shift
        end_time[] = events(fig).mouseposition[][1]
        println([start_time[], end_time[]])
    end
end

rect = select_rectangle(axis.scene)

on(rect) do value
    draw_reject_region(value)
    # poly!([221.92555, -644.2988, 183.09859, 14818.873])
end

# No left/right margin
tightlimits!(axis, Left(), Right())


set_window_config!(focus_on_show = true)
fig
##



# for i in 1:size(axis.scene.plots)[1]
#     if typeof(axis.scene.plots[i]) == LineSegments{Tuple{Base.ReinterpretArray{Point{2, Float32}, 1, Tuple{Point{2, Float32}, Point{2, Float32}}, Vector{Tuple{Point{2, Float32}, Point{2, Float32}}}, false}}}
#         delete!(axis, axis.scene.plots[i])
#     end
# end

