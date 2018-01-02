%%%-------------------------------------------------------------------
%%% @author lijianming
%%% @copyright (C) 2016, <ljming1106@163.com>
%%% @doc
%%%
%%% @end
%%% Created : 30. 四月 2016 1:15
%%%-------------------------------------------------------------------
-module(file_client).
-author("lijianming").

-include("../include/file_server.hrl").

%% External API
-export([
  start_client/3,
  get_msg/2
]).

%% Internal API
-export([
  get_msg_by_tcp/2,
  get_msg_by_udp/2,
  get_msg_by_http/2
]).

%%参数：
%%（1）启动客户端的个数
%% ==> 测试多个Socket连接，对文件服务器的影响
%%
%%（2）每个客户端访问文件服务器的次数
%% ==> 测试单个Socket多次请求，对文件服务器的影响

start_client(Type, ClientNum, AccessTimes) ->
  case catch ets:new(file_client, [named_table, public]) of
    file_client ->
      next;
    _ ->
      ignore
  end,

  ets:insert(file_client, {Type, ClientNum, ClientNum * AccessTimes, now_time()}),
  exec_client(Type, ClientNum, AccessTimes),
  ok.

exec_client(_Type, 0, _AccessTimes) ->
  ignore;
exec_client(Type, ClientNum, AccessTimes) when ClientNum > 0 andalso AccessTimes > 0 ->
  get_msg(Type, AccessTimes),
  exec_client(Type, ClientNum - 1, AccessTimes).

get_msg(Type, AccessTimes) ->
  FileName = "example.txt",
  case AccessTimes > 0 andalso Type of
    tcp ->
      erlang:spawn(?MODULE, get_msg_by_tcp, [FileName, AccessTimes]);
    udp ->
      erlang:spawn(?MODULE, get_msg_by_udp, [FileName, AccessTimes]);
    http ->
      erlang:spawn(?MODULE, get_msg_by_http, [FileName, AccessTimes]);
    _ ->
      io:fwrite("error info:[Type:~p],[AccessTimes:~p]~n", [Type, AccessTimes])
  end,
  ok.

%%计算平时延时
get_average_time(Type) ->
  case ets:lookup(file_client, Type) of
    [{_, RemainNum, Times, Time}] when RemainNum =< 1 ->
      AveTime = (now_time() - Time) / Times,
      io:fwrite("[~p]Average Time:~p~n", [Type, AveTime]);
    [{_, RemainNum, Times, Time}] ->
      ets:insert(file_client, {Type, RemainNum - 1, Times, Time})
  end.

now_time() ->
  {A, B, _} = os:timestamp(),
  A * 1000000 + B.

%%请求某文件的内容信息
get_msg_by_tcp(FileName, AccessTimes) ->
  {ok, Socket} = gen_tcp:connect(?HOST_IP, ?TCP_PORT, [binary, {active, false}]),
  do_tcp_recv(Socket, FileName, AccessTimes).

do_tcp_recv(Socket, _FileName, 0) ->
  get_average_time(tcp),
  gen_tcp:close(Socket);
do_tcp_recv(Socket, FileName, AccessTimes) ->
  case gen_tcp:send(Socket, FileName) of
    ok ->
      case gen_tcp:recv(Socket, 0) of
        {ok, _DataBin} ->
          next;
        {error, Reason} ->
          io:fwrite("[tcp recv]Recv Err:~p~n", [Reason])
      end;
    {error, Reason} -> io:fwrite("[tcp send]Recv Err:~p~n", [Reason])
  end,
  do_tcp_recv(Socket, FileName, AccessTimes - 1).

get_msg_by_udp(FileName, AccessTimes) ->
  {ok, Socket} = gen_udp:open(0, [binary, {active, false}]),
  do_udp_recv(Socket, FileName, AccessTimes).

do_udp_recv(Socket, _FileName, 0) ->
  gen_udp:close(Socket);
do_udp_recv(Socket, FileName, AccessTimes) ->
  set_msg_time(Socket, now_time()),
  case gen_udp:send(Socket, ?HOST_IP, ?UDP_PORT, FileName) of
    ok ->
      case gen_udp:recv(Socket, 0) of
        {ok, {_, _, _DataBin}} ->
          TimeInterval = now_time() - get_msg_time(Socket),
          io:fwrite("[udp]Time:~p~n", [TimeInterval]);
        {error, Reason} ->
          io:fwrite("[udp recv]Recv Err:~p~n", [Reason])
      end;
    {error, Reason} -> io:fwrite("[udp send]Recv Err:~p~n", [Reason])
  end,
  do_udp_recv(Socket, FileName, AccessTimes - 1).

get_msg_by_http(FileName, AccessTimes) ->
  inets:start(),
  get_msg_by_http1(FileName, AccessTimes).

get_msg_by_http1(_FileName, 0) ->
  get_average_time(http);
get_msg_by_http1(FileName, AccessTimes) ->
  case httpc:request(get, {lists:concat(["http://", ?HOST_IP, ":", ?HTTP_PORT, "?filename=", FileName]), []}, [], []) of
    {ok, {_, _, _Data}} ->
      _Data;
    Err ->
      io:fwrite("[http recv]Recv Err:~p~n", [Err])
  end,
  get_msg_by_http1(FileName, AccessTimes - 1).

get_msg_time(Socket) ->
  erlang:get(Socket).
set_msg_time(Socket, Time) ->
  erlang:put(Socket, Time).