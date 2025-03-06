defmodule Wesex.MockAdapter do
  @moduledoc """
  A mock adapter to run a websocket connection against a `WebSock` implementation.
  Implements `Wesex.Adapter`.

  ## Options:
  * `:server` - The pid/name of the `Wesex.MockServer` process.
  """
  @behaviour Wesex.Adapter

  @typep state :: %{conn_holder: GenServer.server(), ref: reference()}

  def get_conn_holder(state), do: state.conn_holder

  @impl true
  @spec connect(url :: URI.t(), headers :: [{String.t(), String.t()}], opts :: Keyword.t()) ::
          {:ok, state()}
  def connect(url, headers, opts) do
    server = opts[:server]
    ref = make_ref()

    conn_holder = Wesex.MockServer.connect(server, ref, url, headers)

    _ = Process.monitor(conn_holder)

    {:ok, %{conn_holder: conn_holder, ref: ref}}
  end

  @impl true
  @spec abort(state()) :: {[Wesex.Connection.adapter_event()], state()}
  def abort(state) do
    _ = Process.exit(state.conn_holder, {:shutdown, :abort})
    {[], state}
  end

  @impl true
  @spec local_close(code_reason :: {1000..4999, nil | binary()}, state()) ::
          {[Wesex.Connection.adapter_event()], state()}
  def local_close({code, reason}, state) do
    events = GenServer.call(state.conn_holder, {:close, code, reason})
    {events, state}
  end

  @impl true
  @spec send(message :: {:text | :binary, binary()}, state()) ::
          {:ok, [Wesex.Connection.adapter_event()], state()}
          | {:error, [Wesex.Connection.adapter_event()], state(), reason :: any()}
  def send(message, state) do
    if Process.alive?(state.conn_holder) do
      try do
        GenServer.call(state.conn_holder, message)
      rescue
        _ -> {:error, [], state, :call_failed}
      else
        events -> {:ok, events, state}
      end
    else
      {:error, [], state, :process_dead}
    end
  end

  @impl true
  @spec send_ping(state()) :: {[Wesex.Connection.adapter_event()], state()}
  def send_ping(state) do
    events =
      if Process.alive?(state.conn_holder) do
        GenServer.call(state.conn_holder, {:ping, nil})
      else
        []
      end

    {events, state}
  end

  @impl true
  @spec send_pong(binary(), state()) :: {[Wesex.Connection.adapter_event()], state()}
  def send_pong(_binary, state) do
    events = GenServer.call(state.conn_holder, :pong)
    {events, state}
  end

  @impl true
  @spec event(raw_event :: {reference(), any()}, state()) ::
          {[Wesex.Connection.adapter_event()], state()} | false

  def event({ref, raw_event_data} = _raw_event, %{ref: ref} = state) do
    case raw_event_data do
      :mock_server_connected ->
        {[:handshake_complete], state}

      {:mock_server_messages, messages} ->
        {messages, state}
    end
  end

  def event({:DOWN, _ref, :process, conn_holder, _reason}, %{conn_holder: conn_holder} = state) do
    {[:tcp_close], state}
  end

  def event(_msg, _state) do
    false
  end
end
