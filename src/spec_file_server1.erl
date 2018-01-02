%%%-------------------------------------------------------------------
%%% @author lijianming
%%% @copyright (C) 2016, <ljming1106@163.com>
%%% @doc
%%%
%%% @end
%%% Created : 03. 五月 2016 0:04
%%%-------------------------------------------------------------------
-module(spec_file_server1).
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
  get_msg_by_udp/0,
  get_tcp_request/1
]).

-export([
  http_accept/2,
  http_loop/1
]).

-define(SERVER, ?MODULE).

-record(state, {}).


%% @TODO 语言驾驭能力L2要求：
%% 1、erlang文件操作(done)

%% 2、各种方式的客户端逻辑 (done)
%% 3、阅读了解并修正http的客户端、服务端逻辑

%% 4、压力测试
%% 提供压力测试结果、包括但不限于：TPS、磁盘IO、网络IO、CPU、内存、平均延时
%% --> 跑多个客户端进行测试
%% --> 客户端需要分发送进程、接收进程吗？

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
  N = erlang:system_info(schedulers),
  http_listen(?HTTP_PORT, N),
  % io:format("ehttpd ready with ~b schedulers on port ~b~n", [N, ?HTTP_PORT]),
  receive Any -> io:format("~p~n", [Any]) end.  %% to stop: ehttpd!stop.

http_listen(Port, N) ->
  Opts = [{active, false},
    binary,
    {backlog, 256},
    {packet, http_bin},
    {raw, 6, 9, <<1:32/native>>}, %defer accept %%?
    {reuseaddr, true}],
  {ok, S} = gen_tcp:listen(Port, Opts),
  Spawn = fun(I) ->
    PID = erlang:spawn(?MODULE, http_accept, [S, I]),
    erlang:register(list_to_atom("acceptor_" ++ integer_to_list(I)), PID)
          end,
  lists:foreach(Spawn, lists:seq(1, N)).

http_accept(S, I) ->
  case gen_tcp:accept(S) of
    {ok, Socket} ->
      %%这里的Socket不用绑定到PID上吗？
      erlang:spawn(?MODULE, http_loop, [Socket]);
    Error ->
      io:fwrite("[Http Mode]accept error:~p~n", [Error])
  end,
  http_accept(S, I).

-define(FILEPATH, "../example.txt").
http_loop(S) ->
  case gen_tcp:recv(S, 0) of
    {ok, http_eoh} ->
      case get_filename() of
        FileName when FileName =/= undefined ->
          {FileData, FileSize} = do_read_file(?FILEPATH),
          %%HTTP响应：状态行、响应头(Response Header)、响应正文
          Content = lists:concat(["HTTP/1.1 200 OK\r\n", "Content-Length: ", FileSize, "\r\n\r\n", FileData]),
          Response = erlang:list_to_binary(Content);
        _ ->
          io:fwrite("[Http Mode]send error:file not exist~n", []),
          Response = erlang:list_to_binary("file not exist")
      end,
      gen_tcp:send(S, Response),
      %%为什么不关闭这个就有问题呢？是因为客户端对应的socket已存在？
      %%应该是客户端跟服务端还连着，所以就有问题
      gen_tcp:close(S),
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
      NameInfo = string:tokens(erlang:binary_to_list(UrlInfo), "filename="),
      [FileName | _] = string:tokens(NameInfo, "&"),
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
  {ok, ListenSocket} = gen_tcp:listen(?TCP_PORT, [binary, {active, false}, {reuseaddr,true}]),
  wait_connect(ListenSocket).

wait_connect(ListenSocket) ->
  {ok, Socket} = gen_tcp:accept(ListenSocket),
  Pid = spawn(?MODULE, get_tcp_request, [Socket]),
  %将该套接字的控制进程改为Pid进程
  gen_tcp:controlling_process(Socket, Pid),
  wait_connect(ListenSocket).
get_tcp_request(Socket) ->
  case gen_tcp:recv(Socket, 0) of
    {ok, BFileName} ->
      case check_file_exist(BFileName) of
        {ok, FilePath} ->
          {FileData, _} = do_read_file(FilePath);
        {error, Err} ->
          io:fwrite("[tcp mode]recv error:~p~n", [Err]),
          FileData = Err
      end,
      gen_tcp:send(Socket, FileData),
      get_tcp_request(Socket);
    {error, closed} ->
      gen_tcp:close(Socket);
    Err ->
      gen_tcp:close(Socket),
      io:fwrite("[tcp mode]recv error:~p~n", [Err])
  end.

%%UDP访问方式
get_msg_by_udp() ->
  {ok, Socket} = gen_udp:open(?UDP_PORT, [binary,{active, false}]),
  get_udp_request(Socket).

% get_udp_request(Socket) ->
%   receive
%   %%???为什么CSocket与Socket一样的
%     {udp, CSocket, Host, Port, BFileName} ->
%       case check_file_exist(BFileName) of
%         {ok, FilePath} ->
%           {FileData, _} = do_read_file(FilePath);
%         {error, Err} ->
%           io:fwrite("[udp mode]recv error:~p~n", [Err]),
%           FileData = Err
%       end,
%       gen_udp:send(CSocket, Host, Port, FileData),
%       get_udp_request(Socket)
%   after 15000 ->
%     gen_udp:close(Socket)
%   end.
get_udp_request(Socket) ->
  case gen_udp:recv(Socket,0) of
    {ok, {Host, Port, BFileName}} ->
      case check_file_exist(BFileName) of
        {ok, FilePath} ->
          {FileData, _} = do_read_file(FilePath);
        {error, Err} ->
          io:fwrite("[udp mode]recv error:~p~n", [Err]),
          FileData = Err
      end,
      gen_udp:send(Socket, Host, Port, FileData),
      get_udp_request(Socket);
    {error,Reason} ->
      io:fwrite("[udp mode]recv error:~p~n", [Reason]),
      gen_udp:close(Socket)
  end.

do_read_file(FilePath) ->
  {ok, File} = file:open(FilePath, [raw, read]),
  FileSize = filelib:file_size(FilePath),
  {ok, Data} = file:read(File, FileSize),
  file:close(File),
  {Data, FileSize}.

check_file_exist(_FileName) ->
%%    case erlang:is_binary(FileName) of
%%        true ->
%%            FileName1 = erlang:binary_to_list(FileName);
%%        _ ->
%%            FileName1 = FileName
%%    end,
%%    FileList = os:cmd("ls"),
%%    FileList1 = string:tokens(FileList, "\n"),
%%    case lists:member(FileName1, FileList1) of
%%        true ->
%%            FilePath = lists:concat(["../", FileName1]),
%%            {ok, FilePath};
%%        _ ->
%%            {error, file_not_exit}
%%    end.
  {ok, "../example.txt"}.




  % %%HTTP访问方式
  % get_msg_by_http() ->
  %   N = erlang:system_info(schedulers),
  %   http_listen(?HTTP_PORT, N),
  %   % io:format("ehttpd ready with ~b schedulers on port ~b~n", [N, ?HTTP_PORT]),
  %   receive Any -> io:format("~p~n", [Any]) end.  %% to stop: ehttpd!stop.

  % http_listen(Port, N) ->
  %   Opts = [{active, once},
  %     binary,
  %     {backlog, 256},
  %     {packet, http_bin},
  %     {raw, 6, 9, <<1:32/native>>}, %defer accept %%?
  %     {reuseaddr, true}],
  %   {ok, S} = gen_tcp:listen(Port, Opts),
  %   Spawn = fun(I) ->
  %     PID = erlang:spawn(?MODULE, http_accept, [S, I]),
  %     erlang:register(list_to_atom("acceptor_" ++ integer_to_list(I)), PID)
  %           end,
  %   lists:foreach(Spawn, lists:seq(1, N)).

  % http_accept(S, I) ->
  %   case gen_tcp:accept(S) of
  %     {ok, Socket} ->
  %       %%这里的Socket不用绑定到PID上吗？
  %       Pid = erlang:spawn(?MODULE, http_loop, [Socket]),
  %       gen_tcp:controlling_process(Socket, Pid);
  %     Error ->
  %       io:fwrite("[Http Mode]accept error:~p~n", [Error])
  %   end,
  %   http_accept(S, I).

  % -define(FILEPATH, "../example.txt").
  % http_loop(S) ->
  %   io:fwrite("[http mode]recv start:~p~n", [S]),
  %   receive
  %     {http,S,http_eoh} ->
  %       io:fwrite("[http mode]recv10:~p~n", [S]),
  %       case get_filename() of
  %         FileName when FileName =/= undefined ->
  %           {FileData, FileSize} = do_read_file(?FILEPATH),
  %           %%HTTP响应：状态行、响应头(Response Header)、响应正文
  %           Content = lists:concat(["HTTP/1.1 200 OK\r\n", "Content-Length: ", FileSize, "\r\n\r\n", FileData]),
  %           Response = erlang:list_to_binary(Content);
  %         _ ->
  %           io:fwrite("[Http Mode]send error:file not exist~n", []),
  %           Response = erlang:list_to_binary("file not exist")
  %       end,
  %       io:fwrite("[http mode]recv:~p~n", [Response]),
  %       gen_tcp:send(S, Response),
  %       %%为什么不关闭这个就有问题呢？是因为客户端对应的socket已存在？
  %       %%应该是客户端跟服务端还连着，所以就有问题
  %       gen_tcp:close(S),
  %       ok;
  %     {http,S,Data} ->
  %       io:fwrite("[http mode]recv1:~p~n", [Data]),
  %       deal_filename(Data),
  %       inet:setopts(S,[{active,once}]),
  %       http_loop(S);
  %     Err ->
  %       io:fwrite("[Http Mode]send error:~p~n", [Err]),
  %       gen_tcp:close(S)
  %   end.

  % deal_filename(Data) ->
  %   case Data of
  %     {http_request, _, {abs_path, UrlInfo}, _} ->
  %       NameInfo = string:tokens(erlang:binary_to_list(UrlInfo), "filename="),
  %       [FileName | _] = string:tokens(NameInfo, "&"),
  %       set_filename(FileName);
  %     _ ->
  %       ingore
  %   end.

  % get_filename() ->
  %   erlang:get(file_name).
  % set_filename(FileName) ->
  %   erlang:put(file_name, FileName).