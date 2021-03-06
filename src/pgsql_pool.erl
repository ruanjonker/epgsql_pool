% vim: ts=4 sts=4 sw=4 et:
-module(pgsql_pool).

-export([start_link/2, start_link/3, stop/1]).
-export([get_connection/1, get_connection/2, return_connection/2]).
-export([get_database/1, status/1]).

-export([init/1, code_change/3, terminate/2]). 
-export([handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {id, size, connections, monitors, waiting, opts, timer}).

%% -- client interface --

opts(Opts) ->
    Defaults = [{host, "localhost"},
                {port, 5432},
                {password, ""},
                {username, "zotonic"},
                {database, "zotonic"},
                {schema, "public"}],
    Opts2 = lists:ukeysort(1, proplists:unfold(Opts)),
    proplists:normalize(lists:ukeymerge(1, Opts2, Defaults), []).


start_link(Size, Opts) ->
    gen_server:start_link(?MODULE, {undefined, Size, opts(Opts)}, []).

start_link(undefined, Size, Opts) ->
    start_link(Size, Opts);
start_link(Name, Size, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Size, opts(Opts)}, []).

%% @doc Stop the pool, close all db connections
stop(P) ->
    gen_server:cast(P, stop).

%% @doc Get a db connection, wait at most 10 seconds before giving up.
get_connection(P) ->
    get_connection(P, 10000).

%% @doc Get a db connection, wait at most Timeout seconds before giving up.
get_connection(P, Timeout) ->
    try
        gen_server:call(P, get_connection, Timeout)
    catch 
        _:_ ->
            gen_server:cast(P, {cancel_wait, self()}),
            {error, timeout}
    end.

%% @doc Return a db connection back to the connection pool.
return_connection(P, C) ->
    gen_server:cast(P, {return_connection, C}).

%% @doc Return the name of the database used for the pool.
get_database(P) ->
    {ok, C} = get_connection(P),
    {ok, Db} = pgsql_connection:database(C),
    return_connection(P, C),
    {ok, Db}.

%% @doc Return the current status of the connection pool.
status(P) ->
    gen_server:call(P, status).
    

%% -- gen_server implementation --

init({Name, Size, Opts}) ->
    process_flag(trap_exit, true),
    Id = case Name of 
        undefined -> self();
        _Name -> Name
    end,
    Connections = case connect(Opts) of
         {ok, Connection} ->
             [{Connection, now_secs()}];
         {error, _Error} ->
             []
     end,
    {ok, TRef} = timer:send_interval(60000, close_unused),
    State = #state{
      id          = Id,
      size        = Size,
      opts        = Opts,
      connections = Connections,
      monitors    = [],
      waiting     = queue:new(),
      timer       = TRef},
    {ok, State}.

%% Requestor wants a connection. When available then immediately return, otherwise add to the waiting queue.
handle_call(get_connection, From, State) ->
    handle_call({get_connection, wait}, From, State);

%% Requestor wants a connection immediately.
handle_call(get_connection_nowait, From, State) ->
    handle_call({get_connection, nowait}, From, State);

handle_call({get_connection, WaitMode}, From, #state{connections = Connections, waiting = Waiting} = State) ->
    case Connections of
        [{C, _} | T] -> 
            {noreply, deliver(From, C, State#state{connections = T})};
        [] ->
            case length(State#state.monitors) < State#state.size of
                true ->
                    case connect(State#state.opts) of
                        {ok, C} ->
                            {noreply, deliver(From, C, State)};
                        {error, _Error} ->
                            {reply, {error, busy}, State}
                    end;
                false ->
                    case WaitMode of
                        wait ->
                            {noreply, State#state{waiting = queue:in(From, Waiting)}};
                        nowait ->
                            {reply, {error, busy}, State}
                    end
            end
    end;

%% Return the status of the connection pool
handle_call(status, _From, State) ->
    {reply, [{free, length(State#state.connections)}, {in_use, length(State#state.monitors)}, {size, State#state.size}, {waiting, queue:len(State#state.waiting)}], State};

%% Return full status of the connection pool
handle_call(full_status, _From, State) ->
    {reply, State, State};
    
%% Trap unsupported calls
handle_call(Request, _From, State) ->
    {stop, {unsupported_call, Request}, State}.

%% Connection returned from the requestor, back into our pool.  Demonitor the requestor.
handle_cast({return_connection, C}, #state{monitors = Monitors} = State) ->
    case lists:keytake(C, 1, Monitors) of
        {value, {C, M}, Monitors2} ->
            erlang:demonitor(M),
            {noreply, return(C, State#state{monitors = Monitors2})};
        false ->
            {noreply, State}
    end;

%% Requestor gave up (timeout), remove from our waiting queue (if any).
handle_cast({cancel_wait, Pid}, #state{waiting = Waiting} = State) ->
    Waiting2 = queue:filter(fun({QPid, _Tag}) -> QPid =/= Pid end, Waiting),
    {noreply, State#state{waiting = Waiting2}};

%% Stop the connections pool.
handle_cast(stop, State) ->
    {stop, normal, State};

%% Trap unsupported casts
handle_cast(Request, State) ->
    {stop, {unsupported_cast, Request}, State}.

%% Close all connections that are unused for longer than a minute.
%% echo: disabled by siden (2011-07)
handle_info(close_unused, State) ->
    {noreply, State};
%% echo: not used for now (2011-07)
handle_info(never_close_unused, State) ->
    Old = now_secs() - 60,
    {Unused, Used} = lists:partition(fun({_C,Time}) -> Time < Old end, State#state.connections),
    [ pgsql:close(C) || {C,_} <- Unused ],
    {noreply, State#state{connections=Used}};

%% Requestor we are monitoring went down. Kill the associated connection, as it might be in an unknown state.
handle_info({'DOWN', M, process, _Pid, _Info}, #state{monitors = Monitors} = State) ->
    case lists:keytake(M, 2, Monitors) of
        {value, {C, M}, Monitors2} ->
            catch pgsql:close(C),
            {noreply, State#state{monitors = Monitors2}};
        false ->
            {noreply, State}
    end;

%% One of our database connections went down. Clean up our administration.
handle_info({'EXIT', ConnectionPid, _Reason}, State) ->
    #state{connections = Connections, monitors = Monitors} = State,
    Connections2 = proplists:delete(ConnectionPid, Connections),
    F = fun({C, M}) when C == ConnectionPid ->
            erlang:demonitor(M),
            false;
        ({_, _}) -> true
    end,
    Monitors2 = lists:filter(F, Monitors),
    {noreply, State#state{connections = Connections2, monitors = Monitors2}};

%% Trap unsupported info calls.
handle_info(Info, State) ->
    {stop, {unsupported_info, Info}, State}.

terminate(_Reason, State) ->
    timer:cancel(State#state.timer),
    ok.

code_change(_OldVsn, State, _Extra) ->
    State.

%% -- internal functions --

connect(Opts) ->
    Host     = proplists:get_value(host, Opts),
    Username = proplists:get_value(username, Opts),
    Password = proplists:get_value(password, Opts),
    try
        connect_ll(Host, Username, Password, Opts)
    catch C:R ->
        {error, {C, R}}
    end.

connect_ll(Host, Username, Password, Opts) ->
    {ok, Conn} = pgsql:connect(Host, Username, Password, Opts),
    {ok, [], []} = pgsql:squery(Conn, "SET search_path TO " ++ proplists:get_value(schema, Opts)),
    {ok, Conn}.

deliver({Pid,_Tag} = From, C, #state{monitors=Monitors} = State) ->
    M = erlang:monitor(process, Pid),
    gen_server:reply(From, {ok, C}),
    State#state{ monitors=[{C, M} | Monitors] }.

return(C, #state{connections = Connections, waiting = Waiting} = State) ->
    case queue:out(Waiting) of
        {{value, From}, Waiting2} ->
            State2 = deliver(From, C, State),
            State2#state{waiting = Waiting2};
        {empty, _Waiting} ->
            Connections2 = Connections ++ [{C, now_secs()}],
            State#state{connections = Connections2}
    end.

%% Return the current time in seconds, used for timeouts.
now_secs() ->
    {M,S,_M} = erlang:now(),
    M*1000000 + S.
