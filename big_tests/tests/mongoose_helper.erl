-module(mongoose_helper).

%% API

-export([is_odbc_enabled/1]).

-export([auth_modules/0]).

-export([total_offline_messages/0,
         total_offline_messages/1,
         total_active_users/0,
         total_privacy_items/0,
         total_private_items/0,
         total_vcard_items/0,
         total_roster_items/0]).

-export([clear_last_activity/2,
         clear_caps_cache/1]).

-export([kick_everyone/0]).
-export([ensure_muc_clean/0]).
-export([successful_rpc/3]).
-export([logout_user/2]).
-export([wait_until/3, wait_until/4, factor_backoff/3]).

-import(distributed_helper, [mim/0,
                             require_rpc_nodes/1,
                             rpc/4]).

-spec is_odbc_enabled(Host :: binary()) -> boolean().
is_odbc_enabled(Host) ->
    case rpc(mim(), mongoose_rdbms, sql_transaction, [Host, fun erlang:yield/0]) of
        {atomic, _} -> true;
        _ -> false
    end.

-spec auth_modules() -> [atom()].
auth_modules() ->
    Hosts = rpc(mim(), ejabberd_config, get_global_option, [hosts]),
    lists:flatmap(
        fun(Host) ->
            rpc(mim(), ejabberd_auth, auth_modules, [Host])
        end, Hosts).

-spec total_offline_messages() -> integer() | false.
total_offline_messages() ->
    generic_count(mod_offline_backend).

-spec total_offline_messages({binary(), binary()}) -> integer() | false.
total_offline_messages(User) ->
    generic_count(mod_offline_backend, User).

-spec total_active_users() -> integer() | false.
total_active_users() ->
    generic_count(mod_last_backend).

-spec total_privacy_items() -> integer() | false.
total_privacy_items() ->
    generic_count(mod_privacy_backend).

-spec total_private_items() -> integer() | false.
total_private_items() ->
    generic_count(mod_private_backend).

-spec total_vcard_items() -> integer() | false.
total_vcard_items() ->
    generic_count(mod_vcard_backend).

-spec total_roster_items() -> integer() | false.
total_roster_items() ->
    Domain = ct:get_config({hosts, mim, domain}),
    RosterMnesia = rpc(mim(), gen_mod, is_loaded, [Domain, mod_roster]),
    RosterODBC = rpc(mim(), gen_mod, is_loaded, [Domain, mod_roster_odbc]),
    case {RosterMnesia, RosterODBC} of
        {true, _} ->
            generic_count_backend(mod_roster_mnesia);
        {_, true} ->
            generic_count_backend(mod_roster_odbc);
        _ ->
            false
    end.

%% Need to clear last_activity after carol (connected over BOSH)
%% It is possible that from time to time the unset_presence_hook,
%% for user connected over BOSH, is called after user removal.
%% This happens when the BOSH session is closed (on server side)
%% after user's removal
%% In such situation the last info is set back
-spec clear_last_activity(list(), atom() | binary() | [atom() | binary()]) -> no_return().
clear_last_activity(Config, User) ->
    S = ct:get_config({hosts, mim, domain}),
    case catch rpc(mim(), gen_mod, is_loaded, [S, mod_last]) of
        true ->
            do_clear_last_activity(Config, User);
        _ ->
            ok
    end.

do_clear_last_activity(Config, User) when is_atom(User)->
    [U, S, _P] = escalus_users:get_usp(Config, carol),
    Acc = new_mongoose_acc(),
    successful_rpc(mod_last, remove_user, [Acc, U, S]);
do_clear_last_activity(_Config, User) when is_binary(User) ->
    U = escalus_utils:get_username(User),
    S = escalus_utils:get_server(User),
    Acc = new_mongoose_acc(),
    successful_rpc(mod_last, remove_user, [Acc, U, S]);
do_clear_last_activity(Config, Users) when is_list(Users) ->
    lists:foreach(fun(User) -> do_clear_last_activity(Config, User) end, Users).

new_mongoose_acc() ->
    successful_rpc(mongoose_acc, new, []).

clear_caps_cache(CapsNode) ->
    ok = rpc(mim(), mod_caps, delete_caps, [CapsNode]).

get_backend(Module) ->
  case rpc(mim(), Module, backend, []) of
    {badrpc, _Reason} -> false;
    Backend -> Backend
  end.

generic_count(mod_offline_backend, {User, Server}) ->
    rpc(mim(), mod_offline_backend, count_offline_messages, [User, Server, 100]).


generic_count(Module) ->
    case get_backend(Module) of
        false -> %% module disabled
            false;
        B when is_atom(B) ->
            generic_count_backend(B)
    end.

generic_count_backend(mod_offline_mnesia) -> count_wildpattern(offline_msg);
generic_count_backend(mod_offline_odbc) -> count_odbc(<<"offline_message">>);
generic_count_backend(mod_offline_riak) -> count_riak(<<"offline">>);
generic_count_backend(mod_last_mnesia) -> count_wildpattern(last_activity);
generic_count_backend(mod_last_odbc) -> count_odbc(<<"last">>);
generic_count_backend(mod_last_riak) -> count_riak(<<"last">>);
generic_count_backend(mod_privacy_mnesia) -> count_wildpattern(privacy);
generic_count_backend(mod_privacy_odbc) -> count_odbc(<<"privacy_list">>);
generic_count_backend(mod_privacy_riak) -> count_riak(<<"privacy_lists">>);
generic_count_backend(mod_private_mnesia) -> count_wildpattern(private_storage);
generic_count_backend(mod_private_odbc) -> count_odbc(<<"private_storage">>);
generic_count_backend(mod_private_mysql) -> count_odbc(<<"private_storage">>);
generic_count_backend(mod_private_riak) -> count_riak(<<"private">>);
generic_count_backend(mod_vcard_mnesia) -> count_wildpattern(vcard);
generic_count_backend(mod_vcard_odbc) -> count_odbc(<<"vcard">>);
generic_count_backend(mod_vcard_riak) -> count_riak(<<"vcard">>);
generic_count_backend(mod_vcard_ldap) ->
    D = ct:get_config({hosts, mim, domain}),
    %% number of vcards in ldap is the same as number of users
    rpc(mim(), ejabberd_auth_ldap, get_vh_registered_users_number, [D]);
generic_count_backend(mod_roster_mnesia) -> count_wildpattern(roster);
generic_count_backend(mod_roster_riak) ->
    count_riak(<<"rosters">>),
    count_riak(<<"roster_versions">>);
generic_count_backend(mod_roster_odbc) -> count_odbc(<<"rosterusers">>).

count_wildpattern(Table) ->
    Pattern = rpc(mim(), mnesia, table_info, [Table, wild_pattern]),
    length(rpc(mim(), mnesia, dirty_match_object, [Pattern])).


count_odbc(Table) ->
    {selected, [{N}]} =
        rpc(mim(), mongoose_rdbms, sql_query,
            [<<"localhost">>, [<<"select count(*) from ", Table/binary, " ;">>]]),
    count_to_integer(N).

count_to_integer(N) when is_binary(N) ->
    list_to_integer(binary_to_list(N));
count_to_integer(N) when is_integer(N)->
    N.

count_riak(BucketType) ->
    {ok, Buckets} = rpc(mim(), mongoose_riak, list_buckets, [BucketType]),
    BucketKeys = [rpc(mim(), mongoose_riak, list_keys, [{BucketType, Bucket}]) || Bucket <- Buckets],
    length(lists:flatten(BucketKeys)).

kick_everyone() ->
    [rpc(mim(), ejabberd_c2s, stop, [Pid]) || Pid <- get_session_pids()],
    asset_session_count(0, 50).

asset_session_count(Expected, Retries) ->
    case wait_for_session_count(Expected, Retries) of
        Expected ->
            ok;
        Other ->
            ct:fail({asset_session_count, {expected, Expected}, {value, Other}})
    end.

wait_for_session_count(Expected, Retries) ->
    case length(get_session_specs()) of
        Expected ->
            Expected;
        _Other when Retries > 0 ->
            timer:sleep(100),
            wait_for_session_count(Expected, Retries-1);
        Other ->
            Other
    end.

get_session_specs() ->
    rpc(mim(), supervisor, which_children, [ejabberd_c2s_sup]).

get_session_pids() ->
    [element(2, X) || X <- get_session_specs()].


ensure_muc_clean() ->
    stop_online_rooms(),
    forget_persistent_rooms().

stop_online_rooms() ->
    Host = ct:get_config({hosts, mim, domain}),
    Supervisor = rpc(mim(), gen_mod, get_module_proc, [Host, ejabberd_mod_muc_sup]),
    SupervisorPid = rpc(mim(), erlang, whereis, [Supervisor]),
    rpc(mim(), erlang, exit, [SupervisorPid, kill]),
    rpc(mim(), mnesia, clear_table, [muc_online_room]),
    ok.

forget_persistent_rooms() ->
    rpc(mim(), mnesia, clear_table, [muc_room]),
    rpc(mim(), mnesia, clear_table, [muc_registered]),
    ok.

-spec successful_rpc(atom(), atom(), list()) -> term().
successful_rpc(Module, Function, Args) ->
    case rpc(mim(), Module, Function, Args) of
        {badrpc, Reason} ->
            ct:fail({badrpc, Module, Function, Args, Reason});
        Result ->
            Result
    end.

%% This function is a version of escalus_client:stop/2
%% that ensures that c2s process is dead.
%% This allows to avoid race conditions.
logout_user(Config, User) ->
    Resource = escalus_client:resource(User),
    Username = escalus_client:username(User),
    Server = escalus_client:server(User),
    Result = successful_rpc(ejabberd_sm, get_session_pid,
                            [Username, Server, Resource]),
    case Result of
        none ->
            %% This case can be a side effect of some error, you should
            %% check your test when you see the message.
            ct:pal("issue=user_not_registered jid=~ts@~ts/~ts",
                   [Username, Server, Resource]),
            escalus_client:stop(Config, User);
        Pid when is_pid(Pid) ->
            MonitorRef = erlang:monitor(process, Pid),
            escalus_client:stop(Config, User),
            %% Wait for pid to die
            receive
                {'DOWN', MonitorRef, _, _, _} ->
                    ok
                after 10000 ->
                    ct:pal("issue=c2s_still_alive "
                            "jid=~ts@~ts/~ts pid=~p",
                           [Username, Server, Resource, Pid]),
                    ct:fail({logout_user_failed, {Username, Resource, Pid}})
            end
    end.

% @doc Waits for `Fun` to return `ExpectedValue`.
% Each time Different value is returned or
% functions throws an error, we sleep.
% Sleep time is 2x longer each try
% but not longer than `max_time`
factor_backoff(Fun, ExpectedValue, #{attempts := Attempts,
                                     min_time := Mintime,
                                     max_time := Maxtime}) ->
    do_wait_until(Fun, ExpectedValue, #{attempts => Attempts,
                                        sleep_time => Mintime,
                                        history => [],
                                        next_sleep_time_fun => fun(E) ->
                                                                  min(E * 2, Maxtime)
                                                          end}).

wait_until(Predicate, Attempts, Sleeptime) ->
    wait_until(Predicate, true, Attempts, Sleeptime).

wait_until(Fun, ExpectedValue, Attempts, SleepTime) ->
    do_wait_until(Fun, ExpectedValue, #{attempts => Attempts,
                                        sleep_time => SleepTime,
                                        history => [],
                                        next_sleep_time_fun => fun(E) -> E end}).


do_wait_until(_Fun, _ExpectedValue, #{attempts := 0, history := History}) ->
    error({badmatch, History});
do_wait_until(Fun, ExpectedValue, #{attempts := AttemptsLeft,
                                    sleep_time := SleepTime,
                                    history := History,
                                    next_sleep_time_fun := NextSleepTimeFun} = State) ->
    try Fun() of
        ExpectedValue ->
            ok;
        OtherValue ->
            wait_and_continue(Fun, ExpectedValue, OtherValue, State)
    catch Error:Reason ->
              wait_and_continue(Fun, ExpectedValue, {Error, Reason}, State)
    end.

wait_and_continue(Fun, ExpectedValue, FunResult, #{attempts := AttemptsLeft,
                                                   sleep_time := SleepTime,
                                                   next_sleep_time_fun := NextSleepTimeFun,
                                                   history := History} = State) ->
    timer:sleep(SleepTime),
    do_wait_until(Fun,
                  ExpectedValue,
                  State#{attempts => dec_attempts(AttemptsLeft),
                         sleep_time => NextSleepTimeFun(SleepTime),
                         history => [FunResult | History]}).



dec_attempts(infinity) -> infinity;
dec_attempts(Attempts) -> Attempts - 1.
