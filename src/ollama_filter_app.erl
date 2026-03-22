%%%-------------------------------------------------------------------
%%% @doc Ollama local LLM agent.
%%%
%%% Sends the query to a local Ollama instance and returns the
%%% generated response as a single embryo map.
%%%
%%% Maintains a conversation memory (list of {query, answer} pairs)
%%% so the LLM can reference prior exchanges in its context window.
%%% Memory is kept in ETS so it survives worker restarts.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: #{history => [{QueryBin, AnswerBin}]} (newest last).
%%% @end
%%%-------------------------------------------------------------------
-module(ollama_filter_app).
%% @encoding utf8
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(MAX_HISTORY, 5).

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"ollama">>, <<"llm">>,
                                      <<"summarize">>, <<"generate">>,
                                      <<"local_ai">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(ollama_filter, ?MODULE, #{
        capabilities => base_capabilities(),
        memory       => ets
    }),
    {ok, self()}.

stop(_State) ->
    em_filter:stop_agent(ollama_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {Value, Timeout} = extract_params(Body),
    case Value of
        "" -> {[], Memory};
        _  ->
            History = maps:get(history, Memory, []),
            Config  = (ollama_handler:get_env_config())#{timeout => Timeout * 1000},
            Prompt  = build_prompt_with_history(Value, History, Config),
            case ollama_handler:generate(Prompt, Config) of
                {ok, AnswerBin} when is_binary(AnswerBin) ->
                    Embryo     = #{<<"properties">> => #{<<"resume">> => AnswerBin}},
                    NewHistory = trim_history(
                        History ++ [{list_to_binary(Value), AnswerBin}],
                        ?MAX_HISTORY),
                    {[Embryo], Memory#{history => NewHistory}};
                {error, Reason} ->
                    io:format("[ollama] generate failed: ~p~n", [Reason]),
                    {[], Memory}
            end
    end;

handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Internal helpers
%%====================================================================

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

build_prompt_with_history(Value, [], _Config) ->
    unicode:characters_to_binary(
        io_lib:format("Résume le texte suivant de façon concise :\n\n~s", [Value]));
build_prompt_with_history(Value, History, _Config) ->
    ContextLines = [["Q: ", Q, "\nA: ", A, "\n"] || {Q, A} <- History],

    unicode:characters_to_binary(
        io_lib:format("Contexte des échanges précédents :\n~s\nNouvelle question : ~s",
                      [ContextLines, Value])).

trim_history(History, Max) ->
    Len = length(History),
    case Len > Max of
        true  -> lists:nthtail(Len - Max, History);
        false -> History
    end.
