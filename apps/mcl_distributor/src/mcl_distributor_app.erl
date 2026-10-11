%%%-------------------------------------------------------------------
%%% @doc OTP application entry point for mcl_distributor.
%%%
%%% The supervisor tree is one worker: the group-key distributor for the
%%% org this service is deployed as. mcl_om's own tree (pool, health
%%% socket, capability publisher, claim worker) starts first, since
%%% mcl_distributor lists mcl_om in its applications.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    mcl_distributor_sup:start_link().

stop(_State) ->
    ok.
