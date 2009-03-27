-module(orchestrator).

-export([start/0, stop/0, start/2, stop/1]).
-export([priv_dir/0]).

start() -> application:start(?MODULE).
stop() -> application:stop(?MODULE).

start(normal, []) ->
    inets:start(), %% assume it succeeded
    orchestrator_root_sup:start_link().

stop(_State) ->
    ok.

priv_dir() ->
    case code:priv_dir(?MODULE) of
    {error, bad_name} ->
        "./priv";
    D ->
        D
    end.