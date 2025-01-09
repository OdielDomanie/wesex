defmodule Wesex.MockAdapter do
  @moduledoc """
  A mock adapter to run a websocket connection against a `WebSock` implementation.
  Implements `Wesex.Adapter`.

  ## Options:
  * `:server` - The pid/name of the `Wesex.MockServer` process.
  """
  @behaviour Wesex.Adapter

  @type state :: GenServer.server()

  @impl true
  @spec connect(url :: URI.t(), headers :: [{String.t(), String.t()}], opts :: Keyword.t()) ::
          {:ok, state()} | {:error, reason :: any()}
  def connect(url, headers, opts) do
    server = opts[:server]
    _ = Process.monitor(server)

    case GenServer.call(server, {:connect, url, headers}, 1000) do
      :ok -> {:ok, server}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec abort(state()) :: {[Wesex.Connection.adapter_event()], state()}
  def abort(state) do
    _ = Process.exit(state, {:shutdown, :abort})
    {[], state}
  end

  @impl true
  @spec local_close(code_reason :: {1000..4999, nil | binary()}, state()) ::
          {[Wesex.Connection.adapter_event()], state()}
  def local_close({code, reason}, state) do
    events = GenServer.call(state, {:close, code, reason})
    {events, state}
  end

  @impl true
  @spec send(message :: {:text | :binary, binary()}, state()) ::
          {:ok, [Wesex.Connection.adapter_event()], state()}
          | {:error, [Wesex.Connection.adapter_event()], state(), reason :: any()}
  def send(message, state) do
    if Process.alive?(state) do
      try do
        GenServer.call(state, message)
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
    events = GenServer.call(state, {:ping, nil})
    {events, state}
  end

  @impl true
  @spec send_pong(binary(), state()) :: {[Wesex.Connection.adapter_event()], state()}
  def send_pong(_binary, state) do
    events = GenServer.call(state, :pong)
    {events, state}
  end

  @impl true
  @spec event(raw_event :: any(), state()) ::
          {[Wesex.Connection.adapter_event()], state()} | false
  def event(raw_event, state) do
    case raw_event do
      :mock_server_connected ->
        {[:handshake_complete], state}

      {:mock_server_messages, messages} ->
        {messages, state}

      {:DOWN, _ref, :process, ^state, _reason} ->
        {[:tcp_close], state}

      _ ->
        false
    end
  end
end
