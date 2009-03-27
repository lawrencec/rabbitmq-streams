-module(couchapi).

%% Low-level.
-export([get/1, post/2, put/2, delete/1]).

%% Mid-level.
-export([simple_result/1]).

%% Somewhat higher-level.
-export([all_dbs/0, createdb/1]).

%%---------------------------------------------------------------------------

get(Url) ->
    get1(Url).

%% get1, put1 exist so we don't have to call unqualified get() or
%% put() anywhere (they overlap with the process dictionary).
get1(Url) ->
    request(get, expand(Url)).

post(Url, Value) ->
    request(post, expand(Url), Value).

put(Url, Value) ->
    put1(Url, Value).

put1(Url, Value) ->
    request(put, expand(Url), Value).

delete(Url) ->
    request(delete, expand(Url)).


simple_result({ok, V = {obj, _}}) ->
    case rfc4627:get_field(V, "ok") of
        {ok, true} ->
            ok;
        {ok, _Other} ->
            {error, {not_ok, V}, <<"Unexpected non-OK response.">>};
        not_found ->
            case rfc4627:get_field(V, "error") of
                {ok, ErrorBin} ->
                    case rfc4627:get_field(V, "reason") of
                        {ok, ReasonBin} ->
                            {error, binary_to_list(ErrorBin), ReasonBin};
                        not_found ->
                            {error, binary_to_list(ErrorBin), undefined}
                    end;
                not_found ->
                    {error, {not_ok, V}, <<"Unexpected response.">>}
            end
    end;
simple_result({ok, Other}) ->
    {error, {not_ok, Other}, <<"Unexpected JSON object.">>};
simple_result(Other = {error, _}) ->
    Other.


all_dbs() ->
    get1("_all_dbs").

createdb(DbName) ->
    simple_result(put1(DbName, null)).

%%---------------------------------------------------------------------------

request(Method, Url) ->
    request1(Method, {Url, []}).

request(Method, Url, Term) ->
    request1(Method, {Url, [], "application/json", rfc4627:encode(Term)}).

request1(Method, Request) ->
    process_response(http:request(Method, Request, [{version, "HTTP/1.0"}], [])).

expand({raw, AbsUrl}) ->
    AbsUrl;
expand(RelUrl) ->
    {ok, CouchBaseUrl} = application:get_env(couch_base_url),
    CouchBaseUrl ++ RelUrl.

process_response({ok, {{_HttpVersion, StatusCode, _StatusLine}, _Headers, Body}}) ->
    process_json_response(StatusCode, Body);
process_response({ok, {StatusCode, Body}}) ->
    process_json_response(StatusCode, Body);
process_response(E = {error, _}) ->
    E.

process_json_response(StatusCode, Body)
  when StatusCode >= 200 andalso StatusCode < 300 ->
    case rfc4627:decode(Body) of
        {ok, Value, _Remainder} ->
            {ok, Value};
        {error, DecodeError} ->
            {error, {json_decode_error, DecodeError}}
    end;
process_json_response(StatusCode, Body) ->
    case rfc4627:decode(Body) of
        {ok, Value, _Remainder} ->
            {error, StatusCode, Value};
        {error, DecodeError} ->
            {error, StatusCode, {json_decode_error, DecodeError}}
    end.