require 'torch'
require 'nn'
require 'nngraph'
require 'optim'
local dataBatchLoader = require 'dataBatchLoader'
local LSTM = require 'LSTM'             -- LSTM timestep and utilities
-- require 'Datalayer'                     -- class name is Datalayer (not namespaced)
local lstm_utils=require 'lstm_utils'


local cmd = torch.CmdLine()
cmd:text()
cmd:text('Training a two-layered encoder LSTM model for sequence classification')
cmd:text()
cmd:text('Options')
cmd:option('-classfile','classfile2.th7','filename of the drivers table')
cmd:option('-datafile','datafile2.th7','filename of the serialized torch ByteTensor to load')
cmd:option('-train_split',0.8,'Fraction of data into training')
cmd:option('-val_split',0.1,'Fraction of data into validation')
cmd:option('-batch_size',1,'number of sequences to train on in parallel')
cmd:option('-seq_length',50,'number of timesteps to unroll to')
cmd:option('-input_size',15,'number of dimensions of input')
cmd:option('-rnn_size', 128,'size of LSTM internal state')
cmd:option('-depth',1,'Number of LSTM layers stacked on top of each other')
cmd:option('-dropout',0.5,'Droput Probability')
cmd:option('-max_epochs',10,'number of full passes through the training data')
cmd:option('-savefile','model_autosave','filename to autosave the model (protos) to, appended with the,param,string.t7')
cmd:option('-save_every',1000,'save every 1000 steps, overwriting the existing file')
cmd:option('-print_every',100,'how many steps/minibatches between printing out the loss')
cmd:option('-eval_every',1000,'evaluate the holdout set every 100 steps')
cmd:option('-seed',123,'torch manual random number generator seed')
cmd:text()

-- parse input params
local opt = cmd:parse(arg)

torch.setdefaulttensortype('torch.DoubleTensor')

local test_split = 1 - opt.train_split - opt.val_split
split_fraction = {opt.train_split, opt.val_split, test_split}

-- preparation stuff:
torch.manualSeed(opt.seed)
opt.savefile = cmd:string(opt.savefile, opt,
    {save_every=true, print_every=true, savefile=true, vocabfile=true, datafile=true})
    .. '.t7'

local loader = dataBatchLoader.create(
        opt.datafile, opt.classfile, opt.batch_size, opt.seq_length, split_fraction)

-- define model prototypes for ONE timestep, then clone them
local protos = {}
-- lstm timestep's input: {x, prev_c, prev_h}, output: {next_c, next_h}
protos.lstm = LSTM.lstm(opt)
-- The softmax and criterion layers will be added at the end of the sequence
softmax = nn.Sequential():add(nn.Linear(opt.rnn_size, 5)):add(nn.LogSoftMax())
criterion = nn.CrossEntropyCriterion()

-- put the above things into one flattened parameters tensor
local params, grad_params = lstm_utils.combine_all_parameters(protos.lstm, softmax)
params:uniform(-0.08, 0.08)

-- make a bunch of clones, AFTER flattening, as that reallocates memory
local clones = {}
for name,proto in pairs(protos) do
    print('cloning '..name)
    clones[name] = lstm_utils.clone_model(proto, opt.seq_length, not proto.parameters)
end

-- LSTM initial state (zero initially, but final state gets sent to initial state when we do BPTT)
local initstate_c = torch.zeros(opt.batch_size, opt.rnn_size)
local initstate_h = initstate_c:clone()

-- LSTM final state's backward message (dloss/dfinalstate) is 0, since it doesn't influence predictions
local dfinalstate_c = initstate_c:clone()
local dfinalstate_h = initstate_c:clone()


-- do fwd/bwd and return loss, grad_params
function feval(params_)
    if params_ ~= params then
        params:copy(params_)
    end
    grad_params:zero()
    
    ------------------ get minibatch -------------------
    local x, y = loader:nextBatch(1)
    -- print(type(x))
    --print('Size of input data %f', x:size())
    -- local x1 = x:view(opt.seq_length, opt.batch_size, -1)
    local x1 = x:t()
    --print(x1:size())
    --print(y:size())
    
    ------------------- forward pass -------------------
    local Datalayers = {}
    local lstm_c = {[0]=initstate_c} -- internal cell states of LSTM
    local lstm_h = {[0]=initstate_h} -- output values of LSTM
    local predictions = {}           -- softmax outputs
    local loss = 0

    for t=1,opt.seq_length do
        Datalayers[t] = x1[{{}, t}]
        lstm_c[t], lstm_h[t] = unpack(clones.lstm[t]:forward{Datalayers[t], lstm_c[t-1], lstm_h[t-1]})
    end
    
    --softmax and loss are only at the last time step
    t = opt.seq_length
    predictions = softmax:forward(lstm_h[t])
    loss = loss + criterion:forward(predictions, y[t])
    
    ------------------ backward pass -------------------
    -- complete reverse order of the above
    local dDatalayers = {}
    local dlstm_c = {[opt.seq_length]=dfinalstate_c}    -- internal cell states of LSTM
    local dlstm_h = {}                                  -- output values of LSTM
    
    t=opt.seq_length
    local doutput_t = criterion:backward(predictions, y[t])
    assert(dlstm_h[t] == nil)
    dlstm_h[t] = softmax:backward(lstm_h[t], doutput_t)
    --print('Done with 1st backprop in the final time step')
    
    for t=opt.seq_length,1,-1 do
        -- backprop through LSTM timestep
        dDatalayers[t], dlstm_c[t-1], dlstm_h[t-1] = unpack(clones.lstm[t]:backward(
            {Datalayers[t], lstm_c[t-1], lstm_h[t-1]},
            {dlstm_c[t], dlstm_h[t]}
        ))
    end

    ------------------------ misc ----------------------
    -- transfer final state to initial state (BPTT)
    initstate_c:copy(lstm_c[#lstm_c])
    initstate_h:copy(lstm_h[#lstm_h])

    -- clip gradient element-wise
    grad_params:clamp(-5, 5)

    --print('one iteration done!')

    return loss, grad_params
end

-- optimization stuff

local losses = {}
local val_losses = {}
local optim_state = {learningRate = 1e-1}
local iterations = opt.max_epochs * loader.nbatches
for i = 1, iterations do
    -- print('In iteration ',i)

    local _, loss = optim.adagrad(feval, params, optim_state)
    losses[#losses + 1] = loss[1]
    
    -- tune the learning rate 
    
    
    if i % opt.eval_every == 0 then
        --local val_loss = evalValLoss(2)
        -- val_losses[i] = val_loss
        -- print(string.format("iteration %4d, loss = %6.8f, loss/seq_len = %6.8f, gradnorm = %6.4e", i, val_loss, val_loss / opt.seq_length, grad_params:norm()))
    end

    if i % opt.save_every == 0 then
        torch.save(opt.savefile, protos)
    end

    if i % opt.print_every == 0 then
        print(string.format("iteration %4d, loss = %6.8f, loss/seq_len = %6.8f, gradnorm = %6.4e", i, loss[1], loss[1] / opt.seq_length, grad_params:norm()))
    end
    
    collectgarbage()
end

-- run prediction on testing

