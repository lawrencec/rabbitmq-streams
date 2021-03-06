-module(orchestrator_root).

-behaviour(gen_server).

-export([start_link/0]).
-export([open_channel/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([server_started_callback/1]).
-export([install_views/0]).

-define(SERVER, ?MODULE).

-include("orchestrator.hrl").
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

open_channel() ->
    gen_server:call(?SERVER, open_channel).

%%---------------------------------------------------------------------------

setup_core_messaging(Ch, LogCh) ->
    #'exchange.declare_ok'{} =
        amqp_channel:call(LogCh, #'exchange.declare'{exchange = ?FEEDSHUB_LOG_XNAME,
                                                  type = <<"topic">>,
                                                  durable = true}),
    #'exchange.declare_ok'{} =
        amqp_channel:call(Ch, #'exchange.declare'{exchange = ?FEEDSHUB_CONFIG_XNAME,
                                                  type = <<"topic">>,
                                                  durable = false}),
    #'exchange.declare_ok'{} =
        amqp_channel:call(LogCh, #'exchange.declare'{exchange = ?FEEDSHUB_NOTIFY_XNAME,
                                                  type = <<"topic">>,
                                                  durable = true}),
    PrivateQ = lib_amqp:declare_private_queue(Ch),
    #'queue.bind_ok'{} = lib_amqp:bind_queue(Ch, ?FEEDSHUB_CONFIG_XNAME, PrivateQ, <<"*">>),
    _ConsumerTag = lib_amqp:subscribe(Ch, PrivateQ, self()),
    ok.

setup_logger(LogCh) ->
    case supervisor:start_child(orchestrator_root_sup,
    			       {orchestrator_root_logger,
    				{orchestrator_logger, start_link, [LogCh]},
    				permanent,
    				brutal_kill,
    				worker,
    				[orchestrator_logger]
    			       }) of
	{ok, _Pid} -> ok;
	{error, {already_started, _Pid}} -> ok
    end.

install_views() ->
    error_logger:info_msg("Installing views in ~p", [streams_config:config_db()]),
    lists:foreach(
      fun({WC, DB}) ->
	      lists:foreach(fun(Dir) -> install_view(DB, Dir) end,
			    filelib:wildcard(orchestrator:priv_dir() ++ WC))
      end, [
	    {"/feedshub_status/views/*", streams_config:config_db()}
	   ]),
    ok.

install_view(DbName, ViewDir) ->
    ViewCollectionName = filename:basename(ViewDir),
    Views = lists:foldl(fun (FileName, V) ->
                                Base = filename:basename(FileName, ".js"),
                                Extn = filename:extension(Base),
                                ViewName = filename:basename(Base, Extn),
                                "." ++ FunctionName = Extn,
                                {ok, FunctionText} = file:read_file(FileName),
                                dict:update(ViewName,
                                            fun (OldViewDict) ->
                                                    dict:store(FunctionName,
                                                               FunctionText,
                                                               OldViewDict)
                                            end,
                                            dict:store(FunctionName, FunctionText, dict:new()),
                                            V)
                        end, dict:new(), filelib:wildcard(ViewDir++"/*.*.js")),
    Path = DbName ++ "/_design/" ++ ViewCollectionName,
    Doc = {obj, [{"views", Views},
		 {"language", <<"javascript">>}]},
    Doc2 =
	case couchapi:get(Path) of
	     {ok, InstalledViews} -> {ok, RevId} = rfc4627:get_field(InstalledViews, "_rev"),
				     rfc4627:set_field(Doc, "_rev", RevId);
	     _ -> Doc
	 end,
    error_logger:info_msg("Installing view ~s", [Path]),
    {ok, _} = couchapi:put(Path, Doc2).

read_root_config() ->
    {ok, RootConfigUrl} = application:get_env(orchestrator, root_config_url),
    {ok, RootConfig} = couchapi:get({raw, RootConfigUrl}),
    case rfc4627:get_field(RootConfig, "feedshub_version") of
        {ok, ?FEEDSHUB_VERSION} ->
            {ok, RMQ} = rfc4627:get_field(RootConfig, "rabbitmq"),
            {ok, RHost} = rfc4627:get_field(RMQ, "host"),
            {ok, RPort} = rfc4627:get_field(RMQ, "port"),
            RVHost = rfc4627:get_field(RMQ, "virtual_host", <<"/">>),
            {ok, RUser} = rfc4627:get_field(RMQ, "user"),
            {ok, RPassword} = rfc4627:get_field(RMQ, "password"),
            {ok, #amqp_config{host = binary_to_list(RHost),
                              port = RPort,
                              virtual_host = RVHost,
                              user = binary_to_list(RUser),
                              password = binary_to_list(RPassword)}};
        {ok, Other} ->
            exit({feedshub_version_mismatch, [{expected, ?FEEDSHUB_VERSION},
                                              {detected, Other}]})
    end.

startup_couch_scan() ->
    {ok, CouchInfo} = couchapi:get(""),
    {couchdb_presence_check, {ok, _}} = {couchdb_presence_check,
                                         rfc4627:get_field(CouchInfo, "couchdb")},
    {ok, CouchVersion} = rfc4627:get_field(CouchInfo, "version"),
    {couchdb_version_check, true} = {couchdb_version_check, lists:prefix("0.9.", binary_to_list(CouchVersion))},
    case couchapi:get(streams_config:config_db()) of
        {ok, _DbInfo} ->
            ok;
        {error, 404, _} ->
            exit({no_status_db, "You need to create " ++ streams_config:config_db() ++
                  "before running the orchestrator"})
    end,
    install_views(),
    {ok, #amqp_config{}} = read_root_config().

activate_thing(ThingId, Module, Args) when is_binary(ThingId) ->
    case supervisor:start_child(orchestrator_root_sup,
                                {ThingId,
                                 {Module, start_link, [ThingId|Args]},
                                 transient,
                                 5000,
                                 supervisor,
                                 [Module]}) of
        {ok, _ChildPid} ->
            ok;
        {error, {already_started, _Child}} ->
            ok;
	Err -> error_logger:error_report({?MODULE, activate_thing, start_error, {ThingId, Module, Args, Err}}),
            {error, start_error}
    end;
activate_thing(ThingId, Module, Args) ->
    activate_thing(list_to_binary(ThingId), Module, Args).

deactivate_thing(ThingId) when is_binary(ThingId) ->
    Res =
	case supervisor:terminate_child(orchestrator_root_sup, ThingId) of
	    ok ->
		ok;
	    {error, not_found} ->
		ok;
	    {error, simple_one_for_one} ->
		error_logger:error_report({?MODULE, deactivate_thing, supervision_config_error, ThingId}),
		{error, supervision_config_error}
	end,
    case Res of
	ok ->
	    case supervisor:delete_child(orchestrator_root_sup, ThingId) of
		ok ->
		    ok;
		{error, Err} ->
		    error_logger:error_report({?MODULE, deactivate_thing, Err, ThingId})
	    end;
	_ -> Res
    end;
deactivate_thing(ThingId) ->
    deactivate_thing(list_to_binary(ThingId)).

activate_server(ServerId, Args) ->
    activate_thing(ServerId, orchestrator_server_sup, Args).

deactivate_server(ServerId, _Args) ->
    deactivate_thing(ServerId).

id_from_status(Status) ->
    case lists:reverse(Status) of
        "sutats_" ++ T ->
            lists:reverse(T);
        NoStatusSuffix ->
            NoStatusSuffix %% FIXME: this silently assumes that it was called mistakenly
    end.

check_active_servers(Channel, Connection, AmqpConfig) ->
    ServerIds = [id_from_status(binary_to_list(rfc4627:get_field(R, "id", undefined)))
		 || R <- couchapi:get_view_rows(streams_config:config_db(), "servers", "active")],
    lists:foreach(fun(ServerId) -> activate_server(ServerId, [Channel, Connection,
							      Channel, Connection,
							      Channel, Connection,
							      self(), AmqpConfig]) end, ServerIds),
    {ok, length(ServerIds)}.

activate_feed(FeedId, Args) ->
    activate_thing(FeedId, orchestrator_feed_sup, Args).

deactivate_feed(FeedId, _Args) ->
    deactivate_thing(FeedId).

check_active_feeds(Connection, AmqpConfig) ->
    FeedIds = [id_from_status(binary_to_list(rfc4627:get_field(R, "id", undefined)))
               || R <- couchapi:get_view_rows(streams_config:config_db(), "feeds", "active")],
    lists:foreach(fun (FeedId) -> activate_feed(FeedId, [Connection, Connection, AmqpConfig]) end, FeedIds),
    ok.

activate_terminal(TermId, Channel) when is_binary(TermId) ->
    case orchestrator_server:find_servers_for_terminal(TermId) of
        {ok, []} -> ok;
	{ok, ServerIds} ->
	    Props = (amqp_util:basic_properties()) #'P_basic' { delivery_mode = 2 },
            RK = lists:foldl(fun (Sid, Acc) ->
                                     binary_to_list(Sid) ++ [$.|Acc]
                             end, [], ServerIds) ++
                binary_to_list(TermId),
	    lib_amqp:publish(Channel, ?FEEDSHUB_CONFIG_XNAME, list_to_binary(RK),
			     <<"status change">>, Props);
	Err ->
	    error_logger:error_report({?MODULE, thing_terminal, Err, TermId})
    end;
activate_terminal(TermId, Channel) ->
    activate_terminal(list_to_binary(TermId), Channel).

check_active_terminals(Channel) ->
    TermIds =
	[id_from_status(binary_to_list(rfc4627:get_field(R, "id", undefined)))
	 || R <- couchapi:get_view_rows(streams_config:config_db(), "terminals", "active")],
    lists:foreach(fun (TermId) -> activate_terminal(TermId, Channel) end, TermIds),
    ok.

status_change(ThingId, Channel, Connection) when is_list(ThingId) ->
    status_change(list_to_binary(ThingId), Channel, Connection);
status_change(ThingId, Channel, Connection) when is_binary(ThingId) ->
    case streams:status_doc(ThingId) of
	{ok, Doc} ->
	    {On, Off, Args} =
		case rfc4627:get_field(Doc, "type") of
		    %% Terminals should never show up here as they
		    %% should not match the routing key of our queue
		    %% bound to the config exchange, and should be
		    %% picked up directly by the server.
		    {ok, <<"feed-status">>} ->
			{fun activate_feed/2, fun deactivate_feed/2, [ThingId, [Connection, Connection]]};
		    {ok, <<"server-status">>} ->
			{fun activate_server/2, fun deactivate_server/2, [ThingId, [Channel, Connection,
										    Channel, Connection,
										    Channel, Connection]]};
		    Err ->
			error_logger:error_report({?MODULE, status_change, Err, ThingId})
		end,
	    case rfc4627:get_field(Doc, "active") of
		{ok, true} ->
	    	    apply(On, Args);
	     	{ok, false} ->
	     	    apply(Off, Args);
	     	Err2 ->
	     	    error_logger:error_report({?MODULE, status_change, Err2, ThingId})
	    end;
	Err3 ->
	    error_logger:error_report({?MODULE, status_change, Err3, ThingId})
    end.

%%---------------------------------------------------------------------------

server_started_callback(RootPid) ->
    gen_server:cast(RootPid, server_started_callback).

-record(state, {config, amqp_connection, ch, logger_ch, server_startup_waiting}).

init([]) ->
    {ok, Configuration = #amqp_config{host = RHost,
                                      port = RPort,
                                      virtual_host = VHost,
                                      user = RUser,
                                      password = RPassword}}
        = startup_couch_scan(),
    AmqpConnectionPid = amqp_connection:start_network_link(RUser, RPassword, RHost, RPort, VHost),
    Ch = amqp_connection:open_channel(AmqpConnectionPid),
    LogCh = amqp_connection:open_channel(AmqpConnectionPid),
    ok = setup_core_messaging(Ch, LogCh),
    gen_server:cast(self(), setup_logger), %% do this after we're fully running.
    gen_server:cast(self(), check_active_servers), %% do this after we're fully running.
    {ok, #state{config = Configuration,
                amqp_connection = AmqpConnectionPid,
                ch = Ch,
		logger_ch = LogCh
	       }}.

handle_call(open_channel, _From, State = #state{amqp_connection = Conn}) ->
    {reply, {ok, amqp_connection:open_channel(Conn)}, State};
handle_call(_Message, _From, State) ->
    {stop, unhandled_call, State}.

handle_cast(server_started_callback, State = #state { server_startup_waiting = SSW }) when SSW > 1 ->
    {noreply, State #state { server_startup_waiting = SSW - 1 }};
handle_cast(server_started_callback, State = #state { server_startup_waiting = SSW }) when SSW =:= 1 ->
    gen_server:cast(self(), check_active_terminals),
    {noreply, State #state { server_startup_waiting = 0 }};
handle_cast(setup_logger, State = #state {logger_ch = LogCh}) ->
    ok = setup_logger(LogCh),
    {noreply, State};
handle_cast(check_active_servers, State = #state { config=AmqpConf, ch = Ch, amqp_connection = Connection }) ->
    {ok, ServerCount} = check_active_servers(Ch, Connection, AmqpConf),
    if 0 =:= ServerCount -> gen_server:cast(self(), check_active_terminals);
       true -> ok
    end,
    {noreply, State #state { server_startup_waiting = ServerCount }};
%% There's no check_active_feeds because we simply "run on" and do it here,
%% since it will still be in order (servers then terminals then feeds).
handle_cast(check_active_terminals, State = #state { ch = Ch, amqp_connection = Connection, config=AmqpConfig }) ->
    ok = check_active_terminals(Ch),
    ok = check_active_feeds(Connection, AmqpConfig),
    {noreply, State};
handle_cast({status_change, ThingId}, State = #state{ch = Ch, amqp_connection = Connection}) ->
    status_change(ThingId, Ch, Connection),
    {noreply, State};
handle_cast(_Message, State) ->
    {stop, unhandled_cast, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    %% As part of setup_core_messaging, we subscribe to a few
    %% things. Ignore the success notices.
    {noreply, State};
handle_info({#'basic.deliver' { exchange = ?FEEDSHUB_CONFIG_XNAME,
				'delivery_tag' = DeliveryTag,
				'routing_key' = RoutingKey
			       },
	     #content { payload_fragments_rev = [<<"status change">>]}},
	    State = #state{ch = Ch, amqp_connection = Connection}) ->
    status_change(RoutingKey, Ch, Connection),
    lib_amqp:ack(Ch, DeliveryTag),
    {noreply, State};
handle_info({#'basic.deliver' { exchange = ?FEEDSHUB_CONFIG_XNAME,
				'delivery_tag' = DeliveryTag
			       },
	     #content { payload_fragments_rev = [<<"install views">>]}},
	    State = #state{ch = Ch}) ->
    ok = install_views(),
    lib_amqp:ack(Ch, DeliveryTag),
    {noreply, State};
handle_info(_Info, State) ->
    {stop, unhandled_info, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
