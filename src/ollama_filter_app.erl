-module(ollama_filter_app).
-behaviour(application).
-behaviour(cowboy_handler).

%% Application callbacks
-export([start/2, stop/1]).

%% Cowboy handler callbacks
-export([init/2, terminate/3]).

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    FilterUrl = lists:concat(["http://localhost:", integer_to_list(Port), "/query"]),
    io:format("Filter registered: ~s~n", [FilterUrl]),
    em_filter:register_filter(FilterUrl),
    em_filter_sup:start_link(ollama_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% Cowboy handler behavior
init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    io:format("Received body: ~p~n", [Body]),
    EmbryoList = generate_embryo_list(Body),
    Response = #{embryo_list => EmbryoList},
    EncodedResponse = jsone:encode(Response),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        EncodedResponse,
        Req
    ),
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

generate_embryo_list(JsonBinary) ->
    io:format("Processing request: ~p~n", [JsonBinary]),
    try jsone:decode(JsonBinary) of
        SearchMap when is_map(SearchMap) ->
            % Extraire la valeur de recherche
            Value = case maps:get(<<"value">>, SearchMap, undefined) of
                undefined -> "";
                ValBin -> binary_to_list(ValBin)
            end,
            
            % Extraire le timeout (défaut: 10 secondes)
            Timeout = case maps:get(<<"timeout">>, SearchMap, undefined) of
                undefined -> 10;
                TimeoutBin when is_binary(TimeoutBin) -> 
                    try list_to_integer(binary_to_list(TimeoutBin))
                    catch _:_ -> 10
                    end;
                TimeoutInt when is_integer(TimeoutInt) -> TimeoutInt;
                _ -> 10
            end,
            
            io:format("Search value: ~p, Timeout: ~p~n", [Value, Timeout]),
            query_ollama(Value, Timeout);
        _ ->
            []
    catch
        _:Error ->
            io:format("Error decoding JSON: ~p~n", [Error]),
            []
    end.

query_ollama(Value, Timeout) ->
    % Lire la configuration d'Ollama
    {OllamaUrl, OllamaModel} = read_ollama_config(),
    
    % Préparer la requête pour Ollama
    RequestBody = #{
        <<"model">> => list_to_binary(OllamaModel),
        <<"prompt">> => list_to_binary(Value),
        <<"temperature">> => 0.7,
        <<"max_tokens">> => 100
    },
    
    EncodedRequest = jsone:encode(RequestBody),
    
    % Configuration de la requête HTTP
    Headers = [{"Content-Type", "application/json"}],
    HTTPOptions = [{timeout, Timeout * 1000}], % Timeout en millisecondes
    Options = [],
    
    io:format("Querying Ollama at: ~s~n", [OllamaUrl]),
    io:format("Request body: ~s~n", [EncodedRequest]),
    
    % Faire la requête HTTP
    case httpc:request(post, {OllamaUrl, Headers, "application/json", EncodedRequest}, HTTPOptions, Options) of
        {ok, {{_Version, 200, _ReasonPhrase}, _Headers, ResponseBody}} ->
            % Convertir la liste en binaire pour jsone
            ResponseBinary = list_to_binary(ResponseBody),
            io:format("Ollama response: ~s~n", [ResponseBinary]),
            extract_embryos_from_ollama_response(ResponseBinary, Value);
        {ok, {{_Version, StatusCode, ReasonPhrase}, _Headers, ResponseBody}} ->
            ResponseBinary = list_to_binary(ResponseBody),
            io:format("Ollama HTTP error ~p: ~s~n~s~n", [StatusCode, ReasonPhrase, ResponseBinary]),
            [];
        {error, Reason} ->
            io:format("Error querying Ollama: ~p~n", [Reason]),
            []
    end.

read_ollama_config() ->
    % Lire la configuration depuis embryo (équivalent de embryo::read_emergence_conf())
    % Pour l'instant, on utilise des valeurs par défaut
    % Vous devrez adapter cette partie selon votre implémentation d'embryo
    DefaultUrl = "http://localhost:11434/v1/completions",
    DefaultModel = "phi3",
    
    % TODO: Implémenter la lecture de la configuration réelle
    % ConfigMap = embryo:read_emergence_conf(),
    % OllamaUrl = maps:get(<<"url">>, maps:get(<<"ollama">>, ConfigMap, #{}), DefaultUrl),
    % OllamaModel = maps:get(<<"model">>, maps:get(<<"ollama">>, ConfigMap, #{}), DefaultModel),
    
    {DefaultUrl, DefaultModel}.

extract_embryos_from_ollama_response(ResponseBinary, OriginalValue) when is_binary(ResponseBinary) ->
    try jsone:decode(ResponseBinary) of
        ResponseMap when is_map(ResponseMap) ->
            io:format("Decoded Ollama response map: ~p~n", [ResponseMap]),
            case maps:get(<<"choices">>, ResponseMap, undefined) of
                Choices when is_list(Choices) ->
                    io:format("Found choices: ~p~n", [Choices]),
                    StartTime = erlang:monotonic_time(millisecond),
                    process_ollama_choices(Choices, OriginalValue, StartTime, 10000, []); % 10 secondes de timeout
                _ ->
                    io:format("No choices found in Ollama response~n"),
                    []
            end;
        _ ->
            io:format("Invalid JSON response from Ollama~n"),
            []
    catch
        Error ->
            io:format("Error parsing Ollama response: ~p~n", [Error]),
            io:format("Response body was: ~s~n", [ResponseBinary]),
            []
    end.

process_ollama_choices([], _OriginalValue, _StartTime, _TimeoutMs, Acc) ->
    lists:reverse(Acc);
process_ollama_choices([Choice | Rest], OriginalValue, StartTime, TimeoutMs, Acc) ->
    CurrentTime = erlang:monotonic_time(millisecond),
    ElapsedTime = CurrentTime - StartTime,
    
    if
        ElapsedTime >= TimeoutMs ->
            io:format("Timeout reached while processing Ollama choices~n"),
            lists:reverse(Acc);
        true ->
            io:format("Processing choice: ~p~n", [Choice]),
            NewAcc = try
                case Choice of
                    #{<<"text">> := Text} when is_binary(Text) ->
                        io:format("Found text field: ~s~n", [Text]),
                        Embryo = #{
                            properties => #{
                                <<"url">> => <<"ollama_test">>,
                                <<"resume">> => Text
                            }
                        },
                        io:format("Generated embryo: ~p~n", [Embryo]),
                        [Embryo | Acc];
                    _ ->
                        io:format("Choice structure: ~p~n", [maps:keys(Choice)]),
                        case maps:find(<<"text">>, Choice) of
                            {ok, Text} when is_binary(Text) ->
                                io:format("Found text via maps:find: ~s~n", [Text]),
                                Embryo = #{
                                    properties => #{
                                        <<"url">> => <<"ollama_test">>,
                                        <<"resume">> => Text
                                    }
                                },
                                [Embryo | Acc];
                            error ->
                                io:format("No text field found in choice~n"),
                                Acc;
                            {ok, Other} ->
                                io:format("Text field is not binary: ~p~n", [Other]),
                                Acc
                        end
                end
            catch
                EType:EError ->
                    io:format("Error processing choice ~p:~p~n", [EType, EError]),
                    Acc
            end,
            process_ollama_choices(Rest, OriginalValue, StartTime, TimeoutMs, NewAcc)
    end.
