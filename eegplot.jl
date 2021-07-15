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

##

# Set up figure
fig = Figure(resolution = (2560, 1440))
axis = fig[1, 1] = Axis(fig, title = "EEG")

# zoom
axis.yzoomlock = true
axis.xzoomlock = true


# Set up slider
slider = Slider(fig[2, 1], range = 1:1:nsamples-nsample_to_show, startvalue = 1)
slider_time = slider.value


# Plot EEG
for chan in 1:nchan
    data_chunk = @lift(data[chan,Int($slider_time):Int($slider_time)+nsample_to_show])
    chunk_mean = @lift(mean($data_chunk))
    data_chunk_plot = @lift($data_chunk .+ (-$chunk_mean + chan*offset) .* scale)
    
    lines!(axis, data_chunk_plot, color = :grey0)
end

# Set ticks
axis.yticks = (offset:offset:(nchan)*offset, chanlabels)
xtick_pos = 1:100:nsample_to_show
axis.xticks = (xtick_pos, ["$((x)/srate)s" for x in xtick_pos])
# dynamic time tick update
on(slider.value) do value
    xtick_pos = 1:100:nsample_to_show
    axis.xticks = (xtick_pos, ["$((value + x)/srate)s" for x in xtick_pos])
end

xlims!(0,nsample_to_show)

fig
##

# register_interaction!(axis, :my_interaction) do event::ScrollEvent, axis
#     nsample_to_show_obs[] = floor(Int, axis.limits.val.widths[1])
#     println(axis.limits.val.origin[1])
# end

# xlims!(axis, [0,500])