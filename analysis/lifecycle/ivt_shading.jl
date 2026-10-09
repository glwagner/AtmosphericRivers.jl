# Rasterize the high-IVT side, rather than filling arbitrary closed contour loops:
# low-IVT holes, open domain boundaries, and the satellite limb remain correct.

function ivt_geographic_position(x,y,projection)
    re,rp = projection["semi_major_axis"],projection["semi_minor_axis"]
    H = re+projection["perspective_point_height"]
    ratio = (re/rp)^2
    sx,cx,sy,cy = sin(x),cos(x),sin(y),cos(y)
    a = sx^2+cx^2*(cy^2+ratio*sy^2)
    b,c = -2H*cx*cy,H^2-re^2
    discriminant = b^2-4a*c
    discriminant < 0 && return (NaN,NaN)
    r = (-b-sqrt(discriminant))/(2a)
    X,Y,Z = r*cx*cy,-r*sx,r*cx*sy
    longitude = projection["longitude_of_projection_origin"]-rad2deg(atan(Y,H-X))
    latitude = rad2deg(atan(ratio*Z/hypot(H-X,Y)))
    longitude,latitude
end

function ivt_bilinear_location(longitude,latitude,λ,φ)
    isfinite(λ) && isfinite(φ) || return nothing
    λ = mod(λ,360)
    first(longitude) <= λ <= last(longitude) || return nothing
    first(latitude) <= φ <= last(latitude) || return nothing
    i = min(searchsortedlast(longitude,λ),length(longitude)-1)
    j = min(searchsortedlast(latitude,φ),length(latitude)-1)
    u = (λ-longitude[i])/(longitude[i+1]-longitude[i])
    v = (φ-latitude[j])/(latitude[j+1]-latitude[j])
    (; index=i+(j-1)*length(longitude),u,v)
end

function ivt_shading_lookup(longitude,latitude,projection,bounds; width=1920)
    xmin,xmax,ymin,ymax = bounds
    height = round(Int,width*(ymax-ymin)/(xmax-xmin))
    dx,dy = (xmax-xmin)/width,(ymax-ymin)/height
    xs = range(xmin+dx/2,xmax-dx/2;length=width)
    ys = range(ymin+dy/2,ymax-dy/2;length=height)
    pixels,indices = Int32[],Int32[]
    u,v = Float32[],Float32[]
    for (j,y) in enumerate(ys), (i,x) in enumerate(xs)
        λ,φ = ivt_geographic_position(x,y,projection)
        cell = ivt_bilinear_location(longitude,latitude,λ,φ)
        isnothing(cell) && continue
        push!(pixels,i+(j-1)*width); push!(indices,cell.index)
        push!(u,cell.u); push!(v,cell.v)
    end
    (; pixels,indices,u,v,size=(width,height),nx=length(longitude))
end

function shade_ivt!(pixels,lookup,ivt,threshold,color)
    transparent = RGBAf(0,0,0,0)
    @inbounds for k in eachindex(lookup.pixels)
        n = lookup.indices[k]
        u,v = lookup.u[k],lookup.v[k]
        lower = (1-u)*ivt[n]+u*ivt[n+1]
        upper = (1-u)*ivt[n+lookup.nx]+u*ivt[n+lookup.nx+1]
        value = (1-v)*lower+v*upper
        pixels[lookup.pixels[k]] = value >= threshold ? color : transparent
    end
    pixels
end
