-module(ollama_filter_app).
-behaviour(application).
-behaviour(cowboy_handler).

-export([start/2, stop/1]).
-export([init/2, terminate/3]).

start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    FilterUrl = lists:concat(["http://localhost:", integer_to_list(Port), "/query"]),
    io:format("Filter registered: ~s~n", [FilterUrl]),
    em_filter:register_filter(FilterUrl),
    em_filter_sup:start_link(ollama_filter, ?MODULE, Port).

stop(_State) -> ok.

init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    {Value, Timeout} = extract_value_and_timeout(Body),
    Embryos = generate_embryos(Value, Timeout),
    Response = jsone:encode(#{embryo_list => Embryos}),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        Response,
        Req
    ),
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) -> ok.

extract_value_and_timeout(JsonBinary) ->
    case jsone:decode(JsonBinary) of
        #{<<"value">> := Val} = Map when is_binary(Val) ->
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined -> 10;
                TimeoutBin when is_binary(TimeoutBin) ->
                    try list_to_integer(binary_to_list(TimeoutBin))
                    catch _:_ -> 10 end;
                TimeoutInt when is_integer(TimeoutInt) -> TimeoutInt;
                _ -> 10
            end,
            {binary_to_list(Val), Timeout};
        _ -> {"", 10}
    end.

generate_embryos(Value, _Timeout) when Value =:= "" -> [];
generate_embryos(Value, Timeout) ->
    io:format("Ollama filter received value: ~p~n", [Value]),
    Config0 = ollama_handler:get_env_config(),
    Config = Config0#{timeout => Timeout * 1000},
    Prompt = ollama_handler:format_prompt(
        maps:get(prompt_template, Config, default_prompt_template()),
        [Value]
    ),
    case ollama_handler:generate(Prompt, Config) of
        {ok, ResumeBin} when is_binary(ResumeBin) ->
            io:format("Ollama filter response: ~s~n", [ResumeBin]),
            [#{properties => #{<<"resume">> => ResumeBin}}];
        {error, Reason} ->
            io:format("Ollama filter error: ~p~n", [Reason]),
            []
    end.

default_prompt_template() ->
    "Résume le texte suivant de façon concise :\n\n~s".

