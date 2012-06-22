-module(yokozuna_entropy).
-compile(export_all).
-include("yokozuna.hrl").

-define(HOUR_SEC, 60 * 60).
-define(DAY_SEC, ?HOUR_SEC * 24).

%% @doc This module contains functionality related to entropy.
%%
%% TODO: proper supervision and probably make tree proc a gen_server

%%%===================================================================
%%% API
%%%===================================================================

-spec new_tree_proc(tree_name()) -> tree_ref() | already_running.
new_tree_proc(Name) ->
    case whereis(Name) of
        undefined ->
            {Pid, Ref} = spawn_monitor(?MODULE, tree_loop, []),
            register(Name, Pid),
            #tree_ref{name=Name, pid=Pid, ref=Ref};
        Pid ->
            {already_running, Pid}
    end.

%%%===================================================================
%%% Private
%%%===================================================================

gen_before() ->
    DateTime = calendar:now_to_universal_time(os:timestamp()),
    to_datetime(minus_period(DateTime, [{mins, 5}])).

build_tree() ->
    Before = gen_before(),
    T1 = hashtree:new(),
    SV = yokozuna_solr:get_vclocks(Before, none, 100),
    iterate_vclocks(Before, T1, SV).

ht_insert({Key, VCHash}, Tree) ->
    hashtree:insert(Key, VCHash, Tree).

iterate_vclocks(Before, Tree, #solr_vclocks{more=true,
                                            continuation=Cont,
                                            pairs=Pairs}) ->
    Tree2 = lists:foldl(fun ht_insert/2, Tree, Pairs),
    SV = yokozuna_solr:get_vclocks(Before, Cont, 100),
    iterate_vclocks(Before, Tree2, SV);
iterate_vclocks(_, Tree, #solr_vclocks{more=false,
                                       pairs=Pairs}) ->
    Tree2 = lists:foldl(fun ht_insert/2, Tree, Pairs),
    hashtree:update_tree(Tree2).

%% @doc Minus Period from DateTime.
%%
%% @spec minus_period(DateTime, Period::Period) -> DateTime
%%   DateTime = {{Year, Month, Day}, {Hour, Min, Sec}}
%%   Period = {period, {days, integer()}, {hours, integer()}}
%%
minus_period(DateTime, Periods) ->
    Days = proplists:get_value(days, Periods, 0),
    Hours = proplists:get_value(hours, Periods, 0),
    Minutes = proplists:get_value(minutes, Periods, 0),
    PeriodSecs = (Days * ?DAY_SEC) + (Hours * ?HOUR_SEC) + (Minutes * 60),
    DateTimeSecs = calendar:datetime_to_gregorian_seconds(DateTime),
    calendar:gregorian_seconds_to_datetime(DateTimeSecs - PeriodSecs).

%% @doc Convert `erlang:now/0' or calendar datetime type to an ISO8601
%% datetime string.
%%
%% @spec(Now | DateTime) -> ISO8601
%%   Now = {MegaSecs, Secs, MicroSecs}
%%   DateTime = {{Year, Month, Day}, {Hour, Min, Sec}}
%%   ISO8601 = binary()
%%
%%
%% TODO: rename to_iso8601
to_datetime({_Mega, _Secs, _Micro}=Now) ->
    to_datetime(calendar:now_to_datetime(Now));
to_datetime({{Year, Month, Day}, {Hour, Min, Sec}}) ->
    list_to_binary(io_lib:format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0B",
                                 [Year,Month,Day,Hour,Min,Sec])).

tree_loop() ->
    Tree = build_tree(),
    tree_loop(Tree).

tree_loop(Tree) ->
    receive
        %% {pairs, Pairs} ->
        %%     throw(do_something);
        {get_tree, Pid, Ref} ->
            Pid ! {tree, Ref, Tree},
            tree_loop(Tree)
    end.