# Included by animate.jl; shares its map styling and loaded data.
function animate_landfall(era5, model, coastline, output_dir; fps=8, preview=false)
    isnothing(model) && return
    title = Observable("")
    note = Observable("")
    field = Observable(model_frame(model,1))
    cursor = Observable([0.0])
    fig = Figure(size=(1600,1200),figure_padding=(40,35,20,20))
    Label(fig[0,1:2],"Landfall at 3 km",fontsize=36,font=:bold,halign=:left,tellwidth=false)
    Label(fig[1,1:2],title,fontsize=23,halign=:left,tellwidth=false)
    ax = map_axis(fig[2,1],"NumericalEarth.jl / Breeze.jl experimental hindcast";
                  longitude=(214,246),latitude=(39,55),fontsize=20)
    hm = heatmap!(ax,model.longitude,model.latitude,field;colormap=IVT_COLORS,colorrange=IVT_LIMITS,
                  interpolate=false,nan_color=colorant"#eff2f5",highclip=last(IVT_COLORS))
    overlays!(ax,coastline;detail=true)
    Colorbar(fig[2,2],hm;label="Integrated vapour transport (kg m⁻¹ s⁻¹)",ticks=0:400:1600,width=22)

    ci,cj = argmin(abs.(era5.longitude .- COAST[1])),argmin(abs.(era5.latitude .- COAST[2]))
    mi,mj = argmin(abs.(model.longitude .- COAST[1])),argmin(abs.(model.latitude .- COAST[2]))
    eidx = findall(t->first(model.dates)<=t<=last(model.dates),era5.dates)
    etimes = Dates.value.(era5.dates[eidx] .- first(model.dates)) ./ 3_600_000
    mtimes = Dates.value.(model.dates .- first(model.dates)) ./ 3_600_000
    ecoast = hypot.(era5.east[ci,cj,eidx],era5.north[ci,cj,eidx])
    mcoast = [model_frame(model,n)[mi,mj] for n in eachindex(model.dates)]
    ticks = collect(first(model.dates):Hour(12):last(model.dates))
    tick_hours = Dates.value.(ticks .- first(model.dates)) ./ 3_600_000
    axt = Axis(fig[3,1:2];title="Washington coast  •  48°N, 124.75°W",titlealign=:left,titlesize=18,
               ylabel="IVT (kg m⁻¹ s⁻¹)",ylabelsize=16,xticklabelsize=15,yticklabelsize=14,
               xticks=(tick_hours,Dates.format.(ticks,dateformat"u d HH:MM")),
               xgridvisible=false,ygridcolor=(:gray,0.12))
    lines!(axt,etimes,ecoast;color=ACCENT,linewidth=2.5,label="ERA5 • hourly")
    lines!(axt,mtimes,mcoast;color=colorant"#b3503d",linewidth=2,label="3 km hindcast • 30 min")
    vlines!(axt,cursor;color=INK,linewidth=2)
    hlines!(axt,[250];color=(MUTED,0.5),linestyle=:dash)
    xlims!(axt,0,last(mtimes));ylims!(axt,0,max(1500,100ceil(maximum(mcoast)/100)))
    axislegend(axt;position=:lt,orientation=:horizontal,framevisible=false,labelsize=14)
    Label(fig[4,1:2],note;fontsize=21,font=:bold,halign=:left,tellwidth=false)
    Label(fig[5,1:2],"1/36° model grid  •  30-minute snapshots  •  32 boundary cells masked  •  No temporal interpolation  •  AtmosphericRivers.jl",fontsize=15,color=MUTED,halign=:left,tellwidth=false)
    rowsize!(fig.layout,2,700);rowsize!(fig.layout,3,150);colsize!(fig.layout,2,75)
    rowgap!(fig.layout,12)
    function update(n)
        field[] = model_frame(model,n)
        title[] = Dates.format(model.dates[n],dateformat"u d, yyyy   HH:MM") * " UTC"
        note[] = event_caption(model.dates[n])
        cursor[] = [mtimes[n]]
    end
    update(49)
    save(joinpath(output_dir,"ar_landfall_3km.png"),fig)
    preview && return
    record(fig,joinpath(output_dir,"ar_landfall_3km.mp4"),eachindex(model.dates);framerate=fps,compression=18,px_per_unit=2) do n
        update(n)
    end
end
