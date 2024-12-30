defmodule Wesex.MintAdapter do
  @moduledoc """
  `Wesex.Adapter` implementation that uses the `Mint.WebSocket` library.
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

    ws_scheme = String.to_existing_atom(url.scheme)

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
  @spec send(state, {:text | :binary, binary()}) ::
          {:ok, state, [Connection.adapter_event()]}
          | {:error, state, [Connection.adapter_event()], reason :: any}
  def send(state, msg) do
    send_frame_result(state, msg)
  end

  @impl true
  def local_close(state, {code, reason}) do
    send_frame(state, {:close, code, reason || ""})
  end

  @impl true
  def send_ping(state) do
    send_frame(state, :ping)
  end

  @impl true
  def send_pong(state, data) do
    send_frame(state, {:pong, data})
  end

  defp send_frame_result(state(conn: conn, ref: ref, ws: websocket) = state, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, frame)

    case Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, conn} ->
        events = tcp_close_events_if_closed(conn)
        {:ok, state(state, ws: websocket, conn: conn), events}

      {:error, conn, reason} ->
        events = tcp_close_events_if_closed(conn)
        {:error, state(state, ws: websocket, conn: conn), events, reason}
    end
  end

  defp send_frame(state, frame) do
    case send_frame_result(state, frame) do
      {:ok, state, events} -> {state, events}
      {:error, state, events, _reason} -> {state, events}
    end
  end

  @impl true
  @spec abort(state()) :: {state(), [Connection.adapter_event()]}
  def abort(state(conn: conn) = state) do
    {:ok, conn} = Mint.HTTP.close(conn)
    {state(state, conn: conn), tcp_close_events_if_closed(conn)}
  end

  defp tcp_close_events_if_closed(conn) do
    if Mint.HTTP.open?(conn) do
      []
    else
      [:tcp_close]
    end
  end

  @impl true
  def event(state(conn: conn) = state, event) do
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
    {state, gen_events} = do_resps(state(state, conn: conn), resps)

    if Mint.HTTP.open?(conn) do
      {state, gen_events}
    else
      {state, gen_events ++ [:tcp_close]}
    end
  end

  defp do_resps(state, []), do: {state, []}

  defp do_resps(state(conn: _conn, ref: ref, ws: :waiting_status) = state, [
         {:status, ref, 101} | rest
       ]) do
    state = state(state, ws: :waiting_headers)
    do_resps(state, rest)
  end

  defp do_resps(
         state(conn: conn, ref: ref, ws: :waiting_status) = state,
         [{:status, ref, status} | _rest]
       )
       when status != 101 do
    conn = Mint.HTTP.close(conn)
    {state(state, conn: conn), [:tcp_close]}
  end

  defp do_resps(state(ref: ref) = state, [{:done, ref} | rest]) do
    do_resps(state, rest)
  end

  defp do_resps(
         state(conn: conn, ref: ref, ws: :waiting_headers) = state,
         [{:headers, ref, resp_headers} | rest]
       ) do
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, resp_headers)
    state = state(state, ws: websocket, conn: conn)
    {state, gen_events} = do_resps(state, rest)
    {state, [:handshake_complete | gen_events]}
  end

  defp do_resps(
         state(ref: ref, ws: websocket) = state,
         [{:data, ref, data} | rest]
       ) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
    ws_events = events_from_frames(frames)
    state = state(state, ws: websocket)
    {state, gen_events} = do_resps(state, rest)
    {state, ws_events ++ gen_events}
  end

  defp events_from_frames([]), do: []

  defp events_from_frames([{msg_type, data} | rest])
       when msg_type in [:text, :binary, :ping] do
    event = {msg_type, data}
    [event | events_from_frames(rest)]
  end

  defp events_from_frames([{:pong, _data} | rest]) do
    [:pong | events_from_frames(rest)]
  end

  defp events_from_frames([{:close, code, data} | rest]) do
    event = {:close, code, data}
    [event | events_from_frames(rest)]
  end
end
