%%
%% Copyright (C) 2014, Jaguar Land Rover
%%
%% This program is licensed under the terms and conditions of the
%% Mozilla Public License, version 2.0.  The full text of the 
%% Mozilla Public License is at https://www.mozilla.org/MPL/2.0/
%%




-module(schedule_rpc).


-export([handle_rpc/2]).
-export([init/0]).

-include_lib("lager/include/log.hrl").

init() ->
    case rvi_common:get_component_config(schedule, exo_http_opts) of
	{ ok, ExoHttpOpts } ->
	    exoport_exo_http:instance(schedule_sup, 
				      schedule_rpc,
				      ExoHttpOpts);
	Err -> Err
    end,
    ok.

schedule_message(SvcName, Timeout, Parameters, Signature, Certificate) ->
    ?debug("schedule_rpc:schedule_request(): service_name:    ~p", [ SvcName]),
    ?debug("schedule_rpc:schedule_request(): timeout:         ~p", [ Timeout]),
%%    ?debug("schedule_rpc:schedule_request(): parameters:      ~p", [Parameters]),
    ?debug("schedule_rpc:schedule_request(): signature:       ~p", [Signature]),
    ?debug("schedule_rpc:schedule_request(): certificate:     ~p", [Certificate]),
    {ok, TransID } = schedule:schedule_message(SvcName, 
					       Timeout, 
					       no_callback,
					       Parameters,
					       Signature,
					       Certificate),
    {ok, [ { status, rvi_common:json_rpc_status(ok)},
	   {transaction_id, TransID } ] }.

register_remote_services(NetworkAddress, AvailableServices) ->
    ?debug("schedule_rpc:register_remote_services(): network_address: ~p", [ NetworkAddress]),
    ?debug("schedule_rpc:register_remote_services(): services:        ~p", [ AvailableServices]),
    schedule:register_remote_services(NetworkAddress, AvailableServices),
    {ok, [ { status, rvi_common:json_rpc_status(ok)}]}.


unregister_remote_services(DiscountinuedServices) ->
    ?debug("schedule_rpc:unregister_remote_services(): services         ~p", [ DiscountinuedServices]),
    schedule:unregister_remote_services(DiscountinuedServices),
    {ok, [ { status, rvi_common:json_rpc_status(ok)}]}.


%% JSON-RPC entry point
%% CAlled by local exo http server
handle_rpc("schedule_message", Args) ->
    {ok, SvcName} = rvi_common:get_json_element(["service_name"], Args),
    {ok, Timeout} = rvi_common:get_json_element(["timeout"], Args),
    {ok, Parameters} = rvi_common:get_json_element(["parameters"], Args),
    {ok, Signature} = rvi_common:get_json_element(["signature"], Args),
    {ok, Certificate} = rvi_common:get_json_element(["certificate"], Args),
    schedule_message(SvcName, 
		     Timeout, 
		     Parameters,
		     Signature,
		     Certificate);

handle_rpc("register_remote_services", Args) ->
    {ok, NetworkAddress} = rvi_common:get_json_element(["network_address"], Args),
    {ok,  AvailableServices} = rvi_common:get_json_element(["services"], Args),
    register_remote_services(NetworkAddress, AvailableServices);

handle_rpc("unregister_remote_services", Args) ->
    {ok,  DiscountinuedServices} = rvi_common:get_json_element(["services"], Args),
    unregister_remote_services(DiscountinuedServices);

handle_rpc(Other, _Args) ->
    ?debug("schedule_rpc:handle_rpc(~p): unknown", [ Other ]),
    {ok, [ {status, rvi_common:json_rpc_status(invalid_command)}]}.

