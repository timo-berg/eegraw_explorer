using Base: func_for_method_checked, structdiff
using GLMakie
using Statistics
include("load_eeglab.jl")


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

##

# Set up figure
fig = Figure(resolution = (2560, 1440))
axis = fig[1, 1] = Axis(fig, title = "EEG")

# native zoom
axis.yzoomlock = true
axis.xzoomlock = true
axis.xpanlock = true
axis.ypanlock = true
axis.xrectzoom = true
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
    draw_events(event_array)
end

# Scrolling zoom
on(events(fig).scroll, priority = 100) do scroll
    nsample_to_show_obs[] = clamp(nsample_to_show_obs[]+scroll[2]*30, 150, nsamples)
    xlims!(0,nsample_to_show_obs[])
    update_time_ticks(axis, slider.value[])
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