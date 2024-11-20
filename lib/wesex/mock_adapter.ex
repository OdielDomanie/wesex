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
  @spec abort(state()) :: {state(), [Wesex.Connection.event()]}
  def abort(state) do
    _ = Process.exit(state, {:shutdown, :abort})
    {state, []}
  end

  @impl true
  @spec local_close(state(), code_reason :: {1000..4999, nil | binary()}) ::
          {state(), [Wesex.Connection.event()]}
  def local_close(state, {code, reason}) do
    events = GenServer.call(state, {:close, code, reason})
    {state, events}
  end

  @impl true
  @spec send(state(), message :: {:text | :binary, binary()}) ::
          {:ok, state(), [Wesex.Connection.event()]}
          | {:error, state(), [Wesex.Connection.event()], reason :: any()}
  def send(state, message) do
    if Process.alive?(state) do
      try do
        GenServer.call(state, message)
      rescue
        _ -> {:error, state, [], :call_failed}
      else
        events -> {:ok, state, events}
      end
    else
      {:error, state, [], :process_dead}
    end
  end

  @impl true
  @spec send_ping(state()) :: {state(), [Wesex.Connection.event()]}
  def send_ping(state) do
    events = GenServer.call(state, {:ping, nil})
    {state, events}
  end

  @impl true
  @spec send_pong(state(), binary()) :: {state(), [Wesex.Connection.event()]}
  def send_pong(state, _binary) do
    events = GenServer.call(state, :pong)
    {state, events}
  end

  @impl true
  @spec event(state(), raw_event :: any()) :: {state(), [Wesex.Connection.event()]} | false
  def event(state, raw_event) do
    case raw_event do
      {:mock_server_messages, messages} ->
        {state, messages}

      {:DOWN, _ref, :process, ^state, _reason} ->
        {state, [:tcp_close]}

      _ ->
        false
    end
  end
end
