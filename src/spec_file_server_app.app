%%%-------------------------------------------------------------------
%%% @author lijianming
%%% @copyright (C) 2016, <ljming1106@163.com>
%%% @doc
%%%
%%% @end
%%% Created : 30. 四月 2016 1:29
%%%-------------------------------------------------------------------
{application, spec_file_server_app, [
  {description, ""},
  {vsn, "1"},
  {registered, [spec_file_server_app]},
  {applications, [
    kernel,
    stdlib
  ]},
  {mod, {spec_file_server_app, []}},
  {env, []}
]}.