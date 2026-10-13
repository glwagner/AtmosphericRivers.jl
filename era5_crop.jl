# Cut ERA5 files for sub-regions out of a larger cached download, so a parent built over new regions
# (NumericalEarth #750's boundary strips) reads the cache instead of queueing CDS requests.
#
# NumericalEarth reads a file by coordinate value (`set_region_data!` offsets into the file by the
# target grid's first center), so any file whose lon/lat axes cover the target's native cells works.
# The crop keeps the same 2-cell margin the CDS request adds (`padded_era5_region`) (enough: a bbox edge on the 0.25° lattice is itself a native cell centre).

using NumericalEarth.DataWrangling: Metadatum, metadata_path
const NCDatasetsModule = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "NCDatasets")

function crop_era5_file(source, destination, longitude, latitude; margin)
    NCDatasetsModule.NCDataset(source) do src
        λ = src["longitude"][:]
        φ = src["latitude"][:]
        is = findall(x -> longitude[1] - margin ≤ x ≤ longitude[2] + margin, λ)
        js = findall(y -> latitude[1] - margin ≤ y ≤ latitude[2] + margin, φ)
        (minimum(λ) ≤ longitude[1] - margin + 1e-6 && maximum(λ) ≥ longitude[2] + margin - 1e-6 &&
         minimum(φ) ≤ latitude[1] - margin + 1e-6 && maximum(φ) ≥ latitude[2] + margin - 1e-6) ||
            error("$source does not cover lon $longitude, lat $latitude (± $margin)")
        ranges = Dict("longitude" => first(is):last(is), "latitude" => first(js):last(js))

        tmp = destination * ".tmp"
        NCDatasetsModule.NCDataset(tmp, "c") do dst
            for (name, n) in src.dim
                NCDatasetsModule.defDim(dst, name, haskey(ranges, name) ? length(ranges[name]) : n)
            end
            for (k, v) in src.attrib
                dst.attrib[k] = v
            end
            for name in keys(src)
                v = src[name]
                dims = NCDatasetsModule.dimnames(v)
                idx = Tuple(get(ranges, d, Colon()) for d in dims)
                raw = v.var   # undecoded storage: no scale/offset/fill conversion
                attrib = Dict(k => a for (k, a) in v.attrib)
                fill = pop!(attrib, "_FillValue", nothing)
                kw = isnothing(fill) ? (;) : (; fillvalue = fill)
                out = NCDatasetsModule.defVar(dst, name, eltype(raw), dims; attrib = collect(attrib), kw...)
                isempty(dims) ? (out.var[] = raw[]) : (out.var[:] = raw[idx...])
            end
        end
        mv(tmp, destination; force = true)
    end
    return destination
end

"""
    crop_era5_regions!(regions, source_region, dataset, names, dates, dir; single_level = (), margin = 0.5)

For every `region` in `regions`, every variable in `names` and every date, write the file NumericalEarth
would download for that region by cropping the cached file for `source_region`. Existing files are kept.
`single_level` lists `(dataset, name, date)` triples handled the same way.
"""
function crop_era5_regions!(regions, source_region, dataset, names, dates, dir; single_level = (), margin = 0.5)
    made = 0
    crop(ds, name, date, region) = begin
        dst = metadata_path(Metadatum(name; dataset = ds, date, region, dir))
        isfile(dst) && return
        src = metadata_path(Metadatum(name; dataset = ds, date, region = source_region, dir))
        isfile(src) || error("no cached source for $name at $date over $source_region: $src")
        crop_era5_file(src, dst, region.longitude, region.latitude; margin)
        made += 1
    end
    for region in regions, name in names, date in dates
        crop(dataset, name, date, region)
    end
    for region in regions, (ds, name, date) in single_level
        crop(ds, name, date, region)
    end
    return made
end
