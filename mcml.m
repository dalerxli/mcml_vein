function [] = mcml_vein(file, runnum)
%MCML_VEIN Multi-layered Monte Carlo simulation, line source, vein present
%
%   Illumination width = 50 mm
%   (Illumination length =  mm) (not required information)
%   Detection width = 40 mm
%   Detection length = 40 mm
%   Bin resolution = 0.05 mm
%
%CONSTANTS (contained in params struct)
%   rusnum   number of scatters before Russian roulette engaged
%   rusfrac   fraction of occurances where photon survives roulette
%   kftn   number of groups of thousands of photons
%   g   anisotropy factor
%   g2   g^2
%   nrel   relative index of refraction (FROM tissue TO air)
%   musp   reduced scattering coefficient (mm^-1)
%   mua   absorption coefficient (mm^-1)
%   mutp   reduced total interaction coefficient (mm^-1)
%   mut   total interaction coefficient (mm^-1)
%   albedo   scattering albedo
%   zb   total depth to boundary (mm)
%   dv   depth to top of vein along central axis (mm)
%   rv   vein radius (mm)
%
%VARIABLES (contained in ftn struct)
%   x[3]   Cartesian coordinates
%   ct[3]   direction cosines
%   nrus   total number of scatters
%   wt   photon weight
%   layer   epidermis(1), dermis(2), subcutis(3), vein(4), "muscle"(5)
%
%OTHER
%   s   pathlength (mm)

% Seed the random number generator based on the current time
rndseed = sum(100*clock);
stream = RandStream('mt19937ar','Seed',rndseed);
RandStream.setGlobalStream(stream);

%disp(['Processing file ',file])

load(file); % Loads input MAT file containing params struct

dbin = zeros(800, 800); % Zero the detection bins

tic; % Start timer for performance measurements

for ftncount = 1:(1000*params.kftn)
    
    local_dbin = zeros(800, 800);
    
    ftn = struct;
    ftn = ftnini(); % Launch photon
    
    % Main portion of code
    while (ftn.wt > 1e-16)
        [ftn, local_dbin] = tissue(ftn, params, local_dbin);
        
        if ftn.wt <= 1e-6 % Photon weight is too small
            ftn.wt = 0;
        end
        
        if realsqrt(ftn.x(1)^2+ftn.x(2)^2) >= 50 % Photon is too far away (x & y dir only)
            ftn.wt = 0;
        end
        
        if ftn.nrus >= params.rusnum % Photon has scattered too many times
            if rand <= params.rusfrac
                ftn.nrus = -10*ftn.nrus; % Reset number of scatters
                ftn.wt = ftn.wt/params.rusfrac; % Correct weight for roulette
            else
                ftn.wt = 0;
            end
        end
        
    end
    
    dbin = dbin + local_dbin;
end

delta_t = toc; % Stop timer for performance measurements, output time

outfile = strcat(file(1:end-4),'_output',sprintf('%04d',str2num(runnum)),'.mat'); % Create output file name
save(outfile, 'dbin', 'params', 'delta_t', 'rndseed')

end

function ftn = ftnini()
%FTNINI Initialize photon

ftn.x(1) = (rand - 0.5)*50; % -25 mm <= x(1) <= 25 mm
ftn.x(2) = 0; % Line source along y = 0
ftn.x(3) = 0; % Launched at surface

ftn.ct = [0, 0, 1]; % Launch straight down (+z) into tissue

ftn.nrus = 0;
ftn.wt = 1;
ftn.layer = 1; % ftn.layer = 1 for epidermis

end

function [ftn, local_dbin] = tissue(ftn, params, local_dbin)
%TISSUE Map out next step in tissue

s = -log(rand)/params.mut(ftn.layer); % Sample for new pathlength
[db, layer2] = distbound(ftn, params); % Determine distance to boundary along current direction vector
[dv, layer3] = distvein(ftn, params); % Determine distance to vein along current direction vector

% Is the step size greater than the distance to the boundary or vein?
if dv >= 0 && dv <= s && dv < db % The photon encounters the vein
    s = dv;
    ftn.layer = layer3;
    ftn.x = ftn.x + s*ftn.ct; % Move to new position on vein boundary
elseif db > 0 && db <= s && db < dv % The photon encounters the boundary
    s = db;
    if layer2 == 5 % layer = 4 is reserved for inside vein
        ftn.wt = 0;
    elseif layer2 == 0
        ftn.x = ftn.x + s*ftn.ct; % Move to new position at surface
        
        % Determine whether to reflect or refract
        bscwt = fresnel(params.nrel, ftn.ct);
        if rand <= bscwt % Reflects off surface back into tissue
            ftn.ct(3) = -ftn.ct(3);
            ftn.layer = 1;
        else % Successfully transmits and is scored/killed
            
            % Determine detector bin
            if (ftn.x(1) >= -20 && ftn.x(1) < 20) && (ftn.x(2) >= -20 && ftn.x(2) < 20) % Photon is within scoring range
                xbin = floor((ftn.x(1) + 20)/0.05) + 1;
                ybin = floor((ftn.x(2) + 20)/0.05) + 1;
                local_dbin(xbin,ybin) = ftn.wt; % Add weight to bin
            end
            
            ftn.wt = 0; % Kill photon
        end
    else
        ftn.layer = layer2;
        ftn.x = ftn.x + s*ftn.ct; % Move to new position at boundary of new layer
    end
else % The photon remains in the same layer
    ftn.x = ftn.x + s*ftn.ct; % Move to new position in same layer
    ftn.wt = params.albedo(ftn.layer)*ftn.wt; % Update photon weight
    ftn.nrus = ftn.nrus + 1;
    ftn.ct = scatter(ftn, params); % Sample for new direction vector
    % ftn.layer remains the same
end

end

function [db, layer2] = distbound(ftn, params)
%DISTBOUND Determine distance to boundary along current direction vector

if ftn.layer == 4  % If inside the vein,
    layer2 = ftn.layer; %  the distance to any boundary doesn't matter
    db = 1000;
else
    if ftn.ct(3) > 0 % If pointed down, into the tissue,
        layer2 = ftn.layer+1; % next layer is deeper
        z = params.zb(layer2);
        db = (z-ftn.x(3))/ftn.ct(3);
    elseif ftn.ct(3) < 0 % If pointed up, toward the surface,
        layer2 = ftn.layer-1; % next layer is more superficial
        z = params.zb(ftn.layer);
        db = (z-ftn.x(3))/ftn.ct(3);
    else % Current photon path runs parallel to boundary
        layer2 = ftn.layer;
        db = 1000;
    end
    
    if layer2 == 4 % Layer 4 is reserved for vein, so fat layer is called layer 5
        layer2 = 5;
    end
end

end

function [dv, layer3] = distvein(ftn, params)
%DISTVEIN Determine distance to vein along current direction vector

if ftn.layer == 3 || ftn.layer == 4 % Special check in layer 3 or 4 for interaction with vein
    a = ftn.ct(1)^2 + ftn.ct(3)^2; % Calculate discriminant
    b = 2*ftn.ct(1)*ftn.x(1) + 2*ftn.ct(3)*(ftn.x(3)-(params.dv + params.rv));
    c = ftn.x(1)^2 + (ftn.x(3)-(params.dv+params.rv))^2 - params.rv^2;
    D = b^2 - 4*a*c;
    if D > 0 % 2 possible intersection points (most common occurance)
        dva = (-b + sqrt(D))/(2*a);
        dvs = (-b - sqrt(D))/(2*a);
        
        if dva > 0 && dvs >= 0
            if ftn.layer == 3
                dv = dvs;
                layer3 = 4;
            else % ftn.layer == 4
                dv = dva;
                layer3 = 3;
            end
        elseif dva >= 0 && dvs < 0
            if ftn.layer == 4
                dv = dva;
                layer3 = 3;
            else
                dv = 1000;
                layer3 = 3;
            end
        elseif dva < 0 && dvs < 0
            if ftn.layer == 3
                dv = 1000;
                layer3 = 3;
            else
                dv = 0.0001;
                layer3 = 3;
            end
        else
            dv = 1000;
            layer3 = ftn.layer;
        end
        
    elseif D == 0 % 1 possible intersection point
        dv = 1000; % Treat like a glancing blow/no interaction
        layer3 = ftn.layer;
    else % 0 possible intersection points
        dv = 1000;
        layer3 = ftn.layer;
    end
    
else
    dv = 1000;
    layer3 = ftn.layer;
end

end

function bscwt = fresnel(nrel, ct)
%BSCWT Calculate the Fresnel refleftn.ction and transmission coefficients

if nrel == 1
    bscwt = 0;
else
    nrsq = nrel^2;
    snisq = 1 - ct(3)^2;
    snrsq = snisq/nrsq;
    if snrsq >= 1
        bscwt = 1;
    else
        ns = realsqrt(nrsq - snisq);
        np = abs(nrsq*ct(3));
        rs = (abs(ct(3)) - ns)/(abs(ct(3)) + ns);
        rp = (ns - np)/(ns + np);
        bscwt = (rs^2 + rp^2)/2;
    end
end

end

function dir = scatter(ftn, params)
%SCATTER Sample for new scatter angle in tissue

% Get sin & cos of azimuthal angle
phi = 2*pi*rand;
sinphi = sin(phi);
cosphi = cos(phi);

% Get scatter angle from Henyey-Greenstein
p = 2*params.g(ftn.layer)*rand + 1 - params.g(ftn.layer);
p = params.g2(ftn.layer)/p;
p = p^2;

costheta = (2 - params.g2(ftn.layer) - p)/(2*params.g(ftn.layer));
sintheta = realsqrt(1 - costheta^2);

% Change direction
if abs(ftn.ct(3)) > 0.999 % If theta = 0, then equations simplify (also prevents error if costheta > 1)
    ftn.ct(1) = sintheta*cosphi;
    ftn.ct(2) = sintheta*sinphi;
    ftn.ct(3) = costheta*ftn.ct(3)/abs(ftn.ct(3));
else
    sinnorm = realsqrt(1-ftn.ct(3)^2);
    cttemp1 = ftn.ct(1)*costheta + sintheta*(ftn.ct(1)*ftn.ct(3)*cosphi - ftn.ct(2)*sinphi)/sinnorm;
    cttemp2 = ftn.ct(2)*costheta + sintheta*(ftn.ct(2)*ftn.ct(3)*cosphi - ftn.ct(1)*sinphi)/sinnorm;
    
    ftn.ct(3) = ftn.ct(3)*costheta - sinnorm*sintheta*cosphi;
    ftn.ct(1) = cttemp1;
    ftn.ct(2) = cttemp2;
end

dir = ftn.ct/norm(ftn.ct);

end