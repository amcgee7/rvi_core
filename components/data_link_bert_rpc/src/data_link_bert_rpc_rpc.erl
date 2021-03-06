%%
%% Copyright (C) 2014, Jaguar Land Rover
%%
%% This program is licensed under the terms and conditions of the
%% Mozilla Public License, version 2.0.  The full text of the 
%% Mozilla Public License is at https://www.mozilla.org/MPL/2.0/
%%


-module(data_link_bert_rpc_rpc).

-export([handle_rpc/2]).
-export([handle_socket/6]).
-export([handle_socket/5]).
-export([setup_static_node_data_link/2]).
-export([init_rvi_component/0]).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("lager/include/log.hrl").
-behavior(gen_server).

-define(DEFAULT_BERT_RPC_PORT, 9999).
-define(DEFAULT_RECONNECT_INTERVAL, 5000).
-define(DEFAULT_BERT_RPC_ADDRESS, "0.0.0.0").
-define(DEFAULT_PING_INTERVAL, 300000).  %% Five minutes
-define(SERVER, ?MODULE). 
-record(st, { }).


start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    ?debug("data_link_bert_rpc_rpc:init(): called."),
    {ok, #st {}}.

init_rvi_component() ->
    ?info("data_link_bert:init_rvi_component(): Called"),
    %% Dig out the bert rpc server setup
    {ok, BertOpts } = rvi_common:get_component_config(data_link, bert_rpc_server, []),
    IP = proplists:get_value(ip, BertOpts, ?DEFAULT_BERT_RPC_ADDRESS),
    Port = proplists:get_value(port, BertOpts, ?DEFAULT_BERT_RPC_PORT),
    ?info("data_link_bert:init_rvi_component(): Starting listener."),

    %% Fire up listener
    connection_manager:start_link(), 
    {ok,Pid} = listener:start_link(), 
    ?info("data_link_bert:init_rvi_component(): Adding listener ~p:~p", [ IP, Port ]),
    
    %% Add listener port.
    case listener:add_listener(Pid, IP, Port) of
	ok ->
	    ?notice("---- RVI Node External Address: ~s", 
		    [ application:get_env(rvi, node_address, undefined)]),

	    %% Setup our http server.
	    case rvi_common:get_component_config(data_link, exo_http_opts) of
		{ ok, ExoHttpOpts } ->
		    exoport_exo_http:instance(data_link_bert_rpc_sup, 
					      data_link_bert_rpc_rpc,
					      ExoHttpOpts),
		    ok;

		_ -> 
		    ?info("data_link_bert_rpc_rpc:init_rvi_component(): exo_http_opts not specified. Gen Server only"),
		    ok
		
	    end;
	Err -> 	
	    ?error("data_link_bert:init_rvi_component(): Failed to launch listener: ~p", [ Err ]),
	    Err
    end,
    ?info("data_link_bert_rpc_rpc:init_rvi_component(): Setting up static nodes."),
    setup_static_node_data_links(),
    ok.

%%
%% Since we, in this demo code, haven't done pure P2P service discovery yet,
%% we will simply connect to all configured static nodes.
%%
setup_static_node_data_links() ->
    setup_static_node_data_links(rvi_common:static_nodes()).

setup_static_node_data_links([ ]) ->
    ok;

setup_static_node_data_links([ { Prefix, NetworkAddress} | T]) ->
    setup_static_node_data_link(Prefix, NetworkAddress),
    setup_static_node_data_links(T).

setup_static_node_data_link(Prefix, NetworkAddress) ->
    [ Address, Port] = string:tokens(NetworkAddress, ":"),
    case setup_data_link(Address, list_to_integer(Port), undefined) of
	{ok, _} -> ok;

	{error, _ } = Err -> %% Failed to connect. Sleep and try again
	    ?notice("data_link_bert:setup_static_node_data_link(~p): Failed: ~p", 
			   [NetworkAddress, Err]),

	    ?notice("data_link_bert:setup_static_node_data_link(~p): Will try again in 5 sec", 
			   [NetworkAddress]),
	    timer:apply_after(?DEFAULT_RECONNECT_INTERVAL, 
			      ?MODULE, setup_static_node_data_link, 
			      [Prefix, NetworkAddress ]),
	    not_available
    end.
    

connect_remote(IP, Port) ->
    case connection_manager:find_connection_by_address(IP, Port) of
	{ ok, _Pid } ->
	    already_connected;

	not_found ->
	    %% Setup a new outbound connection
	    ?info("data_link_bert:connect_remote(): Connecting ~p:~p", 
		   [IP, Port]),
	    case gen_tcp:connect(IP, Port, [binary, {packet, 4}]) of
		{ ok, Sock } -> 
		    ?info("data_link_bert:connect_remote(): Connected ~p:~p", 
			   [IP, Port]),
		    %% Setup a genserver around the new connection.
		    connection:setup(IP, Port, Sock, ?MODULE, handle_socket, []);

		Err -> 
		    ?info("data_link_bert:connect_remote(): Failed ~p:~p: ~p",
			   [IP, Port, Err]),
		    Err
	    end
    end.
		    

setup_data_link(RemoteAddress, RemotePort, Service) ->
    { LocalAddress, LocalPort} = rvi_common:node_address_tuple(),
    ?info("data_link_bert:setup_data_link(): Link:    ~p:~p -> ~p:~p", 
	  [ LocalAddress, LocalPort, RemoteAddress, RemotePort]),
    ?info("data_link_bert:setup_data_link(): Service: ~p", [ Service]),

    
    case connect_remote(RemoteAddress, RemotePort) of
	already_connected -> 
	    ?info("data_link_bert:setup_data_link(): Already connected!"),
	    {ok, [ { status, rvi_common:json_rpc_status(already_connected)}]};
	{ ok, Pid } ->
	    ?info("data_link_bert:setup_data_link(): New connection!"),

	    %% Follow up with an authorize.
	    ?debug("data_link_bert:setup_data_link(): Sending authorize()"),
	    connection:send(Pid, { authorize, 
				   1, LocalAddress, LocalPort, rvi_binary, 
				   {certificate, {}}, { signature, {}} }),

	    {ok, [ { status, rvi_common:json_rpc_status(ok)}]};

	{ error, _ } ->
	    {error, [ { status, rvi_common:json_rpc_status(not_available)}]}
    end.


disconnect_data_link(RemoteAddress, RemotePort) ->
    ?info("data_link_bert:disconnect_data_link(): Remote: ~p:~p", [ RemoteAddress, RemotePort]),
    {ok, [ { status, rvi_common:json_rpc_status(ok)}]}.



send_data(RemoteAddress, RemotePort, Data) ->
    ?info("data_link_bert:send_data(): Remote: ~p:~p", [ RemoteAddress, RemotePort]),
    %% ?info("data_link_bert:send_data(): Data:           ~p", [ Data]),

    Res = connection:send(RemoteAddress, RemotePort, {receive_data, Data}),

    case Res of 
	ok ->
	    ?debug ("data_link_bert:send_data(): bert-rpc result: ~p", [ Res ]);
	_ -> 
	    ?info ("data_link_bert:send_data(): bert-rpc result: ~p", [ Res ])
    end,
    
    {ok, [ { status, rvi_common:json_rpc_status(ok)}]}.


announce_local_service(Service, Availability) ->
    ?debug("data_link_bert:announce_local_service(~p): Service: ~p",  [Availability, Service]),
    %% Grab our local address.
    { LocalAddress, LocalPort } = rvi_common:node_address_tuple(),

    %% Grab all remote addresses we are currently connected to.
    %% We will get the data link address of all remote nodes that
    %% we currently have a conneciton to.
    case rvi_common:send_component_request(service_discovery, get_remote_network_addresses, [], 
					   [ addresses ]) of
	{ ok, _, [ Addresses ] } -> 

	    %% Grab our local address.
	    { LocalAddress, LocalPort } = rvi_common:node_address_tuple(),

	    %% Loop over all returned addresses
	    lists:map(
	      fun(Address) ->
		      ?info("data_link_bert:announce_local_service(~p): Announcing ~p to ~p", 
			    [ Availability, Service, Address]),
		      
		      %% Split the address into host and port
		      [ RemoteAddress, RemotePort] =  string:tokens(Address, ":"),
		      
		      %% Announce the new service to the remote 
		      %% RVI node
		      Res = connection:send(RemoteAddress, list_to_integer(RemotePort), 
				      {service_announce, 3, Availability, 
				       [Service], { signature, {}}}),
		      ?debug("data_link_bert:announce_local_service(~p): Res      ~p", 
			    [ Availability, Res])
	      end,
	      Addresses),
	    
	    {ok, [ { status, rvi_common:json_rpc_status(ok)}]};

	Err -> 
	    ?warning("data_link_bert:announce_local_service(~p) Failed to grab addresses: ~p", 
		     [ Availability, Err ]),
	    {ok, [ { status, rvi_common:json_rpc_status(ok)}]}

    end.


handle_socket(_FromPid, PeerIP, PeerPort, data, ping, _ExtraArgs) ->
    ?info("data_link_bert:ping(): Pinged from: ~p:~p", [ PeerIP, PeerPort]),
    ok;

handle_socket(FromPid, PeerIP, PeerPort, data, 
	      { authorize, 
		TransactionID, 
		RemoteAddress, 
		RemotePort, 
		Protocol, 
		Certificate,
		Signature}, _ExtraArgs) ->

    ?info("data_link_bert:authorize(): Peer Address:   ~p:~p", [PeerIP, PeerPort ]),
    ?info("data_link_bert:authorize(): Remote Address: ~p~p", [ RemoteAddress, RemotePort ]),
    ?info("data_link_bert:authorize(): Protocol:       ~p", [ Protocol ]),
    ?debug("data_link_bert:authorize(): TransactionID:  ~p", [ TransactionID ]),
    ?debug("data_link_bert:authorize(): Certificate:    ~p", [ Certificate ]),
    ?debug("data_link_bert:authorize(): Signature:      ~p", [ Signature ]),


    { LocalAddress, LocalPort } = rvi_common:node_address_tuple(),

    %% If the remote address and port are both reported as "0.0.0.0" and 0,
    %% then the client connects from behind a firewall and cannot
    %% accept return connections. In these cases, we will tie the
    %% gonnection to the peer address provided in PeerIP and PeerPort
    { NRemoteAddress, NRemotePort} =
	case { RemoteAddress, RemotePort } of
	    { "0.0.0.0", 0 } ->
		
		?info("data_link_bert:authorize(): Remote is behind firewall. Will use ~p:~p", 
		      [ PeerIP, PeerPort]),
		{ PeerIP, PeerPort };

	    _ -> { RemoteAddress, RemotePort}
	end,

    %% If FromPid (the genserver managing the socket) is not yet registered
    %% with the conneciton manager, this is an incoming connection
    %% from the client. We should respond with our own authorize followed by
    %% a service announce
    
    %% FIXME: Validate certificate and signature before continuing.
    case connection_manager:find_connection_by_pid(FromPid) of
	not_found ->
	    ?info("data_link_bert:authorize(): New connection!"),
	    connection_manager:add_connection(NRemoteAddress, NRemotePort, FromPid),
	    ?debug("data_link_bert:authorize(): Sending authorize."),
	    Res = connection:send(FromPid, 
			    { authorize, 
			      1, LocalAddress, LocalPort, rvi_binary, 
			      {certificate, {}}, { signature, {}}}),
	    ?debug("data_link_bert:authorize(): Sending authorize: ~p", [ Res]),
	    ok;
	_ -> ok
    end,


    %% Send our own servide announcement to the remote server
    %% that just authorized to us.
    %% First grab all our services.
    case rvi_common:send_component_request(service_discovery, get_local_services, [], 
					   [ services ]) of
	{ ok, _, [ JSONSvc] } -> 
	    %% Covnert to JSON structured typles.
	    LocalServices = 
		lists:foldl(fun({struct, JSONElem}, Acc) -> 
				    [ proplists:get_value("service", JSONElem, undefined) | Acc];
			       ({Service, _LocalAddress}, Acc) -> 
				    [ Service | Acc ];
			       (Elem, Acc) -> 
				    [ Elem | Acc ]
			    end,
			    [], JSONSvc),

	    %% Grab our local address.
	    { LocalAddress, LocalPort } = rvi_common:node_address_tuple(),

	    %% Send an authorize back to the remote node
	    ?info("data_link_bert:authorize(): Announcing local services: ~p to remote ~p:~p",
		  [LocalServices, NRemoteAddress, NRemotePort]),

	    connection:send(FromPid, 
			    { service_announce, 2, available,
			      LocalServices, { signature, {}}});

	Err -> 
	    ?warning("data_link_bert:authorize() Failed at authorize: ~p", 

		     [ Err ]),
	    ok
    end,

    %% Setup ping interval
    gen_server:call(?SERVER, { setup_initial_ping, NRemoteAddress, NRemotePort, FromPid }),
    ok;

handle_socket(_FromPid, RemoteIP, RemotePort, data, 
	      { service_announce, 
		TransactionID, 
		available,
		Services, 
		Signature}, _ExtraArgs) ->
    ?debug("data_link_bert:service_announce(available): Address:       ~p:~p", [ RemoteIP, RemotePort ]),
    ?debug("data_link_bert:service_announce(available): Remote Port:   ~p", [ RemotePort ]),
    ?debug("data_link_bert:service_announce(available): TransactionID: ~p", [ TransactionID ]),
    ?debug("data_link_bert:service_announce(available): Signature:     ~p", [ Signature ]),
    ?debug("data_link_bert:service_announce(available): Service:       ~p", [ Services ]),


    %% Register the received services with all relevant components
    
    RemoteNetworkAddress = RemoteIP  ++ ":" ++ integer_to_list(RemotePort),
    rvi_common:send_component_request(service_discovery, register_remote_services, 
				      [
				       {services, Services}, 
				       {network_address, RemoteNetworkAddress}
				      ]),
    ok;


handle_socket(_FromPid, RemoteIP, RemotePort, data, 
	      { service_announce, 
		TransactionID, 
		unavailable,
		Services, 
		Signature}, _ExtraArgs) ->
    ?debug("data_link_bert:service_announce(unavailable): Address:       ~p:~p", [ RemoteIP, RemotePort ]),
    ?debug("data_link_bert:service_announce(unavailable): Remote Port:   ~p", [ RemotePort ]),
    ?debug("data_link_bert:service_announce(unavailable): TransactionID: ~p", [ TransactionID ]),
    ?debug("data_link_bert:service_announce(unavailable): Signature:     ~p", [ Signature ]),
    ?debug("data_link_bert:service_announce(unavailable): Service:       ~p", [ Services ]),

    %% Register the received services with all relevant components

    rvi_common:send_component_request(service_discovery, unregister_remote_services_by_name, 
				      [
				       {services, Services}
				      ]),
    ok;


handle_socket(_FromPid, SetupIP, SetupPort, data, 
	      { receive_data, Data}, _ExtraArgs) ->
%%    ?info("data_link_bert:receive_data(): ~p", [ Data ]),
    ?debug("data_link_bert:receive_data(): SetupAddress:  {~p, ~p}", [ SetupIP, SetupPort ]),
    case 
	rvi_common:send_component_request(protocol, receive_message, 
					  [
					   { data, Data }
					  ]) of
	{ ok, _ } -> 
	    ok;
	Err -> 
	    ?info("data_link_bert:receive_data(): Failed to send component request: ~p", 
		   [ Err ])
    end,
    ok;


handle_socket(_FromPid, SetupIP, SetupPort, data, Data, _ExtraArgs) ->
    ?warning("data_link_bert:unknown_data(): SetupAddress:  {~p, ~p}", [ SetupIP, SetupPort ]),
    ?warning("data_link_bert:unknown_data(): Unknown data:  ~p",  [ Data]),
    ok.

%% We lost the socket connection.
%% Unregister all services that were routed to the remote end that just died.
handle_socket(_FromPid, SetupIP, SetupPort, closed, _ExtraArgs) ->
    ?info("data_link_bert:socket_closed(): SetupAddress:  {~p, ~p}", [ SetupIP, SetupPort ]),
    RemoteNetworkAddress = SetupIP  ++ ":" ++ integer_to_list(SetupPort),
    rvi_common:send_component_request(service_discovery, unregister_remote_services_by_address, 
				      [
				       {network_address, RemoteNetworkAddress}
				      ]),

    %% Check if this is a static node. If so, setup a timer for a reconnect
    case lists:keyfind(RemoteNetworkAddress, 2, rvi_common:static_nodes()) of
	false ->
	    true;

	{ StaticPrefix, StaticNetworkAddress } ->
	    ?info("data_link_bert:socket_closed(): Reconnect service:  ~p", [ StaticPrefix ]),
	    ?info("data_link_bert:socket_closed(): Reconnect address:  ~p", [ StaticNetworkAddress ]),
	    ?info("data_link_bert:socket_closed(): Reconnect interval: ~p", [ ?DEFAULT_RECONNECT_INTERVAL ]),
	    timer:apply_after(?DEFAULT_RECONNECT_INTERVAL, 
			      ?MODULE, setup_static_node_data_link, 
			      [StaticPrefix, StaticNetworkAddress ])
    end,
    ok;

handle_socket(_FromPid, SetupIP, SetupPort, error, _ExtraArgs) ->
    ?info("data_link_bert:socket_error(): SetupAddress:  {~p, ~p}", [ SetupIP, SetupPort ]),
    ok.


%% JSON-RPC entry point
%% CAlled by local exo http server
handle_rpc("announce_available_local_service", Args) ->
    { ok,  Service } = rvi_common:get_json_element(["service"], Args),
    announce_local_service(Service, available);

handle_rpc("announce_unavailable_local_service", Args) ->
    { ok,  Service } = rvi_common:get_json_element(["service"], Args),
    announce_local_service(Service, unavailable);

handle_rpc("setup_data_link", Args) ->
    { ok, NetworkAddress } = rvi_common:get_json_element(["network_address"], Args),
    [ RemoteAddress, RemotePort] =  string:tokens(NetworkAddress, ":"),
    { ok,  Service } = rvi_common:get_json_element(["service"], Args),

    setup_data_link(RemoteAddress, list_to_integer(RemotePort), Service);


handle_rpc("disconenct_data_link", Args) ->
    { ok, NetworkAddress} = rvi_common:get_json_element(["network_address"], Args),
    [ RemoteAddress, RemotePort] =  string:tokens(NetworkAddress, ":"),

    disconnect_data_link(RemoteAddress, list_to_integer(RemotePort));    

handle_rpc("send_data", Args) ->
    {ok, NetworkAddress} = rvi_common:get_json_element(["network_address"], Args),
    [ RemoteAddress, RemotePort] =  string:tokens(NetworkAddress, ":"),
    { ok,  Data} = rvi_common:get_json_element(["data"], Args),

    send_data(RemoteAddress, list_to_integer(RemotePort), Data);
    
handle_rpc(Other, _Args) ->
    ?info("data_link_bert:handle_rpc(~p): unknown", [ Other ]),
    { ok, [ { status, rvi_common:json_rpc_status(invalid_command)} ] }.


handle_call({rvi_call, announce_available_local_service, Args}, _From, State) ->
    {_, Service} = lists:keyfind(service, 1, Args),
    {reply, announce_local_service(Service, available), State};

handle_call({rvi_call, announce_unavailable_local_service, Args}, _From, State) ->
    {_, Service} = lists:keyfind(service, 1, Args),
    {reply, announce_local_service(Service, unavailable), State};

handle_call({rvi_call, setup_data_link, Args}, _From, State) ->
    {_, NetworkAddress} = lists:keyfind(network_address, 1, Args),
    [ RemoteAddress, RemotePort] =  string:tokens(NetworkAddress, ":"),
    {_, Service} = lists:keyfind(service, 1, Args),

    { reply, setup_data_link(RemoteAddress, 
			     list_to_integer(RemotePort), Service), State };


handle_call({rvi_call, disconnect_data_link, Args}, _From, State) ->
    {_, NetworkAddress} = lists:keyfind(network_address, 1, Args),
    [ RemoteAddress, RemotePort] =  string:tokens(NetworkAddress, ":"),

    { reply, disconnect_data_link(RemoteAddress, 
				  list_to_integer(RemotePort)), State };


handle_call({rvi_call, send_data, Args}, _From, State) ->
    {_, NetworkAddress} = lists:keyfind(network_address, 1, Args),
    [ RemoteAddress, RemotePort] =  string:tokens(NetworkAddress, ":"),
    {_, Data} = lists:keyfind(data, 1, Args),
    { reply, send_data(RemoteAddress, 
		       list_to_integer(RemotePort), Data), State };


handle_call({setup_initial_ping, Address, Port, Pid}, _From, St) ->
    %% Create a timer to handle periodic pings.
    {ok, ServerOpts } = rvi_common:get_component_config(data_link, bert_rpc_server, []),
    Timeout = proplists:get_value(ping_interval, ServerOpts, ?DEFAULT_PING_INTERVAL),

    ?info("data_link_bert_rpc_rpc:setup_ping(): ~p:~p will be pinged every ~p msec", 
	  [ Address, Port, Timeout] ),
										      
    erlang:send_after(Timeout, self(), { rvi_ping, Pid, Address, Port, Timeout }),

    {reply, ok, St};

handle_call(Other, _From, State) ->
    ?warning("data_link_bert_rpc_rpc:handle_rpc(~p): unknown", [ Other ]),
    { reply, { ok, [ { status, rvi_common:json_rpc_status(invalid_command)} ]}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Ping time
handle_info({ rvi_ping, Pid, Address, Port, Timeout},  St) ->

    %% Check that connection is up
    case connection:is_connection_up(Pid) of
	true ->
	    ?info("data_link_bert_rpc_rpc:ping(): Pinging: ~p:~p", [Address, Port]),
	    connection:send(Pid, ping),
	    erlang:send_after(Timeout, self(), { rvi_ping, Pid, Address, Port, Timeout });

	false ->
	    ok
    end,
    {noreply, St};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

