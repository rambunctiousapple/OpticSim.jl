
# MIT license
# Copyright (c) Microsoft Corporation. All rights reserved.
# See LICENSE in the project root for full license information.


using Roots
import DataFrames
import OpticSim.Repeat

# luminance (cd/m2)	Multiple	Value	Item
# 10−6	µcd/m2	1 µcd/m2	Absolute threshold of vision[1]
# 10−5			
# 10−4		400 µcd/m2	Darkest sky[2]
# 10−3	mcd/m2	1 mcd/m2	Night sky[3]
# 1.4   mcd/m2	Typical photographic scene lit by full moon[4]
# 5     mcd/m2	Approximate scotopic/mesopic threshold[5]
# 10−2		40 mcd/m2	Phosphorescent markings on a watch dial after 1 h in the dark[6][7]
# 10−1			
# 100	cd/m2	2 cd/m2	Floodlit buildings, monuments, and fountains[8]
# 5     cd/m2	Approximate mesopic/photopic threshold[5]
# 101		25 cd/m2	Typical photographic scene at sunrise or sunset[4]
# 30    cd/m2	Green electroluminescent source[2]
# 102		250 cd/m2	Peak luminance of a typical LCD monitor[10][11]
# 700   cd/m2	Typical photographic scene on overcast day[4][8][11]
# 103	kcd/m2	2 kcd/m2	Average cloudy sky[2]
# 5     kcd/m2	Typical photographic scene in full sunlight[4][8]



colorbasis(::Repeat.HexBasis1) = SMatrix{2,2}(2, -1, 1, 1)
colorbasis(::Repeat.HexBasis3) = SMatrix{2,2}(2, -1, 1, 1)
colororigins(::Repeat.HexBasis1) = ((0, 0), (-1, 0), (-1, 1))
colororigins(::Repeat.HexBasis3) = ((0, 0), (0, -1), (1, -1))

"""To reduce color channel cross talk it may be useful to arrange the color of lenslets in a hexagonal lattice so that each color is surrounded by lenslets of a different color. With appropriate color filtering crosstalk between immediately neighboring lenslets can be reduced. This function computes the color which should be assigned to any lattice point to ensure this property holds."""
function pointcolor(point, cluster::Repeat.AbstractLatticeCluster)
    latticematrix = colorbasis(Repeat.elementbasis(cluster))
    origins = colororigins(Repeat.elementbasis(cluster))
    colors = zip(origins, ("red", "green", "blue"))
    for (origin, color) in colors
        if nothing !== Repeat.latticepoint(latticematrix, origin, point)
            return color
        end
    end
end
export pointcolor

defaultclusterproperties() = (mtf = .2, minfnumber = 2.0, cyclesperdegree = 11, λ = 530nm, pixelpitch = .9μm)
export defaultclusterproperties

"""maximum allowable display for visibility reasons"""
maxlensletdisplaysize() = (250μm, 250μm)


const ρ_quartervalue = 2.21509 # value of ρ at which the airy disk function has magnitude .25
export ρ_quartervalue
const ρ_zerovalue = 3.832 # value of ρ at which the airy disk function has magnitude 0

"""given pixelpitch and angular subtense (in degrees) of pixel returns focal length"""
focallength(pixelpitch::Unitful.Length,θ) = uconvert(mm, .5 * pixelpitch / tand(θ / 2))
export focallength

"""returns the diffraction limit frequency in cycles/deg

focal length = 𝒇𝒍
diffraction cutoff frequency,fc, in cycles/mm = 1/λF# = diameter/λ*𝒇𝒍
cutoff wavelength, Wc, = 1/cutoff frequency = λ*𝒇𝒍/diameter

angular wavelength, θc, radians/cycle, corresponding to cutoff wavelength:

θ ≈ tanθ for small θ
θc corresponding to Wc:  θc ≈ tanθ = Wc/𝒇𝒍
Wc = θc*𝒇𝒍

from equation for Wc:

λ*𝒇𝒍/diameter = Wc = θc*𝒇𝒍
θc = λ/diameter
cycles/rad = 1/θc = diameter/λ

"""
cyclesperdegree(diameter::Unitful.Length,λ::Unitful.Length) = uconvert(Unitful.NoUnits, diameter / (rad2deg(1) * λ))
export cyclesperdegree

"""diffraction limited response for a circular aperture, normalized by maximum cutoff frequency"""
function mtfcircular(freq, freqcutoff) 
    s =  freq / freqcutoff
    return 2 / π * (acos(s) - s * ((1 - s^2)^.5))
end
export mtfcircular

"""returns the diffraction limit frequency in cycles/degree. At this frequeny the response of the system is zero"""
diffractionlimit(λ::Unitful.Length,diameter::Unitful.Length) = uconvert(Unitful.NoUnits, diameter / λ) / rad2deg(1)
export diffractionlimit

"""computes the diameter of a diffraction limited lens that has response mtf at frequency cyclesperdeg"""
function diameter_for_cycles_deg(mtf, cyclesperdeg, λ::Unitful.Length)
    cyclesperrad = rad2deg(1) * cyclesperdeg
    f(x) = mtfcircular(x, 1.0) - mtf
    normalizedfrequency = find_zero(f, (0.0, 1.0))
    fc = cyclesperrad / normalizedfrequency
    return uconvert(mm, λ * fc)
end
export diameter_for_cycles_deg

airydisk(ρ) = (2 * SpecialFunctions.besselj1(ρ) / ρ)^2

"""The f# required for the first zero of the airy diffraction disk to be at the next sample point"""
diffractionfnumber(λ::Unitful.Length,pixelpitch::Unitful.Length,indexofrefraction) = uconvert(Unitful.NoUnits, pixelpitch / (2.44λ / indexofrefraction))
export diffractionfnumber

"""returns ρ, the normalized distance, at which the airy disk will have the value airyvalue"""
function ρatairyvalue(airyvalue)
    ρ = 1e-5 # start at small angle
    while airydisk(ρ) > airyvalue
        ρ += 1e-5 # numerical precision not an issue here
    end
    return ρ
end
export ρatairyvalue

""" Spacing between lenslets which guarantess that for any pixel visible in all lenslets every point on the eyebox plane is covered. This is closest packing of circles."""
closestpackingdistance(pupildiameter::Unitful.Length) = pupildiameter * cosd(30)
export closestpackingdistance

"""Tries clusters of various sizes to choose the largest one which fits within the eye pupil. Larger clusters allow for greater reduction of the fov each lenslet must cover so it returns the largest feasible cluster"""
function choosecluster(pupildiameter::Unitful.Length, lensletdiameter::Unitful.Length)
    clusters = (hex3RGB(), hex4RGB(), hex7RGB(), hex9RGB(), hex12RGB(), hex19RGB())
    # cdist = closestpackingdistance(pupildiameter)
    cdist = pupildiameter
    maxcluster = clusters[1]
    ratio = 0.0

    for cluster in clusters
        temp = cdist / (lensletdiameter * Repeat.latticediameter(cluster))
            if temp >= 1.0
            ratio = temp
            maxcluster = cluster
        else
            break
        end
    end

    @assert ratio ≥ 1.0 "ratio $ratio cdist $cdist lensletdiameter $lensletdiameter Repeat.latticediameter $(Repeat.latticediameter(maxcluster)) scaled=$(lensletdiameter * Repeat.latticediameter(maxcluster))"

    return (cluster = maxcluster, lensletdiameter = lensletdiameter * ratio, diameteroflattice = Repeat.latticediameter(maxcluster) / ratio, packingdistance = cdist * ustrip(mm, lensletdiameter))
end
export choosecluster

"""Computes the largest feasible cluster size meeting constraints"""
function choosecluster(pupildiameter::Unitful.Length, λ::Unitful.Length, mtf, cyclesperdeg::T) where {T <: Real} 
    diam = diameter_for_cycles_deg(mtf, cyclesperdeg, λ)
    return choosecluster(pupildiameter, diam) # use minimum diameter for now.
end

"""Computes display size assuming lenslet normal to eyebox plane passes through lenslet. This is an approximation but for the narrow fov we are considering it is accurate enough to estimate pixel redundandcy, etc."""
function sizeoflensletdisplay(eyerelief::T, eyebox::AbstractVector{T}, ppd, pixelpitch::S) where {T <: Unitful.Length,S <: Unitful.Length}
    θ = eyeboxangles(eyebox, eyerelief)
    displaysize = @.  θ * ppd * pixelpitch
    return uconvert.(mm, displaysize)
end
export sizeoflensletdisplay

"""This computes the approximate size of the entire display, not the individual lenslet displays."""
sizeofdisplay(fov,eyerelief) = @. 2 * tand(fov / 2) * eyerelief
export sizeofdisplay

"""Computes the number of lenslets required to create a specified field of view at the given eyerelief"""
function numberoflenslets(fov, eyerelief::Unitful.Length, lensletdiameter::Unitful.Length)
    lensletarea = π * (lensletdiameter / 2)^2
    dispsize = sizeofdisplay(fov, eyerelief)
     return dispsize[1] * dispsize[2] / lensletarea
end
export numberoflenslets


"""given the angles each lenslet has to cover compute the corresponding display size"""
sizeoflensletdisplay(angles,ppd,pixelpitch::Unitful.Length) = @. angles * ppd * pixelpitch

"""angular size of the eyebox when viewed from distance eyerelief"""
eyeboxangles(eyebox,eyerelief) = @. atand(uconvert(Unitful.NoUnits, eyebox / eyerelief))
export eyeboxangles

"""computes how the fov can be subdivided among lenslets based on cluster size. Assumes the horizontal size of the eyebox is larger than the vertical so the larger number of subdivisions will always be the first number in the returns Tuple."""
function anglesubdivisions(pupildiameter::Unitful.Length, λ::Unitful.Length, mtf, cyclesperdegree;RGB=true)
    cluster, _ = choosecluster(pupildiameter, λ, mtf, cyclesperdegree)
    numelements = Repeat.clustersize(cluster)
    if numelements == 19
        return RGB ? (3, 2) : (5, 3)
    elseif numelements == 12
        return RGB ? (2, 2) : (4, 3)
   elseif numelements == 9
        return RGB ? (3, 1) : (3, 3)
    elseif numelements == 7
        return RGB ? (3, 1) : (3, 2) 
    elseif numelements == 4 || numelements == 3
        return RGB ? (1, 1) : (3, 1)
    else throw(ErrorException("this should never happen"))
    end
end
export anglesubdivisions


"""Computes the approximate fov required of each lenslet for the given constraints. This is strictly correct only for a lenslet centered in front of the eyebox, but the approximation is good enough for high level analysis"""
function lensletangles(eyerelief::Unitful.Length, eyebox::NTuple{2,Unitful.Length}, pupildiameter::Unitful.Length, ppd; clusterproperties=defaultclusterproperties(), RGB=true)
    cyclesperdegree = ppd / 2.0
    return eyeboxangles(eyebox, eyerelief) ./ anglesubdivisions(pupildiameter, clusterproperties.λ, clusterproperties.mtf, clusterproperties.cyclesperdegree, RGB=RGB)
end
export lensletangles

testangles() = lensletangles(18mm, (10mm, 6mm), 4mm, 45)
export testangles

lensletresolution(angles,ppd) = angles .* ppd

"""Multilens displays tradeoff pixel redundancy for a reduction in total track of the display, by using many short focal length lenses to cover the eyebox. This function computes the ratio of pixels in the multilens display vs. a conventional display of the same nominal resolution"""
function pixelredundancy(fov, eyerelief::Unitful.Length, eyebox::NTuple{2,Unitful.Length}, pupildiameter::Unitful.Length, ppd; RGB=true)
    lensprops = defaultclusterproperties()
    clusterdata = choosecluster(pupildiameter, lensprops.λ, lensprops.mtf, lensprops.cyclesperdegree)
    nominalresolution = fov .* ppd
    angles = lensletangles(eyerelief, eyebox, pupildiameter, ppd, RGB=RGB)
    pixelsperlenslet = angles .* ppd
    numlenses = numberoflenslets(fov, eyerelief, clusterdata.lensletdiameter)
    return (numlenses * pixelsperlenslet[1] * pixelsperlenslet[2]) / ( nominalresolution[1] * nominalresolution[2])
end
export pixelredundancy

testpixelredundancy() = pixelredundancy((55, 35), 18mm, (10mm, 6mm), 4mm, 45, RGB=false)
export testpixelredundancy

label(color) = color ? "RGB" : "Monochrome"

"""generates a contour plot showing pixel redundancy as a function of ppd and pupil diameter"""
function redundancy_ppdvspupildiameter()
    x = 20:2:45
    y = 3.0:.05:4

    RGB = true
    Plots.plot(Plots.contour(x, y, (x, y) -> pixelredundancy((50, 35), 18mm, (10mm, 6mm), y * mm, x, RGB=RGB), fill=true, xlabel="pixels per degree", ylabel="pupil diameter", legendtitle="pixel redundancy", title="$(label(RGB)) lenslets"))
end
export redundancy_ppdvspupildiameter

"""computes lenslet display size to match the design constraints"""
function lensletdisplaysize(fov, eyerelief::Unitful.Length, eyebox::NTuple{2,Unitful.Length}, pupildiameter::Unitful.Length, ppd; RGB=true)
    lensprops = defaultclusterproperties()
    angles = lensletangles(eyerelief, eyebox, pupildiameter, ppd, RGB=RGB)
    return @. angles * ppd * lensprops.pixelpitch
end
export lensletdisplaysize

testlensletdisplaysize() = lensletdisplaysize((55, 35), 18mm, (10mm, 6mm), 4mm, 30, RGB=true)
export testlensletdisplaysize

"""generates a contour plot of lenslet display size as a function of ppd and pupil diameter"""
function displaysize_ppdvspupildiameter()
    x = 20:2:45
    y = 3.0:.05:4
    RGB = true

    Plots.plot(Plots.contour(x, y, (x, y) -> maximum(ustrip.(μm, lensletdisplaysize((50, 35), 18mm, (10mm, 6mm), y * mm, x, RGB=RGB))), fill=true, xlabel="pixels per degree", ylabel="pupil diameter", legendtitle="display size μm", title="$(label(RGB)) lenslets"))
end
export displaysize_ppdvspupildiameter

""" Compute high level properties of a lenslet display system. Uses basic geometric and optical constraints to compute approximate values which should be within 10% or so of a real physical system.

`eyerelief` is in mm: `18mm` not `18`.

`eyebox` is a 2 tuple of lengths, also in mm, that specifies the size of the rectangular eyebox, assumed to lie on vertex of the cornea when the eye is looking directly forward.

`fov` is the field of view of the display as seen by the eye, in degrees (no unit type necessary here).

`pupildiameter` is the diameter of the eye pupil in mm.

`mtf` is the MTF response of the system at the angular frequency `cyclesperdegree`.

`pixelsperdegree` is the number of pixels per degree on the display, as seen by the eye through the lenslets. This is not a specification of the optical resolution of the system (use `mtf` and `cyclesperdegree` for that). It is a physical characteristic of the display.

Example:
```
julia> systemproperties(18mm,(10mm,9mm),(55°,45°),4.0mm,.2,11,30)
(lenslet_diameter = 0.7999999999999999 mm, diffraction_limit = 26.344592482933276, fnumber = 1.9337325040249893, focal_length = 1.5469860032199914 mm, display_size = (18.740413819862866 mm, 14.911688245431423 mm), lenslet_display_size = (261.4914368916943 μm, 358.6281908905529 μm), total_silicon_area = 52.1360390897504 mm^2, number_lenslets = 555.9505147668694, pixel_redundancy = 28.895838544429424 °^-2, eyebox_angles = (29.054604099077146, 26.56505117707799), lenslet_fov = (9.684868033025715, 13.282525588538995), subdivisions = (3, 2))
```
"""
function systemproperties(eyerelief::Unitful.Length, eyebox::NTuple{2,Unitful.Length}, fov, pupildiameter::Unitful.Length, mtf, cyclesperdegree,pixelsperdegree; minfnumber=2.0,RGB=true,λ=530nm,pixelpitch=.9μm)
    diameter = diameter_for_cycles_deg(mtf, cyclesperdegree, λ)
    clusterdata = choosecluster(pupildiameter, diameter)
    difflimit = diffractionlimit(λ, clusterdata.lensletdiameter)
    numlenses = numberoflenslets(fov, eyerelief, clusterdata.lensletdiameter)
    redundancy = pixelredundancy(fov, eyerelief, eyebox, pupildiameter, difflimit, RGB=RGB)
    subdivisions = anglesubdivisions(pupildiameter, λ, mtf, cyclesperdegree, RGB=RGB)
    eyebox_angles = eyeboxangles(eyebox,eyerelief)
    angles = lensletangles(eyerelief, eyebox, pupildiameter, difflimit, clusterproperties=(mtf = mtf, minfnumber = minfnumber, cyclesperdegree = cyclesperdegree, λ = λ, pixelpitch = pixelpitch))
    dispsize = lensletdisplaysize(angles, eyerelief, eyebox, pupildiameter, pixelsperdegree, RGB=RGB)
    focal_length = focallength(pixelpitch,1/pixelsperdegree)
    fnumber = focal_length/clusterdata.lensletdiameter
    siliconarea = uconvert(mm^2,numlenses  * dispsize[1]*dispsize[2])
    fulldisplaysize = sizeofdisplay(fov,eyerelief)

    return (cluster_data = clusterdata, lenslet_diameter = clusterdata.lensletdiameter, diffraction_limit = difflimit, fnumber = fnumber, focal_length = focal_length, display_size = fulldisplaysize, lenslet_display_size = dispsize, total_silicon_area = siliconarea, number_lenslets = numlenses, pixel_redundancy = redundancy, eyebox_angles = eyebox_angles, lenslet_fov = angles, subdivisions = subdivisions)
end
export systemproperties

"""prints system properties nicely"""
function printsystemproperties(eyerelief::Unitful.Length, eyebox::NTuple{2,Unitful.Length}, fov, pupildiameter::Unitful.Length, mtf, cyclesperdegree,pixelsperdegree; minfnumber=2.0,RGB=true,λ=530nm,pixelpitch=.9μm) 
    println("eye relief = $eyerelief")
    println("eye box = $eyebox")
    println("fov = $(fov)°")
    println("pupil diameter = $pupildiameter")
    println("mtf = $mtf @ $cyclesperdegree cycles/degree")
    props = systemproperties(eyerelief, eyebox, fov, pupildiameter, mtf, cyclesperdegree,pixelsperdegree, minfnumber = minfnumber,RGB=RGB,λ=λ,pixelpitch=pixelpitch)
    for (key,value) in pairs(props)
        if key == :diffraction_limit
            println("$key = $value cycles/°")
        else
            println("$key = $value")
        end
    end
    clusterdiameter = props[:cluster_data][:diameteroflattice]
    println("cluster diameter (approx): $(props[:lenslet_diameter]*clusterdiameter)")
end
export printsystemproperties


