defmodule Wesex.MintAdapter do
  @moduledoc """
  `Wesex.Adapter` implementation that uses the `Mint.WebSocket` library.

  ## Adapter options
  * `conn` — Options given to `Mint.HTTP.connect/4`
  * `ws` — Options given to `Mint.WebSocket.upgrade/5`

  """
  alias Wesex.{Adapter, Connection}
  import Record

  @behaviour Adapter

  defrecordp(:state, conn: nil, ref: nil, ws: :waiting_status)

  @typep state ::
           record(:state,
             conn: Mint.HTTP.t(),
             ref: reference(),
             ws: :waiting_status | :waiting_headers | Mint.WebSocket.t()
           )

  @impl true
  def connect(%URI{} = url, headers, opts) when url.scheme in ["ws", "wss"] do
    http_scheme =
      case url.scheme do
        "ws" -> :http
        "wss" -> :https
      end

    ws_scheme =
      case url.scheme do
        "ws" -> :ws
        "wss" -> :wss
      end

    %URI{userinfo: nil, host: host, port: port} = url

    path =
      %URI{path: url.path, query: url.query, fragment: url.fragment} |> URI.to_string()

    case Mint.HTTP.connect(http_scheme, host, port, opts[:conn] || []) do
      {:error, reason} ->
        {:error, reason}

      {:ok, conn} ->
        case Mint.WebSocket.upgrade(ws_scheme, conn, path, headers, opts[:ws] || []) do
          {:error, conn, reason} ->
            {:ok, _} = Mint.HTTP.close(conn)
            {:error, reason}

          {:ok, conn, ref} ->
            {:ok, state(conn: conn, ref: ref)}
        end
    end
  end

  @impl true
  @spec send({:text | :binary, binary()}, state()) ::
          {:ok, [Connection.adapter_event()], state()}
          | {:error, [Connection.adapter_event()], state(), reason :: any}
  def send(msg, state) do
    send_frame_result(msg, state)
  end

  @impl true
  def local_close({code, reason}, state) do
    send_frame({:close, code, reason || ""}, state)
  end

  @impl true
  def send_ping(state) do
    send_frame(:ping, state)
  end

  @impl true
  def send_pong(data, state) do
    send_frame({:pong, data}, state)
  end

  defp send_frame_result(frame, state(conn: conn, ref: ref, ws: websocket) = state) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, frame)

    case Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, conn} ->
        events = tcp_close_events_if_closed(conn)
        {:ok, events, state(state, ws: websocket, conn: conn)}

      {:error, conn, reason} ->
        events = tcp_close_events_if_closed(conn)
        {:error, events, state(state, ws: websocket, conn: conn), reason}
    end
  end

  defp send_frame(frame, state) do
    case send_frame_result(frame, state) do
      {:ok, events, state} -> {events, state}
      {:error, events, state, _reason} -> {events, state}
    end
  end

  @impl true
  @spec abort(state()) :: {[Connection.adapter_event()], state()}
  def abort(state(conn: conn) = state) do
    {:ok, conn} = Mint.HTTP.close(conn)
    {tcp_close_events_if_closed(conn), state(state, conn: conn)}
  end

  defp tcp_close_events_if_closed(conn) do
    if Mint.HTTP.open?(conn) do
      []
    else
      [:tcp_close]
    end
  end

  @impl true
  def event(event, state(conn: conn) = state) do
    case Mint.WebSocket.stream(conn, event) do
      :unknown ->
        false

      {:ok, conn, resps} ->
        do_stream_results(state, conn, resps)

      {:error, conn, _error, resps} ->
        do_stream_results(state, conn, resps)
    end
  end

  defp do_stream_results(state, conn, resps) do
    {gen_events, state} = do_resps(resps, state(state, conn: conn))

    if Mint.HTTP.open?(conn) do
      {gen_events, state}
    else
      {gen_events ++ [:tcp_close], state}
    end
  end

  defp do_resps([], state), do: {[], state}

  defp do_resps(
         [{:status, ref, 101} | rest],
         state(conn: _conn, ref: ref, ws: :waiting_status) = state
       ) do
    state = state(state, ws: :waiting_headers)
    do_resps(rest, state)
  end

  defp do_resps(
         [{:status, ref, status} | _rest],
         state(conn: conn, ref: ref, ws: :waiting_status) = state
       )
       when status != 101 do
    conn = Mint.HTTP.close(conn)
    {[:tcp_close], state(state, conn: conn)}
  end

  defp do_resps([{:done, ref} | rest], state(ref: ref) = state) do
    do_resps(rest, state)
  end

  defp do_resps(
         [{:headers, ref, resp_headers} | rest],
         state(conn: conn, ref: ref, ws: :waiting_headers) = state
       ) do
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, resp_headers)
    state = state(state, ws: websocket, conn: conn)
    {gen_events, state} = do_resps(rest, state)
    {[:handshake_complete | gen_events], state}
  end

  defp do_resps(
         [{:data, ref, data} | rest],
         state(ref: ref, ws: websocket) = state
       ) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
    ws_events = events_from_frames(frames)
    state = state(state, ws: websocket)
    {gen_events, state} = do_resps(rest, state)
    {ws_events ++ gen_events, state}
  end

  defp events_from_frames([]), do: []

  defp events_from_frames([{msg_type, data} | rest])
       when msg_type in [:text, :binary, :ping] do
    event = {msg_type, data}
    [event | events_from_frames(rest)]
  end

  defp events_from_frames([{:pong, data} | rest]) do
    [{:pong, data} | events_from_frames(rest)]
  end

  defp events_from_frames([{:close, code, data} | rest]) do
    event = {:close, code, data}
    [event | events_from_frames(rest)]
  end
end
