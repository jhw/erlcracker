-module(erlcracker_pool_sup).
-behaviour(supervisor).

%%% Pool Supervision Subtree
%%%
%%% Creates a supervision subtree for one pool with rest_for_one strategy:
%%%   1. Worker supervisor (manages worker lifecycle)
%%%   2. Pool manager (manages work distribution)
%%%
%%% If worker_sup dies, pool restarts (it has stale worker refs)
%%% If pool dies, worker_sup stays up (workers unaffected)

%% API
-export([start_link/3]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================

%% Start a supervision subtree for one pool
%% PoolName - registered name for the pool (e.g., my_pool)
%% RuntimeModule - module implementing erlcracker_runtime behaviour
%% PoolConfig - map with pool_size, worker_timeout_ms, etc.
start_link(PoolName, RuntimeModule, PoolConfig) ->
    SupName = list_to_atom(atom_to_list(PoolName) ++ "_sup"),
    supervisor:start_link({local, SupName}, ?MODULE, [PoolName, RuntimeModule, PoolConfig]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([PoolName, RuntimeModule, PoolConfig]) ->
    % rest_for_one: worker_sup starts first, pool depends on it
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 10
    },

    Children = [
        % Worker supervisor - manages worker lifecycle
        % Registers as <PoolName>_worker_sup for pool to find
        #{
            id => worker_sup,
            start => {erlcracker_worker_sup, start_link, [PoolName, RuntimeModule, PoolConfig]},
            restart => permanent,
            shutdown => infinity,  % Supervisor
            type => supervisor,
            modules => [erlcracker_worker_sup]
        },
        % Pool manager - distributes work to workers
        % Looks up worker_sup by registered name (guaranteed by rest_for_one)
        #{
            id => pool,
            start => {erlcracker_pool, start_link, [PoolName, RuntimeModule, PoolConfig]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erlcracker_pool]
        }
    ],

    {ok, {SupFlags, Children}}.
