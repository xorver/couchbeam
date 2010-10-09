%%% -*- erlang -*-
%%%
%%% This file is part of couchbeam released under the MIT license. 
%%% See the NOTICE for more information.

-module(couchbeam).
-author('Benoît Chesneau <benoitc@e-engura.org>').

-behaviour(gen_server).

-include("couchbeam.hrl").

-record(state, {}).

-define(ATOM_HEADERS, [
    {content_type, "Content-Type"},
    {content_length, "Content-Length"}
]).


% generic functions
-export([start_link/0, start/0, stop/0, version/0]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% utilities urls 
-export([server_url/1, uuids_url/1, db_url/1, doc_url/2, make_url/3]).
-export([request/4, request/5, request/6,
         request_stream/4, request_stream/5, request_stream/6,
         db_request/4, db_request/5, db_request/6]).

%% API urls
-export([server_connection/0, server_connection/2, server_connection/4,
        server_connection/5, server_info/1,
        get_uuid/1, get_uuids/2, 
        all_dbs/1, db_exists/2,
        create_db/2, create_db/3, create_db/4, 
        open_db/2, open_db/3,
        open_or_create_db/2, open_or_create_db/3, open_or_create_db/4,
        delete_db/1, delete_db/2, 
        db_info/1,
        save_doc/2, save_doc/3,
        open_doc/2, open_doc/3,
        delete_doc/2, delete_doc/3,
        save_docs/2, save_docs/3, delete_docs/2, delete_docs/3,
        fetch_attachment/3, fetch_attachment/4, fetch_attachment/5,
        stream_fetch_attachment/4, stream_fetch_attachment/5,
        stream_fetch_attachment/6, delete_attachment/3,
        delete_attachment/4, put_attachment/4, put_attachment/5, 
        all_docs/1, all_docs/2, view/2, view/3,
        ensure_full_commit/1, ensure_full_commit/2,
        compact/1, compact/2,
        changes/1, changes/2, changes_wait/2, changes_wait/3,
        changes_wait_once/1, changes_wait_once/2]).

%% --------------------------------------------------------------------
%% Generic utilities.
%% --------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Starts the server
%%--------------------------------------------------------------------
%% @doc Starts the couchbeam process linked to the calling process. Usually 
%% invoked by the supervisor couchbeam_sup
%% @spec start_link() -> {ok, pid()}
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_apps([]) ->
    ok;
start_apps([App|Rest]) ->
    case application:start(App) of
    ok ->
       start_apps(Rest);
    {error, {already_started, App}} ->
       start_apps(Rest);
    {error, _Reason} when App =:= public_key ->
       % ignore on R12B5
       start_apps(Rest);
    {error, _Reason} ->
       {error, {app_would_not_start, App}}
    end.


%% @doc Start the couchbeam process. Useful when testing using the shell. 
start() ->
    couchbeam_deps:ensure(),
    case start_apps([crypto, public_key, sasl, ssl, ibrowse]) of
        ok ->
            couchbeam_sup:start_link();
        Error ->
            Error
    end.

%% @doc Stop the couchbeam process. Useful when testing using the shell. 
stop() ->
    application:stop(couchbeam),
    application:stop(ibrowse),
    application:stop(crypto).

 
%% @spec () -> Version
%%     Version = string()
%% @doc Return the version of the application.
version() ->
    {ok, Version} = application:get_key(couchbeam, vsn),
    Version.   

%% --------------------------------------------------------------------
%% API functins.
%% --------------------------------------------------------------------

%% @doc Create a server for connectiong to a CouchDB node
%% @equiv server_connection("127.0.0.1", 5984, "", [], false)
server_connection() ->
    #server{host="127.0.0.1", port=5984, ssl=false, prefix="",
        options=[]}.

%% @doc Create a server for connectiong to a CouchDB node
%% @equiv server_connection(Host, Port, "", [])

server_connection(Host, Port) ->
    server_connection(Host, Port, "", []).

%% @doc Create a server for connectiong to a CouchDB node
%% @equiv server_connection(Host, Port, "", [], Ssl)
server_connection(Host, Port, Prefix, Options) when is_integer(Port), Port =:=443 ->
    server_connection(Host, Port, Prefix, Options, true);
server_connection(Host, Port, Prefix, Options) ->
    server_connection(Host, Port, Prefix, Options, false).


%% @doc Create a server for connectiong to a CouchDB node
%% 
%%      Connections are made to:
%%      ```http://Host:PortPrefix'''
%%
%%      If ssl is set https is used.
%%
%%      For a description of SSL Options, look in the <a href="http://www.erlang.org/doc/apps/ssl/index.html">ssl</a> manpage. 
%%
%% @spec server_connection(Host::string(), Port::integer(),
%%                        Prefix::string(), Options::optionList(),
%%                        Ssl::boolean()) -> Server::server()
%% optionList() = [option()]
%% option() = 
%%          {ssl_options, [SSLOpt]}            |
%%          {pool_name, atom()}                |
%%          {proxy_host, string()}             |
%%          {proxy_port, integer()}            |
%%          {proxy_user, string()}             |
%%          {proxy_password, string()}         |
%%          {basic_auth, {username(), password()}} |
%%          {cookie, string()}
%%
%% username() = string()
%% password() = string()
%% SSLOpt = term()
server_connection(Host, Port, Prefix, Options, Ssl) when is_binary(Port) ->
    server_connection(Host, binary_to_list(Port), Prefix, Options, Ssl);
server_connection(Host, Port, Prefix, Options, Ssl) when is_list(Port) ->
    server_connection(Host, list_to_integer(Port), Prefix, Options, Ssl); 
server_connection(Host, Port, Prefix, Options, Ssl) ->
    #server{host=Host, port=Port, ssl=Ssl, prefix=Prefix,
        options=Options}.

%% @doc Get Information from the server
%% @spec server_info(server()) -> {ok, iolist()}
server_info(#server{options=IbrowseOpts}=Server) ->
    Url = binary_to_list(iolist_to_binary(server_url(Server))),
    case request(get, Url, ["200"], IbrowseOpts) of
        {ok, _Status, _Headers, Body} ->
            Version = couchbeam_util:json_decode(Body),
            {ok, Version};
        Error -> Error
    end.

%% @doc Get one uuid from the server
%% @spec get_uuid(server()) -> lists()
get_uuid(Server) ->
    get_uuids(Server, 1).

%% @doc Get a list of uuids from the server
%% @spec get_uuids(server(), integer()) -> lists()
get_uuids(Server, Count) ->
    gen_server:call(couchbeam, {get_uuids, Server, Count}, infinity).
 
%% @doc get list of databases on a CouchDB node 
%% @spec all_dbs(server()) -> {ok, iolist()}
all_dbs(#server{options=IbrowseOpts}=Server) ->
    Url = make_url(Server, "_all_dbs", []),
    case request(get, Url, ["200"], IbrowseOpts) of
        {ok, _, _, Body} ->
            AllDbs = couchbeam_util:json_decode(Body),
            {ok, AllDbs};
        Error ->
            Error
    end.

%% @doc test if db with dbname exists on the CouchDB node
%% @spec db_exists(server(), string()) -> boolean()
db_exists(#server{options=IbrowseOpts}=Server, DbName) ->
    Url = make_url(Server, DbName, []),
    case request(head, Url, ["200"], IbrowseOpts) of
        {ok, _, _, _} -> true;
        _Error -> false
    end.

%% @doc Create a database and a client for connectiong to it.
%% @equiv create_db(Server, DbName, [], [])
create_db(Server, DbName) ->
    create_db(Server, DbName, [], []).

%% @doc Create a database and a client for connectiong to it.
%% @equiv create_db(Server, DbName, Options, [])
create_db(Server, DbName, Options) ->
    create_db(Server, DbName, Options, []).

%% @doc Create a database and a client for connectiong to it.
%% 
%%      Connections are made to:
%%      ```http://Host:PortPrefix/DbName'''
%%
%%      If ssl is set https is used.
%%
%% @spec create_db(Server::server(), DbName::string(),
%%                 Options::optionList(), Params::list()) -> {ok, db()|{error, Error}} 
create_db(#server{options=IbrowseOpts}=Server, DbName, Options, Params) ->
    Url = make_url(Server, DbName, Params),
    case request(put, Url, ["201"], IbrowseOpts) of
        {ok, _Status, _Headers, _Body} ->
            {ok, #db{server=Server, name=DbName, options=Options}};
        {error, {ok, "412", _, _}} ->
            {error, db_exists};
       Error ->
          Error
    end. 

%% @doc Create a client for connection to a database
%% @equiv open_db(Server, DbName, [])
open_db(Server, DbName) ->
    open_db(Server, DbName, []).

%% @doc Create a client for connection to a database
%% @spec open_db(server(), string(), list()) -> {ok, db()}
open_db(Server, DbName, Options) ->
    {ok, #db{server=Server, name=DbName, options=Options}}.
    

%% @doc Create a client for connecting to a database and create the
%%      database if needed.
%% @equiv open_or_create_db(Server, DbName, [], [])
open_or_create_db(Server, DbName) ->
    open_or_create_db(Server, DbName, [], []).

%% @doc Create a client for connecting to a database and create the
%%      database if needed.
%% @equiv open_or_create_db(Server, DbName, Options, [])
open_or_create_db(Server, DbName, Options) ->    
    open_or_create_db(Server, DbName, Options, []).

%% @doc Create a client for connecting to a database and create the
%%      database if needed.
%% @spec open_or_create_db(server(), string(), list(), list()) -> {ok, db()|{error, Error}}
open_or_create_db(#server{options=IbrowseOpts}=Server, DbName, Options, Params) ->
    Url = make_url(Server, DbName, []),
    case request(get, Url, ["200"], IbrowseOpts) of
        {ok, _, _, _} ->
            open_db(Server, DbName, Options);
        {error, {ok, "404", _, _}} ->
            create_db(Server, DbName, Options, Params);
        Error ->
            Error
    end.

%% @doc delete database 
%% @equiv delete_db(Server, DbName)
delete_db(#db{server=Server, name=DbName}) ->
    delete_db(Server, DbName).

%% @doc delete database 
%% @spec delete_db(server(), DbName) -> {ok, iolist()|{error, Error}}
delete_db(#server{options=IbrowseOpts}=Server, DbName) ->
    Url = make_url(Server, DbName, []),
    case request(delete, Url, ["200"], IbrowseOpts) of
        {ok, _, _, Body} ->
            {ok, couchbeam_util:json_decode(Body)};
        Error ->
            Error
    end.

%% @doc get database info
%% @spec db_info(db()) -> {ok, iolist()|{error, Error}}
db_info(#db{server=Server, name=DbName, options=IbrowseOpts}) ->
    Url = make_url(Server, DbName, []),
    case request(get, Url, ["200"], IbrowseOpts) of
        {ok, _Status, _Headers, Body} ->
            Infos = couchbeam_util:json_decode(Body),
            {ok, Infos}; 
        {error, {ok, "404", _, _}} ->
            {error, db_not_found};
       Error ->
          Error
    end.

%% @doc open a document 
%% @equiv open_doc(Db, DocId, []) 
open_doc(Db, DocId) ->
    open_doc(Db, DocId, []).

%% @doc open a document
%% Params is a list of query argument. Have a look in CouchDb API
%% @spec open_doc(Db::db(), DocId::string(), Params::list()) 
%%          -> {ok, Doc}|{error, Error}
open_doc(#db{server=Server, options=IbrowseOpts}=Db, DocId, Params) ->
    DocId1 = couchbeam_util:encode_docid(DocId), 
    Url = make_url(Server, doc_url(Db, DocId1), Params),
    case db_request(get, Url, ["200", "201"], IbrowseOpts) of
        {ok, _, _, Body} ->
            {ok, couchbeam_util:json_decode(Body)};
        Error ->
            Error
    end.

%% @doc save a document
%% @equiv save_doc(Db, Doc, [])
save_doc(Db, Doc) ->
    save_doc(Db, Doc, []).

%% @doc save a document
%% A document is a Json object like this one:
%%      
%%      ```{[
%%          {<<"_id">>, <<"myid">>},
%%          {<<"title">>, <<"test">>}
%%      ]}'''
%%
%% Options are arguments passed to the request. This function return a
%% new document with last revision and a docid. If _id isn't specified in
%% document it will be created. Id is created by extracting an uuid from
%% the couchdb node.
%%
%% @spec save_doc(Db::db(), Doc, Options::list()) -> {ok, Doc1}|{error, Error}
save_doc(#db{server=Server, options=IbrowseOpts}=Db, {Props}=Doc, Options) ->
    DocId = case proplists:get_value(<<"_id">>, Props) of
        undefined ->
            [Id] = get_uuid(Server),
            Id;
        DocId1 ->
            couchbeam_util:encode_docid(DocId1)
    end,
    Url = make_url(Server, doc_url(Db, DocId), Options),
    Body = couchbeam_util:json_encode(Doc),
    Headers = [{"Content-Type", "application/json"}],
    case db_request(put, Url, ["201", "202"], IbrowseOpts, Headers, Body) of
        {ok, _, _, RespBody} ->
            {JsonProp} = couchbeam_util:json_decode(RespBody),
            NewRev = proplists:get_value(<<"rev">>, JsonProp),
            NewDocId = proplists:get_value(<<"id">>, JsonProp),
            Doc1 = couchbeam_doc:set_value(<<"_rev">>, NewRev, 
                couchbeam_doc:set_value(<<"_id">>, NewDocId, Doc)),
            {ok, Doc1};
        Error -> 
            Error
    end.

%% @doc delete a document
%% @equiv delete_doc(Db, Doc, [])
delete_doc(Db, Doc) ->
    delete_doc(Db, Doc, []).

%% @doc delete a document
%% @spec delete_doc(Db, Doc, Options) -> {ok,Result}|{error,Error}
delete_doc(Db, Doc, Options) ->
    delete_docs(Db, [Doc], Options).

%% @doc delete a list of documents
%% @equiv delete_docs(Db, Docs, [])
delete_docs(Db, Docs) ->
    delete_docs(Db, Docs, []).

%% @doc delete a list of documents
%% @spec delete_docs(Db::db(), Docs::list(),Options::list()) -> {ok, Result}|{error, Error}
delete_docs(Db, Docs, Options) ->
    Docs1 = lists:map(fun({DocProps})->
        {[{<<"_deleted">>, true}|DocProps]}
        end, Docs),
    save_docs(Db, Docs1, Options).

%% @doc save a list of documents
%% @equiv save_docs(Db, Docs, [])
save_docs(Db, Docs) ->
    save_docs(Db, Docs, []).

%% @doc save a list of documents
%% @spec save_docs(Db::db(), Docs::list(),Options::list()) -> {ok, Result}|{error, Error}
save_docs(#db{server=Server, options=IbrowseOpts}=Db, Docs, Options) ->
    Docs1 = [maybe_docid(Server, Doc) || Doc <- Docs],
    Options1 = couchbeam_util:parse_options(Options),
    {Options2, Body} = case proplists:get_value("all_or_nothing", 
            Options1, false) of
        true ->
            Body1 = couchbeam:json_encode({[
                {<<"all_or_nothing">>, true},
                {<<"docs">>, Docs1}
            ]}),

            {proplists:delete("all_or_nothing", Options1), Body1};
        _ ->
            Body1 = couchbeam_util:json_encode({[{<<"docs">>, Docs1}]}),
            {Options1, Body1}
        end,
    Url = make_url(Server, [db_url(Db), "/", "_bulk_docs"], Options2),
    Headers = [{"Content-Type", "application/json"}], 
    case db_request(post, Url, ["201"], IbrowseOpts, Headers, Body) of
        {ok, _, _, RespBody} ->
            {ok, couchbeam_util:json_decode(RespBody)};
        Error -> 
            Error
        end.

%% @doc fetch a document attachment
%% @equiv fetch_attachment(Db, DocId, Name, [], DEFAULT_TIMEOUT)
fetch_attachment(Db, DocId, Name) ->
    fetch_attachment(Db, DocId, Name, [], ?DEFAULT_TIMEOUT).

%% @doc fetch a document attachment
%% @equiv fetch_attachment(Db, DocId, Name, Options, DEFAULT_TIMEOUT)
fetch_attachment(Db, DocId, Name, Options) ->
    fetch_attachment(Db, DocId, Name, Options, ?DEFAULT_TIMEOUT).

%% @doc fetch a document attachment
%% @spec fetch_attachment(db(), string(), string(), 
%%                        list(), infinity|integer()) -> {ok, binary()}
fetch_attachment(Db, DocId, Name, Options, Timeout) ->
    {ok, ReqId} = stream_fetch_attachment(Db, DocId, Name, self(), Options,
        Timeout),
    couchbeam_attachments:wait_for_attachment(ReqId, Timeout).

%% @doc stream fetch attachment to a Pid.
%% @equiv stream_fetch_attachment(Db, DocId, Name, ClientPid, [], DEFAULT_TIMEOUT)
stream_fetch_attachment(Db, DocId, Name, ClientPid) ->
    stream_fetch_attachment(Db, DocId, Name, ClientPid, [], ?DEFAULT_TIMEOUT).


%% @doc stream fetch attachment to a Pid.
%% @equiv stream_fetch_attachment(Db, DocId, Name, ClientPid, Options, DEFAULT_TIMEOUT)
stream_fetch_attachment(Db, DocId, Name, ClientPid, Options) ->
     stream_fetch_attachment(Db, DocId, Name, ClientPid, Options, ?DEFAULT_TIMEOUT).

%% @doc stream fetch attachment to a Pid. Messages sent to the Pid
%%      will be of the form `{reference(), message()}',
%%      where `message()' is one of:
%%      <dl>
%%          <dt>done</dt>
%%              <dd>You got all the attachment</dd>
%%          <dt>{ok, binary()}</dt>
%%              <dd>Part of the attachment</dd>
%%          <dt>{error, term()}</dt>
%%              <dd>n error occurred</dd>
%%      </dl>
%% @spec stream_fetch_attachment(Db::db(), DocId::string(), Name::string(), 
%%                               ClientPid::pid(), Options::list(), Timeout::integer())
%%          -> {ok, reference()}|{error, term()}
stream_fetch_attachment(#db{server=Server, options=IbrowseOpts}=Db, DocId, Name, ClientPid, 
        Options, Timeout) ->
    Options1 = couchbeam_util:parse_options(Options),
    %% custom headers. Allows us to manage Range.
    {Options2, Headers} = case proplists:get_value("headers", Options1) of
        undefined ->
            {Options1, []};
        Headers1 ->
            {proplists:delete("headers", Options1), Headers1}
    end,
    DocId1 = couchbeam_util:encode_docid(DocId),
    Url = make_url(Server, [db_url(Db), "/", DocId1, "/", Name], Options2),
    StartRef = make_ref(),
    Pid = spawn(couchbeam_attachments, attachment_acceptor, [ClientPid,
            StartRef, Timeout]),
    case request_stream(Pid, get, Url, IbrowseOpts, Headers) of
        {ok, ReqId}    ->
            Pid ! {ibrowse_req_id, StartRef, ReqId},
            {ok, StartRef};
        {error, Error} -> {error, Error}
    end.

%% @doc put an attachment 
%% @equiv put_attachment(Db, DocId, Name, Body, [])
put_attachment(Db, DocId, Name, Body)->
    put_attachment(Db, DocId, Name, Body, []).

%% @doc put an attachment
%% @spec put_attachment(Db::db(), DocId::string(), Name::string(),
%%                      Body::body(), Option::optionList()) -> {ok, iolist()}
%%       optionList() = [option()]
%%       option() = {rev, string()} |
%%                  {content_type, string()} |
%%                  {content_length, string()}
%%       body() = [] | string() | binary() | fun_arity_0() | {fun_arity_1(), initial_state()}
%%       initial_state() = term()
put_attachment(#db{server=Server, options=IbrowseOpts}=Db, DocId, Name, Body, Options) ->
    QueryArgs = case proplists:get_value(rev, Options) of
        undefined -> [];
        Rev -> [{"rev", couchbeam_util:to_list(Rev)}]
    end,
    
    Headers = proplists:get_value(headers, Options, []),

    FinalHeaders = lists:foldl(fun(Hdr, Acc) ->
            case proplists:get_value(Hdr, Options) of
                undefined -> Acc;
                Value -> 
                    Hdr1 = proplists:get_value(Hdr, ?ATOM_HEADERS),
                    [{Hdr1, Value}|Acc]
            end
    end, Headers, [content_type, content_length]),

    Url = make_url(Server, [db_url(Db), "/",
            couchbeam_util:encode_docid(DocId), "/", Name], QueryArgs),

    case db_request(put, Url, ["201"], IbrowseOpts, FinalHeaders, Body) of
        {ok, _, _, RespBody} ->
            {[{<<"ok">>, true}|R]} = couchbeam_util:json_decode(RespBody),
            {ok, {R}};
        Error ->
            Error
    end.
    
%% @doc delete a document attachment
%% @equiv delete_attachment(Db, Doc, Name, [])
delete_attachment(Db, Doc, Name) ->
    delete_attachment(Db, Doc, Name, []).

%% @doc delete a document attachment
%% @spec(db(), string()|list(), string(), list() -> ok 
delete_attachment(#db{server=Server, options=IbrowseOpts}=Db, DocOrDocId, Name, Options) ->
    Options1 = couchbeam_util:parse_options(Options),
    {Rev, DocId} = case DocOrDocId of
        {Props} ->
            Rev1 = proplists:get_value(<<"_rev">>, Props),
            DocId1 = proplists:get_value(<<"_id">>, Props),
            {Rev1, DocId1};
        DocId1 ->
            Rev1 = proplists:get_value("rev", Options1),
            {Rev1, DocId1}
    end,
    case Rev of
        undefined ->
           {error, rev_undefined};
        _ ->
            Options2 = case proplists:get_value("rev", Options1) of
                undefined ->
                    [{"rev", Rev}|Options1];
                _ ->
                    Options1
            end,
            Url = make_url(Server, [db_url(Db), "/", DocId, "/", Name], Options2),
            case db_request(delete, Url, ["200"], IbrowseOpts) of
            {ok, _, _, _Body} ->
                ok; 
            Error ->
                Error
            end
    end.
                    
all_docs(Db) ->
    all_docs(Db, []).
all_docs(Db, Options) ->
    view(Db, "_all_docs", Options).

view(Db, ViewName) ->
    view(Db, ViewName, []).

view(#db{server=Server}=Db, ViewName, Options) ->
    ViewName1 = couchbeam_util:to_list(ViewName),
    Options1 = couchbeam_util:parse_options(Options),
    Url = case ViewName1 of
        {DName, VName} ->
            [db_url(Db), "/_design/", DName, "/_view/", VName];
        "_all_docs" ->
            [db_url(Db), "/_all_docs"];
        _Else ->
            case string:tokens(ViewName1, "/") of
            [DName, VName] ->
                [db_url(Db), "/_design/", DName, "/_view/", VName];
            _ ->
                undefined
            end
    end,
    case Url of
    undefined ->
        {error, invalid_view_name};
    _ ->
        {Method, Options2, Body} = case proplists:get_value("keys",
                Options1) of
            undefined ->
                {get, Options1, []};
            Keys ->
                Body1 = couchbeam_util:json_encode({[{<<"keys">>, Keys}]}),
                {post, proplists:delete("keys", Options1), Body1}
            end,
        Headers = case Method of
            post -> [{"Content-Type", "application/json"}];
            _ -> []
        end,
        NewView = #view{
            db = Db,
            name = ViewName,
            options = Options2,
            method = Method,
            body = Body,
            headers = Headers,
            url_parts = Url,
            url = make_url(Server, Url, Options2)
        },
        {ok, NewView}
    end.


ensure_full_commit(Db) ->
    ensure_full_commit(Db, []).

ensure_full_commit(#db{server=Server, options=IbrowseOpts}=Db, Options) ->
    Url = make_url(Server, [db_url(Db), "/_ensure_full_commit"], Options),
    Headers = [{"Content-Type", "application/json"}],
    case db_request(post, Url, ["201"], IbrowseOpts, Headers) of
        {ok, _, _, Body} ->
            {[{<<"ok">>, true}|R]} = couchbeam_util:json_decode(Body),
            {ok, R};
        Error ->
            Error
    end.

compact(#db{server=Server, options=IbrowseOpts}=Db) ->
    Url = make_url(Server, [db_url(Db), "/_compact"], []),
    Headers = [{"Content-Type", "application/json"}],
    case db_request(post, Url, ["202"], IbrowseOpts, Headers) of
        {ok, _, _, _} ->
            ok;
        Error -> 
            Error
    end.

compact(#db{server=Server, options=IbrowseOpts}=Db, DesignName) ->
    Url = make_url(Server, [db_url(Db), "/_compact/", DesignName], []),
    Headers = [{"Content-Type", "application/json"}],
    case db_request(post, Url, ["202"], IbrowseOpts, Headers) of
        {ok, _, _, _} ->
            ok;
        Error -> 
            Error
    end.


%% @doc get all changes. Do not use this function for longpolling,
%%      instead use  ```changes_wait_once''' or continuous, use 
%%      ```wait_once'''
%% @equiv changes(Db, [])
changes(Db) ->
    changes(Db, []).

%% @doc get all changes. Do not use this function for longpolling,
%%      instead use  ```changes_wait_once''' or continuous, use 
%%      ```wait_once'''
%% @spec changes(Db::db(), Options::changesoptions()) -> term()
%%       changesoptions() = [changeoption()]
%%       changeoption() = {include_docs, string()} |
%%                  {filter, string()} |
%%                  {since, integer()|string()} |
%%                  {heartbeat, string()|boolean()}
changes(#db{server=Server, options=IbrowseOpts}=Db, Options) ->
    Url = make_url(Server, [db_url(Db), "/_changes"], Options),
    case db_request(get, Url, ["200"], IbrowseOpts) of
        {ok, _, _, Body} ->
            {ok, couchbeam_util:json_decode(Body)};
        Error ->
            Error
    end.

%% @doc wait for longpoll changes 
%% @equiv changes_wait_once(Db, [])
changes_wait_once(Db) ->
    changes_wait_once(Db, []).

%% @doc wait for longpoll changes 
changes_wait_once(Db, Options) ->
    Options1 = [{"feed", "longpoll"}|Options],
    changes(Db, Options1). 

%% @doc wait for continuous changes 
%% @equiv changes_wait(Db, ClientPid, [])
changes_wait(Db, ClientPid) ->
    changes_wait(Db, ClientPid, []).

%% @doc wait for continuous changes to a Pid. Messages sent to the Pid
%%      will be of the form `{reference(), message()}',
%%      where `message()' is one of:
%%      <dl>
%%          <dt>done</dt>
%%              <dd>You got all the changes</dd>
%%          <dt>{change, term()}</dt>
%%              <dd>Change row</dd>
%%          <dt>{last_seq, binary()}</dt>
%%              <dd>last sequence</dd>
%%          <dt>{error, term()}</dt>
%%              <dd>n error occurred</dd>
%%      </dl> 
%% @spec changes_wait(Db::db(), Pid::pid(), Options::changeoptions()) -> term() 
changes_wait(#db{server=Server, options=IbrowseOpts}=Db, ClientPid, Options) ->
    Options1 = [{"feed", "continuous"}|Options],
    Url = make_url(Server, [db_url(Db), "/_changes"], Options1),
    StartRef = make_ref(),
    Pid = spawn(couchbeam_changes, continuous_acceptor, [ClientPid, StartRef]),
    case request_stream({Pid, once}, get, Url, IbrowseOpts) of
        {ok, ReqId}    ->
            Pid ! {ibrowse_req_id, StartRef, ReqId},
            {ok, StartRef};
        {error, Error} -> {error, Error}
    end. 

%% --------------------------------------------------------------------
%% Utilities functins.
%% --------------------------------------------------------------------

%% add missing docid to a list of documents if needed
maybe_docid(Server, {DocProps}) ->
    case proplists:get_value(<<"_id">>, DocProps) of
        undefined ->
            DocId = [get_uuid(Server)],
            {[{<<"_id">>, list_to_binary(DocId)}|DocProps]};
        _DocId ->
            {DocProps}
    end.

%% @doc Assemble the server URL for the given client
%% @spec server_url({Host, Port}) -> iolist()
server_url(#server{host=Host, port=Port, ssl=Ssl}) ->
    server_url({Host, Port}, Ssl).

%% @doc Assemble the server URL for the given client
%% @spec server_url({Host, Port}, Ssl) -> iolist()
server_url({Host, Port}, false) ->
    ["http://",Host,":",integer_to_list(Port)];
server_url({Host, Port}, true) ->
    ["https://",Host,":",integer_to_list(Port)].

uuids_url(Server) ->
    binary_to_list(iolist_to_binary([server_url(Server), "/", "_uuids"])).

db_url(#db{name=DbName}) ->
    [DbName].

doc_url(Db, DocId) ->
    [db_url(Db), "/", DocId].

make_url(Server=#server{prefix=Prefix}, Path, Query) ->
    Query1 = couchbeam_util:encode_query(Query),
    binary_to_list(
        iolist_to_binary(
            [server_url(Server),
             Prefix, "/",
             Path, "/",
             [ ["?", mochiweb_util:urlencode(Query1)] || Query1 =/= [] ]
            ])).

db_request(Method, Url, Expect, Options) ->
    db_request(Method, Url, Expect, Options, [], []).
db_request(Method, Url, Expect, Options, Headers) ->
    db_request(Method, Url, Expect, Options, Headers, []).
db_request(Method, Url, Expect, Options, Headers, Body) ->
    case request(Method, Url, Expect, Options, Headers, Body) of
        Resp = {ok, _, _, _} ->
            Resp;
        {error, {ok, "404", _, _}} ->
            {error, not_found};
        {error, {ok, "409", _, _}} ->
            {error, conflict};
        {error, {ok, "412", _, _}} ->
            {error, precondition_failed};
        Error -> 
            Error
    end.

%% @doc send an ibrowse request
request(Method, Url, Expect, Options) ->
    request(Method, Url, Expect, Options, [], []).
request(Method, Url, Expect, Options, Headers) ->
    request(Method, Url, Expect, Options, Headers, []).
request(Method, Url, Expect, Options, Headers, Body) ->
    Accept = {"Accept", "application/json, */*;q=0.9"},
    case ibrowse:send_req(Url, [Accept|Headers], Method, Body, 
            [{response_format, binary}|Options]) of
        Resp={ok, Status, _, _} ->
            case lists:member(Status, Expect) of
                true -> Resp;
                false -> {error, Resp}
            end;
        Error -> Error
    end.

%% @doc stream an ibrowse request
request_stream(Pid, Method, Url, Options) ->
    request_stream(Pid, Method, Url, Options, []).
request_stream(Pid, Method, Url, Options, Headers) ->
    request_stream(Pid, Method, Url, Options, Headers, []).
request_stream(Pid, Method, Url, Options, Headers, Body) ->
    case ibrowse:send_req(Url, Headers, Method, Body,
                          [{stream_to, Pid},
                           {response_format, binary}|Options]) of
        {ibrowse_req_id, ReqId} ->
            {ok, ReqId};
        Error ->
            Error
    end.


%%---------------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------------
%% @private

init(_) ->
    process_flag(trap_exit, true),
    ets:new(couchbeam_uuids, [named_table, public, {keypos, 2}]),
    {ok, #state{}}.

handle_call({get_uuids, #server{host=Host, port=Port}=Server, Count}, _From, State) ->
    {ok, Uuids} = do_get_uuids(Server, Count, [],
        ets:lookup(couchbeam_uuids, {Host, Port})),
    {reply, Uuids, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
do_get_uuids(_Server, Count, Acc, _) when length(Acc) >= Count ->
    {ok, Acc};
do_get_uuids(Server, Count, Acc, []) ->
    {ok, ServerUuids} = get_new_uuids(Server),
    do_get_uuids(Server, Count, Acc, [ServerUuids]);
do_get_uuids(Server, Count, Acc, [#server_uuids{uuids=Uuids}]) ->
    case Uuids of 
        [] ->
            {ok, ServerUuids} = get_new_uuids(Server),
            do_get_uuids(Server, Count, Acc, [ServerUuids]);
        _ ->
            {Acc1, Uuids1} = do_get_uuids1(Acc, Uuids, Count),
            #server{host=Host, port=Port} = Server,
            ServerUuids = #server_uuids{host_port={Host,Port},
                uuids=Uuids1},
            ets:insert(couchbeam_uuids, ServerUuids),
            do_get_uuids(Server, Count, Acc1, [ServerUuids])
    end.



do_get_uuids1(Acc, Uuids, 0) ->
    {Acc, Uuids};
do_get_uuids1(Acc, [Uuid|Rest], Count) ->
    do_get_uuids1([Uuid|Acc], Rest, Count-1).


get_new_uuids(Server=#server{host=Host, port=Port, options=IbrowseOptions}) ->
    Url = make_url(Server, "_uuids", [{"count", "1000"}]),  
    case request(get, Url, ["200"], IbrowseOptions) of
        {ok, _Status, _Headers, Body} ->
            {[{<<"uuids">>, Uuids}]} = couchbeam_util:json_decode(Body),
            ServerUuids = #server_uuids{host_port={Host,
                        Port}, uuids=Uuids},
            ets:insert(couchbeam_uuids, ServerUuids),
            {ok, ServerUuids};
        Error ->
            Error
    end.



