%%%-------------------------------------------------------------------
%%% @author lijianming
%%% @copyright (C) 2016, <ljming1106@163.com>
%%% @doc
%%%
%%% @end
%%% Created : 03. 五月 2016 0:04
%%%-------------------------------------------------------------------
-module(spec_file_server2).
-author("lijianming").

-behaviour(gen_server).

-include("../include/file_server.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-export([
  get_msg_by_http/0,
  get_msg_by_tcp/0,
  get_msg_by_udp/0
]).

-export([
  http_or_tcp_accept/2,
  http_loop/1,
  tcp_loop/1
]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
  %%创建三种访问方式的进程，进行监听
  erlang:spawn(?MODULE, get_msg_by_http, []),
  erlang:spawn(?MODULE, get_msg_by_tcp, []),
  erlang:spawn(?MODULE, get_msg_by_udp, []),
  {ok, #state{}}.

handle_call(_Request, _From, State) ->
  {reply, ok, State}.
handle_cast(_Request, State) ->
  {noreply, State}.
handle_info(_Info, State) ->
  {noreply, State}.
terminate(_Reason, _State) ->
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%HTTP访问方式
get_msg_by_http() ->
  Opts = [{active, false},
    binary,
    {backlog, 256},
    {packet, http_bin},
    {raw, 6, 9, <<1:32/native>>},
    {reuseaddr, true}],
  http_or_tcp_listen(?HTTP_PORT, Opts, http_loop),
  receive Any -> io:format("~p~n", [Any]) end.

http_loop(S) ->
  case gen_tcp:recv(S, 0) of
    {ok, http_eoh} ->
      case get_filename() of
        FileName when FileName =/= undefined ->
          case check_file_exist(FileName) of
            {ok, FilePath} ->
              {FileData, FileSize} = do_read_file(FilePath),
              %%HTTP响应：状态行、响应头(Response Header)、响应正文
              Content = lists:concat(["HTTP/1.1 200 OK\r\n", "Content-Length: ", FileSize, "\r\n\r\n", FileData]),
              Response = erlang:list_to_binary(Content);
            {error, Err} ->
              io:fwrite("[http mode]recv error:~p~n", [Err]),
              Response = Err
          end;
        _ ->
          io:fwrite("[Http Mode]send error:file not exist~n", []),
          Response = erlang:list_to_binary("file not exist")
      end,
      gen_tcp:send(S, Response),
      http_loop(S),
      ok;
    {ok, Data} ->
      deal_filename(Data),
      http_loop(S);
    Err ->
      io:fwrite("[Http Mode]send error:~p~n", [Err]),
      gen_tcp:close(S)
  end.

deal_filename(Data) ->
  case Data of
    {http_request, _, {abs_path, UrlInfo}, _} ->
      [_, FileName] = string:tokens(erlang:binary_to_list(UrlInfo), "="),
      set_filename(FileName);
    _ ->
      ingore
  end.

get_filename() ->
  erlang:get(file_name).
set_filename(FileName) ->
  erlang:put(file_name, FileName).

%%TCP访问方式
get_msg_by_tcp() ->
  Opts = [binary, {active, once}, {reuseaddr, true}],
  http_or_tcp_listen(?TCP_PORT, Opts, tcp_loop).

tcp_loop(Socket) ->
  receive
    {tcp, Socket, BFileName} ->
      case check_file_exist(BFileName) of
        {ok, FilePath} ->
          {FileData, _} = do_read_file(FilePath);
        {error, Err} ->
          io:fwrite("[tcp mode]recv error:~p~n", [Err]),
          FileData = Err
      end,
      gen_tcp:send(Socket, FileData),
      inet:setopts(Socket, [{active, once}]),
      tcp_loop(Socket);
    {tcp_closed, Socket} ->
      gen_tcp:close(Socket);
    Err ->
      gen_tcp:close(Socket),
      io:fwrite("[tcp mode]recv error:~p~n", [Err])
  end.

%%UDP访问方式
get_msg_by_udp() ->
  {ok, Socket} = gen_udp:open(?UDP_PORT, [binary, {active, once}]),
  get_udp_request(Socket).

get_udp_request(Socket) ->
  receive
    {udp, Socket, Host, Port, BFileName} ->
      case check_file_exist(BFileName) of
        {ok, FilePath} ->
          {FileData, _} = do_read_file(FilePath);
        {error, Err} ->
          io:fwrite("[udp mode]recv error:~p~n", [Err]),
          FileData = Err
      end,
      gen_udp:send(Socket, Host, Port, FileData),
      inet:setopts(Socket, [{active, once}]),
      get_udp_request(Socket);
    Err ->
      io:fwrite("[udp mode]recv:~p~n", [Err]),
      gen_udp:close(Socket)
  end.

%%%%% common func %%%%%%%

http_or_tcp_listen(Port, Opts, LoopFunc) ->
  N = erlang:system_info(schedulers),
  {ok, S} = gen_tcp:listen(Port, Opts),
  Spawn = fun() ->
    erlang:spawn(?MODULE, http_or_tcp_accept, [S, LoopFunc])
          end,
  [Spawn || _Num <- lists:seq(1, N)].

http_or_tcp_accept(S, LoopFunc) ->
  case gen_tcp:accept(S) of
    {ok, Socket} ->
      Pid = erlang:spawn(?MODULE, LoopFunc, [Socket]),
      gen_tcp:controlling_process(Socket, Pid);
    Error ->
      io:fwrite("[Http Mode]accept error:~p~n", [Error])
  end,
  http_or_tcp_accept(S, LoopFunc).

do_read_file(FilePath) ->
  {ok, File} = file:open(FilePath, [raw, read]),
  FileSize = filelib:file_size(FilePath),
  {ok, Data} = file:read(File, FileSize),
  file:close(File),
  {Data, FileSize}.

check_file_exist(FileName) ->
  case erlang:is_binary(FileName) of
    true ->
      FileName1 = erlang:binary_to_list(FileName);
    _ ->
      FileName1 = FileName
  end,
  FileList = os:cmd("cd .. && ls"),
  FileList1 = string:tokens(FileList, "\n"),
  case lists:member(FileName1, FileList1) of
    true ->
      FilePath = lists:concat(["../", FileName1]),
      {ok, FilePath};
    _ ->
      {error, file_not_exit}
  end.

