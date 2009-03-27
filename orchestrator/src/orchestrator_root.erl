-module(orchestrator_root).

-behaviour(gen_server).

-export([start_link/0]).
-export([open_channel/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(ROOT_CONFIG_DOCID, ?FEEDSHUB_CONFIG_DBNAME "root_config").

-include("orchestrator.hrl").
-include("rabbit_framing.hrl").

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

open_channel() ->
    gen_server:call(?SERVER, open_channel).

%%---------------------------------------------------------------------------

-record(root_config, {rabbitmq_host, rabbitmq_admin_user, rabbitmq_admin_password}).

setup_core_messaging(Ch) ->
    #'exchange.declare_ok'{} =
        amqp_channel:call(Ch, #'exchange.declare'{exchange = ?FEEDSHUB_CONFIG_XNAME,
                                                  type = <<"topic">>,
                                                  durable = true}),
    PrivateQ = lib_amqp:declare_private_queue(Ch),
    #'queue.bind_ok'{} = lib_amqp:bind_queue(Ch, ?FEEDSHUB_CONFIG_XNAME, PrivateQ, <<"#">>),
    _ConsumerTag = lib_amqp:subscribe(Ch, PrivateQ, self()),
    ok.

install_views() ->
    lists:foreach(fun install_view/1,
                  filelib:wildcard(orchestrator:priv_dir()++"/views/*")).

install_view(ViewDir) ->
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
    {ok, _} = couchapi:put(?FEEDSHUB_CONFIG_DBNAME"_design/" ++ ViewCollectionName,
                           {obj, [{"views", Views},
                                  {"language", <<"javascript">>}]}).

setup_core_couch() ->
    ok = couchapi:createdb(?FEEDSHUB_CONFIG_DBNAME),
    {ok, _} = couchapi:put(?ROOT_CONFIG_DOCID,
                           {obj, [{"feedshub_version", ?FEEDSHUB_VERSION},
                                  {"rabbitmq", {obj, [{"host", <<"localhost">>},
                                                      {"user", <<"feedshub_admin">>},
                                                      {"password", <<"feedshub_admin">>}]}}
                                 ]}),
    ok = install_views(),
    ok.

read_root_config() ->
    {ok, RootConfig} = couchapi:get(?ROOT_CONFIG_DOCID),
    case rfc4627:get_field(RootConfig, "feedshub_version") of
        {ok, ?FEEDSHUB_VERSION} ->
            {ok, RMQ} = rfc4627:get_field(RootConfig, "rabbitmq"),
            {ok, RHost} = rfc4627:get_field(RMQ, "host"),
            {ok, RUser} = rfc4627:get_field(RMQ, "user"),
            {ok, RPassword} = rfc4627:get_field(RMQ, "password"),
            {ok, #root_config{rabbitmq_host = binary_to_list(RHost),
                              rabbitmq_admin_user = binary_to_list(RUser),
                              rabbitmq_admin_password = binary_to_list(RPassword)}};
        {ok, Other} ->
            exit({feedshub_version_mismatch, [{expected, ?FEEDSHUB_VERSION},
                                              {detected, Other}]})
    end.

startup_couch_scan() ->
    {ok, CouchInfo} = couchapi:get(""),
    {couchdb_presence_check, {ok, _}} = {couchdb_presence_check,
                                         rfc4627:get_field(CouchInfo, "couchdb")},
    {couchdb_version_check, {ok, <<"0.9.0">>}} = {couchdb_version_check,
                                                  rfc4627:get_field(CouchInfo, "version")},
    case couchapi:get(?FEEDSHUB_CONFIG_DBNAME) of
        {ok, _DbInfo} ->
            ok;
        {error, 404, _} ->
            ok = setup_core_couch()
    end,
    {ok, #root_config{}} = read_root_config().

%%---------------------------------------------------------------------------

-record(state, {config, amqp_connection, ch}).

init([]) ->
    {ok, Configuration = #root_config{rabbitmq_host = RHost,
                                      rabbitmq_admin_user = RUser,
                                      rabbitmq_admin_password = RPassword}}
        = startup_couch_scan(),
    AmqpConnectionPid = amqp_connection:start_link(RUser, RPassword, RHost),
    Ch = amqp_connection:open_channel(AmqpConnectionPid),
    ok = setup_core_messaging(Ch),
    {ok, #state{config = Configuration,
                amqp_connection = AmqpConnectionPid,
                ch = Ch}}.

handle_call(open_channel, _From, State = #state{amqp_connection = Conn}) ->
    {reply, {ok, amqp_connection:open_channel(Conn)}, State};
handle_call(_Message, _From, State) ->
    {stop, unhandled_call, State}.

handle_cast(_Message, State) ->
    {stop, unhandled_cast, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    %% As part of setup_core_messaging, we subscribe to a few
    %% things. Ignore the success notices.
    {noreply, State};
handle_info(_Info, State) ->
    {stop, unhandled_info, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.