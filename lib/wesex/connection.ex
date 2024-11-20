defmodule Wesex.Connection do
  @moduledoc """
  Manages a websocket connection by functionally manipulating a connection struct.

  The functions may set up timers, whose messages should  be received
  and given to `event/2`.

  ## State diagram
  ```mermaid
  stateDiagram-v2
  [*] --> handshaking: connect/4
  handshaking --> closed: handshake timeout
  handshaking --> open
  open --> closing: ping timeout
  open --> closing: remote close
  open --> closing: close/3
  handshaking --> closing: close/3
  handshaking --> closed: tcp close
  open --> closed: tcp close
  closing --> closed: tcp close
  closing --> closed: close timeout
  ```
  """

  alias __MODULE__, as: C
  alias Wesex.MintAdapter

  @handshake_timeout 4_000
  @ping_intv 10_000
  @close_timeout 4_000

  @type t :: %C{
          callbacks: module(),
          callback_state: any(),
          status:
            :handshaking
            | {:open, :ponged | :unponged}
            | :local_closing
            | :waiting_tcp_close
            | :closed,
          adapter: module(),
          adapter_state: any(),
          timer: {reference(), timer_type()} | nil,
          ref: reference(),
          remote_stop_code_reason: nil | stop_code_reason()
        }

  @type stop_code_reason :: {1000..4999 | nil, binary() | nil}
  @type timer_type :: :handshake_timeout | :ping_timer | :close_timeout

  @opaque event ::
            adapter_event()
            | {reference(), timer_type()}
            | {:sent, reference()}
            | {:send_error, reference(), reason :: any}

  @type adapter_event ::
          :handshake_complete
          | {:ping | :pong, nil | binary()}
          | {:text | :binary, binary()}
          | {:close, 1000..4999 | nil, binary() | nil}
          | :tcp_close

  @type callback_return ::
          {:ok, callback_state :: any, replies :: [{:text | :binary, binary(), reference()}]}
          | {{:stop, 1000..4999, nil | binary()}, callback_state :: any,
             replies :: [{:text | :binary, binary(), reference()}]}

  @callback handle_connected(callback_state :: any) :: callback_return()
  @callback handle_in(
              message :: {:text | :binary, binary()},
              callback_state :: any,
              :open | :closing
            ) ::
              callback_return()
  @callback handle_message_sent(
              {:sent, reference()} | {:send_error, reference(), reason :: any},
              callback_state :: any,
              :open | :closing
            ) :: callback_return()
  @optional_callbacks [handle_message_sent: 3]

  @enforce_keys [:callbacks, :callback_state, :status, :adapter, :adapter_state, :ref]
  defstruct [
    :callbacks,
    :callback_state,
    :status,
    :adapter,
    :adapter_state,
    :timer,
    :ref,
    :remote_stop_code_reason
  ]

  defguardp is_msg_type(type) when type == :text or type == :binary

  @doc """
  The status of the connection, as one of `:handshaking`, `:open`, `:closing`, or `:closed`
  """
  @spec short_status(t) :: :handshaking | :open | :closing | :closed
  def short_status(%C{status: status}) do
    case status do
      :handshaking -> :handshaking
      {:open, _} -> :open
      :local_closing -> :closing
      :waiting_tcp_close -> :closing
      :closed -> :closed
    end
  end

  @doc """
  Starts a websocket connection.

  Returns a connection in the handshaking stage.
  """
  @spec connect(
          module(),
          {module(), any()},
          String.t() | URI.t(),
          [{String.t(), String.t()}],
          Keyword.t()
        ) :: {:ok, t} | {:error, any()}
  def connect(
        adapter \\ MintAdapter,
        {callbacks, callback_state} = _callback_and_state,
        url,
        headers,
        adapter_opts
      ) do
    url = URI.new!(url)

    case adapter.connect(url, headers, adapter_opts) do
      {:ok, adapter_state} ->
        ref = make_ref()

        handshake_timeout =
          Process.send_after(self(), {ref, :handshake_timeout}, @handshake_timeout)

        con = %C{
          adapter: adapter,
          adapter_state: adapter_state,
          callback_state: callback_state,
          callbacks: callbacks,
          ref: ref,
          status: :handshaking,
          timer: {handshake_timeout, :handshake_timeout}
        }

        {:ok, con}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a websocket message.
  """
  @spec send(t, {:text | :binary, binary()}) :: {:ok, t} | {:error, any, t}
  def send(%C{} = con, {type, _data} = msg) when is_msg_type(type) do
    case con.adapter.send(con.callback_state, msg) do
      {:ok, adapter_state, new_events} ->
        con = %C{con | adapter_state: adapter_state}
        con = do_events(con, new_events)
        {:ok, con}

      {:error, adapter_state, new_events, reason} ->
        con = %C{con | adapter_state: adapter_state}
        con = do_events(con, new_events)
        {:error, reason, con}
    end
  end

  @doc """
  Starts the closing process (eg. the closing handshake).
  """
  @spec close(t, 1000..4999, nil | binary()) :: t
  def close(%C{} = con, stop_code, stop_reason \\ nil) do
    {con, new_events} = local_close(con, stop_code, stop_reason)
    do_events(con, new_events)
  end

  @doc """
  Closes the connection abruptly.
  """
  @spec abort(t) :: t
  def abort(%C{} = con) do
    {adapter_state, new_events} = con.adapter.abort(con.adapter_state)
    con = %C{con | adapter_state: adapter_state}
    do_events(con, new_events)
  end

  @doc """
  Feeds a received event.

  This will alter the connection struct and may call the callbacks.
  """
  @spec event(t, event) :: t | false
  def event(connection, event)

  def event(%C{ref: ref} = con, {ref, timer_msg}) do
    do_events(con, [timer_msg])
  end

  def event(%C{} = connection, event) do
    case connection.adapter.event(connection.adapter_state, event) do
      {adapter_state, connection_events} ->
        do_events(%C{connection | adapter_state: adapter_state}, connection_events)

      false ->
        false
    end
  end

  @doc false
  @spec do_events(t, [event()]) :: t
  def do_events(%C{} = connection, []), do: connection

  # connected
  def do_events(%C{status: :handshaking} = con, [:handshake_complete | rest]) do
    # User callback
    result = con.callbacks.handle_connected(con.callback_state)
    # Cancel previous timer
    {timer, :handshake_timeout} = con.timer
    :ok = cancel_timer(timer, :handshake_timeout, con.ref)
    # Start the ping timer
    ping_timer = Process.send_after(self(), {con.ref, :ping_timer}, 0)
    con = %C{con | status: {:open, :ponged}, timer: {ping_timer, :ping_timer}}

    process_callback_result(result, con, rest)
  end

  def do_events(%C{status: :handshaking} = con, [:handshake_timeout | rest]) do
    {con, new_events} = local_close(con, nil, nil)
    do_events(con, rest ++ new_events)
  end

  # message
  def do_events(%C{status: {:open, _}} = con, [{type, _data} = msg | rest])
      when is_msg_type(type) do
    result = con.callbacks.handle_in(msg, con.callback_state, :open)
    process_callback_result(result, con, rest)
  end

  def do_events(%C{status: :local_closing} = con, [{type, _data} = msg | rest])
      when is_msg_type(type) do
    result = con.callbacks.handle_in(msg, con.callback_state, :closing)
    process_callback_result(result, con, rest)
  end

  # message confirmation
  def do_events(%C{} = con, [{:sent, _ref} = confirm | rest]) do
    if Code.ensure_loaded?(con.callbacks) and
         function_exported?(con.callbacks, :handle_message_sent, 3) do
      result = con.callbacks.handle_message_sent(confirm, con.callback_state, short_status(con))
      process_callback_result(result, con, rest)
    else
      do_events(con, rest)
    end
  end

  def do_events(%C{} = con, [{:send_error, _ref, _} = confirm | rest]) do
    _ = Code.ensure_loaded!(con.callbacks)

    if function_exported?(con.callbacks, :handle_message_sent, 3) do
      result = con.callbacks.handle_message_sent(confirm, con.callback_state, short_status(con))
      process_callback_result(result, con, rest)
    else
      do_events(con, rest)
    end
  end

  # get pinged
  def do_events(%C{status: {:open, _}} = con, [{:ping, ping_data} | rest]) do
    {adapter_state, new_events} =
      con.adapter.send_pong(con.adapter_state, ping_data)

    con = %C{con | adapter_state: adapter_state}
    do_events(con, rest ++ new_events)
  end

  def do_events(%C{status: :local_closing} = con, [{:ping, _ping_data} | rest]) do
    do_events(con, rest)
  end

  # ping-pong
  def do_events(%C{status: {:open, :ponged}} = con, [:ping_timer | rest]) do
    {timer, :ping_timer} = con.timer
    false = Process.cancel_timer(timer)

    ping_timer = Process.send_after(self(), {con.ref, :ping_timer}, @ping_intv)

    {adapter_state, new_events} =
      con.adapter.send_ping(con.adapter_state)

    con = %C{
      con
      | timer: {ping_timer, :ping_timer},
        status: {:open, :unponged},
        adapter_state: adapter_state
    }

    do_events(con, rest ++ new_events)
  end

  def do_events(%C{status: {:open, :unponged}} = con, [:pong | rest]) do
    con = %C{con | status: {:open, :ponged}}
    do_events(con, rest)
  end

  def do_events(%C{status: {:open, :ponged}} = con, [:pong | rest]) do
    do_events(con, rest)
  end

  def do_events(%C{status: {:open, :unponged}} = con, [:ping_timer | rest]) do
    {timer, :ping_timer} = con.timer
    false = Process.cancel_timer(timer)

    # 1002: protocol error
    {adapter_state, new_events} =
      con.adapter.local_close(con.adapter_state, {1002, "ping timeout"})

    close_timeout = Process.send_after(self(), {con.ref, :close_timeout}, @close_timeout)

    con = %C{
      con
      | status: :local_closing,
        adapter_state: adapter_state,
        timer: {close_timeout, :close_timeout}
    }

    do_events(con, rest ++ new_events)
  end

  def do_events(%C{status: :local_closing} = con, [:pong | rest]) do
    do_events(con, rest)
  end

  # close response
  def do_events(%C{status: :local_closing} = con, [{:close, code, reason} | rest]) do
    con = %C{con | status: :waiting_tcp_close, remote_stop_code_reason: {code, reason}}
    do_events(con, rest)
  end

  # remote close
  def do_events(%C{status: {:open, _}} = con, [{:close, code, reason} | rest]) do
    {adapter_state, new_events} = con.adapter.local_close(con.adapter_state, {code, nil})
    {timer, :ping_timer} = con.timer
    :ok = cancel_timer(timer, :ping_timer, con.ref)
    close_timeout = Process.send_after(self(), {con.ref, :close_timeout}, @close_timeout)

    con = %C{
      con
      | status: :waiting_tcp_close,
        remote_stop_code_reason: {code, reason},
        adapter_state: adapter_state,
        timer: {close_timeout, :close_timeout}
    }

    do_events(con, rest ++ new_events)
  end

  # tcp close
  def do_events(%C{status: :waiting_tcp_close} = con, [:tcp_close | _rest]) do
    {timer, :close_timeout} = con.timer
    :ok = cancel_timer(timer, :close_timeout, con.ref)
    %C{con | status: :closed, timer: nil}
  end

  # close timeout
  def do_events(%C{} = con, [:close_timeout | rest])
      when con.status in [:local_closing, :waiting_tcp_close] do
    # {timer, :close_timeout} = con.timer
    # false = Process.cancel_timer(timer)
    {adapter_state, new_events} = con.adapter.abort(con.adapter_state)

    con = %C{con | status: :waiting_tcp_close, adapter_state: adapter_state}
    do_events(con, rest ++ new_events)
  end

  # unexpected tcp close
  def do_events(%C{} = con, [:tcp_close | _rest])
      when con.status == :handshaking
      when elem(con.status, 0) == :open
      when con.status == :local_closing do
    {timer, timer_type} = con.timer
    :ok = cancel_timer(timer, timer_type, con.ref)

    %C{con | status: :closed, timer: nil}
  end

  defp cancel_timer(timer, timer_msg, ref) when is_reference(ref) do
    case Process.cancel_timer(timer) do
      false ->
        receive do
          {^ref, ^timer_msg} -> :ok
        after
          0 -> raise "No timer or its message"
        end

      _ ->
        :ok
    end
  end

  defp process_callback_result(result, connection, rest) do
    case result do
      {:ok, callback_state, replies} ->
        connection = %C{connection | callback_state: callback_state}
        {connection, new_events} = do_replies(connection, replies)
        do_events(connection, rest ++ new_events)

      {{:stop, stop_code, stop_reason}, callback_state, replies} ->
        connection = %C{connection | callback_state: callback_state}
        {connection, new_events_1} = do_replies(connection, replies)
        {connection, new_events_2} = local_close(connection, stop_code, stop_reason)
        do_events(connection, rest ++ new_events_1 ++ new_events_2)
    end
  end

  defp local_close(%C{status: {:open, _}} = con, stop_code, stop_reason) do
    {adapter_state, new_events} =
      con.adapter.local_close(con.adapter_state, {stop_code, stop_reason})

    {timer, :ping_timer} = con.timer
    :ok = cancel_timer(timer, :ping_timer, con.ref)

    close_timeout = Process.send_after(self(), {con.ref, :close_timeout}, @close_timeout)

    {%C{
       con
       | status: :local_closing,
         adapter_state: adapter_state,
         timer: {close_timeout, :close_timeout}
     }, new_events}
  end

  defp local_close(%C{status: :remote_closing} = con, stop_code, stop_reason) do
    {adapter_state, new_events} =
      con.adapter.local_close(con.adapter_state, {stop_code, stop_reason})

    {%C{con | status: :waiting_tcp_close, adapter_state: adapter_state}, new_events}
  end

  defp local_close(%C{status: :handshaking} = con, _stop_code, _stop_reason) do
    {adapter_state, new_events} = con.adapter.abort(con.adapter_state)

    {timer, :handshake_timeout} = con.timer
    :ok = cancel_timer(timer, :handshake_timeout, con.ref)
    close_timeout = Process.send_after(self(), {con.ref, :close_timeout}, @close_timeout)

    {%C{
       con
       | status: :waiting_tcp_close,
         adapter_state: adapter_state,
         timer: {close_timeout, :close_timeout}
     }, new_events}
  end

  defp local_close(%C{status: status} = con, _stop_code, _stop_reason)
       when status in [:local_closing, :waiting_tcp_close] do
    {con, []}
  end

  defp do_replies(con, []), do: {con, []}

  defp do_replies(%C{status: {:open, _}} = con, [{type, data, ref} | rest])
       when is_msg_type(type) do
    case con.adapter.send(con.adapter_state, {type, data}) do
      {:ok, adapter_state, new_events} ->
        con = %C{con | adapter_state: adapter_state}
        sent_event = {:sent, ref}
        con = do_events(con, [sent_event])
        {con, events} = do_replies(con, rest)
        {con, new_events ++ events}

      {:error, adapter_state, new_events, reason} ->
        con = %C{con | adapter_state: adapter_state}
        sent_event = {:send_error, ref, reason}
        con = do_events(con, [sent_event])

        {con, events} = do_replies(con, rest)
        {con, new_events ++ events}
    end
  end
end
