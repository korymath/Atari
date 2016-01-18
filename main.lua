local signal = require 'posix.signal'
local _ = require 'moses'
require 'logroll'
local image = require 'image'
local agent = require 'agent'
local evaluator = require 'evaluator'

-- Detect QT for image display
local qt = pcall(require, 'qt')

local cmd = torch.CmdLine()
-- Base Torch7 options
cmd:option('-seed', 123, 'Random seed')
cmd:option('-threads', 4, 'Number of BLAS threads')
cmd:option('-tensorType', 'torch.FloatTensor', 'Default tensor type')
cmd:option('-gpu', 1, 'GPU device ID (0 to disable)')
-- Game
cmd:option('-game', 'catch', 'Name of Atari ROM (stored in "roms" directory)') -- Uses "Catch" env by default
-- Training vs. evaluate mode
cmd:option('-mode', 'train', 'Train vs. test mode: train|eval')
-- Screen preprocessing options
cmd:option('-height', 84, 'Resized screen height')
cmd:option('-width', 84, 'Resize screen width')
cmd:option('-colorSpace', 'y', 'Colour space conversion (screen is RGB): rgb|y|lab|yuv|hsl|hsv|nrgb')
-- Agent options
cmd:option('-histLen', 4, 'Number of consecutive states processed')
cmd:option('-duel', 'true', 'Use dueling networks architecture')
-- Experience replay options
cmd:option('-memSize', 1e6, 'Experience replay memory size (number of tuples)')
cmd:option('-memSampleFreq', 4, 'Memory sample frequency')
cmd:option('-memNReplay', 1, 'Number of times to replay per learning step')
cmd:option('-memPriority', 'none', 'Type of prioritised experience replay: none|rank|proportional')
cmd:option('-alpha', 0.65, 'Prioritised experience replay exponent α') -- Best vals are rank = 0.7, proportional = 0.6
cmd:option('-betaZero', 0.45, 'Initial value of importance-sampling exponent β') -- Best vals are rank = 0.5, proportional = 0.4
-- Reinforcement learning parameters
cmd:option('-gamma', 0.99, 'Discount rate γ')
cmd:option('-eta', 7e-5, 'Learning rate η') -- Accounts for prioritied experience sampling but not duel
cmd:option('-epsilonStart', 1, 'Initial value of greediness ε')
cmd:option('-epsilonEnd', 0.01, 'Final value of greediness ε')
cmd:option('-epsilonSteps', 1e6, 'Number of steps to linearly decay epsilonStart to epsilonEnd') -- Usually same as memory size
cmd:option('-tau', 30000, 'Steps between target net updates τ') -- Larger for duel than for standard DQN
cmd:option('-rewardClip', 1, 'Clips reward magnitude at rewardClip')
cmd:option('-tdClip', 1, 'Clips TD-error δ magnitude at tdClip (0 to disable)')
cmd:option('-doubleQ', 'true', 'Use Double-Q learning')
-- Note from Georg Ostrovski: The advantage operators and Double DQN are not entirely orthogonal as the increased action gap seems to reduce the statistical bias that leads to value over-estimation in a similar way that Double DQN does
cmd:option('-PALpha', 0.9, 'Persistent advantage learning parameter α (0 to disable)')
-- Training options
cmd:option('-optimiser', 'adam', 'Training algorithm') -- Originally a "non-standard" RMSProp was used, as found in Generating Sequences With Recurrent Neural Networks
cmd:option('-momentum', 0.95, 'SGD momentum')
cmd:option('-batchSize', 32, 'Minibatch size')
cmd:option('-steps', 5e7, 'Training iterations (steps)') -- Frame := step in ALE; Time step := consecutive frames treated atomically by the agent
cmd:option('-learnStart', 50000, 'Number of steps after which learning starts')
-- Evaluation options
cmd:option('-progFreq', 10000, 'Number of steps to report progress')
cmd:option('-valFreq', 250000, 'Validation frequency (by number of steps)') -- Therefore valFreq steps is sometimes called an epoch
cmd:option('-valSteps', 125000, 'Number of steps to use for validation')
cmd:option('-valSize', 500, 'Number of transitions to use for validation stats')
-- ALEWrap options
cmd:option('-actRep', 4, 'Times to repeat action') -- Independent of history length
cmd:option('-randomStarts', 30, 'Play no-op action between 1 and randomStarts number of times at the start of each training episode')
cmd:option('-poolFrmsType', 'max', 'Type of pooling over frames: max|mean')
cmd:option('-poolFrmsSize', 2, 'Size of pooling over frames')
-- Experiment options
cmd:option('-_id', '', 'ID of experiment (used to store saved results, defaults to game name)')
cmd:option('-network', '', 'Saved DQN file to load (DQN.t7)')
cmd:option('-verbose', 'false', 'Log info for every training episode')
local opt = cmd:parse(arg)
-- Process boolean options (Torch fails to accept false on the command line)
opt.duel = opt.duel == 'true' or false
opt.doubleQ = opt.doubleQ == 'true' or false
opt.verbose = opt.verbose == 'true' or false

-- Set ID as game name if not set
if opt._id == '' then
  opt._id = opt.game
end

-- Create experiment directory
if not paths.dirp('experiments') then
  paths.mkdir('experiments')
end
paths.mkdir(paths.concat('experiments', opt._id))
-- Set up logs
local flog = logroll.file_logger(paths.concat('experiments', opt._id, 'log.txt'))
local plog = logroll.print_logger()
log = logroll.combine(flog, plog)

-- Torch setup
log.info('Setting up Torch7')
-- Set number of BLAS threads
torch.setnumthreads(opt.threads)
-- Set default Tensor type (float is more efficient than double)
torch.setdefaulttensortype(opt.tensorType)
-- Set manual seeds using random numbers to reduce correlations
math.randomseed(opt.seed)
torch.manualSeed(math.random(1, 1e6))

-- Tensor creation function for removing need to cast to CUDA if GPU is enabled
opt.Tensor = function(...)
  return torch.Tensor(...)
end

-- GPU setup
if opt.gpu > 0 then
  log.info('Setting up GPU')
  require 'cutorch'
  cutorch.setDevice(opt.gpu)
  cutorch.manualSeedAll(torch.random())
  -- Replace tensor creation function
  opt.Tensor = function(...)
    return torch.CudaTensor(...)
  end
end

-- Work out number of colour channels
if not _.contains({'rgb', 'y', 'lab', 'yuv', 'hsl', 'hsv', 'nrgb'}, opt.colorSpace) then
  log.error('Unsupported colour space for conversion')
  error('Unsupported colour space for conversion')
end
opt.nChannels = opt.colorSpace == 'y' and 1 or 3

-- Initialise Arcade Learning Environment (or Catch)
opt.ale = opt.game ~= 'catch'
log.info('Setting up ' .. (opt.ale and 'Arcade Learning Environment' or 'Catch'))
local gameEnv, stateSpec
if opt.ale then
  local Atari = require 'rlenvs.Atari'
  gameEnv = Atari(opt)
  stateSpec = gameEnv:getStateSpec()

  -- Provide original channels, height and width
  opt.origChannels, opt.origHeight, opt.origWidth = unpack(stateSpec[2])
else
  local Catch = require 'rlenvs.Catch'
  gameEnv = Catch()
  stateSpec = gameEnv:getStateSpec()
  
  -- Adjust height and width
  opt.height, opt.width = stateSpec[2][2], stateSpec[2][3]

  -- Adjust other parameters to better suit Catch
  opt.memSize = opt.memSize / 10
  opt.eta = opt.eta * 100
  opt.epsilonSteps = opt.epsilonSteps / 10
  opt.tau = opt.tau / 10
  opt.steps = opt.steps / 10
  opt.learnStart = opt.learnStart / 10
  -- TODO REMOVE (FOR DEBUGGING)
  opt.duel = false
  opt.doubleQ = false
  opt.PALpha = 0

  -- Mention CPU vs GPU
  if opt.gpu > 0 then
    log.info('Note: due to its small size, Catch\'s DQN performs better on a CPU')
  end
end
local initStep = 1

-- Create DQN agent
log.info('Creating DQN')
local DQN = agent.create(gameEnv, opt)
if paths.filep(opt.network) then
  -- Load saved agent if specified
  log.info('Loading pretrained network')
  DQN:load(opt.network)
elseif paths.filep(paths.concat('experiments', opt._id, 'DQN.t7')) then
  -- Ask to load saved agent if found in experiment folder (resuming training)
  log.info('Saved network found - load (y/n)?')
  if io.read() == 'y' then
    log.info('Loading pretrained network')
    DQN:load(paths.concat('experiments', opt._id))
    if opt.mode == 'train' then
      log.info('Loading saved step')
      initStep = torch.load(paths.concat('experiments', opt._id, 'step.t7'))[1]
    end
  end
end

-- Start gaming
log.info('Starting game: ' .. opt.game)
local reward, screen, terminal = 0, gameEnv:start(), false

-- Activate display if using QT
local zoom = opt.ale and 1 or 10
local window = qt and image.display({image=screen, zoom=zoom})

if opt.mode == 'train' then
  log.info('Training mode')

  -- Set up SIGINT (Ctrl+C) handler to save network before quitting
  signal.signal(signal.SIGINT, function(signum)
    log.warn('SIGINT received')
    log.info('Save network (y/n)?')
    if io.read() == 'y' then
      log.info('Saving network')
      DQN:save(paths.concat('experiments', opt._id))
      log.info('Saving step')
      torch.save(paths.concat('experiments', opt._id, 'step.t7'), {opt.step}) -- Save step to resume training
    end
    log.warn('Exiting')
    os.exit(128 + signum)
  end)

  -- Check prioritised experience replay options
  if opt.memPriority == 'proportional' then
    log.info('Proportional prioritised experience replay is not implemented, switching to rank-based')
    opt.memPriority = 'rank'
  elseif not _.contains({'none', 'rank', 'proportional'}, opt.memPriority) then
    log.error('Unrecognised type of prioritised experience replay')
    error('Unrecognised type of prioritised experience replay')
  end

  -- Create ε decay vector
  opt.epsilon = torch.linspace(opt.epsilonEnd, opt.epsilonStart, opt.epsilonSteps)
  opt.epsilon:neg():add(opt.epsilonStart)
  local epsilonFinal = torch.Tensor(opt.steps - opt.epsilonSteps):fill(opt.epsilonEnd)
  opt.epsilon = torch.cat(opt.epsilon, epsilonFinal)
  -- Create β growth vector
  opt.beta = torch.linspace(opt.betaZero, 1, opt.steps)

  -- Set environment and agent to training mode
  if opt.ale then gameEnv:training() end
  DQN:training()

  -- Training variables (reported in verbose mode)
  local episode = 1
  local episodeReward = reward

  -- Validation variables
  local valEpisode, valEpisodeReward, valTotalReward
  local bestValScore = -math.huge

  -- Training loop
  for step = initStep, opt.steps do
    opt.step = step -- Pass step number to agent for use in training

    -- Observe results of previous transition (r, s', terminal') and choose next action (index)
    local actionIndex = DQN:observe(reward, screen, terminal) -- As results received, learn in training mode
    if not terminal then
      -- Act on environment (to cause transition)
      reward, screen, terminal = DQN:act(actionIndex)
      -- Track reward
      episodeReward = episodeReward + reward
    else
      if opt.verbose then
        -- Print score for episode
        log.info('Episode ' .. episode .. ' | Score: ' .. episodeReward .. ' | Steps: ' .. step .. '/' .. opt.steps)
      end

      -- Start a new episode
      episode = episode + 1
      reward, screen, terminal = 0, gameEnv:start(), false
      episodeReward = reward -- Reset episode reward
    end

    -- Update display
    if qt then
      image.display({image=screen, zoom=zoom, win=window})
    end

    -- Trigger learning after a while (wait to accumulate experience)
    if step == opt.learnStart then
      log.info('Learning started')
    end

    -- Report progress
    if step % opt.progFreq == 0 then
      log.info('Steps: ' .. step .. '/' .. opt.steps)
      -- TODO: Report absolute weight and weight gradient values per module in policy network
    end

    -- TODO Replay valSize saved transitions and report average of max Q-value at each step
    if step % opt.valFreq == 0 and step >= opt.learnStart then
      log.info('Validating')
      if opt.ale then gameEnv:evaluate() end
      DQN:evaluate()

      -- Start new game
      reward, screen, terminal = 0, gameEnv:start(), false

      -- Reset validation variables
      valEpisode = 1
      valEpisodeReward = 0
      valTotalReward = 0

      for valStep = 1, opt.valSteps do
        -- Observe and choose next action (index)
        local actionIndex = DQN:observe(reward, screen, terminal)
        if not terminal then
          -- Act on environment
          reward, screen, terminal = DQN:act(actionIndex)
          -- Track reward
          valEpisodeReward = valEpisodeReward + reward
        else
          if valEpisode % (opt.ale and 10 or 100) == 0 then
            -- Print score for episode
            log.info('Val Episode ' .. valEpisode .. ' | Score: ' .. valEpisodeReward .. ' | Steps: ' .. valStep .. '/' .. opt.valSteps)
          end

          -- Start a new episode
          valEpisode = valEpisode + 1
          reward, screen, terminal = 0, gameEnv:start(), false
          valTotalReward = valTotalReward + valEpisodeReward -- Only add to total reward at end of episode
          valEpisodeReward = reward -- Reset episode reward
        end

        -- Update display
        if qt then
          image.display({image=screen, zoom=zoom, win=window})
        end
      end

      -- Print total and average score
      log.info('Total Score: ' .. valTotalReward)
      log.info('Average Score: ' .. valTotalReward/math.min(valEpisode - 1, 1)) -- Only count reward for completed episodes

      -- Use transitions sampled for validation to test performance
      local avgV, avgTdErr = DQN:report()
      log.info('Average V(s): ' .. avgV)
      log.info('Average δ: ' .. avgTdErr)

      -- Save if best score achieved
      if valTotalReward > bestValScore then
        log.info('New best score')
        bestValScore = valTotalReward

        log.info('Saving network')
        DQN:save(paths.concat('experiments', opt._id))
      end

      log.info('Resuming training')
      if opt.ale then gameEnv:training() end
      DQN:training()

      -- Start new game (as previous one was interrupted)
      reward, screen, terminal = 0, gameEnv:start(), false
      episodeReward = reward
    end
  end
elseif opt.mode == 'eval' then
  log.info('Evaluation mode')
  -- Set environment and agent to evaluation mode
  if opt.ale then gameEnv:evaluate() end
  DQN:evaluate()

  -- Report episode reward
  local episodeReward = reward

  -- Play one game (episode)
  while not terminal do
    -- Observe and choose next action (index)
    local actionIndex = DQN:observe(reward, screen, terminal)
    -- Act on environment
    reward, screen, terminal = DQN:act(actionIndex)
    episodeReward = episodeReward + reward

    if qt then
      image.display({image=screen, zoom=zoom, win=window})
    end
  end
  log.info('Final Score: ' .. episodeReward)
end
