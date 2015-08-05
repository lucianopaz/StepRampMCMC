
% timeSeries - holds all trial information (NT = number of trials)
%   timeSeries.y          = spikes at each time (one long vector) 
%   timeSeries.trialIndex = NT x 2 matrix, each row holds the start and end
%                           indices for each trial (with respect to timeSeries.y)
%   timeSeries.trCoh        = coherence for each trial
%
function [ RampFit, RampSamples] = fitRampingModel(timeSeries,params)


totalSamples = params.MCMC.nSamples+params.MCMC.burnIn;
TT = size(timeSeries.y,1);
NT = size(timeSeries.trialIndex,1);
NC = max(timeSeries.trCoh);


%% max firing rate (bound) initialization ------------------------------
firingRateFunc    = @(X) log(1+exp(X))*params.delta_t;
firingRateFuncInv = @(X) log(exp(X/params.delta_t)-1);
timeIndices = timeSeries.trialIndex(: ,1);
timeIndices = [timeIndices;timeIndices+1;timeIndices+2]; 
startFR = firingRateFuncInv(  max(mean( timeSeries.y(timeIndices )), 1e-20));

timeIndices = timeSeries.trialIndex(timeSeries.choice == 1 ,2);
timeIndices = [timeIndices;timeIndices-1;timeIndices-2]; 
endFR1 = firingRateFuncInv(  max(mean( timeSeries.y(timeIndices )), 1e-20));

timeIndices = timeSeries.trialIndex(timeSeries.choice == 2 ,2);
timeIndices = [timeIndices;timeIndices-1;timeIndices-2]; 
endFR2 = firingRateFuncInv(  max(mean( timeSeries.y(timeIndices )), 1e-20));

initialGamma = max(startFR,max(endFR1,endFR2)); %initial gamma is the max of: beginning firing rate, end trial firing rate for choice 1, or end trial firing rate for choice 2 trials 
initialGamma = min(max(10,initialGamma),80); %keep initial gamma within some bounds


%% Sets up space for sampling --------------------------------------
RampSamples.betas        = zeros(totalSamples,NC);
RampSamples.w2s          = zeros(totalSamples,1);
RampSamples.auxThreshold = zeros(NT,totalSamples); %auxiliary variable to say when (if) bound was hit on each trial for each sample of lambda


RampSamples.l_0      = zeros(totalSamples,1);
RampSamples.gammas   = zeros(totalSamples,1);

acceptanceCount.g  = 0;
acceptanceCount.sample = zeros(totalSamples,1);

%special functions that save temp files to keep latent variables from taking over too much RAM
resetLatentsDB(length(timeSeries.y), totalSamples);
%saveLatentsDB(RampingFit.lambdas,1);

%% initial values
RampSamples.betas(1,:) = 0;
RampSamples.w2s(1,:)   = 0.005;
RampSamples.l_0(1)     = 0.5;
RampSamples.gammas(1)  = initialGamma;

RampSamples.rb.sig = zeros([NC+1,totalSamples]); %keeps around variables for potential Rao-Blackwell estimates over betas (I don't use these)
RampSamples.rb.mu  = zeros([NC+1,totalSamples]);


%% prior parameters setup
%makes prior param structures fit the number of params
%  -the same prior might be used for several param values

beta_mu = params.rampPrior.beta_mu;
if(NC > 1 && length(beta_mu) == 1)
    beta_mu = repmat(beta_mu,NC,1);
end
beta_sigma = params.rampPrior.beta_sigma;
if(NC > 1 && length(beta_sigma) == 1)
    beta_sigma = repmat(beta_sigma,NC,1);
end


p_init  = zeros(NC+1,NC+1);
p = zeros(size(p_init));
c_init  = zeros(NC+1,1);
c = zeros(size(c_init));

for b = 1:NC
    p_init(b,b) = 1/beta_sigma(b).^2;
    c_init(b)     = beta_mu(b) / beta_sigma(b).^2;
end
c_init(end)     = params.rampPrior.l0_mu/params.rampPrior.l0_sigma^2;
p_init(end,end) = 1/params.rampPrior.l0_sigma^2;


%% Setting up the GPU variables
trIndex = zeros(NT+1,1);

betaVector = zeros(TT+1,1);
maxTrLength = 0;
for tr = 1:NT
    T1 = timeSeries.trialIndex(tr,1);
    T2 = timeSeries.trialIndex(tr,2);
    T = T2 - T1 + 1;
    maxTrLength = max(T,maxTrLength);
    
    trIndex(tr+1) = trIndex(tr) + T;
    
    betaVector(T1:T2) = timeSeries.trCoh(tr)-1;
end

lambdaBlockSize = 50; %how often to pull samples back from GPU

lambdaCounter  = 0;
lambdaBlockNum = 0;

gpu_lambda       = kcArrayToGPU( loadLatentsDB(1:min(lambdaBlockSize,totalSamples))); %latent variables are loaded/unloaded in blocks to the GPU
gpu_auxThreshold = kcArrayToGPUint( int32(RampSamples.auxThreshold(:,1:min(lambdaBlockSize,totalSamples))));
gpu_y            = kcArrayToGPU( timeSeries.y);
gpu_trIndex      = kcArrayToGPUint(int32(trIndex));      
gpu_trBetaIndex  = kcArrayToGPUint(int32(betaVector)); 

%% run the sampler

fprintf('Starting Ramping MCMC sampler...\n');

for ss = 2:totalSamples
    if(mod(ss,50) == 0 || ss == totalSamples)
        fprintf('  Ramping MCMC sample %d / %d \n', ss, totalSamples);
    end
    
    
    %% sample latent states
    c(1:end)       = c_init;
    p(1:end,1:end) = p_init;
    gpu_lambdaN       = kcArrayGetColumn(gpu_lambda,mod(lambdaCounter+1,lambdaBlockSize));
    gpu_auxThresholdN = kcArrayGetColumnInt(gpu_auxThreshold,mod(lambdaCounter+1,lambdaBlockSize));

    kcRampPathSampler(gpu_lambdaN,gpu_auxThresholdN,gpu_y,gpu_trIndex,gpu_trBetaIndex,RampSamples.betas(ss-1,:),RampSamples.w2s(ss-1),RampSamples.l_0(ss-1),RampSamples.gammas(ss-1),params.delta_t, params.rampSampler.numParticles, params.rampSampler.minNumParticles,params.rampSampler.sigMult,maxTrLength, c, p);
    
    lambdaCounter = mod(lambdaCounter+1,lambdaBlockSize);
    if(lambdaCounter == lambdaBlockSize-1) 
        saveLatentsDB(kcArrayToHost(gpu_lambda),(1:lambdaBlockSize) + lambdaBlockNum*lambdaBlockSize);
        RampSamples.auxThreshold(:,(1:lambdaBlockSize) + lambdaBlockNum*lambdaBlockSize) = kcArrayToHostint(gpu_auxThreshold);
        lambdaBlockNum = lambdaBlockNum + 1;
    end   
   
    %% Sample betas, l_0
    mu = p\c;
    sig = inv(p);
    RampSamples.rb.sig(:,ss) = diag(sig);
    RampSamples.rb.mu(:,ss)  = mu;
    
    maxSample = 100; %samples, and resamples l_0 until a value below 1 is found (truncating the multivariate normal)
    for sampleAttempt = 1:maxSample
        driftSample = mvnrnd(mu,sig);
        if(ss < 500 && ss < params.MCMC.burnIn)

            if(driftSample(end) < 0.95)
                break;
            elseif(maxSample == sampleAttempt)
                fprintf('Warning: l_0 going too high! Attemping to correct...\n');
                driftSample(end) = 0.95;
            end
        else
            if(driftSample(end) < 1)
                break;
            elseif(maxSample == sampleAttempt)
                fprintf('Warning: l_0 going too high! Attemping to correct...\n');
                driftSample(end) = 1 - 1e-4;
            end
        end
    end
        
    RampSamples.betas(ss,:) = driftSample(1:end-1);

    RampSamples.l_0(ss) = driftSample(end);
    
    if(sum(isnan( driftSample))>0)
        error('Unknown problem with sampling drift rates.');
    end
    
    %% Sample w^2
    [w1_c, w2_c] = kcRampVarianceSampler(gpu_lambdaN,gpu_auxThresholdN,gpu_trIndex,gpu_trBetaIndex,RampSamples.betas(ss,:),RampSamples.l_0(ss));
    w2s_1 = sum(w1_c);
    w2s_2 = sum(w2_c);
    
    RampSamples.w2s(ss) = 1./gamrnd(params.rampPrior.w2_shape + w2s_1,1./(params.rampPrior.w2_scale + w2s_2)); %gamrnd does not use (alpha,beta) param, uses the one with theta on the wikipedia page for gamma dist
    if(isnan( RampSamples.w2s(ss) ) )
        error('Unknown problem with sampling drift variance.');
    end
    
    
    %% Step size setup for MALA on parameters
    if(params.rampSampler.learnStepSize && ss < params.MCMC.burnIn)
        if(ss <= 2)
            g_delta = params.rampSampler.epsilon_init;
            fprintf('Starting Langevin step size at %f\n',g_delta);
        elseif(mod(ss-1, params.rampSampler.MALAadjust) == 0)
            acceptPercent = mean(acceptanceCount.sample(ss-params.rampSampler.MALAadjust:ss-1));
            if(g_delta > params.rampSampler.epsilon_min && (acceptPercent < params.rampSampler.accept_min))
                g_delta = max(g_delta/params.rampSampler.adjustRate,params.rampSampler.epsilon_min);
                
                fprintf('Adjusting Langevin step size down to %f\n',g_delta);
            elseif(g_delta < params.rampSampler.epsilon_max && (acceptPercent > params.rampSampler.accept_max))
                g_delta = min(g_delta*params.rampSampler.adjustRate,params.rampSampler.epsilon_max);
                fprintf('Adjusting Langevin step size up to %f\n',g_delta);
            end
        end
    elseif(ss < params.MCMC.burnIn)
    	g_delta = params.rampSampler.epsilon_init;
    end
    if(ss == params.MCMC.burnIn + 1 && ~isnan(params.rampSampler.epsilon_fixed))
        g_delta = params.rampSampler.epsilon_fixed;
        fprintf('Fixing Langevin step size to %f\n',g_delta);
    end
    
    %% MALA (Metropolis-Adjusted Langevin Algorithm) sample gamma
    % this MALA proposal is conditioned using the fisher information of gamma
    gamma_a = params.rampPrior.gammaAlpha;
    gamma_b = params.rampPrior.gammaBeta;
    
    G_prior = -(gamma_a-1)/RampSamples.gammas(ss-1)^2;
    [log_p_lambda, der_log_p_y, G_log_p_y] = kcRampBoundHeightSampler(gpu_lambdaN,gpu_auxThresholdN,gpu_y,gpu_trIndex,RampSamples.gammas(ss-1),params.delta_t,G_prior);
    p_mu = RampSamples.gammas(ss-1) + 1/2*g_delta^2*(G_log_p_y\der_log_p_y);

    p_sig = (g_delta)^2/G_log_p_y;
    gamma_star = p_mu + sqrt(p_sig)*randn;
    log_q_star = -1/2*log(2*pi*p_sig) - 1/(2*p_sig)*(gamma_star - p_mu)^2;
    
    G_prior_star = -(gamma_a-1)/gamma_star^2;
    [log_p_lambda_star, der_log_p_y_star, G_log_p_y_star] = kcRampBoundHeightSampler(gpu_lambdaN,gpu_auxThresholdN,gpu_y,gpu_trIndex,gamma_star,params.delta_t,G_prior_star);
    p_mu_star  = gamma_star + 1/2*g_delta^2*(G_log_p_y_star\der_log_p_y_star);
    p_sig_star = (g_delta)^2/G_log_p_y_star;
    log_q = -1/2*log(2*pi*p_sig_star) - 1/(2*p_sig_star)*(RampSamples.gammas(ss-1) - p_mu_star)^2;
    
    if(gamma_a > 0 && gamma_b > 0)
        log_p      = log_p_lambda      + gamma_a*log(gamma_b) - gammaln(gamma_a) + (gamma_a-1) * log(RampSamples.gammas(ss-1))    - gamma_b*RampSamples.gammas(ss-1);
        log_p_star = log_p_lambda_star + gamma_a*log(gamma_b) - gammaln(gamma_a) + (gamma_a-1) * log(gamma_star) - gamma_b*gamma_star;
    else
        log_p      = log_p_lambda      - log(RampSamples.gammas(ss-1));
        log_p_star = log_p_lambda_star - log(gamma_star);
    end
    
    log_a = log_p_star + log_q - log_p - log_q_star;
    lrand = log(rand);
    if(gamma_star > 0 && lrand < log_a)
        RampSamples.gammas(ss) = gamma_star;
        acceptanceCount.g = acceptanceCount.g+1;
        acceptanceCount.sample(ss) = 1;
    else
        RampSamples.gammas(ss) = RampSamples.gammas(ss-1);
        acceptanceCount.sample(ss) = 0;
    end
    
    %% plot outputs
    if(mod(ss,50) == 0)
        if(exist('paramPlotFigure','var') && ishandle(paramPlotFigure))
            set(0,'CurrentFigure',paramPlotFigure);
        else
            paramPlotFigure = figure(200);
        end
        
        clf

        startMean = max(1,ss-250);
        if(ss > params.MCMC.burnIn + 100)
            startMean = params.MCMC.burnIn+1;
        end
        
        subplot(4,1,1)
        hold on
        plot(1:ss,RampSamples.betas(1:ss,:));
        title('betas');
        
        meanB = mean(RampSamples.betas(startMean:ss,:));
        plot([1 totalSamples],[meanB;meanB],':');
        xlim([1 totalSamples]);
        hold off
        
        subplot(4,1,2)
        hold on
        plot(1:ss,RampSamples.w2s(1:ss,:));
        title('w2s');
        meanW2 = mean(RampSamples.w2s(startMean:ss));
        plot([1 totalSamples],[meanW2 meanW2],':k');
        xlim([1 totalSamples]);
        hold off
        
        subplot(4,1,3)
        hold on
        plot(1:ss,RampSamples.l_0(1:ss));
        title('l_0');
        meanL0 = mean(RampSamples.l_0(startMean:ss));
        plot([1 totalSamples],[meanL0 meanL0],':k');
        xlim([1 totalSamples]);
        hold off
        
        
        subplot(4,1,4)
        hold on
        plot(1:ss,RampSamples.gammas(1:ss));
        title(['gamma, acceptance percentage = ' num2str(acceptanceCount.g / (ss-1)*100) '%']);
        if(isfield(timeSeries,'actualPs'))
            plot([1 totalSamples],repmat(timeSeries.actualPs.gamma,2,1),'--');
        end
        meanGamma = mean(RampSamples.gammas(startMean:ss));
        plot([1 totalSamples],[meanGamma meanGamma],':k');
        xlim([1 totalSamples]);
        hold off
        
        if(exist('latentStateFigure','var') && ishandle(latentStateFigure))
            set(0,'CurrentFigure',latentStateFigure);
        else
            latentStateFigure = figure(201);
        end
        clf
        hold on
        
        
        range = [];
        allTrs = [];
        for ii = 1:NC 
            nTrialsAtCoh = sum(timeSeries.trCoh == ii);
            trs = find(timeSeries.trCoh == ii,1);
            range = [range timeSeries.trialIndex(trs,1):timeSeries.trialIndex(trs+min(3,nTrialsAtCoh)-1,2) ]; %#ok<AGROW>
            allTrs = [allTrs trs:(trs+min(3,nTrialsAtCoh)-1)]; %#ok<AGROW>
        end
        
        
        trialsToPlot = max(1,ss-100):ss;
        gMult = repmat(RampSamples.gammas(trialsToPlot)',length(range),1);
        
        latentBlock = loadLatentsDB(trialsToPlot);
        for ii = 1:length(allTrs)
            for jj = 1:length(trialsToPlot)
                T1 = timeSeries.trialIndex(allTrs(ii),1);
                T2 = timeSeries.trialIndex(allTrs(ii),2);
                
                tc = find(latentBlock(T1:T2,jj) >= 1,1);
                if(~isempty(tc))
                    latentBlock(T1+tc-1:T2,jj) = 1;
                end
            end
        end
        plot(1:length(range),firingRateFunc(latentBlock(range,:).*gMult),'b');
        plot(1:length(range),timeSeries.y(range),'r');
        hold off
        
        
        drawnow;
        
    end
    
end


%% finish up---------------------------------------
thinRate = params.MCMC.thinRate;

%get sampling stats for path
try
    RampFit.lambdas.mean   = meanLatentsDB((params.MCMC.burnIn+1):thinRate:totalSamples);
catch exc %#ok<NASGU>
    RampFit.lambdas.mean   = [];
end
RampFit.auxThreshold.mean   = mean(RampSamples.auxThreshold(:,params.MCMC.burnIn+1:thinRate:end),2);
RampFit.auxThreshold.median = median(RampSamples.auxThreshold(:,params.MCMC.burnIn+1:thinRate:end),2);
RampFit.auxThreshold.std    = std(RampSamples.auxThreshold(:,params.MCMC.burnIn+1:thinRate:end),[],2);

RampFit.beta.mean  = mean(RampSamples.betas(params.MCMC.burnIn+1:thinRate:end,:))';
RampFit.w2.mean    = mean(RampSamples.w2s(params.MCMC.burnIn+1:thinRate:end))';
RampFit.gamma.mean = mean(RampSamples.gammas(params.MCMC.burnIn+1:thinRate:end))';
RampFit.l_0.mean   = mean(RampSamples.l_0(params.MCMC.burnIn+1:thinRate:end))';

RampFit.beta.interval  = prctile(RampSamples.betas(((params.MCMC.burnIn+1):thinRate:end),:),[2.5 97.5],1);
RampFit.w2.interval    = prctile(RampSamples.w2s((params.MCMC.burnIn+1):thinRate:end,:),[2.5 97.5],1);
RampFit.l_0.interval   = prctile(RampSamples.l_0((params.MCMC.burnIn+1):thinRate:end),[2.5 97.5],1);
RampFit.gamma.interval = prctile(RampSamples.gammas((params.MCMC.burnIn+1):thinRate:end),[2.5 97.5],1);

try 
    kcFreeGPUArray(gpu_y);
    kcFreeGPUArray(gpu_lambda);
    kcFreeGPUArray(gpu_auxThreshold);
    kcFreeGPUArray(gpu_trIndex);
    kcFreeGPUArray(gpu_trBetaIndex);
catch e
    fprintf('Error clearing cuda memory: %s\n',e);
end

fprintf('Ramping model sampler complete.\n');
end