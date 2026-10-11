%% @doc OTP application entry.
%%
%% mcl_om:boot/1 wires the mesh, the realm identity and health, then starts
%% this service and advertises its capabilities only once it is up. The
%% distributor itself is a child of mcl_distributor_sup, started from
%% mcl_distributor_service:start/1.
-module(mcl_distributor_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> mcl_om:boot(mcl_distributor_service).

stop(_State) -> ok.
