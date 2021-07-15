using Base: func_for_method_checked
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
    xtick_pos = LinRange(50,nsample_to_show_obs[]-50, 10)
    axis.xticks = (xtick_pos, ["$((value + x)/srate)s" for x in xtick_pos])
end

##

# Set up figure
fig = Figure(resolution = (2560, 1440))
axis = fig[1, 1] = Axis(fig, title = "EEG")

# zoom
axis.yzoomlock = true
axis.xzoomlock = true

nsample_to_show_obs = Node(nsample_to_show)

on(events(fig).keyboardbutton , priority = 0) do event
    if event.action in (Keyboard.press, Keyboard.repeat)
        if event.key == Keyboard.a
            nsample_to_show_obs[] += 100
            xlims!(0,nsample_to_show_obs[])
            update_time_ticks(axis, slider.value[])
        end

        if event.key == Keyboard.s
            nsample_to_show_obs[] -= 100
            xlims!(0,nsample_to_show_obs[])
            update_time_ticks(axis, slider.value[])
        end
    end
    println(nsample_to_show_obs[])
    return Consume(false)
end


# Set up slider
slider = Slider(fig[2, 1], range = 1:1:nsamples-nsample_to_show, startvalue = 1)
slider_time = slider.value


# Plot EEG
for chan in 1:nchan
    range = @lift((Int($slider_time),Int($slider_time)+$nsample_to_show_obs))
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


xlims!(0,nsample_to_show_obs[])

fig
##


# xlims!(axis, [0,500])

