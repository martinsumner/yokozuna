%% -------------------------------------------------------------------
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc This module provides the interface for making calls to Solr.
%%      All interaction with Solr should go through this API.

-module(yz_solr).
-export([build_mapping/1,
         commit/1,
         core/2,
         core/3,
         cores/0,
         delete/2,
         dist_search/2,
         dist_search/3,
         encode_delete/1,
         encode_doc/1,
         entropy_data/2,
         get_doc_pairs/1,
         get_ibrowse_config/0,
         get_response/1,
         index_batch/2,
         is_up/0,
         jmx_port/0,
         mbeans_and_stats/1,
         partition_list/1,
         ping/1,
         port/0,
         prepare_json/1,
         set_ibrowse_config/1,
         search/3]).
-include_lib("riak_core/include/riak_core_bucket_type.hrl").
-include("yokozuna.hrl").

-define(CORE_ALIASES, [{index_dir, instanceDir},
                       {cfg_file, config},
                       {schema_file, schema},
                       {delete_instance, deleteInstanceDir},
                       {delete_index, deleteIndex},
                       {delete_data_dir, deleteDataDir}]).
-define(FIELD_ALIASES, [{continuation, continue},
                        {limit, n}]).
-define(QUERY(Bin), {struct, [{'query', Bin}]}).
-define(LOCALHOST, "localhost").

-type delete_op() :: {id, binary()}
                   | {bkey, bkey()}
                   | {bkey, bkey(), lp()}
                   | {'query', binary()}.

-type ibrowse_config_key() :: max_sessions | max_pipeline_size.
-type ibrowse_config_value() :: pos_integer().
-type ibrowse_config() :: [{ibrowse_config_key(), ibrowse_config_value()}].

-export_type([delete_op/0]).
-export_type([ibrowse_config_key/0, ibrowse_config_value/0, ibrowse_config/0]).

-ifdef(EQC).
%% -define(EQC_DEBUG(S, F), eqc:format(S, F)).
-define(EQC_DEBUG(S, F), ok).
-else.
-define(EQC_DEBUG(S, F), ok).
-endif.



%%%===================================================================
%%% API
%%%===================================================================

%% @doc Create a mapping from the `Nodes' hostname to the port which
%% Solr is listening on.  The resulting list could be smaller than the
%% input in the case that the port cannot be determined for one or
%% more nodes.
-spec build_mapping([node()]) -> [{node(), {string(), string()}}].
build_mapping(Nodes) ->
    [{Node, HP} || {Node, HP={_,P}} <- [{Node, host_port(Node)}
                                        || Node <- Nodes],
                   P /= unknown].

-spec commit(index_name()) -> ok.
commit(Core) ->
    JSON = encode_commit(),
    Params = [{commit, true}, {waitFlush, true}, {waitSearcher, true}],
    Encoded = mochiweb_util:urlencode(Params),
    URL = ?FMT("~s/~s/update?~s", [base_url(), Core, Encoded]),
    Headers = [{content_type, "application/json"}],
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, Headers, post, JSON, Opts,
                          ?YZ_SOLR_REQUEST_TIMEOUT) of
        {ok, "200", _, _} -> ok;
        Err -> throw({"Failed to commit", Err})
    end.

%% @doc Perform Core related actions.
-spec core(atom(), proplist()) -> {ok, list(), binary()} |
                                  {error, term()}.
core(Action, Props) ->
    core(Action, Props, ?YZ_SOLR_REQUEST_TIMEOUT).

-spec core(atom(), proplist(), ms()) -> {ok, list(), binary()} |
                                        {error, term()}.
core(Action, Props, Timeout) ->
    BaseURL = base_url() ++ "/admin/cores",
    Action2 = convert_action(Action),
    Params = proplists:substitute_aliases(?CORE_ALIASES,
                                          [{action, Action2}|Props]),
    Encoded = mochiweb_util:urlencode(Params),
    Opts = [{response_format, binary}],
    URL = BaseURL ++ "?" ++ Encoded,

    case ibrowse:send_req(URL, [], get, [], Opts, Timeout) of
        {ok, "200", Headers, Body} ->
            {ok, Headers, Body};
        {ok, "400", Headers, Body} ->
            case re:run(Body, "already exists") of
                nomatch ->
                    {error, {ok, "400", Headers, Body}};
                _ ->
                    {error, exists}
            end;
        X ->
            {error, X}
    end.

-spec cores() -> {ok, ordset(index_name())} | {error, term()}.
cores() ->
    case yz_solr:core(status, [{wt,json}]) of
        {ok, _, Body} ->
            {struct, Status} = kvc:path([<<"status">>], mochijson2:decode(Body)),
            Cores = ordsets:from_list([Name || {Name, _} <- Status]),
            {ok, Cores};
        {error,_} = Err ->
            Err
    end.

%% @doc Perform the delete `Ops' against the `Index'.
%%
%% There are several types of delete operations.
%%
%%   `{id, Id :: binary()}' - Delete the doc with matching unique id.
%%
%%   `{bkey, BK :: bkey()}' - Delete the doc(s) with matching Riak Key.
%%
%%   `{siblings, BK :: bkey()}' - Delete the doc(s) which are
%%       siblings of the Riak Key.
%%
%%   `{'query', Q :: binary}' - Delete the doc(s) matching query `Q'.
-spec delete(index_name(), [delete_op()]) -> ok | {error, term()}.
delete(Index, Ops) ->
    JSON = mochijson2:encode({struct, [{delete, encode_delete(Op)} || Op <- Ops]}),
    URL = ?FMT("~s/~s/update", [base_url(), Index]),
    Headers = [{content_type, "application/json"}],
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, Headers, post, JSON, Opts,
                          ?YZ_SOLR_REQUEST_TIMEOUT) of
        {ok, "200", _, _} -> ok;
        {ok, "404", _, _} -> {error, nothing_to_delete};
        Err -> {error, Err}
    end.

%% @doc Get slice of entropy data.  Entropy data is used to build
%%      hashtrees for active anti-entropy.  This is meant to be called
%%      in an iterative fashion in order to page through the entropy
%%      data.
%%
%%  `Core' - The core to get entropy data for.
%%
%%  `Filter' - The list of constraints to filter out entropy
%%             data.
%%
%%    `before' - An ios8601 datetime, return data for docs written
%%               before and including this moment.
%%
%%    `continuation' - An opaque value used to continue where a
%%                     previous return left off.
%%
%%    `limit' - The maximum number of entries to return.
%%
%%    `partition' - Return entries for specific logical partition.
%%
%%  `ED' - An entropy data record containing list of entries and
%%         continuation value.
-spec entropy_data(index_name(), ed_filter()) ->
                          ED::entropy_data() | {error, term()}.
entropy_data(Core, Filter) ->
    Params = [{wt, json}|Filter] -- [{continuation, none}],
    Params2 = proplists:substitute_aliases(?FIELD_ALIASES, Params),
    Opts = [{response_format, binary}],
    URL = ?FMT("~s/~s/entropy_data?~s",
               [base_url(), Core, mochiweb_util:urlencode(Params2)]),
    case ibrowse:send_req(URL, [], get, [], Opts, ?YZ_SOLR_ED_REQUEST_TIMEOUT) of
        {ok, "200", _Headers, Body} ->
            R = mochijson2:decode(Body),
            More = kvc:path([<<"more">>], R),
            Continuation = get_continuation(More, R),
            Pairs = get_pairs(R),
            make_ed(More, Continuation, Pairs);
        X ->
            {error, X}
    end.

index_batch(Core, Ops) ->
    ?EQC_DEBUG("index_batch: About to send entries. ~p~n", [Ops]),
    JSON = encode_json(Ops),
    ?EQC_DEBUG("index_batch: About to send JSON. ~p~n", [JSON]),
    maybe_make_http_request(Core, JSON).

maybe_make_http_request(_Core, {error, _} = Error) ->
    ?EQC_DEBUG("Not making HTTP request due to error: ~p", [Error]),
    Error;
maybe_make_http_request(Core, JSON) ->
    URL = ?FMT("~s/~s/update", [base_url(), Core]),
    Headers = [{content_type, "application/json"}],
    Opts = [{response_format, binary}],
    ?EQC_DEBUG("About to send_req: ~p", [[URL, Headers, post, JSON, opts, ?YZ_SOLR_REQUEST_TIMEOUT]]),
    Res = case ibrowse:send_req(URL, Headers, post, JSON, Opts,
                          ?YZ_SOLR_REQUEST_TIMEOUT) of
        {ok, "200", _, _} -> ok;
        {ok, "400", _, ErrBody} ->
            {error, {badrequest, ErrBody}};
        Err ->
            {error, {other, Err}}
    end,
    %% ?PULSE_DEBUG("send_req result: ~p", [Res]),
    Res.

encode_json(Ops) ->
    JSON = try
               mochijson2:encode({struct, Ops})
           catch _:E ->
        {error, {bad_data, E}}
           end,
    ?EQC_DEBUG("Encoded JSON: ~p", [JSON]),
    JSON.

%% @doc Determine if Solr is running.
-spec is_up() -> boolean().
is_up() ->
    case cores() of
        {ok, _Cores} -> true;
        _ -> false
    end.

-spec mbeans_and_stats(index_name()) -> {ok, JSON :: binary()} |
                                        {error, Reason :: term()}.
mbeans_and_stats(Index) ->
    Params = [{stats, <<"true">>},
              {wt, <<"json">>}],
    URL = ?FMT("~s/~s/admin/mbeans?~s", [base_url(), Index, mochiweb_util:urlencode(Params)]),
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, [], get, [], Opts) of
        {ok, "200", _, Body} -> {ok, Body};
        Err -> {error, Err}
    end.

prepare_json(Docs) ->
    Content = {struct, [{add, encode_doc(D)} || D <- Docs]},
    mochijson2:encode(Content).

%% @doc Return the set of unique partitions stored on this node.
-spec partition_list(index_name()) -> {ok, Resp::binary()} | {error, term()}.
partition_list(Core) ->
    Params = [{q, "*:*"},
              {facet, "on"},
              {"facet.mincount", "1"},
              {"facet.field", ?YZ_PN_FIELD_S},
              {wt, "json"}],
    Encoded = mochiweb_util:urlencode(Params),
    URL = ?FMT("~s/~s/select?~s", [base_url(), Core, Encoded]),
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, [], get, [], Opts, ?YZ_SOLR_REQUEST_TIMEOUT) of
        {ok, "200", _, Resp} -> {ok, Resp};
        Err -> {error, Err}
    end.

%% @doc Return boolean based on ping response from Solr.
-spec ping(index_name()) -> boolean()|error.
ping(Core) ->
    URL = ?FMT("~s/~s/admin/ping", [base_url(), Core]),
    Response = ibrowse:send_req(URL, [], head),
    Result = case Response of
        {ok, "200", _, _} -> true;
        {ok, "404", _, _} -> false;
        _ -> error
    end,
    Result.

-spec port() -> non_neg_integer().
port() ->
    app_helper:get_env(?YZ_APP_NAME, solr_port, ?YZ_DEFAULT_SOLR_PORT).

jmx_port() ->
    app_helper:get_env(?YZ_APP_NAME, solr_jmx_port, undefined).

dist_search(Core, Params) ->
    dist_search(Core, [], Params).

dist_search(Core, Headers, Params) ->
    Plan = yz_cover:plan(Core),
    case Plan of
        {ok, {Nodes, FilterPairs, Mapping}} ->
            HostPorts = [proplists:get_value(Node, Mapping) || Node <- Nodes],
            ShardFrags = [shard_frag(Core, HostPort) || HostPort <- HostPorts],
            ShardFrags2 = string:join(ShardFrags, ","),
            ShardFQs = build_shard_fq(FilterPairs, Mapping),
            Params2 = Params ++ [{shards, ShardFrags2}|ShardFQs],
            search(Core, Headers, Params2);
        {error, _} = Err ->
            Err
    end.

search(Core, Headers, Params) ->
    Body = mochiweb_util:urlencode(Params),
    URL = ?FMT("~s/~s/select", [base_url(), Core]),
    Headers2 = [{content_type, "application/x-www-form-urlencoded"}|Headers],
    Opts = [{response_format, binary}],
    case ibrowse:send_req(URL, Headers2, post, Body, Opts,
                          ?YZ_SOLR_REQUEST_TIMEOUT) of
        {ok, "200", RHeaders, Resp} -> {RHeaders, Resp};
        {ok, CodeStr, _, Err} ->
            {Code, _} = string:to_integer(CodeStr),
            lager:error("Solr search ~p failed. Response was: ~p:~p", [URL, Err, CodeStr]),
            throw({solr_error, {Code, URL, Err}});
        Err ->
            lager:error("ibrowse error making Solr search ~p request. Error was: ~p", [URL, Err]),
            throw({"Failed to search", URL, Err})
    end.

-spec set_ibrowse_config(ibrowse_config()) -> ok.
set_ibrowse_config(Config) ->
    lists:foreach(
      fun({Key, Value}) -> set_ibrowse_config(Key, Value) end,
      Config),
    ok.

set_ibrowse_config(?YZ_SOLR_MAX_SESSIONS, Max) when is_integer(Max), Max > 0 ->
    ibrowse:set_max_sessions(?LOCALHOST, port(), Max);
set_ibrowse_config(?YZ_SOLR_MAX_PIPELINE_SIZE, Max) when is_integer(Max), Max > 0 ->
    ibrowse:set_max_pipeline_size(?LOCALHOST, port(), Max).

get_ibrowse_config() ->
    [{?YZ_SOLR_MAX_SESSIONS, get_ibrowse_config(?YZ_SOLR_MAX_SESSIONS)},
     {?YZ_SOLR_MAX_PIPELINE_SIZE, get_ibrowse_config(?YZ_SOLR_MAX_PIPELINE_SIZE)}].

get_ibrowse_config(Key) ->
    try
        ibrowse:get_config_value({Key, ?LOCALHOST, port()}, undefined)
    catch
        _ -> undefined
    end.

%%%===================================================================
%%% Private
%%%===================================================================

%% @doc Get the base URL.
base_url() ->
    "http://" ++ ?LOCALHOST ++ ":" ++ integer_to_list(port()) ++
        ?SOLR_HOST_CONTEXT.

%% @private
%%
%% @doc Build list of per-node filter queries.
-spec build_shard_fq(logical_cover_set(), solr_host_mapping()) ->
                            [{binary(), string()}].
build_shard_fq(LCoverSet, Mapping) ->
    GroupedByNode = yz_misc:group_by(LCoverSet, fun group_by_node/1),
    [begin
         {Host, Port} = proplists:get_value(Node, Mapping),
         Key = <<(list_to_binary(Host))/binary,":",(list_to_binary(Port))/binary>>,
         Value = partition_filters_to_str(PartitionFilters),
         {Key, Value}
     end || {Node, PartitionFilters} <- GroupedByNode].

%% @private
%%
%% @doc Get hostname and Solr port for `Node'.  Return `unknown' for
%% the port if the RPC fails.
-spec host_port(node()) -> {string(), string() | unknown}.
host_port(Node) ->
    case rpc:call(Node, yz_solr, port, [], ?YZ_SOLR_PORT_RPC_TIMEOUT) of
        {badrpc, Reason} ->
            ?DEBUG("error retrieving Solr port ~p ~p", [Node, Reason]),
            {yz_misc:hostname(Node), unknown};
        Port when is_integer(Port) ->
            {yz_misc:hostname(Node), integer_to_list(Port)}
    end.

group_by_node({{Partition, Owner}, all}) ->
    {Owner, Partition};
group_by_node({{Partition, Owner}, FPFilter}) ->
    {Owner, {Partition, FPFilter}}.

-spec partition_filters_to_str([{lp(), logical_filter()}]) -> string().
partition_filters_to_str(Partitions) ->
    F = fun({Partition, FPFilter}) ->
                PNQ = pn_str(Partition),
                FPQ = string:join(lists:map(fun fpn_str/1, FPFilter), " OR "),
                "(" ++ PNQ ++ " AND " ++ "(" ++ FPQ ++ "))";
           (Partition) ->
                pn_str(Partition)
        end,
    string:join(lists:map(F, Partitions), " OR ").

pn_str(Partition) ->
    ?YZ_PN_FIELD_S ++ ":" ++ integer_to_list(Partition).

fpn_str(FPN) ->
    ?YZ_FPN_FIELD_S ++ ":" ++ integer_to_list(FPN).

convert_action(create) -> "CREATE";
convert_action(status) -> "STATUS";
convert_action(remove) -> "UNLOAD";
convert_action(reload) -> "RELOAD".

encode_commit() ->
    <<"{}">>.

%% @private
%%
%% @doc Encode a delete operation into a mochijson2 compatiable term.
-spec encode_delete(delete_op()) -> {struct, [{atom(), binary()}]}.
encode_delete({bkey, {{Type, Bucket},Key}, LP}) ->
    PNQ = encode_field_query(?YZ_PN_FIELD_B, escape_special_chars(?INT_TO_BIN(LP))),
    TypeQ = encode_field_query(?YZ_RT_FIELD_B, escape_special_chars(Type)),
    BucketQ = encode_field_query(?YZ_RB_FIELD_B, escape_special_chars(Bucket)),
    KeyQ = encode_field_query(?YZ_RK_FIELD_B, escape_special_chars(Key)),
    ?QUERY(<<TypeQ/binary, " AND ", BucketQ/binary, " AND ", KeyQ/binary, " AND ", PNQ/binary>>);
%% NOTE: Used for testing only. This deletes _all_ documents for _all_ partitions
%% which may cause extra docs to be deleted if a fallback partition exists
%% on the same node as a primary, or if handoff is still ongoing in a newly-built
%% cluster
encode_delete({bkey,{{Type, Bucket},Key}}) ->
    TypeQ = encode_field_query(?YZ_RT_FIELD_B, escape_special_chars(Type)),
    BucketQ = encode_field_query(?YZ_RB_FIELD_B, escape_special_chars(Bucket)),
    KeyQ = encode_field_query(?YZ_RK_FIELD_B, escape_special_chars(Key)),
    ?QUERY(<<TypeQ/binary," AND ",BucketQ/binary, " AND ",KeyQ/binary>>);
%% NOTE: Also only used for testing
encode_delete({bkey,{Bucket,Key}}) ->
    %% Need to take legacy (pre 2.0.0) objects into account.
    encode_delete({bkey,{{?DEFAULT_TYPE, Bucket}, Key}});
encode_delete({bkey, {Bucket,Key}, LP}) ->
    %% Need to take legacy (pre 2.0.0) objects into account.
    encode_delete({bkey, {{?DEFAULT_TYPE, Bucket}, Key}, LP});
encode_delete({'query', Query}) ->
    ?QUERY(Query);
encode_delete({id, Id}) ->
    %% NOTE: Solr uses the name `id' to represent the `uniqueKey'
    %%       field of the schema.  Thus `id' must be passed, not
    %%       `YZ_ID_FIELD'.
    {struct, [{id, Id}]}.

encode_doc({doc, Fields}) ->
    {struct, [{doc, lists:map(fun encode_field/1, Fields)}]}.

encode_field({Name,Value}) when is_list(Value) ->
    {Name, list_to_binary(Value)};
encode_field({Name,Value}) ->
    {Name, Value}.

%% @private
%%
%% @doc Encode a field and query.
-spec encode_field_query(binary(), binary()) -> binary().
encode_field_query(Field, Query) ->
    <<Field/binary,":\"",Query/binary,"\"">>.

%% @private
%%
%% @doc Escape the backslash and double quote chars to prevent from
%% being improperly interpreted by Solr's query parser.
-spec escape_special_chars(binary()) ->binary().
escape_special_chars(Bin) when is_binary(Bin)->
    Bin2 = binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
    binary:replace(Bin2, <<"\"">>, <<"\\\"">>, [global]).

%% @doc Get the continuation value if there is one.
get_continuation(false, _R) ->
    none;
get_continuation(true, R) ->
    kvc:path([<<"continuation">>], R).

get_pairs(R) ->
    Docs = kvc:path([<<"response">>, <<"docs">>], R),
    [to_pair(DocStruct) || DocStruct <- Docs].

%% @doc Convert a doc struct into a pair. Remove the bucket_type to match
%% kv trees when iterating over entropy data to build yz trees.
to_pair({struct, [{_,_Vsn},{_,<<"default">>},{_,BName},{_,Key},{_,Base64Hash}]}) ->
    {{BName,Key}, base64:decode(Base64Hash)};
to_pair({struct, [{_,_Vsn},{_,BType},{_,BName},{_,Key},{_,Base64Hash}]}) ->
    {{{BType, BName},Key}, base64:decode(Base64Hash)}.

get_doc_pairs(Resp) ->
    Docs = kvc:path([<<"docs">>], Resp),
    [to_doc_pairs(DocStruct) || DocStruct <- Docs].

to_doc_pairs({struct, Values}) ->
    Values.

-spec get_response(term()) -> term().
get_response(R) ->
    kvc:path([<<"response">>], R).

make_ed(More, Continuation, Pairs) ->
    #entropy_data{more=More, continuation=Continuation, pairs=Pairs}.

-spec shard_frag(index_name(), {string(), string()}) -> string().
shard_frag(Core, {Host, Port}) ->
    ?FMT("~s:~s"++?SOLR_HOST_CONTEXT++"/~s", [Host, Port, Core]).
