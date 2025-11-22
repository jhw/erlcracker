-module(erlcracker_worker_sup).
-behaviour(supervisor).

%%% Worker Supervisor
%%%
%%% simple_one_for_one supervisor that spawns workers dynamically.
%%% Workers are permanent - automatically restarted on crash.

%% API
-export([start_link/3, start_worker/1]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================

start_link(PoolName, RuntimeModule, PoolConfig) ->
    % Register with <PoolName>_worker_sup so pool can find us
    % Standard OTP coordination pattern via registered names
    SupName = list_to_atom(atom_to_list(PoolName) ++ "_worker_sup"),
    supervisor:start_link({local, SupName}, ?MODULE, [PoolName, RuntimeModule, PoolConfig]).

%% Start a new worker under this supervisor
start_worker(SupPid) ->
    supervisor:start_child(SupPid, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([PoolName, RuntimeModule, PoolConfig]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,  % Allow up to 10 worker restarts
        period => 60      % Within 60 seconds
    },

    % Worker spec - PoolName, RuntimeModule, and Config bound in closure
    WorkerSpec = #{
        id => erlcracker_worker,
        start => {erlcracker_worker, start_link, [PoolName, RuntimeModule, PoolConfig]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [erlcracker_worker]
    },

    {ok, {SupFlags, [WorkerSpec]}}.
