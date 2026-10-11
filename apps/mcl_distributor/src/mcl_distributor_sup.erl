%%%-------------------------------------------------------------------
%%% @doc The supervisor: one permanent worker, the distributor.
%%%
%%% A restart costs the node nothing but in-memory epochs: members holding
%%% the current epoch go on publishing and opening, and their re-pulls get
%%% `unknown_epoch' for the ids the restart lost, which the keyring
%%% remembers and answers fail-closed until the next rotation
%%% (macula_group_keys' own contract).
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Child = #{id => mcl_distributor,
              start => {mcl_distributor, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [mcl_distributor]},
    {ok, {{one_for_one, 5, 10}, [Child]}}.
