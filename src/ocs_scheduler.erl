%%% ocs_scheduler.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2017 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%
-module(ocs_scheduler).
-copyright('Copyright (c) 2016 - 2017 SigScale Global Inc.').

-export([start/0, start/2]).
-export([product_charge/0]).

-include("ocs.hrl").

-define(CHUNKSIZE, 100).
%% support deprecated_time_unit()
-define(MILLISECOND, milli_seconds).
%-define(MILLISECOND, millisecond).

-export([frp/1]).
-spec start() -> ok.
%% @equiv start(Interval)
start() ->
	{ok, ScheduledTime} = application:get_env(charging_scheduler_time), 
	{ok, Interval} = application:get_env(charging_interval),
	start(ScheduledTime, Interval).

-spec start(ScheduledTime, Interval) -> ok
	when
		ScheduledTime :: tuple(),
		Interval :: pos_integer().
%% @doc
start(ScheduledTime, Interval) ->
	NextInterval = interval(ScheduledTime, Interval),
	timer:apply_interval(NextInterval, ?MODULE, product_charge, []),
	ok.

-spec product_charge() -> ok.
%% @doc Scheduler update for all the subscriptions.
product_charge() ->
	case get_offers() of
		{error, Reason} ->
			error_logger:error_report("Scheduler Failed",
					[{module, ?MODULE}, {reason, Reason}]);
		Offers ->
			Now = erlang:system_time(?MILLISECOND),
			product_charge1(get_product(start), Now, frp(Offers))
	end.
%% @hidden
product_charge1('$end_of_table', _Now, _Offers) ->
	ok;
product_charge1(ProdRef, Now, Offers) ->
	F = fun() ->
			case mnesia:read(product, ProdRef, write) of
				[#product{product = OfferId,
						payment = Payments,
						balance = BucketRefs} = Product] ->
					case if_recur(OfferId, Offers) of
						{true, Offer} ->
							case if_dues(Payments, Now) of
								true ->
									Buckets1 = lists:flatten([mnesia:select(bucket,
											[{'$1',
											[
												{'==', Id, {element, #bucket.id, '$1'}}
											],
											['$1']}]) || Id <- BucketRefs]),
									{NewProduct1, Buckets3} = ocs:subscription(Product, Offer,
											Buckets1, false),
									NewBRefs = update_buckets(BucketRefs, Buckets1, Buckets3),
									NewProduct2 = NewProduct1#product{balance = NewBRefs},
									ok = mnesia:write(NewProduct2);
								false ->
									ok
							end;
						false ->
							ok
					end;
				[] ->
					throw(product_ref_nof_found)
			end
	end,
	case mnesia:transaction(F) of
		{atomic, ok} ->
			product_charge1(get_product(ProdRef), Now, Offers);
		{aborted, Reason} ->
			error_logger:error_report("Scheduler Update Failed",
					[{module, ?MODULE}, {product_id, ProdRef},
					{time, erlang:system_time(?MILLISECOND)},
					{reason, Reason}]),
			product_charge1(get_product(ProdRef), Now, Offers)
	end.

%%----------------------------------------------------------------------
%%  internal functions
%%----------------------------------------------------------------------
%% @private
if_dues([{_, DueDate} | _], Now) when DueDate < Now ->
	true;
if_dues([_ | T], Now) ->
	if_dues(T, Now);
if_dues([], _Now)  ->
	false.

%% @private
if_recur(OfferId, Offers) ->
	case lists:keyfind(OfferId, 1, Offers) of
		{_, Offer} ->
			{true, Offer};
		false ->
			false
	end.

%% @private
get_product(start) ->
	ets:first(product);
get_product(SId) ->
	ets:next(product, SId).

-spec get_offers() -> Result
	when
		Result :: Offers | {error, Reason},
		Offers :: [#offer{}],
		Reason :: term().
%% @private
get_offers() ->
	MatchSpec = [{'_', [], ['$_']}],
	F = fun F(start, Acc) ->
				F(mnesia:select(offer, MatchSpec,
						?CHUNKSIZE, read), Acc);
			F ('$end_of_table', Acc) ->
				lists:flatten(lists:reverse(Acc));
			F({error, Reason}, _Acc) ->
				{error, Reason};
			F({Offers, Cont}, Acc) ->
				F(mnesia:select(Cont), [Offers | Acc])
	end,
	case mnesia:transaction(F, [start, []]) of
		{aborted, Reason} ->
			{error, Reason};
		{atomic, Result} ->
			Result
	end.

-spec frp(Offers) -> FilterOffer
	when
		Offers :: [#offer{}],
		FilterOffer :: [{OfferId, Offer}],
		OfferId :: string(),
		Offer :: #offer{}.
%% @doc Filter recurring prices
%% @private
frp(Offers) ->
	frp1(Offers, []).
%% @hidden
frp1([#offer{name = OfferId, price = Prices} = Offer | T], Acc) ->
	case lists:any(fun frp2/1, Prices) of
		false ->
			frp1(T, Acc);
		true ->
			frp1(T, [{OfferId, Offer}] ++ Acc)
	end;
frp1([], Acc) ->
	lists:reverse(Acc).
%% @hidden
frp2(#price{type = Bundle}) when Bundle /= [] ->
	true;
frp2(#price{type = recurring}) ->
	true;
frp2(#price{alteration = #alteration{type = recurring}}) ->
	true;
frp2(_) ->
	false.

%% @private
update_buckets(BRefs, OldB, NewB) ->
	AllNewKeys = [B#bucket.id || B <- NewB],
	UpdatedB = NewB -- OldB,
	update_b(UpdatedB),
	ok = delete_b(BRefs -- AllNewKeys),
	AllNewKeys.

%% @private
update_b([B | T]) ->
	ok = mnesia:write(B),
	update_b(T);
update_b([]) ->
	ok.

%% @private
delete_b([BRef | T]) ->
	ok = mnesia:delete(bucket, BRef, write),
	delete_b(T);
delete_b([]) ->
	ok.

%% @hidden
interval(ScheduledTime, Interval) ->
	{Date, Time} = erlang:universaltime(),
	Today = calendar:date_to_gregorian_days(Date),
	Period = Interval div 1440,
	ScheduleDay = calendar:gregorian_days_to_date(Today + Period),
	Next = {ScheduleDay, ScheduledTime},
	Now = calendar:datetime_to_gregorian_seconds({Date, Time}),
	(calendar:datetime_to_gregorian_seconds(Next) - Now) * 1000.

