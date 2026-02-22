%%%-------------------------------------------------------------------
%%% @doc Ollama local LLM filter.
%%%
%%% Sends the query to a local Ollama instance and returns the
%%% generated response as a single embryo map.
%%% @end
%%%-------------------------------------------------------------------
-module(ollama_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_filter(ollama_filter, ?MODULE).

stop(_State) ->
    em_filter:stop_filter(ollama_filter).

%%====================================================================
%% Filter handler — returns a list of embryo maps
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    generate_embryos(Value, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        #{<<"value">> := Val} = Map when is_binary(Val) ->
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {binary_to_list(Val), Timeout};
        _ -> {"", 10}
    catch
        _:_ -> {"", 10}
    end.

generate_embryos("", _) -> [];
generate_embryos(Value, Timeout) ->
    Config = (ollama_handler:get_env_config())#{timeout => Timeout * 1000},
    Prompt = ollama_handler:format_prompt(
        maps:get(prompt_template, Config, default_prompt()),
        [Value]),
    Result = ollama_handler:generate(Prompt, Config),
    io:format("[OLLAMA] generate result: ~p~n", [Result]),
    case Result of
        {ok, ResumeBin} when is_binary(ResumeBin) ->
            [#{<<"properties">> => #{<<"resume">> => ResumeBin}}];
        _ ->
            []
    end.

default_prompt() ->
    "Résume le texte suivant de façon concise :\n\n~s".
