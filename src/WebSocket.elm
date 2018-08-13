effect module WebSocket
    where { command = MyCmd, subscription = MySub }
    exposing
        ( keepAlive
        , listen
        , send
        )

{-| Web sockets make it cheaper to talk to your servers.

Connecting to a server takes some time, so with web sockets, you make that
connection once and then keep using. The major benefits of this are:

1.  It faster to send messages. No need to do a bunch of work for every single
    message.

2.  The server can push messages to you. With normal HTTP you would have to
    keep _asking_ for changes, but a web socket, the server can talk to you
    whenever it wants. This means there is less unnecessary network traffic.

The API here attempts to cover the typical usage scenarios, but if you need
many unique connections to the same endpoint, you need a different library.


# Web Sockets

@docs listen, keepAlive, send

-}

import Dict exposing (Dict)
import Process
import Task exposing (Task)
import WebSocket.LowLevel as WS exposing (WebSocket)


-- COMMANDS


type MyCmd msg
    = Send String (List String) String


{-| Send a message to a particular address. You might say something like this:

    send "ws://echo.websocket.org" "Hello!"

**Note:** It is important that you are also subscribed to this address with
`listen` or `keepAlive`. If you are not, the web socket will be created to
send one message and then closed. Not good!

-}
send : String -> List String -> String -> Cmd msg
send url protocols message =
    command (Send url protocols message)


cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap _ (Send url protocols msg) =
    Send url protocols msg



-- SUBSCRIPTIONS


type MySub msg
    = Listen String (List String) (String -> msg)
    | KeepAlive String (List String)


{-| Subscribe to any incoming messages on a websocket. You might say something
like this:

    type Msg = Echo String | ...

    subscriptions model =
      listen "ws://echo.websocket.org" Echo

**Note:** If the connection goes down, the effect manager tries to reconnect
with an exponential backoff strategy. Any messages you try to `send` while the
connection is down are queued and will be sent as soon as possible.

-}
listen : String -> List String -> (String -> msg) -> Sub msg
listen url protocols tagger =
    subscription (Listen url protocols tagger)


{-| Keep a connection alive, but do not report any messages. This is useful
for keeping a connection open for when you only need to `send` messages. So
you might say something like this:

    subscriptions model =
        keepAlive "ws://echo.websocket.org"

**Note:** If the connection goes down, the effect manager tries to reconnect
with an exponential backoff strategy. Any messages you try to `send` while the
connection is down are queued and will be sent as soon as possible.

-}
keepAlive : String -> List String -> Sub msg
keepAlive url protocols =
    subscription (KeepAlive url protocols)


subMap : (a -> b) -> MySub a -> MySub b
subMap func sub =
    case sub of
        Listen url protocols tagger ->
            Listen url protocols (tagger >> func)

        KeepAlive url protocols ->
            KeepAlive url protocols



-- MANAGER


type alias State msg =
    { queues : QueuesDict
    , subs : SubsDict msg
    , sockets : SocketsDict
    }


type alias SocketsDict =
    Dict String Connection


type alias QueuesDict =
    Dict String (List String)


type alias SubsDict msg =
    Dict String (List (String -> msg))


type Connection
    = Opening Int Process.Id
    | Connected WebSocket


init : Task Never (State msg)
init =
    Task.succeed (State Dict.empty Dict.empty Dict.empty)



-- HANDLE APP MESSAGES


(&>) : Task x a -> Task x b -> Task x b
(&>) t1 t2 =
    Task.andThen (always t2) t1


onEffects :
    Platform.Router msg Msg
    -> List (MyCmd msg)
    -> List (MySub msg)
    -> State msg
    -> Task Never (State msg)
onEffects router cmds subs state =
    let
        newSubs =
            buildSubDict subs Dict.empty

        cleanup newQueues =
            let
                newEntries =
                    Dict.union newQueues (Dict.map (\_ _ -> []) newSubs)

                leftStep name _ getNewSockets =
                    Task.map2
                        (\pid newSockets -> Dict.insert name (Opening 0 pid) newSockets)
                        (attemptOpen router 0 name)
                        getNewSockets

                bothStep name _ connection getNewSockets =
                    Task.map (Dict.insert name connection) getNewSockets

                rightStep name connection getNewSockets =
                    closeConnection connection &> getNewSockets
            in
            Task.succeed Dict.empty
                |> Dict.merge leftStep bothStep rightStep newEntries state.sockets
                |> Task.map (State newQueues newSubs)
    in
    Task.andThen cleanup (sendMessagesHelp cmds state.sockets state.queues)


sendMessagesHelp : List (MyCmd msg) -> SocketsDict -> QueuesDict -> Task x QueuesDict
sendMessagesHelp cmds socketsDict queuesDict =
    case cmds of
        [] ->
            Task.succeed queuesDict

        (Send name _ msg) :: rest ->
            case Dict.get name socketsDict of
                Just (Connected socket) ->
                    WS.send socket msg
                        &> sendMessagesHelp rest socketsDict queuesDict

                _ ->
                    sendMessagesHelp rest socketsDict (Dict.update name (add msg) queuesDict)


buildSubDict : List (MySub msg) -> SubsDict msg -> SubsDict msg
buildSubDict subs acc =
    case subs of
        [] ->
            acc

        (Listen name _ tagger) :: rest ->
            buildSubDict rest (Dict.update name (add tagger) acc)

        (KeepAlive name _) :: rest ->
            buildSubDict rest (Dict.update name (Just << Maybe.withDefault []) acc)


add : a -> Maybe (List a) -> Maybe (List a)
add value maybeList =
    Just (value :: Maybe.withDefault [] maybeList)



-- HANDLE SELF MESSAGES


type Msg
    = Receive String String
    | Die String
    | GoodOpen String WebSocket
    | BadOpen String


onSelfMsg : Platform.Router msg Msg -> Msg -> State msg -> Task Never (State msg)
onSelfMsg router selfMsg state =
    case selfMsg of
        Receive name str ->
            let
                sends =
                    Dict.get name state.subs
                        |> Maybe.withDefault []
                        |> List.map (\tagger -> Platform.sendToApp router (tagger str))
            in
            Task.sequence sends &> Task.succeed state

        Die name ->
            case Dict.get name state.sockets of
                Nothing ->
                    Task.succeed state

                Just _ ->
                    attemptOpen router 0 name
                        |> Task.map (\pid -> updateSocket name (Opening 0 pid) state)

        GoodOpen name socket ->
            case Dict.get name state.queues of
                Nothing ->
                    Task.succeed (updateSocket name (Connected socket) state)

                Just messages ->
                    List.foldl
                        (\msg task -> WS.send socket msg &> task)
                        (Task.succeed (removeQueue name (updateSocket name (Connected socket) state)))
                        messages

        BadOpen name ->
            case Dict.get name state.sockets of
                Nothing ->
                    Task.succeed state

                Just (Opening n _) ->
                    attemptOpen router (n + 1) name
                        |> Task.map (\pid -> updateSocket name (Opening (n + 1) pid) state)

                Just (Connected _) ->
                    Task.succeed state


updateSocket : String -> Connection -> State msg -> State msg
updateSocket name connection state =
    { state | sockets = Dict.insert name connection state.sockets }


removeQueue : String -> State msg -> State msg
removeQueue name state =
    { state | queues = Dict.remove name state.queues }



-- OPENING WEBSOCKETS WITH EXPONENTIAL BACKOFF


attemptOpen : Platform.Router msg Msg -> Int -> String -> Task x Process.Id
attemptOpen router backoff name =
    let
        goodOpen ws =
            Platform.sendToSelf router (GoodOpen name ws)

        badOpen _ =
            Platform.sendToSelf router (BadOpen name)

        actuallyAttemptOpen =
            open name router
                |> Task.andThen goodOpen
                |> Task.onError badOpen
    in
    Process.spawn (after backoff &> actuallyAttemptOpen)


open : String -> Platform.Router msg Msg -> Task WS.BadOpen WebSocket
open name router =
    WS.open name
        {- @TODO -} []
        { onMessage = \_ msg -> Platform.sendToSelf router (Receive name msg)
        , onClose = \_ -> Platform.sendToSelf router (Die name)
        }


after : Int -> Task x ()
after backoff =
    if backoff < 1 then
        Task.succeed ()
    else
        Process.sleep (toFloat (10 * 2 ^ backoff))



-- CLOSE CONNECTIONS


closeConnection : Connection -> Task x ()
closeConnection connection =
    case connection of
        Opening _ pid ->
            Process.kill pid

        Connected socket ->
            WS.close socket
