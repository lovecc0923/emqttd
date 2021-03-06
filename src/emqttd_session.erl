%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2015 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%%
%%% Session for persistent MQTT client.
%%%
%%% Session State in the broker consists of:
%%%
%%% 1. The Client’s subscriptions.
%%%
%%% 2. inflight qos1/2 messages sent to the client but unacked, QoS 1 and QoS 2
%%%    messages which have been sent to the Client, but have not been completely
%%%    acknowledged.
%%%
%%% 3. inflight qos2 messages received from client and waiting for pubrel. QoS 2
%%%    messages which have been received from the Client, but have not been
%%%    completely acknowledged.
%%%
%%% 4. all qos1, qos2 messages published to when client is disconnected.
%%%    QoS 1 and QoS 2 messages pending transmission to the Client.
%%%
%%% 5. Optionally, QoS 0 messages pending transmission to the Client.
%%%
%%% State of Message:  newcome, inflight, pending
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(emqttd_session).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

%% Session API
-export([start_link/3, resume/3, destroy/2]).

%% PubSub APIs
-export([publish/2,
         puback/2, pubrec/2, pubrel/2, pubcomp/2,
         subscribe/2, subscribe/3, unsubscribe/2]).

-behaviour(gen_server2).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% gen_server2 Message Priorities
-export([prioritise_call/4, prioritise_cast/3, prioritise_info/3]).

-record(session, {

        %% Clean Session Flag
        clean_sess = true,

        %% ClientId: Identifier of Session
        client_id   :: binary(),

        %% Client Pid bind with session
        client_pid  :: pid(),

        %% Client Monitor
        client_mon  :: reference(),

        %% Last packet id of the session
		packet_id = 1,
        
        %% Client’s subscriptions.
        subscriptions :: list(),

        %% Inflight qos1, qos2 messages sent to the client but unacked,
        %% QoS 1 and QoS 2 messages which have been sent to the Client,
        %% but have not been completely acknowledged.
        %% Client <- Broker
        inflight_queue :: list(),

        max_inflight = 0,

        %% All qos1, qos2 messages published to when client is disconnected.
        %% QoS 1 and QoS 2 messages pending transmission to the Client.
        %%
        %% Optionally, QoS 0 messages pending transmission to the Client.
        message_queue  :: emqttd_mqueue:mqueue(),

        %% Inflight qos2 messages received from client and waiting for pubrel.
        %% QoS 2 messages which have been received from the Client,
        %% but have not been completely acknowledged.
        %% Client -> Broker
        awaiting_rel  :: map(),

        %% Awaiting PUBREL timeout
        await_rel_timeout = 8,

        %% Max Packets that Awaiting PUBREL
        max_awaiting_rel = 100,

        %% Awaiting timers for ack, rel.
        awaiting_ack  :: map(),

        %% Retry interval for redelivering QoS1/2 messages
        retry_interval = 20,

        %% Awaiting for PUBCOMP
        awaiting_comp :: map(),

        %% session expired after 48 hours
        expired_after = 172800,

        expired_timer,

        collect_interval,

        collect_timer,
        
        timestamp}).

-define(PUBSUB_TIMEOUT, 60000).

%%------------------------------------------------------------------------------
%% @doc Start a session.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(boolean(), mqtt_client_id(), pid()) -> {ok, pid()} | {error, any()}.
start_link(CleanSess, ClientId, ClientPid) ->
    gen_server2:start_link(?MODULE, [CleanSess, ClientId, ClientPid], []).

%%------------------------------------------------------------------------------
%% @doc Resume a session.
%% @end
%%------------------------------------------------------------------------------
-spec resume(pid(), mqtt_client_id(), pid()) -> ok.
resume(SessPid, ClientId, ClientPid) ->
    gen_server2:cast(SessPid, {resume, ClientId, ClientPid}).

%%------------------------------------------------------------------------------
%% @doc Destroy a session.
%% @end
%%------------------------------------------------------------------------------
-spec destroy(pid(), mqtt_client_id()) -> ok.
destroy(SessPid, ClientId) ->
    gen_server2:cast(SessPid, {destroy, ClientId}).

%%------------------------------------------------------------------------------
%% @doc Subscribe Topics
%% @end
%%------------------------------------------------------------------------------
-spec subscribe(pid(), [{binary(), mqtt_qos()}]) -> ok.
subscribe(SessPid, TopicTable) ->
    subscribe(SessPid, TopicTable, fun(_) -> ok end).

-spec subscribe(pid(), [{binary(), mqtt_qos()}], AckFun :: fun()) -> ok.
subscribe(SessPid, TopicTable, AckFun) ->
    gen_server2:cast(SessPid, {subscribe, TopicTable, AckFun}).

%%------------------------------------------------------------------------------
%% @doc Publish message
%% @end
%%------------------------------------------------------------------------------
-spec publish(pid(), mqtt_message()) -> ok.
publish(_SessPid, Msg = #mqtt_message{qos = ?QOS_0}) ->
    %% publish qos0 directly
    emqttd_pubsub:publish(Msg);

publish(_SessPid, Msg = #mqtt_message{qos = ?QOS_1}) ->
    %% publish qos1 directly, and client will puback automatically
	emqttd_pubsub:publish(Msg);

publish(SessPid, Msg = #mqtt_message{qos = ?QOS_2}) ->
    %% publish qos2 by session 
    gen_server2:call(SessPid, {publish, Msg}, ?PUBSUB_TIMEOUT).

%%------------------------------------------------------------------------------
%% @doc PubAck message
%% @end
%%------------------------------------------------------------------------------
-spec puback(pid(), mqtt_packet_id()) -> ok.
puback(SessPid, PktId) ->
    gen_server2:cast(SessPid, {puback, PktId}).

-spec pubrec(pid(), mqtt_packet_id()) -> ok.
pubrec(SessPid, PktId) ->
    gen_server2:cast(SessPid, {pubrec, PktId}).

-spec pubrel(pid(), mqtt_packet_id()) -> ok.
pubrel(SessPid, PktId) ->
    gen_server2:cast(SessPid, {pubrel, PktId}).

-spec pubcomp(pid(), mqtt_packet_id()) -> ok.
pubcomp(SessPid, PktId) ->
    gen_server2:cast(SessPid, {pubcomp, PktId}).

%%------------------------------------------------------------------------------
%% @doc Unsubscribe Topics
%% @end
%%------------------------------------------------------------------------------
-spec unsubscribe(pid(), [binary()]) -> ok.
unsubscribe(SessPid, Topics) ->
    gen_server2:cast(SessPid, {unsubscribe, Topics}).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

init([CleanSess, ClientId, ClientPid]) ->
    %% process_flag(trap_exit, true),
    QEnv    = emqttd:env(mqtt, queue),
    SessEnv = emqttd:env(mqtt, session),
    Session = #session{
            clean_sess        = CleanSess,
            client_id         = ClientId,
            client_pid        = ClientPid,
            subscriptions     = [],
            inflight_queue    = [],
            max_inflight      = emqttd_opts:g(max_inflight, SessEnv, 0),
            message_queue     = emqttd_mqueue:new(ClientId, QEnv, emqttd_alarm:alarm_fun()),
            awaiting_rel      = #{},
            awaiting_ack      = #{},
            awaiting_comp     = #{},
            retry_interval    = emqttd_opts:g(unack_retry_interval, SessEnv),
            await_rel_timeout = emqttd_opts:g(await_rel_timeout, SessEnv),
            max_awaiting_rel  = emqttd_opts:g(max_awaiting_rel, SessEnv),
            expired_after     = emqttd_opts:g(expired_after, SessEnv) * 3600,
            collect_interval  = emqttd_opts:g(collect_interval, SessEnv, 0),
            timestamp         = os:timestamp()},
    emqttd_sm:register_session(CleanSess, ClientId, info(Session)),
    %% monitor client
    MRef = erlang:monitor(process, ClientPid),
    %% start statistics
    {ok, start_collector(Session#session{client_mon = MRef}), hibernate}.

prioritise_call(Msg, _From, _Len, _State) ->
    case Msg of _  -> 0 end.

prioritise_cast(Msg, _Len, _State) ->
    case Msg of
        {destroy, _}        -> 10;
        {resume, _, _}      -> 9;
        {pubrel,  _PktId}   -> 8;
        {pubcomp, _PktId}   -> 8;
        {pubrec,  _PktId}   -> 8;
        {puback,  _PktId}   -> 7;
        {unsubscribe, _, _} -> 6;
        {subscribe, _, _}   -> 5;
        _                   -> 0
    end.

prioritise_info(Msg, _Len, _State) ->
    case Msg of
        {'DOWN', _, _, _, _} -> 10;
        {'EXIT', _, _}  -> 10;
        session_expired -> 10;
        {timeout, _, _} -> 5;
        collect_info    -> 2;
        {dispatch, _}   -> 1;
        _               -> 0
    end.

handle_call({publish, Msg = #mqtt_message{qos = ?QOS_2, pktid = PktId}}, _From,
                Session = #session{client_id         = ClientId,
                                   awaiting_rel      = AwaitingRel,
                                   await_rel_timeout = Timeout}) ->
    case check_awaiting_rel(Session) of
        true ->
            TRef = timer(Timeout, {timeout, awaiting_rel, PktId}),
            AwaitingRel1 = maps:put(PktId, {Msg, TRef}, AwaitingRel),
            {reply, ok, Session#session{awaiting_rel = AwaitingRel1}};
        false ->
            lager:critical([{client, ClientId}], "Session(~s) dropped Qos2 message "
                                "for too many awaiting_rel: ~p", [ClientId, Msg]),
            {reply, {error, dropped}, Session}
    end;

handle_call(Req, _From, State) ->
    lager:error("Unexpected Request: ~p", [Req]),
    {reply, ok, State}.

handle_cast({subscribe, TopicTable0, AckFun}, Session = #session{
                client_id = ClientId, subscriptions = Subscriptions}) ->

    TopicTable = emqttd_broker:foldl_hooks('client.subscribe', [ClientId], TopicTable0),

    case TopicTable -- Subscriptions of
        [] ->
            catch AckFun([Qos || {_, Qos} <- TopicTable]),
            noreply(Session);
        _  ->
            %% subscribe first and don't care if the subscriptions have been existed
            {ok, GrantedQos} = emqttd_pubsub:subscribe(TopicTable),

            catch AckFun(GrantedQos),

            emqttd_broker:foreach_hooks('client.subscribe.after', [ClientId, TopicTable]),

            lager:info([{client, ClientId}], "Session(~s): subscribe ~p, Granted QoS: ~p",
                        [ClientId, TopicTable, GrantedQos]),

            Subscriptions1 =
            lists:foldl(fun({Topic, Qos}, Acc) ->
                            case lists:keyfind(Topic, 1, Acc) of
                                {Topic, Qos} ->
                                    lager:warning([{client, ClientId}], "Session(~s): "
                                                    "resubscribe ~s, qos = ~w", [ClientId, Topic, Qos]), Acc;
                                {Topic, OldQos} ->
                                    lager:warning([{client, ClientId}], "Session(~s): "
                                                    "resubscribe ~s, old qos=~w, new qos=~w", [ClientId, Topic, OldQos, Qos]),
                                    lists:keyreplace(Topic, 1, Acc, {Topic, Qos});
                                false ->
                                    %%TODO: the design is ugly, rewrite later...:(
                                    %% <MQTT V3.1.1>: 3.8.4
                                    %% Where the Topic Filter is not identical to any existing Subscription’s filter,
                                    %% a new Subscription is created and all matching retained messages are sent.
                                    emqttd_retained:dispatch(Topic, self()),
                                    [{Topic, Qos} | Acc]
                            end
                        end, Subscriptions, TopicTable),
            noreply(Session#session{subscriptions = Subscriptions1})
    end;

handle_cast({unsubscribe, Topics0}, Session = #session{client_id = ClientId,
                                                       subscriptions = Subscriptions}) ->

    Topics = emqttd_broker:foldl_hooks('client.unsubscribe', [ClientId], Topics0),

    %% unsubscribe from topic tree
    ok = emqttd_pubsub:unsubscribe(Topics),

    lager:info([{client, ClientId}], "Session(~s) unsubscribe ~p", [ClientId, Topics]),

    Subscriptions1 =
    lists:foldl(fun(Topic, Acc) ->
                    case lists:keyfind(Topic, 1, Acc) of
                        {Topic, _Qos} ->
                            lists:keydelete(Topic, 1, Acc);
                        false ->
                            lager:warning([{client, ClientId}], "Session(~s) not subscribe ~s", [ClientId, Topic]), Acc
                    end
                end, Subscriptions, Topics),

    noreply(Session#session{subscriptions = Subscriptions1});

handle_cast({destroy, ClientId}, Session = #session{client_id = ClientId}) ->
    lager:warning([{client, ClientId}], "Session(~s) destroyed", [ClientId]),
    {stop, {shutdown, destroy}, Session};

handle_cast({resume, ClientId, ClientPid}, Session) ->

    #session{client_id      = ClientId,
             client_pid     = OldClientPid,
             client_mon     = MRef,
             inflight_queue = InflightQ,
             awaiting_ack   = AwaitingAck,
             awaiting_comp  = AwaitingComp,
             expired_timer  = ETimer} = Session,

    lager:info([{client, ClientId}], "Session(~s) resumed by ~p", [ClientId, ClientPid]),

    %% cancel expired timer
    cancel_timer(ETimer),

    %% Kickout old client
    if
        OldClientPid == undefined ->
            ok;
        OldClientPid == ClientPid ->
            ok; %% ??
        true ->
            lager:error([{client, ClientId}], "Session(~s): ~p kickout ~p",
                            [ClientId, ClientPid, OldClientPid]),
            OldClientPid ! {stop, duplicate_id, ClientPid},
            erlang:demonitor(MRef, [flush])
    end,

    %% Redeliver PUBREL
    [ClientPid ! {redeliver, {?PUBREL, PktId}} || PktId <- maps:keys(AwaitingComp)],

    %% Clear awaiting_ack timers
    [cancel_timer(TRef) || TRef <- maps:values(AwaitingAck)],

    %% Clear awaiting_comp timers
    [cancel_timer(TRef) || TRef <- maps:values(AwaitingComp)],

    Session1 = Session#session{client_pid    = ClientPid,
                               client_mon    = erlang:monitor(process, ClientPid),
                               awaiting_ack  = #{},
                               awaiting_comp = #{},
                               expired_timer = undefined},

    %% Redeliver inflight messages
    Session2 =
    lists:foldl(fun({_Id, Msg}, Sess) ->
            redeliver(Msg, Sess)
        end, Session1, lists:reverse(InflightQ)),

    %% Dequeue pending messages
    noreply(dequeue(Session2));

%% PUBACK
handle_cast({puback, PktId}, Session = #session{client_id = ClientId, awaiting_ack = AwaitingAck}) ->
    case maps:find(PktId, AwaitingAck) of
        {ok, TRef} ->
            cancel_timer(TRef),
            noreply(dequeue(acked(PktId, Session)));
        error ->
            lager:error([{client, ClientId}], "Session(~s) cannot find PUBACK ~w", [ClientId, PktId]),
            noreply(Session)
    end;

%% PUBREC
handle_cast({pubrec, PktId}, Session = #session{client_id         = ClientId,
                                                awaiting_ack      = AwaitingAck,
                                                awaiting_comp     = AwaitingComp,
                                                await_rel_timeout = Timeout}) ->
    case maps:find(PktId, AwaitingAck) of
        {ok, TRef} ->
            cancel_timer(TRef),
            TRef1 = timer(Timeout, {timeout, awaiting_comp, PktId}),
            AwaitingComp1 = maps:put(PktId, TRef1, AwaitingComp),
            Session1 = acked(PktId, Session#session{awaiting_comp = AwaitingComp1}),
            noreply(dequeue(Session1));
        error ->
            lager:error([{client, ClientId}], "Session(~s) cannot find PUBREC ~w", [ClientId, PktId]),
            noreply(Session)
    end;

%% PUBREL
handle_cast({pubrel, PktId}, Session = #session{client_id = ClientId,
                                                awaiting_rel = AwaitingRel}) ->
    case maps:find(PktId, AwaitingRel) of
        {ok, {Msg, TRef}} ->
            cancel_timer(TRef),
            emqttd_pubsub:publish(Msg),
            noreply(Session#session{awaiting_rel = maps:remove(PktId, AwaitingRel)});
        error ->
            lager:error([{client, ClientId}], "Session(~s) cannot find PUBREL ~w", [ClientId, PktId]),
            noreply(Session)
    end;

%% PUBCOMP
handle_cast({pubcomp, PktId}, Session = #session{client_id = ClientId, awaiting_comp = AwaitingComp}) ->
    case maps:find(PktId, AwaitingComp) of
        {ok, TRef} ->
            cancel_timer(TRef),
            noreply(Session#session{awaiting_comp = maps:remove(PktId, AwaitingComp)});
        error ->
            lager:error("Session(~s) cannot find PUBCOMP ~w", [ClientId, PktId]),
            noreply(Session)
    end;

handle_cast(Msg, State) ->
    lager:error("Unexpected Msg: ~p, State: ~p", [Msg, State]),
    {noreply, State}.

%% Queue messages when client is offline
handle_info({dispatch, Msg}, Session = #session{client_pid = undefined,
                                                message_queue = Q})
    when is_record(Msg, mqtt_message) ->
    noreply(Session#session{message_queue = emqttd_mqueue:in(Msg, Q)});

%% Dispatch qos0 message directly to client
handle_info({dispatch, Msg = #mqtt_message{qos = ?QOS_0}},
            Session = #session{client_pid = ClientPid}) ->
    ClientPid ! {deliver, Msg},
    noreply(Session);

handle_info({dispatch, Msg = #mqtt_message{qos = QoS}}, Session = #session{message_queue = MsgQ})
    when QoS =:= ?QOS_1 orelse QoS =:= ?QOS_2 ->

    case check_inflight(Session) of
        true ->
            {noreply, deliver(Msg, Session)};
        false ->
            {noreply, Session#session{message_queue = emqttd_mqueue:in(Msg, MsgQ)}}
    end;

handle_info({timeout, awaiting_ack, PktId}, Session = #session{client_pid = undefined,
                                                               awaiting_ack = AwaitingAck}) ->
    %% just remove awaiting
    noreply(Session#session{awaiting_ack = maps:remove(PktId, AwaitingAck)});

handle_info({timeout, awaiting_ack, PktId}, Session = #session{client_id      = ClientId,
                                                               inflight_queue = InflightQ,
                                                               awaiting_ack   = AwaitingAck}) ->
    lager:info("Awaiting Ack Timeout: ~p:", [PktId]),
    case maps:find(PktId, AwaitingAck) of
        {ok, _TRef} ->
            case lists:keyfind(PktId, 1, InflightQ) of
                {_, Msg} ->
                    noreply(redeliver(Msg, Session));
                false ->
                    lager:error([{client, ClientId}], "Session(~s):"
                                    "Awaiting timeout but Cannot find PktId :~p", [ClientId, PktId]),
                    noreply(dequeue(Session))
                end;
        error ->
            lager:error([{client, ClientId}], "Session(~s):"
                           "Cannot find Awaiting Ack:~p", [ClientId, PktId]),
            noreply(Session)
    end;

handle_info({timeout, awaiting_rel, PktId}, Session = #session{client_id = ClientId,
                                                               awaiting_rel = AwaitingRel}) ->
    case maps:find(PktId, AwaitingRel) of
        {ok, {Msg, _TRef}} ->
            lager:error([{client, ClientId}], "Session(~s) AwaitingRel Timout!~n"
                            "Drop Message:~p", [ClientId, Msg]),
            noreply(Session#session{awaiting_rel = maps:remove(PktId, AwaitingRel)});
        error ->
            lager:error([{client, ClientId}], "Session(~s) cannot find AwaitingRel ~w", [ClientId, PktId]),
            {noreply, Session, hibernate}
    end;

handle_info({timeout, awaiting_comp, PktId}, Session = #session{client_id = ClientId,
                                                                awaiting_comp = Awaiting}) ->
    case maps:find(PktId, Awaiting) of
        {ok, _TRef} ->
            lager:error([{client, ClientId}], "Session(~s) "
                            "Awaiting PUBCOMP Timout: PktId=~p!", [ClientId, PktId]),
            noreply(Session#session{awaiting_comp = maps:remove(PktId, Awaiting)});
        error ->
            lager:error([{client, ClientId}], "Session(~s) "
                            "Cannot find Awaiting PUBCOMP: PktId=~p", [ClientId, PktId]),
            noreply(Session)
    end;

handle_info(collect_info, Session = #session{clean_sess = CleanSess, client_id = ClientId}) ->
    emqttd_sm:register_session(CleanSess, ClientId, info(Session)),
    {noreply, start_collector(Session), hibernate};

handle_info({'DOWN', _MRef, process, ClientPid, _}, Session = #session{clean_sess = true,
                                                                       client_pid = ClientPid}) ->
    {stop, normal, Session};

handle_info({'DOWN', _MRef, process, ClientPid, _}, Session = #session{clean_sess = false,
                                                                       client_pid = ClientPid,
                                                                       expired_after = Expires}) ->
    TRef = timer(Expires, session_expired),
    noreply(Session#session{client_pid = undefined, client_mon = undefined, expired_timer = TRef});

handle_info({'DOWN', _MRef, process, Pid, Reason}, Session = #session{client_id  = ClientId,
                                                                      client_pid = ClientPid}) ->
    lager:error([{client, ClientId}], "Session(~s): unexpected DOWN: "
                    "client_pid=~p, down_pid=~p, reason=~p",
                        [ClientId, ClientPid, Pid, Reason]),
    noreply(Session);

handle_info(session_expired, Session = #session{client_id = ClientId}) ->
    lager:error("Session(~s) expired, shutdown now.", [ClientId]),
    {stop, {shutdown, expired}, Session};

handle_info(Info, Session = #session{client_id = ClientId}) ->
    lager:error("Session(~s) unexpected info: ~p", [ClientId, Info]),
    {noreply, Session}.

terminate(_Reason, #session{clean_sess = CleanSess, client_id = ClientId}) ->
    emqttd_sm:unregister_session(CleanSess, ClientId).

code_change(_OldVsn, Session, _Extra) ->
    {ok, Session}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% Check inflight and awaiting_rel
%%------------------------------------------------------------------------------

check_inflight(#session{max_inflight = 0}) ->
     true;
check_inflight(#session{max_inflight = Max, inflight_queue = Q}) ->
    Max > length(Q).

check_awaiting_rel(#session{max_awaiting_rel = 0}) ->
    true;
check_awaiting_rel(#session{awaiting_rel     = AwaitingRel,
                            max_awaiting_rel = MaxLen}) ->
    maps:size(AwaitingRel) < MaxLen.

%%------------------------------------------------------------------------------
%% Dequeue and Deliver
%%------------------------------------------------------------------------------

dequeue(Session = #session{client_pid = undefined}) ->
    %% do nothing if client is disconnected
    Session;

dequeue(Session) ->
    case check_inflight(Session) of
        true  -> dequeue2(Session);
        false -> Session
    end.

dequeue2(Session = #session{message_queue = Q}) ->
    case emqttd_mqueue:out(Q) of
        {empty, _Q} ->
            Session;
        {{value, Msg}, Q1} ->
            %% dequeue more
            dequeue(deliver(Msg, Session#session{message_queue = Q1}))
    end.

deliver(Msg = #mqtt_message{qos = ?QOS_0}, Session = #session{client_pid = ClientPid}) ->
    ClientPid ! {deliver, Msg}, Session; 

deliver(Msg = #mqtt_message{qos = QoS}, Session = #session{packet_id = PktId,
                                                           client_pid = ClientPid,
                                                           inflight_queue = InflightQ})
    when QoS =:= ?QOS_1 orelse QoS =:= ?QOS_2 ->
    Msg1 = Msg#mqtt_message{pktid = PktId, dup = false},
    ClientPid ! {deliver, Msg1},
    await(Msg1, next_packet_id(Session#session{inflight_queue = [{PktId, Msg1}|InflightQ]})).

redeliver(Msg = #mqtt_message{qos = ?QOS_0}, Session) ->
    deliver(Msg, Session); 

redeliver(Msg = #mqtt_message{qos = QoS}, Session = #session{client_pid = ClientPid})
    when QoS =:= ?QOS_1 orelse QoS =:= ?QOS_2 ->
    ClientPid ! {deliver, Msg#mqtt_message{dup = true}},
    await(Msg, Session).

%%------------------------------------------------------------------------------
%% Awaiting ack for qos1, qos2 message
%%------------------------------------------------------------------------------
await(#mqtt_message{pktid = PktId}, Session = #session{awaiting_ack   = Awaiting,
                                                       retry_interval = Timeout}) ->
    TRef = timer(Timeout, {timeout, awaiting_ack, PktId}),
    Awaiting1 = maps:put(PktId, TRef, Awaiting),
    Session#session{awaiting_ack = Awaiting1}.

acked(PktId, Session = #session{client_id      = ClientId,
                                inflight_queue = InflightQ,
                                awaiting_ack   = Awaiting}) ->
    case lists:keyfind(PktId, 1, InflightQ) of
        {_, Msg} ->
            emqttd_broker:foreach_hooks('message.acked', [ClientId, Msg]);
        false ->
            lager:error("Session(~s): Cannot find acked message: ~p", [PktId])
    end,
    Session#session{awaiting_ack   = maps:remove(PktId, Awaiting),
                    inflight_queue = lists:keydelete(PktId, 1, InflightQ)}.

next_packet_id(Session = #session{packet_id = 16#ffff}) ->
    Session#session{packet_id = 1};

next_packet_id(Session = #session{packet_id = Id}) ->
    Session#session{packet_id = Id + 1}.

timer(TimeoutSec, TimeoutMsg) ->
    erlang:send_after(timer:seconds(TimeoutSec), self(), TimeoutMsg).

cancel_timer(undefined) -> 
	undefined;
cancel_timer(Ref) -> 
	catch erlang:cancel_timer(Ref).

noreply(State) ->
    {noreply, State, hibernate}.

start_collector(Session = #session{collect_interval = 0}) ->
    Session;

start_collector(Session = #session{collect_interval = Interval}) ->
    TRef = erlang:send_after(timer:seconds(Interval), self(), collect_info),
    Session#session{collect_timer = TRef}.

info(#session{clean_sess      = CleanSess,
              subscriptions   = Subscriptions,
              inflight_queue  = InflightQueue,
              max_inflight    = MaxInflight,
              message_queue   = MessageQueue,
              awaiting_rel    = AwaitingRel,
              awaiting_ack    = AwaitingAck,
              awaiting_comp   = AwaitingComp,
              timestamp       = CreatedAt}) ->
    Stats = emqttd_mqueue:stats(MessageQueue),
    [{clean_sess,     CleanSess},
     {subscriptions,  Subscriptions},
     {max_inflight,   MaxInflight},
     {inflight_queue, length(InflightQueue)},
     {message_queue,  proplists:get_value(len, Stats)},
     {message_dropped,proplists:get_value(dropped, Stats)},
     {awaiting_rel,   maps:size(AwaitingRel)},
     {awaiting_ack,   maps:size(AwaitingAck)},
     {awaiting_comp,  maps:size(AwaitingComp)},
     {created_at,     CreatedAt}].

