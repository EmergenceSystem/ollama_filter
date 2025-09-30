-module(ollama_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    FilterUrl = lists:concat(["http://localhost:", integer_to_list(Port), "/query"]),
    io:format("Filter registered: ~s~n", [FilterUrl]),
    em_filter:register_filter(FilterUrl),
    em_filter_sup:start_link(ollama_filter, ?MODULE, Port).

stop(_State) -> ok.

%% @doc Handle incoming requests from the filter server.
%% This function is called by em_filter_server through Wade.
%% @param Body The request body (JSON binary or string)
%% @return JSON response as binary or string
handle(Body) when is_binary(Body) ->
    handle(binary_to_list(Body));

handle(Body) when is_list(Body) ->
    io:format("Bing Filter received body: ~p~n", [Body]),
    EmbryoList = generate_embryo_list(list_to_binary(Body)),
    Response = #{embryo_list => EmbryoList},
    jsone:encode(Response);

handle(_) ->
    jsone:encode(#{error => <<"Invalid request body">>}).

generate_embryo_list(Body) ->
    {Value, Timeout} = extract_value_and_timeout(Body),
    generate_embryos(Value, Timeout).

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

