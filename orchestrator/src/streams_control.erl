-module(streams_control).

%% Streams control application.  Use this to start and stop the application
%% from a script.

% Largely cribbed from rabbit_control.erl

-export([start/0, stop/0]).

-define(RPC_TIMEOUT, 30000).

-record(params, {quiet, node, command, args}).

start() ->
    FullCommand = init:get_plain_arguments(),
    #params{quiet = Quiet, node = Node, command = Command, args = Args} =
        parse_args(FullCommand, #params{ quiet = false, node = splice_localnode(streams) }),
    Inform = case Quiet of
                 true -> fun (_, _) -> ok end;
                 false -> fun (Format, Args1) ->
                                  io:format(Format ++ "~n", Args1)
                          end
             end,
    case catch action(Command, Node, Args, Inform) of
        ok ->
            Inform("...done.", []),
            halt();
       {'EXIT', {function_clause, [{?MODULE, action, _} | _]}} ->
            error("invalid command '~s'", [Command]),
            usage();
        {error, Reason} ->
            error("~p", [Reason]),
            halt(2);
        Other ->
            error("~p", [Other]),
            halt(2)
    end.

error(Fmt, Args) ->
    io:format(Fmt, Args).

usage() ->
    io:format("Usage streamsctl [-q] [-n <node>] <command>

Available commands:

 start_app        - starts RabbitMQ Streams in an already running node
 stop_app         - stops RabbitMQ Streams, leaving the node running
 stop             - stops RabbitMQ Streams and halts the node
 status
 restart          - rereads configuration and restarts the application
                    (also reinstalls the configuration views)
 debug true|false - sets debug output on ('true') or off ('false'); will
                    will take effect when pipelines are restarted.
 trace true|false - set tracing to on ('true') or ('off'); this outputs
                    timing messages from the plugins.  It will take
                    effect when pipelines are restarted.

Output is suppressed using the \"-q\" flag.

<node> is the short or full name of the node running RabbitMQ Streams.
"),
    halt(1).

parse_args(["-n", NodeS | Args], Params) ->
    Node = case lists:member($@, NodeS) of
               true -> list_to_atom(NodeS);
               false -> splice_localnode(list_to_atom(NodeS))
           end,
    parse_args(Args, Params#params{node = Node});
parse_args(["-q" | Args], Params) ->
    parse_args(Args, Params#params{quiet = true});
parse_args([Command | Args], Params) ->
    Params#params{command = list_to_atom(Command), args = Args};
parse_args(Args, _) when Args =:= [] orelse Args =:= ["--help"] orelse Args =:= ["-h"]->
    usage().


stop() ->
    ok.

action(stop, Node, [], Inform) ->
    Inform("Stopping and halting node ~p", [Node]),
    call(Node, {orchestrator, stop_and_halt, []});
action(stop_app, Node, [], Inform) ->
    Inform("Stopping RabbitMQ Streams application on ~p", [Node]),
    call(Node, {orchestrator, stop, []});
action(start_app, Node, [], Inform) ->
    Inform("Starting RabbitMQ Streams application on ~p", [Node]),
    call(Node, {orchestrator, start, []});
action(restart, Node, [], Inform) ->
    Inform("Restarting RabbitMQ Streams application on ~p", [Node]),
    call(Node, {orchestrator, restart, []});
action(status, Node, [], Inform) ->
    Inform("Status of node ~p", [Node]),
    call(Node, {orchestrator, status, []});
action(Flag, Node, [Value], Inform) when Flag =:= debug; Flag =:= trace ->
    Inform("Setting ~p to ~p on ~p", [Flag, Value, Node]),
    call(Node, {orchestrator, set_flag, [atom_to_list(Flag), Value]}).

splice_localnode(Node) ->
    list_to_atom(lists:append(atom_to_list(Node),
                              lists:dropwhile(fun (C) -> C =/= $@ end,
                                              atom_to_list(node())))).

call(Node, {Mod, Fun, Args}) ->
    rpc_call(Node, Mod, Fun, lists:map(fun list_to_binary/1, Args)).

rpc_call(Node, Mod, Fun, Args) ->
    rpc:call(Node, Mod, Fun, Args, ?RPC_TIMEOUT).
